# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

Sections §1–§26 substantially complete. Current head implements a working 3-stage Fetch/Decode/Execute pipelined ARM7TDMI-S core (`rtl/core/arm7tdmis_core_pipelined.sv`) with full ARM + Thumb decode coverage; branch/BL/BX; all addressing modes for LDR/STR/LDM/STM/SWP including LDM ^ user-bank (with and without PC-in-list / CPSR-from-SPSR); MUL/MLA/UMULL/SMULL/UMLAL/SMLAL with m-parameter cycle accuracy; ARM↔Thumb interworking; exception entry for SWI/UNDEF/IRQ/FIQ/PABT/DABT with ABORT sampling, writeback suppression, and LDM DABT restart-safety (Rn deferred to S_BLOCK_WB); coprocessor handshake outputs with UNDEF trap for unaccepted instructions; CP14 DCC data transfer; CP15 Main ID Register read; JTAG TAP with IDCODE, scan chain 2 (ICE-RT register R/W) and scan chain 1 (instruction injection — fully wired to core F-stage); EmbeddedICE-RT with WP0/WP1 XNOR+mask comparators, CHAIN/RANGE coupling, Vector Catch, Debug Status, debug-state FSM (HALTED + RESTART), DBGACK + IFEN plumbing, 2-flop DBGRQ/DBGBREAK synchronizers; ETM-facing DBGnEXEC/DBGINSTRVALID; arm7tdmis_chip wrapper with DFT pins; first-pass Cyclone V SDC. §18 bus-cycle overlap eliminated S_DADDR/S_BLOCK_ADDR/S_SWP_RADDR/S_SWP_WADDR — LDR/STR=3 cycles, SWP=4, LDM/STM n=n+1 (TRM-aligned).

Integration test coverage: smoke (§7-§15) + 11 directed tests (UMULL, UMLAL, CP15 Main ID, CP14 DCC round-trip, Vector Catch, DABT for LDR, IRQ, FIQ, LDM-^-PC CPSR restore, PABT, LDM DABT restart). 10 unit tests. All green.

What's left: Quartus FPGA bring-up (out-of-RTL work — toolchain install + part selection + place-and-route iteration); §27 expansion (Thumb BL specifically, scan-chain-1 end-to-end JTAG sequence, more edge cases); §28-§29 milestone checklists; possibly an ARM cross-assembler integration to replace hand-encoded .hex files.

## Authoritative sources

- **`TASKS.md`** — the implementation roadmap. 29 sections, organized as a build-order plan with 10 milestones (M1 minimal ARM core → M10 signoff). Treat it as the source of truth for *what to build next* and *in what order*. Do not reorder milestones casually: each one assumes the prior one works (e.g., the 3-stage pipeline in §16 explicitly *replaces* the simple non-pipelined model from §7).
- **`ARM_DDI_0234B_ARM7TDMI-S_r4p3_TRM.pdf`** — the ARM Technical Reference Manual for ARM7TDMI-S r4p3. This is the architectural spec the implementation must match. TASKS.md cites it heavily ("the TRM states…", "Chapter 7 says…"); when a task references TRM behavior, read the cited section before implementing rather than going from memory. Particularly load-bearing chapters: Ch. 7 (instruction cycle timings), Figure 1-3 (datapath block diagram), the exception/vector tables, and the EmbeddedICE-RT + JTAG TAP chapters.

## Planned repository layout

TASKS.md §1 fixes the directory structure. Use it when creating new files — do not invent alternative locations:

```
rtl/{core,decode,datapath,memory,coproc,debug,jtag,etm,top}/
tb/{unit,integration,formal,programs}/
docs/
scripts/
```

Common SystemVerilog packages live at the `rtl/` root: `arm7tdmis_types_pkg.sv`, `arm7tdmis_instr_pkg.sv`, `arm7tdmis_psr_pkg.sv`, `arm7tdmis_bus_pkg.sv`, `arm7tdmis_debug_pkg.sv`. Shared enums (ARM/Thumb state, processor modes, exception types, ALU/shift ops, TRANS cycle types, etc.) belong in these packages, not redefined per module.

## Top-level pin list

The `arm7tdmis_top` port list is fixed by the TRM and enumerated in TASKS.md §1.4 (CLK/CLKEN/nRESET, ADDR/WRITE/SIZE/PROT/LOCK/TRANS/WDATA/RDATA/ABORT, the CPxxx coprocessor handshake group, the DBGxxx debug + JTAG group, DMORE). Match those names exactly — downstream tests, the ETM-facing wrapper (§24), and the scan wrapper (§25) all assume these signal names.

