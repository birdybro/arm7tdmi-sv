# Program Status Register Contract

This document freezes the ARM7TDMI-S CPSR/SPSR behavior selected for
architecturally reserved or UNPREDICTABLE operations. The normative external
references are the ARM7TDMI-S r4p3 TRM §§2.8.1–2.8.3 and the ARMv4T
architecture; `TASKS.md` ISA-004 is the release gate.

## Bit map

| Bits | Meaning | Software write behavior |
|---|---|---|
| 31:28 | N, Z, C, V | Selected by MSR `_f`. |
| 27:24 | Reserved part of `_f` | Preserved. |
| 23:16 | Reserved `_s` field | Preserved. |
| 15:8 | Reserved `_x` field | Preserved. |
| 7 | I, IRQ disable | Privileged CPSR/SPSR `_c`. |
| 6 | F, FIQ disable | Privileged CPSR/SPSR `_c`. |
| 5 | T, ARM/Thumb state | Dropped for CPSR MSR; writable in SPSR. |
| 4:0 | Mode | Validated before a selected `_c` field commits. |

There is no Q flag in ARMv4T. Reserved storage is not assumed to be zero:
field writes are true read-modify-write preservation even when exception state
or a future implementation supplies nonzero reserved bits.

## Privilege and SPSR access

User mode can change only CPSR.NZCV. It cannot change I, F, T, the mode, or
reserved fields. System mode is privileged for CPSR purposes, shares the User
register bank, and has no SPSR.

FIQ, IRQ, Supervisor, Abort, and Undefined each select their own SPSR.
User and System select none. The deterministic no-SPSR policy is:

- MRS SPSR reads zero;
- MSR SPSR is ignored; and
- an SPSR-to-CPSR restore request is ignored.

The zero read is intentional. The internal bank-index default must never make
an absent SPSR expose FIQ state.

## Invalid modes

The seven valid mode values are User `10000`, FIQ `10001`, IRQ `10010`,
Supervisor `10011`, Abort `10111`, Undefined `11011`, and System `11111`.
The TRM calls an illegal mode write unrecoverable. This soft core instead uses
a deterministic, recoverable policy:

- when an MSR selects `_c` and its source M[4:0] is invalid, the complete
  control byte is rejected;
- independently selected writable flags still commit; and
- reserved fields continue to preserve.

The rule applies to CPSR and SPSR writes. It prevents a malformed debugger or
guest program from placing the register-file bank selector in an undefined
state while retaining ordinary MSR field independence.

## T-bit policy

The TRM forbids changing CPSR.T with MSR and labels the result
UNPREDICTABLE. This implementation drops that bit from every CPSR MSR write.
BX, exception entry, and CPSR restoration remain the architectural state-change
paths. SPSR.T is writable so exception-return software can select the state to
restore.

`tb/integration/arm7tdmis_psr_policy_tb.sv` executes an all-field CPSR MSR
with T set, proves `CPTBIT` never enters Thumb state, and measures the
instruction as one E cycle per TRM Table 7-6.

## Evidence

- `tb/unit/psr_tb.sv` covers reset, field writes, SPSR banks, restore, and BX.
- `tb/unit/psr_policy_tb.sv` covers reserved-bit preservation with nonzero
  storage, invalid modes, User/System RAZ/WI, and privilege filtering.
- `tb/integration/arm7tdmis_psr_policy_tb.sv` executes the policy in
  Supervisor, FIQ, User, and System modes through the public CPU/memory pins.
- `tb/integration/arm7tdmis_debug_register_scan_tb.sv` covers the
  OpenOCD-compatible CPSR/SPSR debug transfer sequence.
