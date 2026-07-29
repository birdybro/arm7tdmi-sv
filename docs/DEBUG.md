# Debug Subsystem Architecture

> **Audit status:** The current EmbeddedICE-RT/JTAG/DCC implementation is a partial
> scaffold. Monitor mode, conformant instruction injection, DCC semantics, and other
> release blockers are tracked in `TASKS.md` §31.6–§31.8.

EmbeddedICE-RT + JTAG TAP + CP14 DCC, as implemented in `rtl/debug/arm7tdmis_ice_rt.sv` and `rtl/jtag/arm7tdmis_jtag_tap.sv`. The TRM chapters are 5.13–5.27.

## Top-level data flow

```
                                                           ┌─────────────────┐
   External JTAG                                            │       core      │
       │                                                   │                 │
       ▼                                                   │   F → D → E     │
   ┌──────┐  scan       ┌────────────┐  scan-2 38-bit      │                 │
   │ TAP  │──chain──▶───│  ICE-RT    │◀─────────────────▶  │   regfile       │
   │      │  selector   │            │   register R/W      │   memory bus    │
   │ IR=N │             │  WP / VC   │                     │                 │
   │      │             │  regs[32]  │  core_halt          │                 │
   │      │             │            │──────────────────▶  │   CLKEN gate    │
   │      │             │  dbg FSM   │                     │                 │
   │      │             │  dbg_break │                     │                 │
   │      │ chain-1     │            │  dbg_inject_*       │                 │
   │      │ 33-bit ──▶  │  inject    │──────────────────▶  │   F-stage       │
   │      │             │  FSM       │                     │   fd_q override │
   └──────┘             └────────────┘                     └─────────────────┘
                              ▲
                              │
                              │  CP14 DCC data
                              │  (MCR/MRC p14, c0)
                              ▼
                        ┌──────────┐
                        │   core   │  (MCR p14 c0 → core_dcc_we)
                        └──────────┘  (MRC p14 c0 ← core_dcc_rdata)
```

The TAP runs on the system CLK gated by DBGTCKEN (off-chip TCK synchronizer deferred). The core runs on CLK gated by `CLKEN && !core_halt`. This means the TAP keeps cycling JTAG state while the core is frozen — exactly what a debugger needs.

## EmbeddedICE-RT register bank

32 register slots (5-bit scan addr), 32 bits each. Address map per TRM §5.14:

| Addr | Register | Width used | Notes |
|---|---|---|---|
| 0x00 | Debug Control | 6 bits | Bit 0 force-DBGACK; bit 1 force-DBGRQ; bit 2 INTDIS |
| 0x01 | Debug Status | 5 bits, read-only | Live state mux (see below) |
| 0x02 | Vector Catch | 8 bits | One bit per exception vector |
| 0x04 | DCC Data | 32 bits | Bidirectional, also CP14 c0 |
| 0x05 | DCC Control | 2 bits | W/R-available flags (not yet wired) |
| 0x08-0x0F | WP0 (8 regs) | 32/9 bits | Addr/Data/Ctrl value+mask + 2 reserved |
| 0x10-0x17 | WP1 (8 regs) | same | |

### Debug Status live mux

Read of addr 0x01 returns a synthesized value, not the RAM slot:

```
[4] TBIT          = watch_tbit (= CPSR.T)
[3] TRANS[1]      = watch_priv (= PROT[1], privileged-mode bit)
[2] IFEN          = ifen output (computed locally)
[1] DBGRQ synced  = dbg_rq_synced (2-flop sync chain)
[0] DBGACK        = dbg_ack output
```

## Watchpoint comparators

Two units (WP0 and WP1). Each has Addr/Data/Ctrl value+mask register pairs. Match logic per TRM §30.22.2 uses **XNOR-with-mask**, not AND-with-mask:

```
match[i] = (value[i] XNOR input[i]) OR mask[i]
full_match = all bits in match are 1
```

In code: `&((value ~^ input) | mask)`.