## Build / lint / test

Toolchain: **Verilator 5.x** for simulation and `verilator --lint-only -Wall` for lint. **GTKWave** for waveforms (Verilator emits FST via `--trace-fst`). No commercial simulator; no Yosys/SymbiYosys yet (defer until §27 formal work). No Quartus on the build box yet — FPGA bring-up (§26) will install it. ARM cross-assembler (`arm-none-eabi-binutils`) is **not** installed; install before §27 instruction tests, not before. Build scripts and `.f` filelists live in `scripts/`; commit-message convention `§N.M description …` per the working-style note below.

Reference-model strategy for §2 cross-checking is **hand-written TRM-derived expected state per test** — no QEMU/Unicorn cosim. Each unit/instruction test embeds the expected register/CPSR/memory state derived directly from the TRM; failures point at the spec, not at a foreign model's quirks.

## RTL coding discipline (load-bearing — read before writing any `.sv`)

The `rtl/` tree must be **synthesizable SystemVerilog that describes parallel hardware**, not software written in HDL syntax. Most "make it work" shortcuts that are fine in C are either wrong or produce grotesque hardware here. The TRM's behavior is already inherently parallel (3-stage pipeline, pipelined bus where address leads data by one cycle, latched watchpoint comparators, scan-chain shift registers clocked independently of `CLK`); the RTL must reflect that parallelism *directly* — do not collapse it into a sequential FSM "for simplicity."

- **Describe hardware, don't program it.** Every `always_ff` is a register bank that updates on a clock edge; every `always_comb` is a cone of combinational logic that must settle within one clock period. Think *"what happens each cycle, in parallel"*, not *"what steps run in order."* If a block reads like an algorithm with sequential steps, refactor — the synthesizer cannot infer the hardware you actually want.
- **Synthesizable subset only.** No `initial` blocks outside testbenches, no `#delay`, no `wait`, no real numbers, no dynamic arrays, no `class`/`new`, no recursion, no `fork…join`. `assert`/`assume`/`cover` belong inside `// pragma translate_off` regions or formal-only files.
- **No `/` or `%` operators, period — with one exception.** A bare `/` or `%` against a non-power-of-two operand infers a multi-cycle worth of combinational divider logic; the synth tool will either explode the area or quietly insert a vendor IP block. The only acceptable form is power-of-two division/modulus by a *constant*, and even then prefer the explicit bit-level form: use `x >> N` instead of `x / (1<<N)` and `x[N-1:0]` instead of `x % (1<<N)`. It's clearer about the hardware and avoids tool-dependent inference.
- **`*` is fine and should infer DSP.** A bare `*` on reasonable widths maps to Cyclone V variable-precision DSP blocks. The ARM 32×8 multiplier (§5.3) should infer to one or a few DSP blocks; do not hand-roll an array multiplier unless cycle-accurate modeling of multiplier early-termination (§30.5.1) forces it — and even then, isolate the cycle-shaping logic from the arithmetic so the DSP path stays inferable.
- **Use block RAM for anything wide-and-deep.** When a structure is large enough that mapping it to ALM registers would be wasteful (register file 31×32, instruction prefetch buffer, scan-chain-2 38-bit shift, trace FIFOs in the ETM-facing wrapper), write a standard inferable RAM idiom (synchronous write, synchronous or 1-cycle-latency read; one write port; one or two read ports) and let the tool map to **MLAB** (≈640-bit, distributed, fast — good for small/fast structures like the register file) or **M10K** (10 Kbit, dual-port — good for buffers/FIFOs). Multi-read-port structures may need replication or a LUT-register fallback; choose deliberately, don't accept whatever the tool happens to pick.
- **Don't instantiate vendor primitives directly.** No `altsyncram`, no `LCELL`, no Quartus-only attributes baked into RTL. Keep the source portable across simulators and synth tools; rely on inference, and constrain via SDC/QSF rather than RTL pragmas where possible. Vendor wrappers, if absolutely needed, live in `rtl/top/` behind a thin shim.
- **Initial FPGA target: Intel/Altera Cyclone V.** Concretely: ALM-based logic (fracturable 6-LUT pairs, two registers per ALM), MLAB + M10K BRAM only (no UltraRAM-class memories, no LUTRAM-as-distributed-RAM feature parity with Xilinx), variable-precision DSP blocks (9×9, 18×19, 27×27, MAC). Prefer constructs that map cleanly to those primitives. Be especially careful with: (a) wide register files needing many simultaneous read ports — replication into MLAB is usually right; (b) reset style — Cyclone V flops have only async clear, so heavy synchronous-reset usage burns LUTs gating the D-input. Match the TRM's reset semantics first, then optimize.
- **Reset and clocking.** Synchronous deassertion of `nRESET` at the macrocell boundary is required by the TRM (§4 / §30.4); inside the core, prefer synchronous reset on data paths and use async-reset only where the TRM mandates it (`DBGnTRST` per §30.23.7). `CLKEN` is a wait-state mechanism on the bus, not a clock gate — never gate `CLK` with it; sample it as an enable on the relevant `always_ff`.

