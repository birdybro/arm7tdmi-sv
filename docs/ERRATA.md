# ARM7TDMI-S Errata Policy

This is the normative disposition of all 15 entries in Arm
`FR002-PRDC-002719 7.0` for the corrected-default soft core. It is not a
real-silicon defect-compatibility profile.

## Source provenance

The reviewed source is Arm's
[ARM7TDMI-S Errata List](https://documentation-service.arm.com/static/5ed62dc5ca06a95ce53f9214),
document `FR002-PRDC-002719 7.0`, issued 20 March 2009:

| Item | Value |
|---|---|
| Downloaded PDF length | 409,457 bytes |
| PDF SHA-256 | `8da116eacb963149fcd67d1e3b85435118aebbb4d94766092043e8ad43f910d7` |
| Review date | 2026-07-29 |
| Referenced r4p3 TRM SHA-256 | `bb9cd0e3f2b7e2fdca4ff961cdfc5c9c85c063842e491f8997a504d3241baa14` |

The errata PDF is not copied into this repository because its own copyright
notice restricts reproduction. The official URL, exact byte length, and hash
freeze the reviewed input without asserting redistribution rights. The TRM is
the existing `ARM_DDI_0234B_ARM7TDMI-S_r4p3_TRM.pdf` at repository root.

## Release policy

The sole supported policy is the architecturally corrected result:

- defects corrected by Arm before r4p3 remain corrected;
- defects still present in real r4p3 are corrected in this implementation;
- no synthesis parameter reproduces any of the 15 defects;
- the raw `arm7tdmis_top` contract treats `DBGRQ` as synchronous to `CLK`;
  asynchronous sources must use the synchronizer in `arm7tdmi_mister` or an
  equivalent adapter; and
- the repository provides no Arm EIS logger or Thumb disassembler. Erratum 10
  is therefore not applicable to either synthesized RTL or simulation
  support. The external ETM7 signal path is separately verified.

Adding defect emulation would create a new compatibility profile, parameter,
tests for both settings, and a versioned documentation change. It is not an
implicit interpretation of r4p3 compatibility.

## Complete matrix

Each row below paraphrases the full triggering conditions reviewed in the
official notice. Test names are Make integration names; run the complete set
with `make -C scripts errata`.

| No. | r4p3 status | Corrected project behavior and full-condition evidence |
|---:|---|---|
| 1 | Corrected before r4p3 | A single comparator still reports the refetched target of an ARM branch to PC+8, a Thumb branch to PC+4, and the branch-adjacent soft-opcode pattern. Two consecutive halts restart exactly. `debug_consecutive_breakpoints`. |
| 2 | Corrected | ARM-to-Thumb and Thumb-to-Thumb PC changes use both BX and their applicable ALU-to-PC form, each followed by an Undefined-looking second shadow halfword; destination SWI and destination Prefetch Abort win independently. `erratum2_exception_priority`. |
| 3 | Corrected | Both one-cycle pin DBGRQ and Debug Control[1]'s scan-created request are crossed with Undefined, bounced coprocessor, Prefetch Abort, load Data Abort, and store Data Abort; each preserves the exception, vector fetch, mode, link, and resume point. `debug_dbgrq_exception`. |
| 4 | Corrected | Undefined, bounced coprocessor, and store Data Abort handlers return before the immediately following breakpoint. A watched store first halts for its watchpoint, then reaches a breakpoint on its second successor. Both restarts preserve exact instruction order. `debug_exception_breakpoint_sequence`. |
| 5 | Corrected | Register-controlled shift, multiply, load, and store predecessors are each followed by two breakpointed instructions; both stops and restarts are exact. `debug_multicycle_breakpoints`. |
| 6 | Corrected | A watched load followed by a Prefetch Abort, a watched store followed by one instruction and then Prefetch Abort, and final-cycle watched-load IRQ/FIQ collisions all enter debug and later take the right exception at the right PC. `debug_watchpoint_pabt_sequence`, `debug_watchpoint_priority`. |
| 7 | Corrected | DBGRQ coincident with breakpoint entry retains breakpoint identity. DBGRQ coincident with both load and store watchpoints retains watchpoint identity, completed-access state, and the first unretired successor. `debug_breakpoint_execute`, `debug_watchpoint_priority`. |
| 8 | Corrected in r4p3 | A pending IRQ during an eight-beat at-speed STM and a pending FIQ during an eight-beat at-speed LDM cannot truncate the transfer or enter an interrupt mode; all data and writeback are scanned back. `debug_system_speed`. |
| 9 | Corrected in r4p3 | CP14 c0 and public JTAG scan chain 2 both return EmbeddedICE-RT version `0111`, with the same live W/R ownership bits. `cp14_dcc`. |
| 10 | Corrected, non-synthesized Arm support block | Not applicable: this repository contains no EIS log/disassembler module, and the Arm notice explicitly excludes the netlist and ETM. Thumb execution status and raw ETM-facing signals remain covered by `etm_trace_matrix` and `etm7_adapter_tb`. |
| 11 | Present in real r4p3 | A condition-failed reserved/Undefined encoding retires without a trap; a following SWI or aborted fetch is classified independently. There is no defect-emulation mode. `cond_fail_matrix`, `pabt_pipeline`. |
| 12 | Corrected in r4p3 | Thumb STR, STMIA, and PUSH at a halfword-only address, each immediately followed by a PC-relative load, produce exact halfword-resolution `r14_abt` on Data Abort. `erratum12_thumb_dabt_lr`. |
| 13 | Present in real r4p3 | The synchronous soft-core DBGRQ contract makes ARM and Thumb PC modifications atomic and retains a pending redirect for the debugger's r15 view. Asynchronous board inputs are synchronized outside the raw macrocell. No defect-emulation mode exists. `debug_pc_modify_dbgrq`. |
| 14 | Present in real r4p3 | Non-indexed, no-writeback LDC, LDCL, STC, and STCL execute through the external coprocessor protocol with both U directions. No defect-emulation mode exists. `cp_erratum14`. |
| 15 | Present in real r4p3 | Consecutive MRC operations with every opcode1 `x1x` pattern execute independently when CPA/CPB claim one cycle early. No defect-emulation mode exists. `cp_erratum15`. |

The matrix was run successfully on baseline commit `5e5241f` with Verilator
5.048 on 2026-07-29. Release sign-off must use the clean machine-readable
regression result described in `VERIFICATION.md`; this baseline note is not a
substitute for that final artifact.
