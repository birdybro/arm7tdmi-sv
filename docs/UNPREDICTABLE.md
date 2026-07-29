# ARMv4T UNPREDICTABLE behavior policy

This is the normative project ledger for behavior that ARMv4T or the
ARM7TDMI-S r4p3 TRM labels **UNPREDICTABLE**, **UNKNOWN**, or otherwise leaves
implementation-selected. It closes `TASKS.md` ISA-016 for the ARM7TDMI-S
instruction set, reset-visible state, EmbeddedICE-RT register map, and JTAG
interface implemented by this repository.

None of the outcomes below is promoted to an ARM architectural guarantee.
Software that executes an UNPREDICTABLE case is invalid even when this core
returns the same deterministic result on every run. Tests for these outcomes
are compatibility and safety regressions, not portable-software conformance
tests.

## Policy classes

The implementation uses four classes:

- **Precise Undefined** — take the Undefined Instruction exception before any
  instruction data transfer, register write, memory write, lock, or external
  coprocessor acceptance side effect.
- **Ignore/preserve** — reject the forbidden field or access and retain the
  prior architectural state.
- **Deterministic result** — execute using the r4p3 datapath, banking, bus, or
  address result documented below.
- **RAZ/WI or BYPASS** — return zero/ignore writes for reserved debug storage,
  or select the one-bit JTAG bypass register.

A condition-failed ARM instruction is not executed. Its policy behavior is
therefore suppressed along with its ordinary side effects; the 1,092-row
`arm7tdmis_cond_fail_matrix_tb` checks this precedence across all relevant
execute paths.

## Encoding and operand policies

| ARMv4T case | Selected behavior | Primary evidence |
|---|---|---|
| Any ARM word with `cond=1111` | Precise Undefined; never reinterpret it as an ARMv5+ unconditional instruction. | `reserved_decode_tb`, `arm7tdmis_reserved_execute_tb` |
| TST/TEQ/CMP/CMN with nonzero `Rd`, or MOV/MVN with nonzero `Rn` | Precise Undefined. | `unpredictable_decode_tb`, `arm7tdmis_unpredictable_trap_tb` |
| MUL with nonzero SBZ accumulator field; MUL/MLA using r15; long multiply using r15 or equal `RdHi/RdLo` | Precise Undefined. | Same two tests above |
| MRS with `Rd=r15`; MSR with no selected field; register MSR with `Rm=r15` | Precise Undefined. | Same two tests above |
| Noncanonical required-SBZ/SBO fields in MRS, MSR, BX, SWP/SWPB, or register-offset Addressing Mode 3 | Precise Undefined. Every noncanonical affected field value is enumerated, including all 60 extra-transfer SBZ rows. | Same two tests above |
| Addressing Mode 2/3 unsafe writeback aliases or prohibited r15 operands | Precise Undefined before a data address. Defined no-writeback aliases still execute normally. | `arm7tdmis_single_ls_policy_tb` |
| ARM block transfer with an empty list, `Rn=r15`, invalid S/W combination, or an S form in User/System | Precise Undefined before the first beat. | `arm7tdmis_block_ls_policy_tb` |
| Thumb empty LDMIA/STMIA/PUSH/POP | Precise Undefined before the first beat. | `arm7tdmis_thumb_block_policy_tb` |
| SWP/SWPB with `Rn=Rd`, `Rn=Rm`, or r15 in any operand position | Precise Undefined before LOCK or a data address. `Rd=Rm` remains the defined exchange. | `arm7tdmis_swp_policy_tb` |
| Indexed LDC/STC with `Rn=r15` | Precise Undefined before `CPnI`; unindexed/offset PC-relative forms remain executable. | `unpredictable_decode_tb`, `arm7tdmis_unpredictable_trap_tb` |
| Thumb high ADD/CMP/MOV with both high bits clear; high CMP with `Rn=pc`; pre-v5 BLX-register spelling; BX with nonzero SBZ bits | Precise Undefined. | `unpredictable_decode_tb`, `arm7tdmis_unpredictable_trap_tb` |

`unpredictable_decode_tb` exhausts the affected allocated fields: 1,066 ARM
precise-trap rows, 448 Thumb precise-trap rows, and 12 deliberately executable
deterministic rows. `arm7tdmis_unpredictable_trap_tb` independently carries 24
representatives through public pins and checks exact Undefined state plus the
absence of register, memory, successor, and coprocessor side effects.

Genuinely unallocated or ARMv4T-Undefined encodings are tracked separately by
ISA-007. Calling the selected trap above “Undefined” describes the exception
this implementation takes; it does not reclassify the original encoding in
the ARM architecture.

