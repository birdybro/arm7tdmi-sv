# arm7tdmi-sv

A from-scratch SystemVerilog reimplementation of the **ARM7TDMI-S r4p3** processor, built to the publicly-available ARM technical reference manual (`ARM_DDI_0234B_ARM7TDMI-S_r4p3_TRM.pdf`, included in this repo).

The goal is a **cycle-accurate, synthesizable** ARMv4T core suitable for FPGA bring-up on Intel Cyclone V, with the full r4p3 debug architecture (EmbeddedICE-RT + JTAG TAP) and ETM-facing instrumentation.

---

## Status at a glance

**Not sign-off ready and not currently drop-in for MiSTer.** A 2026-07-28
source/test/specification audit found architectural defects and major unimplemented
integration work. [`TASKS.md` §31](TASKS.md#31-release-readiness-audit-and-immutable-sign-off-contract)
is the canonical status and release gate.

| Area | Audited status |
|---|---|
| ARM/Thumb RTL | **Partial** — directed tests cover all Thumb formats and numerous ARM edge fixes; exhaustive encoding/state coverage remains |
| Exceptions/aborts | **Partial** — directed tests cover priority, ARM/Thumb LR values, DABT+FIQ, SWP, and per-beat LDM/STM abort behavior; full closure remains |
| Bus/cycle/endian | **Partial** — little/big-endian lanes, fetch history, stalls, and selected burst/abort cases are tested; complete pin-level cycle closure remains |
| Coprocessor/CP14/CP15 | **Partial** — directed tests cover external ready/busy/data transfers, absent internal CP15, conformant c0/c1 DCC ownership, and monitor-generated c2 `DbgAbt`; remaining CP closure is tracked in §31.6 |
| EmbeddedICE-RT/JTAG/ETM | **Partial** — halt-mode and monitor-mode paths have directed coverage; exact pin sampling, FPGA transport synchronization, ETM, and debugger interoperability remain |
| Verification | **Partial** — registered benches fail hard and the smoke regression passes; exhaustive, differential, coverage, formal, and release closure are absent |
| FPGA/MiSTer | **Missing** — no valid completed SDC, Quartus result, wrapper/package, MiSTer build, or PocketStation integration |

---

## Implemented RTL paths (not sign-off claims)

The inventories below describe intended or present RTL paths at the audited baseline.
They do not mean the full encoding space or edge behavior is verified. Known defects and
the evidence required to promote a path to VERIFIED are listed in `TASKS.md` §31.

### ARM instructions (ARMv4T)

| Class | Coverage |
|---|---|
| Data-processing (16 opcodes) | Immediate/register and shifter paths exist; flag and r15 edge behavior is incomplete |
| Multiply | Paths for MUL, MLA, UMULL, UMLAL, SMULL, SMLAL and m-cycle control exist |
| Branch | B, BL, and BX paths exist |
| Load/Store | Broad LDR/STR byte/word addressing paths exist; the full encoding/alias space is unverified |
| Halfword / signed L/S | Broad LDRH/STRH/LDRSH/LDRSB paths exist |
| Block transfer | LDM/STM paths include IA/IB/DA/DB, writeback, user-bank, and PC-list cases; abort behavior is wrong |
| Swap | SWP/SWPB paths and LOCK output exist; atomic/abort/endian closure is missing |
| PSR transfer | MRS/MSR register/immediate and field-mask paths exist; privilege/reserved-bit handling is incomplete |
| Software interrupt | An SWI entry path exists |
| Coprocessor | Decode classes and pins exist; accepted-operation and busy/data protocols do not |

The RTL contains condition-code handling for ARM instructions, but complete side-effect
suppression and exact failed-condition bus/debug behavior are not yet proven.

### Thumb instruction decoder paths

| Fmt | Operation | Path status |
|---|---|---|
| 1 | MOV shifted register | Present, unverified |
| 2 | ADD/SUB register/imm3 | Present, unverified |
| 3 | MOV/CMP/ADD/SUB imm8 | Present, unverified |
| 4 | ALU register-register (16 sub-ops) | Present, unverified |
| 5 | Hi-register ADD / CMP / MOV / BX | Present, unverified |
| 6 | PC-relative LDR | Present, unverified |
| 7 | LDR/STR register offset | Present, unverified |
| 8 | LDR/STR sign-extended byte/halfword | Present, unverified |
| 9 | LDR/STR imm offset (byte/word) | Present, unverified |
| 10 | LDRH/STRH imm offset | Present, unverified |
| 11 | SP-relative LDR/STR | Present, unverified |
| 12 | Load address (SP-form AND PC-form) | Present, unverified |
| 13 | SP add/sub imm7 | Present, unverified |
| 14 | PUSH / POP | Present, unverified |
| 15 | LDMIA / STMIA | Present, unverified |
| 16 | Conditional branch | Present, unverified |
| 17 | SWI | Present, unverified |
| 18 | Unconditional branch | Present, unverified |
| 19 | Long BL (2-halfword prefix + suffix) | Present, unverified |

Most formats do not yet have exhaustive or even directed integration coverage.

### Exceptions

RTL entry paths exist for all seven exception types, but they are not TRM-correct yet.
The required priority is Reset > DABT > FIQ > IRQ > PABT > UNDEF > SWI; the current
simultaneous-event logic, saved LR values, and abort handling have known defects.

- **Reset** (vector 0x00): synchronous deassertion of `nRESET`, sets Supervisor mode, I=F=1, T=0, PC=0
- **UNDEF** (0x04): unknown opcode, NV condition, unaccepted coprocessor op
- **SWI** (0x08): software interrupt, banks Supervisor
- **PABT** (0x0C): ABORT sampled during a fetch — propagates via `fd_q.pabort` through the pipeline, fires when the aborted instruction reaches E
- **DABT** (0x10): an entry path exists, but current LDM/STM base-writeback and
  post-abort destination suppression conflict with the r4p3 TRM
- **IRQ** (0x18): nIRQ pin, gated by CPSR.I
- **FIQ** (0x1C): nFIQ pin, gated by CPSR.F; banks r8–r14

Paths for `MOVS PC, LR` and `LDM ^` with PC are present; return-to-Thumb, alignment,
saved-LR, mode, and refill edge cases still require verification and fixes.

### Pipeline structure and current cycle harness

The RTL has a 3-stage F/D/E structure with a 12-state E-stage substate FSM. The current
cycle bench measures E-state durations for 26 selected instructions; it does not verify
the complete external bus waveform and therefore is not cycle-conformance evidence.
The table records current harness expectations:

| Instruction | E cycles | Current bench's claimed mapping (not conformance) |
|---|---|---|
| DP imm / shift-by-imm / MOV / MVN | 1 | 7-3: 1S |
| DP shift-by-register | 2 | 7-3: 1S+1I |
| MRS / MSR | 1 | 7-3: 1S |
| Branch (B / BL / BX) | 3 (incl. 2-cycle refill) | 7-5: 2S+1N |
| LDR / LDRB / LDRH / LDRSH / LDRSB | 3 | 7-7: 1S+1N+1I |
| STR / STRB / STRH | 2 | 7-9: 1S+1N |
| LDM, n regs | n+2 | 7-12: 1S+(n-1)S+1N+1I |
| STM, n regs | n+1 | 7-15: 1S+(n-1)S+1N |
| SWP / SWPB | 4 | 7-17: 1S+2N+1I |
| MUL | 1+m | 7-19: 1S+mI |
| MLA | 2+m | 7-19: 1S+(m+1)I |
| UMULL / SMULL | 2+m | 7-21: 1S+(m+1)I |
| UMLAL / SMLAL | 3+m | 7-23: 1S+(m+2)I |

`m` is the multiplier early-termination parameter from Rs (1–4 per TRM §7.7).

Current, unverified cycle-shape choices include folding STM writeback into the final
`S_BLOCK_DATA` beat, a branch `early_flush_fetch` path, and `S_LOAD_WB` for loads.
`TASKS.md` §31 requires these to be re-derived against both the Chapter 7 summary and
each detailed pin-level table.

See [docs/PIPELINE.md](docs/PIPELINE.md) for the detailed FSM, bus-overlap reasoning, and the `de_q` staleness latch protocol.

### Debug architecture

- **EmbeddedICE-RT (partial)** (`rtl/debug/arm7tdmis_ice_rt.sv`): aligned
  breakpoint/watchpoint comparators, halt/restart, debug-speed register and PSR
  transfer, staged system-speed access, monitor-generated PABT/DABT, and external
  abort precedence have directed tests. The remaining §31.7 cases are still open.
- **JTAG TAP (partial)** (`rtl/jtag/arm7tdmis_jtag_tap.sv`): all 16 TAP
  transitions, public/default instructions, SCAN_N, and the physical chain-1/2
  wire orders are fail-hard tested. Chain-1 entry causes, debug-speed transfers,
  scan-loaded resume, and staged bit-33 system-speed access have public-pin tests;
  the explicitly same-CLK FPGA transport is protocol-tested. An asynchronous
  pod needs a separate CDC bridge, and real-debugger integration remains open.
- **ETM-facing instrumentation**: `DBGnEXEC` and `DBGINSTRVALID` exist, but their full
  commit semantics and the external ETM contract are unverified.

See [docs/DEBUG.md](docs/DEBUG.md).

### Coprocessor handshake

- **CP14:** c0 control and independent c1 RX/TX buffers implement W/R ownership,
  rev-4 chain-2 status, CLKEN, DBGEN-gated pins, and producer/consumer races. c2
  storage/decode, monitor-generated `DbgAbt`, and external-abort priority are covered.
- **CP15:** there is no fabricated internal p15. An unclaimed p15 access traps
  Undefined; a system coprocessor can claim it through the external interface.
- **External coprocessors:** directed tests cover pipeline-follow signals,
  privilege, ready/busy/absent handshakes, MCR/MRC/CDP, variable LDC/STC,
  aborts, and interrupt/DBGRQ abandonment. §31.6 remains the sign-off ledger.

---

## Known gaps

This table is only a short summary. Some gaps are correctness bugs, not optional
features; the complete backlog is `TASKS.md` §31.

| Gap | Why | Re-enable when |
|---|---|---|
| **Quartus place-and-route** | Toolchain not installed on the build box. RTL is written to Cyclone V conventions (ALM logic, MLAB/M10K BRAM inference, DSP for `*`); SDC first pass exists. | `§26` FPGA bring-up. |
| Correct exception, abort, endian, and bus timing | Release-blocking functional work. | Implement and verify §31.3–§31.5. |
| MiSTer/PocketStation integration | No wrapper, package, build, or reference boot exists. | Implement and verify §31.9. |
| Formal/differential/coverage closure | Required sign-off evidence is absent. | Implement and verify §31.10. |

ARMv4T features that don't exist in r4p3 are also not implemented (and explicitly forbidden in TASKS.md §30.0): `BKPT`, `BLX`, `CLZ`, the Q flag, the `MAS[1:0]` bus pins (it's `SIZE[1:0]` here), `DBGRESTART`, separate `DBGINSTR` (only `DBGINSTRVALID` is real). Software breakpoints work via EmbeddedICE-RT pattern matching.

