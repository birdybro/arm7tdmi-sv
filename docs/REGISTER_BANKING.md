# Register banking contract

This document is the normative physical-register map for ARM7TDMI-S r4p3 and
closes `TASKS.md` ISA-017. The governing external references are TRM §2.7,
Table 2-2, and Figure 2-5.

## Architectural count

ARM describes 31 physical general-purpose registers. In this implementation
that means:

| Storage family | Count |
|---|---:|
| Shared r0-r7 | 8 |
| Non-FIQ r8-r12 | 5 |
| User/System r13-r14 | 2 |
| FIQ r8-r14 | 7 |
| IRQ/Supervisor/Abort/Undefined r13-r14 | 8 |
| Shared r15/PC | 1 |
| **Total** | **31** |

Only 30 of those registers are r0-r14 storage. The PC is owned by the
pipelined core so sequential PC advance never competes with the single GPR
write port. The flat regfile array has 31 entries because slot 15 is retained
as an inaccessible layout hole; it is not an additional architectural
register.

## Flat GPR map

| Flat slots | Architectural registers | Selected modes |
|---|---|---|
| 0-7 | r0-r7 | All modes |
| 8-12 | r8-r12 | User, System, IRQ, Supervisor, Abort, Undefined |
| 13-14 | r13_usr-r14_usr | User and System |
| 15 | Inaccessible layout hole | None |
| 16-20 | r8_fiq-r12_fiq | FIQ |
| 21-22 | r13_fiq-r14_fiq | FIQ |
| 23-24 | r13_irq-r14_irq | IRQ |
| 25-26 | r13_svc-r14_svc | Supervisor |
| 27-28 | r13_abt-r14_abt | Abort |
| 29-30 | r13_und-r14_und | Undefined |

User and System are exact GPR-bank aliases. FIQ alone banks r8-r12. Every
exception mode owns a distinct r13 and r14. r0-r7 are shared universally.

The shared PC is mode-independent. A normal r15 register read returns the
current instruction address plus 8 in ARM state or plus 4 in Thumb state.
Instruction-specific paths that require PC+12 are selected in the core before
or after this generic view as documented in [PIPELINE.md](PIPELINE.md).
r15 writes request a core PC update and cannot modify flat slot 15.

## CPSR and SPSR map

There is one shared CPSR and five physical SPSRs:

| SPSR array index | Register | Owning mode |
|---:|---|---|
| 0 | SPSR_fiq | FIQ |
| 1 | SPSR_irq | IRQ |
| 2 | SPSR_svc | Supervisor |
| 3 | SPSR_abt | Abort |
| 4 | SPSR_und | Undefined |

User and System have no SPSR. Their architectural SPSR view follows the
project's deterministic read-as-zero/write-ignore policy, and restore requests
leave CPSR unchanged. Invalid stored modes and reset-visible values are
specified in [PSR.md](PSR.md) and
[UNPREDICTABLE.md](UNPREDICTABLE.md).

## User-bank block transfers

For STM/LDM with S=1 and without r15 in the list, execution from FIQ, IRQ,
Supervisor, Abort, or Undefined mode selects User-bank registers while the
memory access remains privileged and the current processor mode is retained.
This is the `STM^`/`LDM^` form.

System mode is privileged for CPSR and memory-protection purposes, but it has
no SPSR and already uses the User GPR bank. ARMv4T requires S=0 in both User
and System mode. This core's documented policy is a precise Undefined
exception before a data beat for either mode; System must not be counted as a
sixth defined `^` source mode.

LDM with S=1 and r15 in the list is the exception-return form. It uses the
current register bank for the other listed registers and restores CPSR from
the current mode's SPSR when r15 commits. STM with S=1 retains User-bank
selection even if r15 is listed. Invalid S/writeback combinations follow the
policy ledger rather than being treated as defined transfers.

The debug scan data path has an explicit force-User selector because
debug-speed LDM/STM uses the same bank semantics while normal CLKEN is
stopped. That selector cannot make r15 banked.

## Exhaustive evidence

- `tb/unit/regfile_banking_tb.sv` performs 599 operations. It checks every
  logical r0-r14 view in every mode, all normal and debug write routes,
  force-User reads/writes, all three read ports, every flat slot after each
  mutation, PC visibility in both states, CLKEN, and reset.
- `tb/unit/psr_banking_tb.sv` performs 47 operations across every SPSR
  write/read/restore/exception-save route, all mode transitions, absent-bank
  behavior, CLKEN, and reset.
- `tb/integration/arm7tdmis_register_banking_matrix_tb.sv` executes ten
  reset-per-case pin-level rows: STM^ and LDM^ from all five SPSR-owning
  modes. It checks seven address phases, seven pipelined response phases,
  memory, all flat slots, all SPSRs, and final CPSR.
- `tb/integration/arm7tdmis_block_ls_policy_tb.sv` independently checks
  User/System traps, Supervisor User-bank transfers, STM^ with r15, and
  LDM^ exception returns.
- `tb/integration/arm7tdmis_exception_return_matrix_tb.sv` cross-products
  all five SPSR-owning modes, ARM/Thumb destinations, and six return forms
  while checking source SP/LR banks and all otherwise untouched physical
  registers.
