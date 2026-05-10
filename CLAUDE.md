# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project status

Greenfield. The repo contains planning + reference material plus the empty directory skeleton (`rtl/{core,decode,datapath,memory,coproc,debug,jtag,etm,top}/`, `tb/{unit,integration,formal,programs}/`, `docs/`, `scripts/`) — no RTL, testbench, scripts, or build system have been written yet. The first code task in any session is almost certainly to scaffold the first SystemVerilog files into one of those existing directories, not to create new top-level paths or modify existing sources.

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

No toolchain is wired up yet. When the first scripts land they will live in `scripts/`. Until then, do not invent commands — ask the user which simulator (Verilator, Questa, VCS, Xcelium, …) and which lint flow they want before writing a Makefile or `.f` file.

## Architectural conventions worth knowing up front

These are the non-obvious traps the TRM and TASKS.md flag — internalize them before writing execution logic:

- **Build verification before the CPU.** TASKS.md §2 deliberately puts the testbench, behavioral memory model, cycle logger, and reference-model path *before* the core. Don't skip ahead to RTL without the surrounding harness.
- **Two execution models, in sequence.** §7 builds a deliberately non-pipelined "known-good" core to validate architectural state; §16 *replaces* it with the real 3-stage Fetch/Decode/Execute pipeline. Cycle-accurate timing (§18) only makes sense after §16.
- **PC pipeline semantics.** In ARM state the executing instruction sees PC ahead of itself due to the pipeline; Thumb has its own offset rule. Any code that reads or writes PC must respect this — a write to PC also forces a pipeline flush + refill.
- **Conditional execution is universal in ARM state.** Every ARM instruction has a `cond[31:28]` field; condition-fail must suppress register writes, memory writes, and CPSR writes — but cycles still elapse and `DBGnEXEC` must be driven correctly. Thumb only has conditional branches.
- **Banked registers depend on mode.** 31 GPRs + 6 SPSRs across User/FIQ/IRQ/Supervisor/Abort/Undefined/System; FIQ banks r8–r14, the others bank only r13/r14. Register read/write mapping is mode-driven and must be implemented for every mode (§3).
- **Reset state is specific.** Supervisor mode, I=1, F=1, T=0, ARM state, PC=0x00000000 — set all of them, don't just clear PC.
- **Bus is pipelined.** Address-class signals (ADDR/WRITE/SIZE/PROT/LOCK) are broadcast one bus cycle *ahead* of the data cycle they describe. `CLKEN` gates bus progression; treat it as a wait-state mechanism, not a clock gate.
- **Hardest blocks per the roadmap:** PC/pipeline semantics, LDM/STM abort behavior, ARM↔Thumb interworking, cycle-accurate bus timing, and EmbeddedICE-RT + JTAG. Budget effort accordingly.
- **Reserved coprocessor IDs.** CP14 is the Debug Communications Channel; CP15 is system control. External coprocessors must not use those IDs.
- **TAP IDCODE.** Rev 4 r4p3 TAP ID register value is `0x7F1F0F0F` (§23).

## Working style for this repo

- When implementing a task from TASKS.md, cite the section number in commit messages so progress against the roadmap stays legible (e.g., `§5.1 barrel shifter: LSL/LSR/ASR/ROR + RRX`).
- Prefer extending the package enums over magic numbers — mode bits, TRANS encodings, SIZE encodings, and exception vectors are all enumerated in the TRM and should be named constants.
- Don't add CP15 / coprocessor / debug / ETM / scan features speculatively. Each has its own milestone (M6–M9) and depends on a stable core; landing them early just creates dead code that has to be re-validated later.