Mask bit = 1 means "this bit always matches" (don't-care); mask bit = 0 means exact equality required. Common implementation bug is to use AND — easy to miss because the polarity is inverted from what most masks do.

### 9-bit control compare

```
[8] ENABLE          (unmaskable — no corresponding mask bit)
[7] RANGE           (WP0 only — uses RANGEOUT from WP1)
[6] CHAIN           (WP0 only — uses CHAINOUT from WP1)
[5:4] EXTERN[1:0]   (DBGEXT pin compare)
[3] nTRANS          (placeholder; not yet wired)
[2] nOPC            (= 0 for opcode fetch, 1 for data)
[1] nRW             (= 0 for read, 1 for write)
[0] TBIT            (CPSR.T at the bus cycle)
```

### CHAIN / RANGE coupling

WP1 feeds two signals to WP0:

- **RANGEOUT** (combinational) = `wp1_addr_match && wp1_ctrl_match` — independent of `wp1_data_match` and `wp1_enable`. Used by WP0's RANGE bit to pair with WP1 for power-of-2 address ranges. Always observable on `DBGRNG[1]` (gated only by DBGEN, not ENABLE).

- **CHAINOUT** (latched) — Write-enabled by WP1's address+control match; D-input is `wp1_data_match`. Cleared on (a) DBGnTRST, (b) any scan-chain-2 write to WP1's control-value register. The latch resets on programming changes so the debugger doesn't see false matches after reconfiguring (TRM §30.22.3).

WP0 full match:
```
wp0_full_match = wp0_addr_match && wp0_data_match && wp0_ctrl_match
              && wp0_enable
              && (!wp0_chain_bit || chainout_q)
              && (!wp0_range_bit || rangeout)
```

WP1 has no upstream, so its full match is just `addr & data & ctrl & enable`.

## Vector Catch

Register addr 0x02, 8 bits, one bit per vector:

```
[0] reset    @ 0x00      [4] DABT     @ 0x10
[1] undef    @ 0x04      [5] reserved @ 0x14
[2] SWI      @ 0x08      [6] IRQ      @ 0x18
[3] PABT     @ 0x0C      [7] FIQ      @ 0x1C
```

Trap fires when `!watch_nopc` (opcode fetch) AND `watch_addr` matches one of the eight vector addresses AND the corresponding bit is set. ORs into `dbg_break_internal` alongside WP0/WP1 full matches.

## Debug-state FSM

```
            tap_restart_req
              ◀──────────────
   ┌───────────┐                ┌───────────┐
   │ RUNNING   │──halt_entry──▶│  HALTED   │
   └───────────┘  _req          └───────────┘
                                      │
                                      │ tap_inject_we
                                      ▼
                              (un-halt window, 8 CLK)
                                      │
                                      ▼
                              back to HALTED
```

`halt_entry_req` = any of (gated by DBGEN):
- `dbg_break_internal` (WP/VC hit)
- synced external `DBGBREAK` pin
- `DBGRQI` = force-DBGRQ (ctrl[1]) OR synced external `DBGRQ`

`tap_restart_req` is sampled on the edge that enters Run-Test/Idle with
IR=RESTART, matching TRM §5.13.5.

DBG_MONITOR (data-abort variant where the core takes an exception instead of halting) is stubbed — the wiring would overlap §17 DABT entry, deferred until that integration test lands.

## Output plumbing

Per TRM §30.22.6:

```
DBGACK_pin = DBGEN && (ctrl[0] OR DBGACKI)
IFEN       = !(DBGEN && (ctrl[2] OR DBGACKI))
```

Where `DBGACKI = (dbg_state_q == HALTED)`. IFEN gates IRQ/FIQ to the core at the top level:

```
nIRQ_eff = nIRQ | ~ifen     // ifen=0 → force HIGH (no interrupt)
nFIQ_eff = nFIQ | ~ifen
```

Per §5.19.2 IRQ/FIQ are forced disabled internally during debug-state regardless of CPSR.I/F — that's the `DBGACKI` term doing it.

## 2-flop synchronizers (CDC)

DBGRQ and DBGBREAK pins are asynchronous to CLK on real silicon. Each goes through a standard 2-flop chain inside ICE-RT with async DBGnTRST clear. The 2nd flop output is what the FSM and Debug Status Register see.

## JTAG TAP

Standard IEEE 1149.1 16-state controller in `rtl/jtag/arm7tdmis_jtag_tap.sv`. Notable wrinkles:

- Uses CLK with DBGTCKEN as enable (off-chip TCK synchronizer per §30.23.9 deferred).
- The top-level DBGEN gate freezes TCK/TMS/TDI, forces DBGTDO LOW, and forces
  DBGnTDOEN HIGH immediately while debug is disabled. DBGnTRST remains
  asynchronous and ungated.
- DBGnTRST resets the TAP to Test-Logic-Reset AND force-loads IR with IDCODE (IEEE §6.1).
- The default IDCODE is `0x7F1F0F0F` (TRM §5.14.2 for the historical
  r4p3 macrocell). `JTAG_VERSION`, `JTAG_PART_NUMBER`, and
  `JTAG_MANUFACTURER_ID` parameters on `arm7tdmis_top` and
  `arm7tdmis_chip` let a synthesized product publish its assigned identity.
  IEEE IDCODE bit 0 is always constructed as one and cannot be overridden.
  Integrators must not ship the ARM default as their own vendor identity
  unless they are implementing a compatibility-only internal simulation.

### IR opcodes (TRM §5.13)

```
SCAN_N   = 4'b0010   // select scan chain
RESTART  = 4'b0100   // exit debug state
INTEST   = 4'b1100   // access selected scan chain
IDCODE   = 4'b1110   // shift out IDCODE
BYPASS   = 4'b1111   // single-bit DR shift (default)
```

### Scan chains

- **Chain 0**: reserved, returns zeros.
- **Chain 1**: 33-bit logical value: `[32] DBGBREAK + [31:0] data`. Its
  physical path is TDI → DATA0…DATA31 → DBGBREAK → TDO, so DBGBREAK is the
  first captured bit shifted out and the first host bit shifted in when loading
  a complete value, followed by DATA31…DATA0.
- **Chain 2**: 38-bit logical value: `[37] R/W + [36:32] addr + [31:0] data`.
  Its physical path is TDI → R/W → ADDR4…ADDR0 → DATA0…DATA31 → TDO.

The test transport in `tb/integration/arm7tdmis_jtag_tb_pkg.sv` serializes these
physical cell orders explicitly; treating either chain as a packed LSB-first
vector reverses architecturally visible fields.

### Chain 2 R/W protocol

To write a register, serialize the logical `{R/W=1, addr[4:0], data[31:0]}`
using the chain-2 wire order above. Update-DR pulses `ice_scan_we` to the
ICE-RT, which writes the selected register.

To read a register, shift in a request with R/W=0. The read takes place at
Update-DR, as required by TRM §5.14.5/§5.20.1, and the response is repacked
into the physical scan cells. Chain 2 performs no Capture-DR action, so that
response remains intact and shifts out on the next pass.

### Scan chain 1 inject runtime

Capture-DR snapshots the core write-data bus into the 32 data cells. On debug
entry, the DBGBREAK cell reports the cause on its first capture: zero for an
opcode breakpoint and one for a data watchpoint. That cause latch is consumed
by the capture, so later captures return zero. The end-to-end regression is
`tb/integration/arm7tdmis_debug_entry_cause_tb.sv`.

When the TAP fires `tap_inject_we` (Update-DR with IR=INTEST + chain selector
= 1), the ICE-RT latches the instruction and holds `dbg_inject_we` until the
core acknowledges it. The core then remains released for the actual lifetime
of the instruction, including wait states and multicycle transfers. Its
explicit retirement pulse re-arms debug halt; there is no guessed timeout.

The core's F-stage handles the inject by overriding `fd_q`:

```systemverilog
if (dbg_inject_we) begin
    fd_q.instr  <= dbg_inject_instr;
    fd_q.pc     <= de_q.pc;        // placeholder
    fd_q.thumb  <= cpsr.t;
    fd_q.pabort <= 1'b0;
    fd_q.injected <= 1'b1;
    fd_q.valid  <= 1'b1;
end else if (latch_into_fd) ...
```

This bypasses the normal instruction-fetch RDATA latch. D decodes the injected
instruction and E executes it; memory data phases still use the external bus.
The accepted/retired handshake is covered with a 12-register LDM plus a
mid-transfer CLKEN stall in
`tb/integration/arm7tdmis_debug_inject_handshake_tb.sv`.

Debug-speed `LDMIA`/`STMIA` without writeback follows the ARM7TDMI scan-data
protocol used by OpenOCD: scan the block instruction, two pipeline NOPs, then
one word for each selected register in ascending register order. The transfer
uses an internal register-file debug port, honors the instruction's `S`
user-bank selection, and keeps the external bus idle. The public-pin round
trip for r0-r14 is verified by
`tb/integration/arm7tdmis_debug_register_scan_tb.sv`.

An STM capture of r15 includes the three-word advance contributed by the STM
and its two pipeline NOPs, even though the FPGA stream adapter consumes those
operations internally. Consequently, OpenOCD's ARM-state `-12` scan-pipeline
correction followed by its ARM7TDMI `-8` DBGRQ correction produces the next
architectural instruction address. A linear `MOV r0,pc` program verifies that
relationship without using an internal PC signal in
`tb/integration/arm7tdmis_debug_pc_capture_tb.sv`.

For an instruction breakpoint, ICE retains the pre-execute entry cause for the
whole halt session. The stream adapter adds the breakpoint's extra PC word as
well as the common three-word STM bias, so OpenOCD's two `-12` corrections
recover the exact breakpoint address. The same regression verifies both the
captured address and suppression of the breakpointed instruction.

Writing r15 through that stream also replaces the halted pipeline's fetch PC.
The address is halfword-aligned in Thumb state and word-aligned in ARM state;
all saved pre-debug fetch/decode state is discarded. The standard scan exit
sequence (four pipeline NOPs, a bit-33-marked NOP, the final branch, then
`RESTART`) therefore resumes from the scan-loaded address without exposing the
debug instructions on the external memory bus. This public-pin sequence is
fail-hard covered by `tb/integration/arm7tdmis_debug_pc_resume_tb.sv`.

For a system-speed access, bit 33 arms the *following* scan-chain word rather
than changing the speed of the word shifted beside it. The debugger scans
`NOP/0`, `NOP/1`, then the load or store with bit 33 low. That final
instruction remains staged until RESTART enters Run-Test/Idle. It then runs
under `CLKEN`, temporarily deasserts `DBGACK` unless Debug Control bit 0 forces
it, keeps interrupts masked, and automatically returns to debug halt when its
accepted/retired handshake completes. The first chain-1 capture after that
return reports bit 33 high. A stalled LDR exercises the complete sequence in
`tb/integration/arm7tdmis_debug_system_speed_tb.sv`.

Only ARM single-, block-, and extra-load/store encodings are admitted to this
at-speed path. A non-memory word following a bit-33-marked scan is the final
debug-exit PC-control marker; it is consumed while halted and does not arm
automatic debug re-entry.

## CP14 DCC data path

The Debug Communications Channel is an internal coprocessor (CP14 c0) per TRM §5.18. Code-side and debugger-side both read/write a single shared 32-bit register, which is ICE-RT register 0x04.

### Code → debugger (MCR p14, 0, Rd, c0, c0, 0)

Core writeback for the MCR routes `rf_rc_data` (= Rd's value via port C) into ICE-RT via `core_dcc_we`. ICE-RT writes `regs[0x04] := core_dcc_wdata`. Debugger reads via scan chain 2 at addr 0x04.

### Debugger → code (MRC p14, 0, Rd, c0, c0, 0)

ICE-RT exposes `regs[0x04]` continuously on `core_dcc_rdata`. Core's writeback mux's `cp14_mrc_dcc_fires` branch writes `regs[Rd] := core_dcc_rdata`.

### Simultaneous-write resolution

Both the scan chain 2 path (`scan_we`) and the core's `core_dcc_we` path can write to `regs[0x04]`. The ICE-RT's always_ff prioritizes scan (debugger arbitrates timing per the TRM protocol; we resolve deterministically rather than fault).

## Forbidden pin clarifications (TRM §30.0)

Several pin names that *sound* like they should exist on ARM7TDMI-S r4p3 do not:

- **`DBGRESTART`**: not real. RESTART is a JTAG IR opcode (4'b0100), not a pin.
- **`DBGINSTR`**: not real. `DBGINSTRVALID` is the actual ETM-facing valid signal.
- **`MAS[1:0]`**: not real on r4p3. Earlier ARM7s had it; r4p3 calls the same field `SIZE[1:0]`.

Don't add them.

## Files

- `rtl/debug/arm7tdmis_ice_rt.sv` — EmbeddedICE-RT macrocell (register bank + comparators + debug FSM + inject FSM + sync chains).
- `rtl/jtag/arm7tdmis_jtag_tap.sv` — JTAG TAP controller + scan chain shift registers.
- `rtl/arm7tdmis_debug_pkg.sv` — IR opcodes, IDCODE value, debug state enum, scan chain widths.
- `tb/unit/ice_rt_tb.sv` — Watchpoint match + scan chain 2 R/W unit test.
- `tb/unit/jtag_tap_tb.sv` — IDCODE shift-out + BYPASS IR-load unit test.
