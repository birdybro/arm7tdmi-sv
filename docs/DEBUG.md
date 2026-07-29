# Debug Subsystem Architecture

> **Audit status:** The subsystem remains partial overall. Halt-mode scan transport,
> debug-speed register/PSR transfer, staged system-speed access, and the bidirectional
> CP14 DCC have fail-hard directed coverage. Monitor-mode breakpoint/watchpoint
> aborts and CP14 Debug Abort Status coupling are also covered end to end. Exact
> debug-pin sampling, a synchronous FPGA debug-port wrapper, ETM closure, and the
> remaining release blockers are tracked in `TASKS.md` §31.6–§31.8.

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
                              │  (MCR/MRC p14, c1)
                              ▼
                        ┌──────────┐
                        │   core   │  (MCR p14 c1 → TX buffer)
                        └──────────┘  (MRC p14 c1 ← RX buffer)
```

The TAP runs on the system CLK gated by DBGTCKEN (off-chip TCK synchronizer deferred). The core runs on CLK gated by `CLKEN && !core_halt`. This means the TAP keeps cycling JTAG state while the core is frozen — exactly what a debugger needs.

## EmbeddedICE-RT register bank

32 register slots (5-bit scan addr), 32 bits each. Address map per TRM §5.14:

| Addr | Register | Width used | Notes |
|---|---|---|---|
| 0x00 | Debug Control | 6 bits | Bit 5 comparator disable; bit 4 monitor mode; bit 3 RAZ; bit 2 INTDIS; bit 1 force-DBGRQ; bit 0 force-DBGACK |
| 0x01 | Debug Status | 5 bits, read-only | Live state mux (see below) |
| 0x02 | Vector Catch | 8 bits | One bit per exception vector |
| 0x04 | DCC Control | 32 bits | Version `0111`, W/R ownership; also CP14 c0 |
| 0x05 | DCC Data | 32 bits | JTAG side of the separate CP14 c1 TX/RX buffers |
| 0x08-0x0F | WP0 (8 regs) | 32/9 bits | Addr/Data/Ctrl value+mask + 2 reserved |
| 0x10-0x17 | WP1 (8 regs) | same | |

### Debug Status live mux

Read of addr 0x01 returns a synthesized value, not the RAM slot:

```
[4] TBIT          = watch_tbit (= CPSR.T)
[3] TRANS[1]      = live core bus TRANS[1]
[2] IFEN          = ifen output (computed locally)
[1] DBGRQ         = synchronous external DBGRQ input
[0] DBGACKI       = internal debug-state acknowledge
```

Debug Control bit 0 can force the external `DBGACK` pin, but does not alter
Debug Status bit 0.

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
[7] RANGE           (WP0 input from WP1 RANGEOUT; zero for WP1)
[6] CHAIN           (WP0 input from WP1 CHAINOUT; zero for WP1)
[5] EXTERN          (DBGEXT[0] for WP0, DBGEXT[1] for WP1)
[4] nTRANS          (= aligned address-phase PROT[1])
[3] nOPC            (= aligned address-phase PROT[0])
[2:1] SIZE          (= aligned address-phase SIZE)
[0] nRW             (= aligned address-phase WRITE)
```

### CHAIN / RANGE coupling

WP1 feeds two signals to WP0:

- **RANGEOUT** (combinational) = the complete address, data, and control
  comparison, independent of the ENABLE bit. WP1's output is also the RANGE
  input to WP0. Both outputs remain observable on `DBGRNG[1:0]` when
  Debug Control bit 5 is clear, even when their ENABLE bits are clear.

- **CHAINOUT** (latched) — Write-enabled by WP1's address+control match; D-input is `wp1_data_match`. Cleared on (a) DBGnTRST, (b) any scan-chain-2 write to WP1's control-value register. The latch resets on programming changes so the debugger doesn't see false matches after reconfiguring (TRM §30.22.3).

An enabled WP0 event is its complete RANGEOUT comparison plus ENABLE. RANGE and
CHAIN are ordinary compared inputs in the control vector, fed respectively by
WP1's RANGEOUT and the CHAINOUT latch:

```
wp0_event = wp0_addr_match && wp0_data_match
          && masked_match(wp0_ctrl_value,
                          {wp1_rangeout, chainout_q, DBGEXT[0],
                           privilege, opcode/data, size, write},
                          wp0_ctrl_mask)
          && wp0_enable
```

WP1 has zero on its RANGE and CHAIN inputs and uses `DBGEXT[1]`.

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
                    ◀────────────────────
   ┌───────────┐                         ┌───────────┐
   │ RUNNING   │─────halt_entry_req─────▶│  HALTED   │
   └───────────┘                         └───────────┘
        │                                      │
        │ monitor breakpoint/watchpoint        │ scan-chain-1 instruction
        ▼                                      ▼
   generated PABT/DABT                 release until accepted/retired,
   (never enters HALTED)               then return to HALTED
