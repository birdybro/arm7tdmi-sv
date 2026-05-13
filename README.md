# arm7tdmi-sv

A from-scratch SystemVerilog reimplementation of the **ARM7TDMI-S r4p3** processor, built to the publicly-available ARM technical reference manual (`ARM_DDI_0234B_ARM7TDMI-S_r4p3_TRM.pdf`, included in this repo).

The goal is a **cycle-accurate, synthesizable** ARMv4T core suitable for FPGA bring-up on Intel Cyclone V, with the full r4p3 debug architecture (EmbeddedICE-RT + JTAG TAP) and ETM-facing instrumentation.

---

## Status at a glance

| Area | Status |
|---|---|
| ARM ISA decode + execute | **Complete** — all 15 instruction classes, all 16 DP opcodes, all addressing modes |
| Thumb ISA decode + execute | **Complete** — all 19 formats |
| ARM ↔ Thumb interworking | **Complete** — BX both directions, Thumb BL, T-bit pipeline-aware fetch |
| Exception handling | **Complete** — all 7 types (Reset / UNDEF / SWI / PABT / DABT / IRQ / FIQ), priority encoder, abort restart safety |
| 3-stage F / D / E pipeline | **Complete** — bus-cycle overlap, branch fast-path flush, 12-state E substate FSM |
| Cycle accuracy vs TRM Ch. 7 | **Verified** end-to-end across 26 instructions (Tables 7-3 through 7-23) |
| Pipelined memory bus | **Complete** — ADDR/WRITE/SIZE/PROT/LOCK/TRANS/WDATA/RDATA, CLKEN wait-states, byte/halfword/word + endianness |
| Multiplier (MUL/MLA/UMULL/UMLAL/SMULL/SMLAL) | **Complete** — m-parameter early termination, accumulate forms |
| Coprocessor handshake (pins) | **Complete** — CPnMREQ/CPSEQ/CPnTRANS/CPnOPC/CPTBIT/CPnI/CPA/CPB |
| Internal CPs (CP14 DCC, CP15 Main ID) | **Complete** |
| External CP data transfer (LDC/STC body) | **Not implemented** — pins traps to UNDEF when no CP accepts (correct standalone behavior) |
| EmbeddedICE-RT macrocell | **Complete** — WP0/WP1 (XNOR+mask, CHAIN/RANGE), Vector Catch, debug-state FSM, DBGACK / IFEN / DBGRQ |
| JTAG TAP | **Complete** — 16-state controller, IDCODE `0x7F1F0F0F`, scan chain 1 (instruction injection), scan chain 2 (ICE-RT R/W) |
| ETM-facing signals | **Complete** — DBGnEXEC, DBGINSTRVALID, plus pipeline-follow shadows |
| DFT / scan wrapper | **Complete** — `arm7tdmis_chip` with DFT pins |
| Cyclone V SDC | **First pass** — clock domains, IO timing |
| Quartus place-and-route | **Not yet** — toolchain not installed, planned for §26 bring-up |
| Formal verification (SymbiYosys) | **Deferred** to §27 |
| Verification harness | **Complete** — Verilator 5.x, 10 unit tests, 15 integration tests, cycle-accuracy harness |

---

## What's implemented

### ARM instructions (ARMv4T)

| Class | Coverage |
|---|---|
| Data-processing (16 opcodes: AND/EOR/SUB/RSB/ADD/ADC/SBC/RSC/TST/TEQ/CMP/CMN/ORR/MOV/BIC/MVN) | imm, shift-by-imm, shift-by-register; all four shifts (LSL/LSR/ASR/ROR + RRX); S-bit flag updates |
| Multiply | MUL, MLA, UMULL, UMLAL, SMULL, SMLAL; cycle-accurate m-parameter early termination |
| Branch | B, BL, BX (including ARM→Thumb) |
| Load/Store | LDR / STR / LDRB / STRB; all U/P/W combinations (imm offset, register offset with shift, pre/post indexed, writeback) |
| Halfword / signed L/S | LDRH / STRH / LDRSH / LDRSB; imm and register offset forms |
| Block transfer | LDM / STM; all addressing modes (IA/IB/DA/DB), writeback, S-bit (user-bank with `^`), PC in list with CPSR restore from SPSR |
| Swap | SWP, SWPB; locked read-modify-write |
| PSR transfer | MRS, MSR (both register and immediate forms, field-masked) |
| Software interrupt | SWI (vector 0x08, banks Supervisor) |
| Coprocessor | CDP / MCR / MRC / LDC / STC — handshake pins driven; UNDEF if no CP accepts |

