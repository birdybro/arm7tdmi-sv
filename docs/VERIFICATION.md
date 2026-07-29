# Verification and regression evidence

`make -C scripts regress` is the release-facing directed regression entry point.
It always removes the Verilator build directory first, then runs:

1. Raw-core RTL, canonical MiSTer-wrapper, and testbench lint.
2. The harness unit test and intentional-failure sentinel.
3. Every unit test in the `UNIT_TESTS` manifest.
4. Every directed test in the `INTEG_TESTS` manifest.
5. The mixed-instruction smoke test.

The runner stops at the first failing phase and returns nonzero. The intentional
failure sentinel contains a real SystemVerilog `$fatal`; the enclosing target
passes only when Verilator propagates that failure as a nonzero process status.
This catches accidental loss of simulator failures in shell or result handling.

## Machine-readable result

Each run atomically updates `reports/generated/regression.json` using schema
`arm7tdmis-regression-v1`. It records:

- the full Git commit, dirty status, and SHA-256 of local source/build inputs;
- Verilator, Python, GNU Make, Git, and host-platform versions;
- build variant and deterministic seed;
- the complete lint, harness, unit, integration, and smoke manifests;
- each phase's command, timestamps, duration, exit status, log path, and
  SHA-256; and
- the aggregate `running`, `passed`, `failed`, or `interrupted` status.

Per-phase logs live beside the report under `reports/generated/logs/`. Generated
reports are ignored because an ordinary developer run is not immutable release
evidence. A release workflow must copy the selected report and logs to its
versioned artifact archive together with the corresponding clean source commit.

`make -C scripts regress-quick` exercises the same metadata, clean-build, lint,
harness, and smoke path with one unit and one integration test. Its report is
explicitly marked `"mode": "quick"` and cannot be mistaken for the full run.

## Exhaustive encoding evidence

`reserved_decode_tb` is deliberately exhaustive rather than sample-based. It
checks all 4,096 ARMv4T decode-bit combinations, every one of those
combinations under the implementation's ARMv4 `cond=1111` trap policy, and
all 65,536 original Thumb halfwords. Fixed allocation totals make an
accidentally weakened reference map fail hard. The independent
`arm7tdmis_reserved_execute_tb` then executes one representative from every
reserved family through the pin-level memory interface and checks exception
state and absence of memory/coprocessor side effects.

## Unaligned and endian evidence

`arm7tdmis_unaligned_access_matrix_tb` is a 72-row reset-per-case pin-level
matrix. Its 64 data rows cover LDR, STR, LDRH, STRH, LDRSH, LDRSB, SWP, and
SWPB at address low bits 0 through 3 in both endian configurations. Each row
checks architectural data, memory, transfer width/direction/address, and SWP
lock lifetime. The eight remaining rows feed every two-bit target suffix to BX
in both endian configurations and require aligned ARM/Thumb fetches of the
correct width.

The test distinguishes specification from policy. ARMv4T word-load rotation
is architectural. Odd halfword behavior is labeled architecturally
UNPREDICTABLE and checked only as this implementation's deterministic r4p3
bus/lane policy.

## ARM single-transfer evidence

Three reset-per-case matrices close the ARM Addressing Mode 2 and Mode 3
functional space:

- `arm7tdmis_single_ls_matrix_tb` executes all 64 combinations of
  P/U/B/W/L and immediate/register offset. Register-offset rows exercise LSL,
  LSR, ASR, and the encoded `ROR #0` RRX case.
- `arm7tdmis_extra_ls_matrix_tb` executes STRH, LDRH, LDRSB, and LDRSH for
  every P/U/W and immediate/register combination (64 rows).
- `arm7tdmis_single_ls_policy_tb` executes 12 defined alias/r15 cases and 14
  statically detectable ARMv4T UNPREDICTABLE operand combinations.

Every ordinary row checks the transfer address, size, direction, privilege,
lock state, load/store data, destination, and base writeback. Unsafe operand
rows require the project's deterministic precise-Undefined policy, including
the exact LR/SPSR/handler state, no data cycle, no successor retirement, and
unchanged memory. The policy is implementation behavior, not an architectural
promise about UNPREDICTABLE encodings.

## ARM block-transfer evidence

`arm7tdmis_block_ls_matrix_tb` executes 272 reset-per-case rows. Its 256
one-hot rows cover every P/U/W/L combination and each individual r0-r15 list
bit with a distinct base register. Sixteen eight-register rows cover
IA/IB/DA/DB, W, and L with a multibeat list. The checks include exact word
addresses, ascending register/address order, N then S transfer
classification, data direction and values, privilege, LOCK, final base, the
ARM r15 store value, and LDM-to-r15 pipeline redirection.