---

## Repository layout

```
rtl/
  arm7tdmis_{bus,debug,instr,psr,types}_pkg.sv   shared SV packages (enums, types)
  core/        arm7tdmis_core_pipelined.sv (the 3-stage pipelined core)
               arm7tdmis_psr.sv             (CPSR / SPSR register file)
               arm7tdmis_reset_sync.sv      (nRESET synchronizer)
  datapath/    arm7tdmis_alu.sv, arm7tdmis_shifter.sv,
               arm7tdmis_multiplier.sv, arm7tdmis_regfile.sv
  decode/      arm7tdmis_decoder.sv         (ARM)
               arm7tdmis_thumb_decoder.sv   (Thumb, formats 1-19)
               arm7tdmis_condition.sv       (16 ARM condition codes)
  debug/       arm7tdmis_ice_rt.sv          (EmbeddedICE-RT macrocell)
  jtag/        arm7tdmis_jtag_tap.sv        (IEEE 1149.1 TAP + scan chains)
               arm7tdmis_sync_debug_port.sv (same-CLK FPGA debug transport)
  top/         arm7tdmis_top.sv             (pin-level integration)
               arm7tdmis_chip.sv            (chip wrapper with DFT pins)

tb/
  unit/        per-module SystemVerilog testbenches (10 tests)
  integration/ 15 `make integ` benches plus a separate `make run` smoke bench
  programs/    hand-encoded .hex test programs

docs/
  PIPELINE.md, DEBUG.md, MULTIPLY.md, EXCEPTIONS.md, README.md

scripts/      Makefile, sim.f / tb.f filelists, arm7tdmis.sdc

ARM_DDI_0234B_ARM7TDMI-S_r4p3_TRM.pdf   authoritative spec
TASKS.md      implementation roadmap (29 sections, 10 milestones)
AGENTS.md      guidance for GPT/Codex and other coding agents
```