All instructions support all 16 condition codes; condition-fail correctly suppresses writes while still consuming the cycle and driving `DBGnEXEC`.

### Thumb instructions (all 19 formats)

| Fmt | Operation | Status |
|---|---|---|
| 1 | MOV shifted register | ✅ |
| 2 | ADD/SUB register/imm3 | ✅ |
| 3 | MOV/CMP/ADD/SUB imm8 | ✅ |
| 4 | ALU register-register (16 sub-ops) | ✅ |
| 5 | Hi-register ADD / CMP / MOV / BX | ✅ |
| 6 | PC-relative LDR | ✅ |
| 7 | LDR/STR register offset | ✅ |
| 8 | LDR/STR sign-extended byte/halfword | ✅ |
| 9 | LDR/STR imm offset (byte/word) | ✅ |
| 10 | LDRH/STRH imm offset | ✅ |
| 11 | SP-relative LDR/STR | ✅ |
| 12 | Load address (SP-form AND PC-form) | ✅ |
| 13 | SP add/sub imm7 | ✅ |
| 14 | PUSH / POP | ✅ |
| 15 | LDMIA / STMIA | ✅ |
| 16 | Conditional branch | ✅ |
| 17 | SWI | ✅ |
| 18 | Unconditional branch | ✅ |
| 19 | Long BL (2-halfword prefix + suffix) | ✅ |

### Exceptions

All seven r4p3 exception types implemented with TRM-correct priority (Reset > DABT > FIQ > IRQ > PABT > UNDEF/SWI):

- **Reset** (vector 0x00): synchronous deassertion of `nRESET`, sets Supervisor mode, I=F=1, T=0, PC=0
- **UNDEF** (0x04): unknown opcode, NV condition, unaccepted coprocessor op
- **SWI** (0x08): software interrupt, banks Supervisor
- **PABT** (0x0C): ABORT sampled during a fetch — propagates via `fd_q.pabort` through the pipeline, fires when the aborted instruction reaches E
- **DABT** (0x10): ABORT during a data access; suppresses register writeback; LDM/STM restart-safety (Rn deferred to `S_BLOCK_WB`)
- **IRQ** (0x18): nIRQ pin, gated by CPSR.I
- **FIQ** (0x1C): nFIQ pin, gated by CPSR.F; banks r8–r14

Both exception-return patterns work: `MOVS PC, LR` (restores CPSR from SPSR) and `LDM ^ with PC in list`.

### Pipeline & cycle accuracy

3-stage F/D/E pipeline with a 12-state E-stage substate FSM. Cycle counts verified end-to-end against TRM Tables 7-3 through 7-23 by `tb/integration/arm7tdmis_cycles_tb.sv`:

| Instruction | E cycles | TRM |
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

