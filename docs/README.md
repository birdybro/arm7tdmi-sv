# Architecture Documentation

Design docs for the load-bearing subsystems. Each doc focuses on the non-obvious decisions and the traps caught the hard way; the RTL itself is the source of truth for behavior.

## Documents

- **[PIPELINE.md](PIPELINE.md)** — 3-stage F/D/E pipeline structure, stage registers, bus-cycle overlap in the E substate FSM, the `issue_fetch` `state_next` gate (one of the load-bearing decisions of the whole design), `de_q` staleness traps and the latch protocol.

- **[DEBUG.md](DEBUG.md)** — EmbeddedICE-RT macrocell (register bank, WP comparators with TRM-correct XNOR+mask shape, CHAIN/RANGE coupling, Vector Catch, debug-state FSM), JTAG TAP (16-state controller, IDCODE, scan chains 1+2), scan-chain-1 instruction-injection runtime path, CP14 DCC data flow.

- **[MULTIPLY.md](MULTIPLY.md)** — Multiply forms (MUL/MLA/UMULL/SMULL/UMLAL/SMLAL), m-parameter cycle shaping, the UMLAL/SMLAL 2-cycle accumulator read across S_EXEC + S_MULL_ACC and the latches that make it work.

- **[EXCEPTIONS.md](EXCEPTIONS.md)** — All seven exception types (Reset/UNDEF/SWI/PABT/DABT/IRQ/FIQ), priority ordering, the per-exception detection signals, banked r14 writeback, SPSR save mechanism, the `data_abort_now` vs `data_abort_q` trick for single-vs-multi-beat memory ops, LDM DABT restart-safety, and the two exception-return patterns (`MOVS PC, LR` and `LDM ^ with PC`).

## Reading order

If you've never seen this codebase: PIPELINE → EXCEPTIONS → MULTIPLY → DEBUG. Each builds on the previous one's vocabulary.

If you're debugging a specific area: jump to the relevant doc; they're independent.

If you're modifying RTL: the docs are *not* exhaustive — they capture the load-bearing ideas. The packages in `rtl/*.sv` (instr / types / bus / debug / psr) have authoritative field definitions; the per-module headers explain that module's contract.

## TRM cross-references

The ARM ARM7TDMI-S r4p3 TRM (`ARM_DDI_0234B_ARM7TDMI-S_r4p3_TRM.pdf` at the repo root) is the architectural spec. Citations throughout the docs use chapter / section numbers (e.g., TRM §5.20.2 for the watchpoint XNOR+mask shape). When in doubt, the TRM wins.

`TASKS.md` is the implementation roadmap and contains a `§30` addendum that catches several real-world traps the TRM glosses over.