---

## Build / run

Requires **Verilator 5.x** (uses `--binary --trace-fst`) and optionally **GTKWave** for viewing waveforms.

```sh
cd scripts

make lint            # Verilator --lint-only -Wall on the RTL filelist
make lint-tb         # same, including the integration TB top

make sim             # build the smoke integration testbench
make run             # build + run smoke → cycle.csv + waves.fst
make wave            # open waves.fst in GTKWave

make unit            # run every registered unit test
make unit-<name>     # run one (e.g. make unit-shifter)

make integ           # run every registered integration test
make integ-<name>    # run one (e.g. make integ-cycles)

make clean
```

The registered benches now terminate nonzero on failed checks, and the current smoke
test passes. A successful directed regression is still not sign-off by itself:
`TASKS.md` §31.10 requires independent differential, coverage, formal, and release
evidence.

---

## Current test inventory

**Unit tests** (`tb/unit/`):

| Test | Current exercised scope |
|---|---|
| `regfile_tb` | 31×32 bank with mode-driven r13/r14/r8–12 routing |
| `psr_tb` | CPSR / SPSR writes with field mask, mode transitions |
| `reset_sync_tb` | synchronous nRESET deassertion |
| `shifter_tb` | LSL / LSR / ASR / ROR / RRX with all amount edges |
| `alu_tb` | all 16 DP opcodes + flag updates |
| `multiplier_tb` | unsigned / signed / accumulate; m-parameter cycle count |
| `condition_tb` | all 16 ARM condition codes against flag inputs |
| `decoder_tb` | ARM decode tables (instruction-class dispatch) |
| `jtag_tap_tb` | exhaustive TAP transitions, instructions, scan selectors/order, update atomicity, BYPASS, and default IDCODE |
| `ice_rt_tb` | fail-hard EmbeddedICE register/watchpoint primitives |