Key cycle-shape decisions:
- **STM has no I cycle** — Rn writeback folded into the last `S_BLOCK_DATA` beat (TRM gives STM `n+1` cycles vs LDM's `n+2`).
- **Branch fast-path flush** — the `early_flush_fetch` signal hijacks ADDR=flush_target_pc with TRANS=N on the cycle the branch resolves, saving a 1-cycle refill bubble.
- **LDR/LDRB/LDRH needs S_LOAD_WB** — the TRM I cycle is the regfile-commit cycle, not the data-read cycle.

See [docs/PIPELINE.md](docs/PIPELINE.md) for the detailed FSM, bus-overlap reasoning, and the `de_q` staleness latch protocol.

### Debug architecture

- **EmbeddedICE-RT macrocell** (`rtl/debug/arm7tdmis_ice_rt.sv`): WP0/WP1 watchpoint comparators with TRM-correct XNOR+mask shape, CHAIN/RANGE coupling, Vector Catch register, Debug Status register, debug-state FSM (HALTED + RESTART), DBGACK / IFEN plumbing, 2-flop DBGRQ/DBGBREAK synchronizers.
- **JTAG TAP** (`rtl/jtag/arm7tdmis_jtag_tap.sv`): full 16-state IEEE 1149.1 controller, IDCODE register `0x7F1F0F0F` (r4p3-specific), scan chain 2 (38-bit ICE-RT register R/W), scan chain 1 (33-bit instruction injection, wired into the core F-stage for runtime instruction forcing).
- **ETM-facing instrumentation**: `DBGnEXEC`, `DBGINSTRVALID`, plus shadows of the bus-cycle type signals so an ETM7 can reconstruct the pipeline.

See [docs/DEBUG.md](docs/DEBUG.md).

### Coprocessor handshake

- **CP14 DCC** (Debug Communications Channel): internal, integrated with the JTAG TAP for host↔target data exchange.
- **CP15 c0 Main ID Register** read: returns `0x41429243` (ARM Ltd / variant 4 / ARMv4T / part 0x924 / revision 3) per TRM §4.1.
- **External coprocessors** (any other CP number): the core drives `CPnMREQ/CPSEQ/CPnTRANS/CPnOPC/CPTBIT/CPnI` so an external CP can shadow the pipeline, and samples `CPA/CPB` for the accept/busy handshake. If `CPA=1` (no acceptor) at execute time, the core traps to UNDEF — TRM-correct standalone behavior.

---

## What's not implemented

These are intentional gaps for the current scope, not bugs:

| Gap | Why | Re-enable when |
|---|---|---|
| External coprocessor **data transfer body** for LDC/STC/CDP/MCR/MRC (anything except CP14 DCC + CP15 c0) | r4p3 standalone with no CP attached → UNDEF is the correct TRM behavior. The handshake pins (CPA/CPB) are exported. | A real coprocessor (FPU, MMU) is wired up in a downstream design. |
| **Coprocessor busy-wait loop** (stall on `CPB=1`) | Same — no external CP to stall on. | Same as above. |
| **Quartus place-and-route** | Toolchain not installed on the build box. RTL is written to Cyclone V conventions (ALM logic, MLAB/M10K BRAM inference, DSP for `*`); SDC first pass exists. | `§26` FPGA bring-up. |
| **Formal verification** (SymbiYosys properties) | Deferred per TASKS.md §27. | After M9 — when the RTL is feature-stable. |
| **ARM cross-assembler integration** | Hand-encoded `.hex` test programs work today and keep dependencies minimal. | When the test suite expands enough that assembly-by-hand becomes a bottleneck (install `arm-none-eabi-binutils`). |

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
  top/         arm7tdmis_top.sv             (pin-level integration)
               arm7tdmis_chip.sv            (chip wrapper with DFT pins)

tb/
  unit/        per-module SystemVerilog testbenches (10 tests)
  integration/ full-core directed tests + smoke (15 tests)
  programs/    hand-encoded .hex test programs

docs/
  PIPELINE.md, DEBUG.md, MULTIPLY.md, EXCEPTIONS.md, README.md

scripts/      Makefile, sim.f / tb.f filelists, arm7tdmis.sdc

ARM_DDI_0234B_ARM7TDMI-S_r4p3_TRM.pdf   authoritative spec
TASKS.md      implementation roadmap (29 sections, 10 milestones)
CLAUDE.md     guidance for AI agents working in this repo
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

make unit            # run every unit test (10 tests)
make unit-<name>     # run one (e.g. make unit-shifter)

make integ           # run every integration test (15 tests)
make integ-<name>    # run one (e.g. make integ-cycles)

make clean
```

All targets exit 0 on green; failures print `FAIL` lines and a non-zero exit.

---

## Test coverage

**Unit tests** (`tb/unit/`):

| Test | Verifies |
|---|---|
| `regfile_tb` | 31×32 bank with mode-driven r13/r14/r8–12 routing |
| `psr_tb` | CPSR / SPSR writes with field mask, mode transitions |
| `reset_sync_tb` | synchronous nRESET deassertion |
| `shifter_tb` | LSL / LSR / ASR / ROR / RRX with all amount edges |
| `alu_tb` | all 16 DP opcodes + flag updates |
| `multiplier_tb` | unsigned / signed / accumulate; m-parameter cycle count |
| `condition_tb` | all 16 ARM condition codes against flag inputs |
| `decoder_tb` | ARM decode tables (instruction-class dispatch) |
| `jtag_tap_tb` | 16-state TAP controller + BYPASS / IDCODE |
| `ice_rt_tb` | watchpoint XNOR+mask, Vector Catch, debug-state FSM |

**Integration tests** (`tb/integration/`):

| Test | What it exercises |
|---|---|
| smoke (`make run`) | basic boot + MOV/ADD/STR/LDR sequence |
| `cycles` | 26 instructions across every cycle-shape class vs TRM Ch. 7 |
| `umull` / `umlal` | 64-bit multiply with high-half writeback |
| `cp15_main_id` | MRC p15, c0, c0 returns `0x41429243` |
| `cp14_dcc` | DCC round-trip via MCR/MRC p14, c0, c0 |
| `vector_catch` | EmbeddedICE-RT vector-catch register traps fetch |
| `abort` | DABT during LDR — Rd preserved, vector entry |
| `pabt` | PABT propagation via `fd_q.pabort` |
| `ldm_abort` | LDM DABT restart-safety (Rn deferred to S_BLOCK_WB) |
| `ldm_pc` | LDM with PC in list + `^` — CPSR restored from SPSR |
| `irq` / `fiq` | nIRQ / nFIQ pin → exception entry, banked r14 |
| `swi` | SWI #imm → Supervisor mode, r14_svc, vector 0x08 |
| `undef` | CDP p7 (unaccepted CP) → UNDEF, r14_und, vector 0x04 |
| `thumb` | ARM→Thumb via BX; Thumb fmt3/4 ALU + fmt19 BL + fmt5 hi-reg + fmt12 PC-form |

---

## Documentation

- [`docs/PIPELINE.md`](docs/PIPELINE.md) — 3-stage F/D/E pipeline, 12-state E substate FSM, bus-cycle overlap, `issue_fetch` gate, `de_q` staleness latch protocol, branch fast-path flush.
- [`docs/DEBUG.md`](docs/DEBUG.md) — EmbeddedICE-RT (registers, WP comparators, CHAIN/RANGE, Vector Catch, debug-state FSM), JTAG TAP (16 states, IDCODE, scan chains 1+2), scan-chain-1 instruction-injection runtime, CP14 DCC data flow.
- [`docs/MULTIPLY.md`](docs/MULTIPLY.md) — MUL/MLA/UMULL/UMLAL/SMULL/SMLAL, m-parameter cycle shaping, UMLAL/SMLAL 2-cycle accumulator read across S_EXEC + S_MULL_ACC.
- [`docs/EXCEPTIONS.md`](docs/EXCEPTIONS.md) — all 7 exception types, priority encoder, banked r14, SPSR save, `data_abort_now` vs `data_abort_q` for single-vs-multi-beat memory ops, LDM DABT restart, the two exception-return patterns.

The authoritative spec is **`ARM_DDI_0234B_ARM7TDMI-S_r4p3_TRM.pdf`** at the repo root.
The implementation roadmap is **[`TASKS.md`](TASKS.md)** — 29 sections, 10 milestones, plus the §30 addendum that catches real-world traps the TRM glosses over.

---

## License

See [`LICENSE`](LICENSE).

This repo includes the publicly-distributable ARM7TDMI-S r4p3 Technical Reference Manual (ARM DDI 0234B) for reference — that document remains under its original ARM copyright.