```

`halt_entry_req` = any of (gated by DBGEN):
- an aligned data watchpoint from WP0/WP1 or external `DBGBREAK`
- `DBGRQI` = Run-Test/Idle-latched force-DBGRQ (ctrl[1]) OR synchronous
  external `DBGRQ`

WP0/WP1 or external opcode breakpoints do not use the generic request path:
they are carried as tags with the fetched instruction and stop only if that
instruction reaches Execute.

`tap_restart_req` is sampled on the edge that enters Run-Test/Idle with
IR=RESTART, matching TRM §5.13.5.

Debug Control bit 4 selects monitor policy. An enabled instruction breakpoint is
tagged with its fetched instruction and becomes a Prefetch Abort only if that
instruction reaches Execute. An enabled data watchpoint becomes a Data Abort on
the aligned transfer response. Neither path enters HALTED or asserts DBGACK.
`DbgAbt` is set only when the debug-generated abort wins exception selection;
a coincident external `ABORT` has priority and leaves `DbgAbt` clear.

The r4p3 monitor-mode restrictions are enforced fail-closed: a comparator
configured for a data-dependent match or RANGE/CHAIN coupling cannot generate a
monitor abort. `DBGEXT[0]` and `DBGEXT[1]` remain permitted address/control
qualifiers, as explicitly listed by TRM §5.9.2. External `DBGBREAK` is ignored
in monitor mode, and the implementation never combines monitor and halt policy.

`tb/integration/arm7tdmis_debug_monitor_mode_tb.sv` covers breakpoint PABT,
watchpoint DABT, coincident external instruction/data abort priority, CP14 c2,
and the absence of halt/DBGACK through public JTAG programming.
`tb/unit/ice_watchpoint_tb.sv` covers comparator disable, `DBGEXT`, and rejection
of data-dependent, RANGE, and CHAIN monitor configurations.

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

## Debug-input sampling

`DBGBREAK` is sampled on the rising edge with the address/control phase and
carried with that transaction. Opcode pulses become flushable pipeline tags;
data pulses remain pending through the marked instruction's completion boundary.
`tb/integration/arm7tdmis_debug_external_break_tb.sv` covers one-cycle opcode
and final-LDM-beat pulses, restart, completion ordering, and entry cause.

Appendix B defines the ARM7TDMI-S soft-core `DBGRQ` input as synchronous to
`CLK`; an integrator must synchronize an asynchronous board-level source before
driving it. Debug Control bit 1 passes through a latch that opens only in TAP
Run-Test/Idle, matching Figure 5-17 and §5.24.2. Debug Status bit 1 reports the
external synchronous input, while bit 0 reports internal `DBGACKI` rather than
the force-modified external pin. These distinctions are covered by
`tb/integration/arm7tdmis_debug_control_sync_tb.sv`.

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

The same internal data-bus adapter handles OpenOCD's PSR export primitive:
`MRS Rd,{CPSR|SPSR}`, `STR Rd,[r15]`, two NOPs, then a chain-1 capture.
The MRS and four-immediate MSR sequences execute in the core, while the exact
`STR Rd,[r15]` transfer is consumed by the adapter and never reaches external
memory. CPSR and the current-mode SPSR are written, read back, cross-isolation
checked, and bus-isolation checked in
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

A normal data watchpoint uses the same two `-12` corrections to identify the
instruction containing the watched access. The multibeat LDM regression proves
that r15 remains correct after every load and base writeback commits, before
the following instruction is allowed to execute:
`tb/integration/arm7tdmis_debug_watchpoint_completion_tb.sv`.

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

## CP14 DCC and Debug Abort Status

The internal CP14 register transfers use exact opcode-field matches:

- c0 is the read-only DCC control register. Bits `[31:28]` return the selected
  r4p3 EmbeddedICE-RT version (`0111` in the default profile), bit 1 is W
  (processor TX full), and bit 0 is R (host RX full).
- c1 is directional data: `MCR p14,0,Rd,c1,c0,0` fills the processor-to-host
  TX buffer; `MRC p14,0,Rd,c1,c0,0` returns and consumes the independent
  host-to-processor RX buffer.
- c2 is the one-bit Debug Abort Status register. Its storage, exact CP14
  decode, sticky set, software clear, and set-over-clear behavior are covered.
  Monitor-generated PABT/DABT events set it end to end; a coincident external
  abort wins and does not set it.

The JTAG view uses EmbeddedICE addresses 0x04 for control and 0x05 for data.
A chain-2 read of 0x05 returns the TX word and consumes W; a write to 0x05
deposits the RX word and sets R. In the rev-4 single-access response, address
bit 0 is replaced by W so the host receives data-valid status with the word.
Ordinary chain-2 response pipelining still applies: a request is committed at
Update-DR and shifted out by the following access.

Processor-side effects honor CLKEN while JTAG remains live. If a producer and
consumer act on the same edge, the newly produced word wins for that direction,
so it remains pending. `DBGCOMMTX` is high when TX is empty and `DBGCOMMRX` is
high when RX is full; DBGEN forces both pins low without changing buffered
state.

`tb/integration/arm7tdmis_cp14_dcc_tb.sv` verifies both public CP14/JTAG
directions, c0 through both interfaces, rev-4 response status, pin transitions,
CLKEN, and DBGEN gating with pending data. `tb/unit/dcc_tb.sv` verifies
independent storage, both simultaneous producer/consumer races, reset, and the
implemented c2 storage semantics. `tb/integration/arm7tdmis_cp14_decode_tb.sv`
verifies architectural c2 read/write decode, while the monitor-mode integration
test verifies its real event source and external-abort priority.

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
- `tb/unit/dcc_tb.sv` — Independent DCC ownership/races and Debug Abort Status storage.
- `tb/integration/arm7tdmis_cp14_dcc_tb.sv` — Public CP14/JTAG DCC round trip and pins.
