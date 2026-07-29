# Exception Entry Architecture

> **Audit status:** Implementation notes, not a release sign-off. Use `TASKS.md`
> §31.4 as the authoritative requirement and status; directed evidence below does
> not replace the remaining exception, bus, and verification gates.

Seven exception types per the ARM7TDMI-S r4p3 TRM §2.9. This doc captures their entry semantics, priorities, and where they fire in our pipelined core.

## Vector table

```
0x00  Reset       ← deassertion of nRESET
0x04  Undefined   ← INSTR_UNDEF + cond_pass, cond=1111 policy, unhandled coprocessor
0x08  SWI         ← INSTR_SWI + cond_pass
0x0C  PABT        ← fd_q.pabort (= ABORT during this instruction's fetch)
0x10  DABT        ← ABORT during a memory data cycle
0x14  reserved
0x18  IRQ         ← nIRQ low + !cpsr.i
0x1C  FIQ         ← nFIQ low + !cpsr.f
```

The vector slots typically hold `B <handler>` branches.

## Priority ordering

Higher priority wins when multiple exceptions are simultaneously raised. Implemented in the `exc_mode_target` always_comb chain in `arm7tdmis_core_pipelined.sv`:

```
1. UNDEF  → mode=UND, vec=0x04, spsr_idx=4
2. PABT   → mode=ABT, vec=0x0C, spsr_idx=3
3. DABT   → mode=ABT, vec=0x10, spsr_idx=3
4. FIQ    → mode=FIQ, vec=0x1C, spsr_idx=0
5. IRQ    → mode=IRQ, vec=0x18, spsr_idx=1
6. SWI    → mode=SVC, vec=0x08, spsr_idx=2 (default)
```

Reset is special — it's the implicit "exception" when nRESET deasserts, and goes through the reset_sync module rather than this path.

## Entry sequence

For any exception E (gated by `any_exc_fires`):

```
1. r14_<E-mode> := de_q.pc + 4        (return address)
2. SPSR_<E-mode> := current CPSR      (saved program status)
3. CPSR.M := exc_mode_target          (switch banks)
4. CPSR.I := 1                        (mask IRQs in handler)
5. CPSR.F := 1 if FIQ-entry only      (FIQs auto-disable on FIQ entry)
6. CPSR.T := 0                        (ARM state in handler)
7. PC    := vector address            (flush + branch)
```

All steps commit at the same posedge. The pipeline flush invalidates F/D state; the next cycle's fetch is from the new PC.

### r14 banked-write

During exception entry, the regfile is muxed to the *target* mode (`regfile_mode_eff = any_exc_fires ? exc_mode_target : cpsr.m`) so the r14 writeback lands in the target bank, not the current mode's bank. E.g., UNDEF from SVC writes r14_und (slot 30 in the flat regfile layout), not r14_svc.

### PSR save

`u_psr.exc_enter_en` triggers SPSR write to the indexed bank. The SPSR captures the *current* CPSR (pre-mode-switch) so the handler can MOVS PC, LR (or LDM ^ with PC) to atomically restore both PC and CPSR.

## Where each exception is detected

### UNDEF

```systemverilog
wire undef_fires = executing && ((condition_pass && instr_is_undef)
                              || cond_is_nv
                              || cp_undef_trap);
```

`instr_is_undef` matches the decoded `INSTR_UNDEF` class. ARMv4 specifies
`cond=1111` as UNPREDICTABLE, not as the ARMv5+ unconditional extension
space. This implementation freezes a precise Undefined trap as its
deterministic policy; `cond_is_nv` is a defense-in-depth trap route even
though the ARM decoder also returns `INSTR_UNDEF`. `cp_undef_trap` fires on
coprocessor instructions the core does not handle (CDP/MCR/MRC/LDC/STC with
`cp_num` outside the internal CP14 subset and no external acceptor).

The ARM decoder applies the ARM ARM extension-space rule before selecting an
execute unit. It rejects all unallocated `[27:20]`/`[7:4]` decode rows,
including the signed-store encodings later used for doubleword transfers and
the `11000x0x` coprocessor double-register-transfer space. Consequently a
reserved word cannot perform a memory transfer or assert `CPnI` before taking
Undefined. The exhaustive evidence is `reserved_decode_tb` (4,096 ARM decode
rows, all 4,096 `cond=1111` variants, and all 65,536 Thumb words) plus the
pin-level `arm7tdmis_reserved_execute_tb`.

### PABT (prefetch abort)

```systemverilog
wire pabt_fires = executing && de_q.pabort;
```

`fd_q.pabort` latches at the F-stage RDATA capture; carried through D into `de_q.pabort`. When the aborted instruction reaches E, this fires. The same instruction is *not* committed (no regfile write, no PC advance — exception entry takes over).

### DABT (data abort)

```systemverilog
wire data_abort_now = ABORT && ((state_q == S_DDATA)
                              || (state_q == S_BLOCK_DATA)
                              || (state_q == S_SWP_RDATA)
                              || (state_q == S_SWP_WDATA));

logic data_abort_q;
// latched on data_abort_now, cleared on S_EXEC entry

wire dabt_fires = (data_abort_q || data_abort_now)
               && (state_next == S_EXEC)
               && (state_q != S_EXEC);
```

The `data_abort_now` term is load-bearing: for single-beat LDR/STR, the S_DDATA cycle IS the transition out (`state_next == S_EXEC`), so `data_abort_q` hasn't been latched yet. Including the live signal catches this case; the latched `data_abort_q` covers multi-beat LDM/STM where the abort fires mid-iteration and persists through S_BLOCK_WB.

### IRQ / FIQ