`arm7tdmis_block_ls_policy_tb` adds 21 rows for base-in-list outcomes,
privileged User-bank transfers, STM^ with r15, and LDM^+PC with and without
writeback. It also freezes the implementation policy for statically
detectable ARMv4T UNPREDICTABLE operands: empty lists, Rn=r15, invalid S/W
forms, and S forms in User/System take a precise Undefined exception before
the first data beat. Defined and deterministic-policy rows require their
architectural register, bank, memory, writeback, CPSR, PC, and bus results.

The base-in-list policy distinguishes architecture from implementation. STM
writeback with Rn lowest stores the original base as ARMv4T specifies; a
non-lowest Rn stores the deterministic updated value. LDM writeback with Rn in
the list retains the r4p3-compatible Base Updated result. The independent
`arm7tdmis_stm_base_list_tb`, `arm7tdmis_ldm_abort_base_list_tb`,
`arm7tdmis_ldm_pc_tb`, and `arm7tdmis_pc_write_alignment_tb` regressions cover
the adjacent all-addressing-mode, abort, CPSR-restore, and refill rules.

## ARM swap evidence

The SWP/SWPB rows in `arm7tdmis_unaligned_access_matrix_tb` cover both swap
widths at address low bits 0 through 3 in little- and big-endian
configurations. They check the ARMv4T word-read rotation and aligned
word-write rules, all byte lanes, exact address/size/direction, loaded and
stored data, and exactly two locked accepted transfers.

`arm7tdmis_swp_policy_tb` adds 18 reset-per-case rows. Distinct operands and
the architecturally defined Rd=Rm exchange execute in both Supervisor and
User modes. Rn=Rd, Rn=Rm, and r15 in each operand position take the project's
precise Undefined policy before a data cycle or LOCK assertion. These are
implementation outcomes for ARMv4T UNPREDICTABLE operands, not architectural
guarantees.

`arm7tdmis_swp_bus_matrix_tb` runs 16 word/byte rows across normal completion,
independent read- and write-response CLKEN stalls, read and write Data
Aborts, reset in either response phase, and DBGRQ between the locked
transfers. It requires an uninterrupted same-address read/write pair, stable
pins and state through stalls, correct cancellation/writeback behavior, and
LOCK release on every exit. A read abort must cancel the write address;
either abort suppresses Rd and memory modification. The independent
`arm7tdmis_swp_read_abort_tb`, `arm7tdmis_swpb_data_tb`, cycle, and
debug-injection tests preserve neighboring behavior.

## ARM condition-failure evidence

`arm7tdmis_cond_fail_matrix_tb` executes 1,092 independent rows: Supervisor
and User modes, all 14 ARM conditions that can evaluate false, and 39
representative instruction paths. The path set spans all 16 decode classes,
every multicycle detour, register/flag/PC/base/memory destinations,
policy-Undefined routes, SWI, ready external CDP/MCR/MRC/LDC/STC, and every
supported CP14 side-effect type.

Each row checks both pipelined halves of r4p3 Table 7-23. The returned opcode
and saved address-class tuple are the sequential word read at instruction
PC+8; the simultaneously outgoing address is the sequential opcode read at
PC+12. Opcode/data and User/privileged PROT, LOCK, the coprocessor-following
signals, `DBGINSTRVALID`, and `DBGnEXEC` are exact. The next instruction must
reach Execute one clock later. Snapshots prove all 31 physical GPRs, CPSR,
all five SPSRs, the complete test memory, and CP14 DCC/debug-abort state are
unchanged, with no exception, coprocessor request, DMORE, or LOCK activity.

`arm7tdmis_pabt_pipeline_tb` covers the sequence-specific r4p3 erratum-11
boundary. A condition-failed UDF retires without an exception; a following
unconditional SWI selects SWI, and a following aborted opcode selects PABT.
Both cases check the selected source, handler, mode, LR, SPSR, and absence of
a false Undefined exception. The project deliberately implements this
architecturally corrected behavior only; it has no defect-emulation mode.

## Exception-return evidence

`arm7tdmis_exception_return_matrix_tb` executes 60 reset-per-row cases: all
five modes that own an SPSR, both ARM and Thumb destinations, and six return
forms spanning direct `MOVS`, immediate `SUBS #4/#8`, the separate
register-controlled-shifter path for both operations, and
`LDMIA sp!,{r4,pc}^`.

Each row writes a distinct complete SPSR and independently checks its physical
bank plus the source mode's banked LR/SP. Deliberately misaligned loaded PC
values prove destination-state alignment. The first redirected opcode address,
SIZE, N-cycle classification, and restored User privilege are exact; the
target then reaches Execute with the expected opcode, PC/state, and full CPSR.
Snapshots prove all SPSRs, memory, and every non-destination physical GPR are
unchanged. LDM rows additionally require the exact two data beats, loaded
register, and writeback to the source exception-mode SP after CPSR restoration.
The focused `arm7tdmis_ldm_pc_tb` and
`arm7tdmis_pc_write_alignment_tb` provide independent neighboring coverage.

Functional/line/toggle coverage reporting, mutation testing of architectural
controls, differential testing, and formal evidence remain separate open
requirements in `TASKS.md` §31.