## Architectural conventions worth knowing up front

These are the non-obvious traps the TRM and TASKS.md flag — internalize them before writing execution logic:

- **Build verification before the CPU.** TASKS.md §2 deliberately puts the testbench, behavioral memory model, cycle logger, and reference-model path *before* the core. Don't skip ahead to RTL without the surrounding harness.
- **Pipeline structure.** §16 landed: F (continuous prefetch via `fetch_pc_q` + `inflight_pc_q` + F→D register), D (combinational decode through `arm7tdmis_decoder` / `arm7tdmis_thumb_decoder` muxed on the latched T-bit, D→E register), and E (single S_EXEC cycle plus the existing 10-state memory/multiply substate FSM as substates). Flush triggers (branch, BX, exception, DP-to-PC, LDR-to-PC, LDM-with-PC) invalidate F and D and redirect `fetch_pc_q`. The non-obvious-but-load-bearing trick: F's `issue_fetch` is gated by `state_next == S_EXEC` to avoid speculatively prefetching the cycle E enters a multi-cycle substate (else the result arrives during a cycle F can't latch and the instruction is lost). Cycle-accurate timing (§18) refines from here.
- **PC pipeline semantics.** In ARM state the executing instruction sees PC ahead of itself due to the pipeline; Thumb has its own offset rule. Any code that reads or writes PC must respect this — a write to PC also forces a pipeline flush + refill.
- **Conditional execution is universal in ARM state.** Every ARM instruction has a `cond[31:28]` field; condition-fail must suppress register writes, memory writes, and CPSR writes — but cycles still elapse and `DBGnEXEC` must be driven correctly. Thumb only has conditional branches.
- **Banked registers depend on mode.** 31 GPRs + 6 SPSRs across User/FIQ/IRQ/Supervisor/Abort/Undefined/System; FIQ banks r8–r14, the others bank only r13/r14. Register read/write mapping is mode-driven and must be implemented for every mode (§3).
- **Reset state is specific.** Supervisor mode, I=1, F=1, T=0, ARM state, PC=0x00000000 — set all of them, don't just clear PC.
- **Bus is pipelined.** Address-class signals (ADDR/WRITE/SIZE/PROT/LOCK) are broadcast one bus cycle *ahead* of the data cycle they describe. `CLKEN` gates bus progression; treat it as a wait-state mechanism, not a clock gate.
- **Hardest blocks per the roadmap:** PC/pipeline semantics, LDM/STM abort behavior, ARM↔Thumb interworking, cycle-accurate bus timing, and EmbeddedICE-RT + JTAG. Budget effort accordingly.
- **Reserved coprocessor IDs.** CP14 is the Debug Communications Channel; CP15 is system control. External coprocessors must not use those IDs.
- **TAP IDCODE.** Rev 4 r4p3 TAP ID register value is `0x7F1F0F0F` (§23).
- **Don't invent v5+ features or hard-macrocell pins.** ARMv4T does not have `BKPT`, `BLX`, `CLZ`, or the Q flag; r4p3 does not have `MAS[1:0]` (it's `SIZE[1:0]`), `DBGRESTART`, or `DBGINSTR` (`DBGINSTRVALID` is the real, distinct signal). Software breakpoints use EmbeddedICE-RT pattern matching, not a `BKPT` opcode. Full list of forbidden additions is in TASKS.md §30.0.

## Working style for this repo

- When implementing a task from TASKS.md, cite the section number in commit messages so progress against the roadmap stays legible (e.g., `§5.1 barrel shifter: LSL/LSR/ASR/ROR + RRX`).
- Prefer extending the package enums over magic numbers — mode bits, TRANS encodings, SIZE encodings, and exception vectors are all enumerated in the TRM and should be named constants.
- Don't add CP15 / coprocessor / debug / ETM / scan features speculatively. Each has its own milestone (M6–M9) and depends on a stable core; landing them early just creates dead code that has to be re-validated later.