**Integration tests** (`tb/integration/`):

| Test | Current exercised scope |
|---|---|
| smoke (`make run`) | fail-hard broad mixed-instruction path |
| `cycles` | internal E-duration checks for 26 selected instructions; not pin-level cycle conformance |
| `umull` / `umlal` | 64-bit multiply with high-half writeback |
| `cp15_undef` | Bare-core p15 access with no external claimant enters Undefined |
| `cp14_dcc` | Public CP14/JTAG bidirectional c0/c1 DCC ownership, rev-4 status, pins, CLKEN, and DBGEN gating |
| `debug_reserved_regs` | public-JTAG RAZ/WI checks for every reserved EmbeddedICE-RT address |
| `debug_dbgen_sources` | Complete core-facing DBGEN disable matrix across requests, comparators, monitor mode, outputs, and IRQ/FIQ pass-through |
| `debug_inject_matrix` | All §5.16.1 debug-speed classes with one-accept/one-retire checks and pre-response CLKEN stalls |
| `abort` | DABT during LDR — Rd preserved, vector entry |
| `pabt` | PABT propagation via `fd_q.pabort` |
| `ldm_abort` | Per-beat load suppression, base writeback/restoration, and r15 protection |
| `ldm_pc` | LDM with PC in list + `^` — CPSR restored from SPSR |
| `irq` / `fiq` | nIRQ / nFIQ pin → exception entry, banked r14 |
| `swi` | SWI #imm → Supervisor mode, r14_svc, vector 0x08 |
| `undef` | CDP p7 (unaccepted CP) → UNDEF, r14_und, vector 0x04 |
| `thumb` | ARM→Thumb via BX; Thumb fmt3/4 ALU + fmt19 BL + fmt5 hi-reg + fmt12 PC-form |

---

## Documentation

- [`docs/PIPELINE.md`](docs/PIPELINE.md) — 3-stage F/D/E pipeline, 12-state E substate FSM, bus-cycle overlap, `issue_fetch` gate, `de_q` staleness latch protocol, branch fast-path flush.
- [`docs/DEBUG.md`](docs/DEBUG.md) — EmbeddedICE-RT (r4p3 register map, WP comparators, CHAIN/RANGE, debug-state FSM), JTAG TAP (16 states, IDCODE, scan chains 1+2), scan-chain-1 instruction-injection runtime, CP14 DCC data flow.
- [`docs/COPROCESSOR.md`](docs/COPROCESSOR.md) — bare-core ownership, exact CP14 decode, external CPA/CPB and pipeline-following contract, transfers, abandonment, and corrected r4p3 errata 14/15 policy.
- [`docs/MULTIPLY.md`](docs/MULTIPLY.md) — MUL/MLA/UMULL/UMLAL/SMULL/SMLAL, m-parameter cycle shaping, UMLAL/SMLAL 2-cycle accumulator read across S_EXEC + S_MULL_ACC.
- [`docs/EXCEPTIONS.md`](docs/EXCEPTIONS.md) — all 7 exception types, priority encoder, banked r14, SPSR save, `data_abort_now` vs `data_abort_q` for single-vs-multi-beat memory ops, LDM DABT restart, the two exception-return patterns.

The authoritative spec is **`ARM_DDI_0234B_ARM7TDMI-S_r4p3_TRM.pdf`** at the repo root.
The implementation and release ledger is **[`TASKS.md`](TASKS.md)**. Section 31 is the
canonical audited status and immutable v1.0 sign-off contract.

---

## License

See [`LICENSE`](LICENSE).

This repo includes the publicly-distributable ARM7TDMI-S r4p3 Technical Reference Manual (ARM DDI 0234B) for reference — that document remains under its original ARM copyright.