## PSR, mode, and exception-return policies

| ARMv4T case | Selected behavior | Primary evidence |
|---|---|---|
| CPSR MSR attempts to change T | Ignore T and apply any independently valid selected fields. | `psr_policy_tb`, `arm7tdmis_psr_policy_tb` |
| MSR writes reserved `_x`, `_s`, or low `_f` bits | Preserve their stored values. | Same tests |
| Selected control byte contains an invalid mode | Reject the complete control byte; independently selected NZCV may still commit. This applies to CPSR and SPSR writes. | Same tests |
| MRS/MSR SPSR or S+PC restore in User/System, which have no SPSR | MRS reads zero, MSR is ignored, and restore leaves CPSR unchanged. A result-writing DP S+PC still commits its current-state-aligned PC result. | `psr_policy_tb`, `arm7tdmis_psr_policy_tb`, `arm7tdmis_dp_pc_no_spsr_policy_tb` |
| Exception return from an SPSR whose mode field is invalid | Reject the CPSR restore in full and retain the current CPSR; still commit the ordinary aligned PC result. | `arm7tdmis_invalid_spsr_return_policy_tb` |
| General DP or exception-return write of an unaligned value to r15 | Clear bit 0 for Thumb destination state or bits `[1:0]` for ARM destination state. Restored SPSR.T chooses the state before masking and refill. | `arm7tdmis_pc_write_alignment_tb`, `arm7tdmis_exception_return_matrix_tb` |

The instruction-specific alignment rules for LDR/LDM/POP-to-PC and ordinary
BX are architectural and are not made policy merely because the same tests
cover them.

## PC operand, branch, and address policies

| ARMv4T case | Selected behavior | Primary evidence |
|---|---|---|
| Register-controlled ARM data processing using r15 as Rn, Rm, Rs, or Rd | Rn/Rs read the visible PC+8 value, Rm reads the r4p3 PC+12 value, and Rd commits the deterministic aligned result. | `arm7tdmis_unpredictable_runtime_tb` |
| BX target ending in binary `10` | Enter ARM state after clearing bits `[1:0]`. | `arm7tdmis_unaligned_access_matrix_tb` |
| Thumb `BX pc` at a halfword-only instruction address | Use visible PC+4, clear bits `[1:0]`, and enter ARM state. Word-aligned `BX pc` remains the defined case. | `arm7tdmis_thumb_bx_pc_policy_tb` |
| Standalone Thumb BL suffix | Use the current architectural LR as its target base and write the ordinary suffix link value. | `arm7tdmis_thumb_bl_boundary_tb` |
| Thumb BL prefix not followed by a suffix | Retain the prefix-computed LR and execute the ordinary successor without branching. | `arm7tdmis_thumb_bl_pair_policy_tb` |
| Executed sequential fetch, B/BL target, or multiword LDM/STM/PUSH/POP/LDC/STC crossing `0xFFFF_FFFF` | Continue with modulo-2^32 address arithmetic. | `arm7tdmis_address_wrap_policy_tb`, `arm7tdmis_cp_address_wrap_policy_tb` |

The rollover matrices cover 13 core/branch/block rows plus two external
coprocessor rows and check raw addresses rather than relying on the test
memory's intentional aliasing. ARMv4T has no LDRD/STRD instructions, so the
later-architecture doubleword cases are outside this core's instruction set.

## Arithmetic policies

| ARMv4T case | Selected behavior | Primary evidence |
|---|---|---|
| MULS/MLAS/long-multiply-S C flag | Preserve C. V is likewise preserved by every multiply form. N/Z come from the final result. | `multiplier_tb`, `arm7tdmis_multiply_matrix_tb`, `arm7tdmis_mull_flags_tb` |
| ARM short multiply with `Rd=Rm` | Read all operands before writeback and return the ordinary mathematical result. | `unpredictable_decode_tb`, `arm7tdmis_multiply_matrix_tb` |
| Pre-ARMv6 Thumb MUL with identical operands | Return the ordinary square, update N/Z, and preserve C/V. | `unpredictable_decode_tb`, `arm7tdmis_unpredictable_runtime_tb` |

## Data-access and block-transfer result policies

