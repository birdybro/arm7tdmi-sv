# Coprocessor Integration Contract

This document freezes the bare-core coprocessor behavior used for the v1.0
release gate. The architectural source is the ARM7TDMI-S r4p3 TRM, especially
chapters 4 and 7. `TASKS.md` §31 remains the audited status ledger.

## Bare-core ownership

The core contains only the ARM7TDMI-S CP14 debug registers described below.
It does not contain CP15. Any CDP, MCR, MRC, LDC, or STC addressed to another
coprocessor is offered on the external coprocessor interface. If no external
coprocessor claims the instruction (`CPA=1`, `CPB=1`), the instruction enters
Undefined. A system that needs CP15 must implement and claim it outside the
bare core.

Only ARMv4T coprocessor instruction rows are offered. In particular,
`bits[27:23]=11000` with `bit[21]=0` is the later MCRR/MRRC extension space;
it decodes directly as Undefined and never asserts `CPnI`, regardless of
`CPA/CPB`.

Internal CP14 accepts only these exact ARM-state register-transfer encodings:

- `MRC p14,0,Rd,c0,c0,0`: read DCC control.
- `MRC p14,0,Rd,c1,c0,0`: processor reads the DCC receive word.
- `MCR p14,0,Rd,c1,c0,0`: processor writes the DCC transmit word.
- `MRC p14,0,Rd,c2,c0,0`: read sticky Debug Abort Status.
- `MCR p14,0,Rd,c2,c0,0`: clear Debug Abort Status.

Other CP14 encodings enter Undefined rather than aliasing one of those
registers. DCC ownership and JTAG behavior are documented in
[DEBUG.md](DEBUG.md).

## Pipeline-following pins

The external interface is the raw ARM7TDMI-S coprocessor interface:

| Signal | Contract |
|---|---|
| `CPnMREQ` | Low for an active N or S memory request. |
| `CPSEQ` | High for an S or C cycle; low for N or I. |
| `CPnTRANS` | Low in User mode and high in privileged modes. It is not a code/data indication. |
| `CPnOPC` | Low for opcode fetches and high for data/internal cycles. |
| `CPTBIT` | Current instruction-set state (`CPSR.T`). |
| `CPnI` | Low while an executing external coprocessor instruction is being offered or busy-waited. |

An attached coprocessor follows the previous/current `CPnMREQ`, `CPnOPC`, and
`CPTBIT` values as specified by TRM §4.3. `CLKEN=0` freezes both the processor
pipeline and this observation boundary; the attached coprocessor must not
advance its follower on a stalled clock.

## Claim and completion protocol

`CPA` and `CPB` are sampled only for the active external instruction:

| `CPA` | `CPB` | Meaning |
|---:|---:|---|
| 1 | 1 | Absent: take Undefined. |
| 0 | 0 | Present and ready: accept or complete the current phase. |
| 0 | 1 | Present but busy: hold an idempotent wait until ready or abandoned. |

The reserved `CPA=1`, `CPB=0` combination is not an acceptance state.
Condition-failed and flushed coprocessor instructions are not offered.

CDP completes after acceptance with the specified N/C/I sequence. MCR drives
the ARM register value on `WDATA` during its data phase; MRC samples the
coprocessor value from `RDATA` and applies the architectural r15 special case.
LDC and STC repeat word data phases while the coprocessor requests more words,
drive `CPSEQ` for continuation phases, use ARM Addressing Mode 5 for address
and writeback, and terminate when the coprocessor presents the final
high/high phase. The project selects the Base Updated abort model: requested
base writeback remains visible, no failed store reaches memory, and Data Abort
is taken after the coprocessor terminates the transfer.

An unmasked IRQ or FIQ, or a halt-mode DBGRQ, can abandon an indefinitely busy
instruction. The core raises `CPnI` while the busy indication is still
visible, performs no ghost completion, and preserves restart state. Busy
cycles are idempotent so abandonment cannot expose a partial architectural
commit.

## r4p3 errata policy

The FPGA profile implements architecturally corrected behavior and deliberately
does not provide real-silicon-defect compatibility parameters for errata 14 or
15:

- Erratum 14: `P=0,U=1,W=0` LDC/LDCL/STC/STCL forms execute. The option byte is
  ignored by ARM, the first address is `Rn`, and `Rn` is not written back.
- Erratum 15: each consecutive MRC with opcode1 matching `x1x` executes and
  receives its own data, including when the coprocessor asserts `CPA/CPB`
  early.

## Executable evidence

The public regressions are:

- Decode and ownership:
  `decoder_tb`, `reserved_decode_tb`, `arm7tdmis_reserved_execute_tb`,
  `arm7tdmis_cp15_undef_tb`,
  `arm7tdmis_cp14_decode_tb`, and `arm7tdmis_cp14_r15_tb`.
- Pipeline and privilege:
  `arm7tdmis_cpntrans_tb` and `arm7tdmis_cp_pipeline_follow_tb`.
- CDP and register transfer:
  `arm7tdmis_cp_cdp_protocol_tb`, `arm7tdmis_cp_reg_transfer_tb`, and
  `arm7tdmis_cp_reg_r15_tb`.
- Load/store, abort, and abandonment:
  `arm7tdmis_cp_ldc_stc_tb`, `arm7tdmis_cp_ldc_stc_abort_tb`,
  `arm7tdmis_cp_busy_interrupt_tb`, and `arm7tdmis_cp_busy_dbgrq_tb`.
- Corrected errata:
  `arm7tdmis_cp_erratum14_tb` and `arm7tdmis_cp_erratum15_tb`.

All integration tests are individually runnable as
`make -C scripts integ-<test-name-without-arm7tdmis-prefix-or-tb-suffix>`.
