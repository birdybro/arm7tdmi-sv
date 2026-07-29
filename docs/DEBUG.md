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

`tap_restart_req` pulses when TAP latches IR=RESTART at Update-IR.

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
- DBGnTRST resets the TAP to Test-Logic-Reset AND force-loads IR with IDCODE (IEEE §6.1).
- IDCODE = `0x7F1F0F0F` (TRM §5.14.2 for r4p3).

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
- **Chain 1**: 33-bit. `[32] DBGBREAK control cell + [31:0] instruction`. Used for instruction injection during debug state.
- **Chain 2**: 38-bit. `[37] R/W + [36:32] addr + [31:0] data`. EmbeddedICE-RT register R/W.

DR shift register is sized to 38 bits to hold chain 2. Smaller chains use the low bits.

### Chain 2 R/W protocol

To write a register: shift in `{R/W=1, addr[4:0], data[31:0]}`. Update-DR pulses `ice_scan_we` to the ICE-RT, which writes `regs[addr] := data`.

To read a register: shift in `{R/W=0, target_addr, X*32}`. Update-DR latches nothing. On the next pass, Capture-DR loads the shift register with `{6'h0, regs[target_addr]}`. Shift-DR shifts the value out.

The address-then-read pattern relies on `dr_shift_q[36:32]` (the addr field) being whatever was last shifted in — between passes it stays at the previously-shifted target address.

### Scan chain 1 inject runtime

When the TAP fires `tap_inject_we` (Update-DR with IR=INTEST + chain selector = 1), the ICE-RT:

1. Latches the instruction into `inject_instr_q`.
2. Arms an 8-CLK un-halt window (`inject_phase_q := 8`).
3. While the window is open, drops `core_halt` so the core processes the injected instruction.
4. First cycle of the window pulses `dbg_inject_we` to the core.

The core's F-stage handles the inject by overriding `fd_q`:

```systemverilog
if (dbg_inject_we) begin
    fd_q.instr  <= dbg_inject_instr;
    fd_q.pc     <= de_q.pc;        // placeholder
    fd_q.thumb  <= cpsr.t;
    fd_q.pabort <= 1'b0;
    fd_q.valid  <= 1'b1;
end else if (latch_into_fd) ...
```

This bypasses the normal RDATA latch — no bus fetch happens during the un-halt window. D decodes the injected instruction, E executes it. Single-port regfile, single bus → the architecturally-allowed debug-state instructions per TRM §5.16.1 (DP, all L/S including LDM/STM, MSR/MRS) all work through this path.

8 CLK is sized for the worst single-instruction completion (LDM-type or SWP with the §18 bus-overlap refactor). A more rigorous version would watch `state_q` for retirement and end the window precisely; the current shape relies on the debugger pacing chain-1 writes per TRM §5.16 anyway.

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