| ARMv4T case | Selected behavior | Primary evidence |
|---|---|---|
| Odd-address ARM or Thumb LDRH/LDRSH/STRH | Present the raw odd address with halfword SIZE. The memory ignores bit 0; address bit 1 and endianness select the lane. | `arm7tdmis_unaligned_access_matrix_tb`, `arm7tdmis_thumb_halfword_policy_tb` |
| Pre-v6 Thumb word LDR/STR at an unaligned address | Use the shared ARM7 word path: rotate the naturally aligned word right by `8 * address[1:0]` on loads and write the unrotated word to the naturally aligned location on stores. The raw calculated address remains visible on the bus. | `arm7tdmis_thumb_word_unaligned_policy_tb` |
| ARM LDR-to-PC from an unaligned data address | Apply ordinary LDR rotation, then clear result bits `[1:0]` using the pre-v5 LDR-to-PC rule before the ARM refill. | `arm7tdmis_ldr_pc_unaligned_policy_tb` |
| Addressing Mode 3 with `P=0,W=1` | Perform an ordinary privileged post-index transfer at the original base and commit the deterministic add/subtract writeback. | `arm7tdmis_extra_ls_matrix_tb` |
| ARM LDM writeback with base in list | The loaded register value wins during the beats and the final base becomes the deterministic updated address. | `arm7tdmis_block_ls_policy_tb`, abort/base-list tests |
| ARM/Thumb STM writeback with base non-lowest in list | Store the already-updated base when its turn arrives. If base is lowest, store the architectural original base. | `arm7tdmis_block_ls_policy_tb`, `arm7tdmis_thumb_block_policy_tb`, `arm7tdmis_stm_base_list_tb` |
| Thumb LDMIA with base in list | The loaded base value wins; this is architecture-defined, not an implementation policy. | `arm7tdmis_thumb_block_policy_tb` |

Word LDR/SWP rotation and aligned STR/SWP storage are architecture-defined for
ordinary ARM instructions. The table separately records Thumb unaligned word
accesses and unaligned ARM LDR-to-PC because ARMv4T labels those inputs
UNPREDICTABLE even though this implementation reuses the same datapath rules.

## Reset-visible state

Reset initializes all 31 flat regfile-array slots to zero: 30 architectural
r0-r14 locations plus the deliberately inaccessible slot 15 retained by the
implementation layout. It also initializes all five physical SPSRs to zero.
This includes the architecturally UNPREDICTABLE `r14_svc` and `SPSR_svc`
reset values. The shared architectural PC is core-owned and follows the
reset-vector contract. CPSR uses its architecture-defined
Supervisor/ARM/I/F reset value. Reset dominates CLKEN.

`reset_state_policy_tb` checks every physical storage slot with CLKEN low.
`arm7tdmis_invalid_spsr_return_policy_tb` proves that consuming the zero
`SPSR_svc` cannot place the core in invalid mode.

## Coprocessor and debug policies

The r4p3 target gives MCR with r15 a concrete visible-PC transfer result:
PC+12. This repository implements and tests that r4p3 behavior in
`arm7tdmis_cp_reg_r15_tb`; MRC with r15 updates NZCV only. These target-specific
rules take precedence over descriptions for other architecture revisions.

For the implemented debug interface:

| TRM-reserved selection | Selected behavior | Primary evidence |
|---|---|---|
| Any of the 11 unused four-bit JTAG instruction values | One-bit BYPASS. | `jtag_tap_tb` |
| SCAN_N chain other than 1 or 2, including reserved chain 0 | Shift zeros and cause no chain side effect. | `jtag_tap_tb` |
| Any of the 16 unlisted five-bit EmbeddedICE-RT register addresses | Read-as-zero/write-ignore. Address `0x02` cannot act as Vector Catch. | `arm7tdmis_debug_reserved_regs_tb` |

The TAP test enumerates all 16 IR values and all 16 scan-chain selectors.
The register-map test enumerates all 32 addresses and attacks every unlisted
one through the public 38-bit chain.

## Explicit scope boundaries

ISA-016 assigns behavior to every ARMv4T/r4p3 UNPREDICTABLE case that the
implemented processor can originate or observe under its documented external
contracts. It does not invent a policy for:

- later-architecture instructions or encodings absent from ARMv4T;
- encodings that ARMv4T classifies as Undefined rather than UNPREDICTABLE;
- an external coprocessor violating the CPA/CPB/data protocol, or the contents
  of coprocessor registers after an aborted LDC;
- memory/debug pins that violate setup, clock-domain, or response contracts;
- metastability, electrical behavior, or silicon-only analogue effects; or
- software coherence outside the explicit unified-memory refill contract.

Those are excluded interfaces or separate requirements, not silently
uncovered ISA-016 cases. Any newly implemented architectural feature that
introduces another UNPREDICTABLE input must add a row here and a fail-hard
test before release.