```systemverilog
wire irq_pending = executing && !nIRQ && !cpsr.i;
wire fiq_pending = executing && !nFIQ && !cpsr.f;
wire fiq_fires   = fiq_pending && !swi_fires && !undef_fires;
wire irq_fires   = irq_pending && !fiq_pending
                && !swi_fires && !undef_fires;
```

Both gate on `executing` (= state_q==S_EXEC && de_q.valid), so an interrupt asserting during a multi-cycle substate doesn't fire until E returns to S_EXEC. FIQ wins over IRQ.

Note that `nIRQ` / `nFIQ` are pre-gated at the top by IFEN (the EmbeddedICE-RT interrupt-mask logic — see DEBUG.md):

```
nIRQ_eff = nIRQ | ~ice_ifen
nFIQ_eff = nFIQ | ~ice_ifen
```

So a debug session can mask interrupts entirely via the Debug Control Register INTDIS bit.

### SWI

```systemverilog
wire swi_fires = passes_cond && instr_is_swi;
```

Fires on commit of an `INSTR_SWI` (= `cond | 0b1111 | comment24`).

## LDM/STM Data Abort completion

The r4p3 TRM requires an LDM/STM to complete its transfer sequence after a
Data Abort and leave the requested modified base visible. Implementation:

1. **LDM destination suppression**: `block_writes_ldm` is gated by
   `!data_abort_q && !data_abort_now`. Loads before the abort commit; the
   aborting and every later destination write are suppressed. Because r15 is
   last, an abort on any beat prevents the PC write.

2. **LDM Base Updated result**: normal writeback occurs in `S_BLOCK_WB`.
   After an abort that port is needed for LR_abt, so
   `block_ldm_abort_writeback` restores `block_writeback_addr_q` into Rn on
   the final data beat. This also prevents an earlier base-in-list load from
   replacing the modified base.

3. **STM writeback and stores**: requested STM writeback commits in the setup
   cycle, before any response can abort. All beats are still presented; the
   external memory contract determines that the selected failed store does
   not commit, while the independent non-aborted beats do.

4. **Latched snapshots**: `block_writeback_q`,
   `block_writeback_addr_q`, and `block_rn_q` are captured at S_EXEC end so
   completion never relies on `dec.*` after the pipeline advances.

`arm7tdmis_ldm_abort_tb`, `arm7tdmis_ldm_abort_base_list_tb`, and
`arm7tdmis_stm_abort_tb` inject ABORT independently on every beat and check
all four transfers, register/store reachability, modified-base writeback,
r15 protection, exception state, and successor suppression.

## SWP/SWPB Data Abort

A precise abort on the locked read cancels the write address immediately;
the operation behaves as though it had not executed. An abort reported for
the write response also suppresses the loaded-value writeback. In either
case Rd is unchanged, the failed memory operation does not commit, the
successor is flushed, LR_abt receives the swap instruction address plus
eight, and LOCK is released before exception handling.

`arm7tdmis_swp_read_abort_tb` covers the architecture-required read-abort
contract independently for both widths. `arm7tdmis_swp_bus_matrix_tb` covers
both read- and write-response aborts alongside normal, stalled, reset, and
debug exits.

## Return from exception

Two common patterns:

### MOVS PC, LR

```
MOVS r15, r14
```

A DP instruction with Rd=15 and S=1. The `dp_writes_pc && dec.s_bit` path triggers `cpsr_restore_now`, which atomically:
- Writes PC := r14 (the saved return address).
- Restores CPSR := SPSR_of_current_mode.

Used by SWI handlers and similar exception returns.

### LDM ^ with PC in list

```
LDMFD sp!, {r0-r12, lr, pc}^
```

The `^` form with PC in the register list. When r15 loads (in S_BLOCK_DATA with `block_curr_reg_q==15`), `block_ldm_pc_restore` fires:
```
block_ldm_pc_restore = (state_q == S_BLOCK_DATA)
                    && block_load_q
                    && (block_curr_reg_q == 4'd15)
                    && block_user_mode_q;
```

`cpsr_restore_now` ORs this into the SPSR-restore trigger.

Force-user-bank routing is gated off for this variant (`block_has_pc_q` set, `force_user_bank_eff` zero) because the ARM ARM specifies the *current* bank for r0-r14 when PC is in the list — only the SPSR restore is the "S=1" effect.

Validated by `tb/integration/arm7tdmis_ldm_pc_tb.sv`: handler clears cpsr.F before LDM ^ PC, then asserts cpsr.F = 1 (restored from SPSR) after return.

## Tests

| Test | Coverage |
|---|---|
| `arm7tdmis_irq_tb` | nIRQ pin → vector 0x18 → handler |
| `arm7tdmis_fiq_tb` | nFIQ pin → vector 0x1C → handler |
| `arm7tdmis_abort_tb` | DABT during LDR → vector 0x10 → handler |
| `arm7tdmis_pabt_tb` | PABT during fetch → vector 0x0C → handler |
| `arm7tdmis_ldm_abort_tb` | DABT on every LDM beat → later destinations suppressed, Base Updated, r15 protected |
| `arm7tdmis_ldm_abort_base_list_tb` | DABT on every LDM beat with Rn in list → modified base restored |
| `arm7tdmis_stm_abort_tb` | DABT on every STM beat → sequence completes and requested writeback remains |
| `arm7tdmis_swp_read_abort_tb` | SWP/SWPB read abort → no write address, memory/Rd preserved |
| `arm7tdmis_swp_bus_matrix_tb` | SWP/SWPB read/write abort and LOCK exit matrix |
| `arm7tdmis_ldm_pc_tb` | LDM ^ PC exception return → CPSR restore |
| `arm7tdmis_tb_top` | SWI (in smoke flow) |

UNDEF currently smoke-only (the smoke test exercises the NV-cond → undef path implicitly through the SWI handler's MOVS PC, LR sequence).
