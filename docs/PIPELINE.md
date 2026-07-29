# 3-stage Pipeline Architecture

> **Audit status:** Historical implementation notes, not a conformance specification.
> Known cycle and bus-waveform errors are tracked in `TASKS.md` §31.5; §31 supersedes
> every "verified" or "TRM-aligned" statement below.

This document captures the architectural decisions in `rtl/core/arm7tdmis_core_pipelined.sv` — particularly the non-obvious ones, since the RTL itself is dense.

## Stage structure

Three stages: **Fetch → Decode → Execute**, with two stage registers carrying state across cycle boundaries:

```
   ┌───────┐    ┌────┐    ┌───────┐    ┌────┐    ┌───────┐
   │   F   │───▶│fd_q│───▶│   D   │───▶│de_q│───▶│   E   │
   └───────┘    └────┘    └───────┘    └────┘    └───────┘
       │                       │                      │
   fetch bus               combinational         multi-cycle
   (issue/latch)            decoders mux on      substate FSM
                            fd_q.thumb           (S_EXEC + 8)
```

In steady state, three different instructions are in flight per cycle. Throughput is 1S per ARM instruction (the TRM headline figure).

### F→D register (`fd_q`)

| Field | Width | Meaning |
|---|---|---|
| `instr` | 32 | Raw instruction bits (Thumb halfword in `[15:0]` or `[31:16]` per `pc[1]`) |
| `pc` | 32 | PC that produced this instruction |
| `thumb` | 1 | T-bit captured at fetch issue time |
| `pabort` | 1 | ABORT asserted during this fetch's data cycle → prefetch abort when this instr reaches E |
| `valid` | 1 | Stage register validity |

### D→E register (`de_q`)

Same plus `dec` (the normalized `decoded_t` from the ARM/Thumb decoders).

### Architectural r15 views

`de_q.pc` is the address of the instruction in Execute, not an already advanced
architectural PC. Most register-file reads of r15 add 8 in ARM state or 4 in Thumb
state. The few architecturally distinct consumers derive their value from the
instruction address explicitly:

| Consumer | Value |
|---|---|
| Ordinary ARM operand / ARM PC-relative base | `de_q.pc + 8` |
| ARM register-controlled shift `Rm=r15` | `de_q.pc + 12` |
| ARM `STR`/`STM` store data for r15 | instruction PC `+ 12` |
| ARM `BL` link | `de_q.pc + 4` |
| Thumb ordinary operand | `de_q.pc + 4` |
| Thumb PC-relative literal / address generation | `(de_q.pc + 4) & ~3` |
| ARM MCR source r15 | `de_q.pc + 12` |
| ARM MRC destination r15 | CPSR NZCV only; no PC write |

Scalar stores snapshot the exceptional value with the rest of the transfer controls.
Block stores use `memory_instr_pc_q`, because `de_q` can contain the following
instruction during `S_BLOCK_DATA`; using the live register-file view would make the
result depend on pipeline occupancy. Normal execution is covered by
`tb/integration/arm7tdmis_pc_operands_tb.sv`; the CP and debug-specific views are
covered by the r15 and public-scan regressions named in `TASKS.md` ISA-005.

### Why `pabort` rides the pipeline

ABORT is sampled at the F-stage RDATA latch, not at E-stage execute. Without `pabort` per-instruction, the abort signal would be lost between fetch and execute (the original ARM7TDMI memory bus model has them many cycles apart in the steady state). When the aborted instruction reaches E, `pabt_fires` triggers via `executing && de_q.pabort`.

## Bus protocol

ARM7TDMI has a **pipelined bus**: address-class signals (ADDR/WRITE/SIZE/PROT/LOCK/TRANS) drive in cycle N, the matching data appears (or commits, for stores) in cycle N+1. The memory model (`tb/integration/arm7tdmis_memory.sv`) latches addr-class at posedge and produces RDATA combinationally next cycle.

This means a single cycle on the bus is doing **two** transfers' worth of work:
- Addr-class for the *next* transfer.
- Data for the *previous* transfer.

The §18 bus-overlap refactor folds this into the E-stage substate FSM (see below).

## E-stage substate FSM

Twelve states:

```
S_EXEC      — single-cycle execute. Drives the addr-class of any
              memory substate entered this cycle.
S_DDATA     — LDR/STR data cycle. For LDR, latches the loaded
              value (load_value_q) and drives the fetch addr-class.
              For STR, completes the store and drives next fetch.
S_LOAD_WB   — LDR/LDRB regfile writeback I cycle (TRM 1S+1N+1I).
              Commits load_value_q to Rd; flushes if Rd=PC.
S_DP_SHIFT  — Data-processing-with-shift-by-register I cycle
              (TRM Table 7-3: 1S+1I). Commits the latched
              shifter+ALU result.
S_BLOCK_DATA— LDM/STM beat iteration. Drives next beat addr (or
              next instr fetch on the last beat). For STM, also
              commits Rn writeback on the *last* beat (no I cycle).
S_BLOCK_WB  — LDM Rd-writeback I cycle (also commits Rn when W=1).
              STM does *not* enter this state.
S_SWP_RDATA — SWP read data + drive write addr.
S_SWP_WDATA — SWP write data + drive next instr fetch.
S_SWP_WB    — SWP Rd-writeback I cycle (TRM 1S+2N+1I).
S_MULL_HI   — UMULL/SMULL/UMLAL/SMLAL RdHi writeback cycle.
S_MULL_ACC  — UMLAL/SMLAL accumulator-read cycle (port-A reads RdHi
              while the multiplier sees latched RdLo as acc_lo).
S_MUL_BUSY  — Multiplier internal cycles (1..4 per the m param).
```

The non-pipelined model had separate `S_DADDR`, `S_BLOCK_ADDR`, `S_SWP_RADDR`, `S_SWP_WADDR` states for "drive the addr-class" — these are gone now. Their work folded into the *previous* state's bus drive (S_EXEC for the first addr; the iteration state itself for subsequent beats).

### Cycle counts (TRM-aligned, verified by `tb/integration/arm7tdmis_cycles_tb.sv`)

| Instruction | E cycles | Substates | TRM Table 7-N |
|---|---|---|---|
| DP, MOV (imm or shift-by-imm), MVN | 1 | S_EXEC | 7-3: 1S |
| DP shift-by-register | 2 | S_EXEC + S_DP_SHIFT | 7-3: 1S+1I |
| MRS / MSR | 1 | S_EXEC | 7-3: 1S |
| Branch (B / BL / BX) | 3 (incl. 2-cycle refill) | S_EXEC + 2 refill | 7-5: 2S+1N |
| LDR / LDRB / LDRH / LDRSH / LDRSB | 3 | S_EXEC + S_DDATA + S_LOAD_WB | 7-7: 1S+1N+1I |
| STR / STRB / STRH | 2 | S_EXEC + S_DDATA | 7-9: 1S+1N |
| LDR with Rd=PC | 5 | S_EXEC + S_DDATA + S_LOAD_WB + flush + 2S refill | 7-7: 2S+2N+1I |
| LDM, n regs | n+2 | S_EXEC + S_BLOCK_DATA × n + S_BLOCK_WB | 7-12: 1S+(n-1)S+1N+1I |
| STM, n regs | n+1 | S_EXEC + S_BLOCK_DATA × n (Rn writeback in last beat) | 7-15: 1S+(n-1)S+1N |
| SWP / SWPB | 4 | S_EXEC + S_SWP_RDATA + S_SWP_WDATA + S_SWP_WB | 7-17: 1S+2N+1I |
| MUL | 1+m | S_EXEC + S_MUL_BUSY × m | 7-19: 1S+mI |
| MLA | 2+m | S_EXEC + S_MUL_BUSY × (m+1) | 7-19: 1S+(m+1)I |
| UMULL / SMULL | 2+m | + S_MULL_HI | 7-21: 1S+(m+1)I |
| UMLAL / SMLAL | 3+m | + S_MULL_ACC + S_MULL_HI (acc-read cycle) | 7-23: 1S+(m+2)I |

`m` is the multiplier early-termination parameter from `Rs` (1..4 per TRM §7.7).

Three non-obvious cycle-shape decisions:

- **STM has no I cycle.** TRM Table 7-15 gives STM `n+1` cycles vs LDM's `n+2`. To match, STM commits Rn writeback in the *last* `S_BLOCK_DATA` cycle and transitions directly to `S_EXEC` (skipping `S_BLOCK_WB`). The regfile write port is free that cycle because STM has no load to commit. See `block_stm_does_writeback`.
- **LDR/LDRB/LDRH needs S_LOAD_WB.** The "I cycle" in 1S+1N+1I is the regfile-commit cycle for the loaded value — not the data-read cycle (S_DDATA). Naively folding the writeback into S_DDATA gave 2 cycles instead of 3. Splitting it produces TRM-correct timing and naturally accommodates LDR-to-PC (the loaded value drives the flush in S_LOAD_WB).
- **Branch fast-path flush.** On a branch/BX/DP-to-PC the flush fires in an `S_EXEC` cycle where the bus would otherwise drive a now-stale prefetch. The `early_flush_fetch` signal hijacks ADDR=flush_target_pc, TRANS=N for that cycle and captures it as an inflight prefetch — saves the 1-cycle bubble and brings branches to TRM's 2S+1N=3 total. Exception entry (any_exc_fires) is excluded so its multi-step entry sequence is unchanged; LDR-to-PC and LDM-with-PC are also excluded (TRM gives them a longer refill profile that doesn't compress).

## The `issue_fetch` gate (load-bearing)

```systemverilog
wire issue_fetch = !flush && (state_next == S_EXEC);
```

This expression took the longest of any single decision to get right. Here's why:

**Naive version**: `issue_fetch = !flush && !e_busy` — i.e., "issue whenever F can drive the bus."

**Bug**: when E enters a multi-cycle substate (LDR/STR), the cycle E is *about to enter* the substate is itself an S_EXEC cycle (`e_busy = 0`). So F would issue a fetch on that cycle. The fetched instruction arrives during the substate's data cycle — when F can't latch (the bus is busy with data) and `latch_into_fd` is gated by `!e_busy`. **The fetched instruction is silently dropped.**

This caused exactly the cascade in commit `95cc544` (the original §16): three consecutive memory ops dropped three instructions, and the smoke test got cumulative pipeline confusion (`r5 = 0xA` because MOV `r5, #0x200` never fetched).

**Fix**: gate on `state_next == S_EXEC`. F only issues a fetch when the cycle whose RDATA will carry the result is an S_EXEC cycle, where it can be latched. With the §18 bus overlap this expanded to "any cycle whose state_next is S_EXEC" — which includes the last cycle of memory substates.

## Flush mechanism

PC writes flush the pipeline. Triggers (combinational, fire for one cycle):

| Source | Condition |
|---|---|
| DP to PC | `passes_cond && instr_is_dp && (dec.rd == 15)` |
| B / BL / BX | `passes_cond && (instr_is_branch || instr_is_bx)` |
| Exception | `any_exc_fires` (SWI/UNDEF/IRQ/FIQ/PABT/DABT) |
| LDR to PC | `(state_q == S_LOAD_WB) && (ls_rd_q == 15)` |
| LDM with PC in list | `(state_q == S_BLOCK_DATA) && block_load_q && (block_curr_reg_q == 15)` |

On `flush`:
- `fetch_pc_q := flush_target_pc`
- `inflight_valid_q := 0` (kill any in-flight prefetch)
- `fd_q.valid := 0` (kill captured-but-not-yet-decoded instr)
- `de_q.valid := 0` (kill in-execute instr — but its writeback already fired this cycle)

`flush_target_pc` priority: `ddata_writes_pc → load_value`, `block_writes_pc → RDATA`, else `pc_target_exec`.

Every raw target is aligned before that priority mux: ARM destinations clear
bits `[1:0]`, while Thumb destinations clear bit `[0]`. BX obtains the destination
state from its source bit 0. `MOVS/SUBS pc` and `LDM ... pc^` obtain it from SPSR.T,
so the same restored state controls target masking, the first refill's SIZE, and the
subsequent fetch increment. Register-controlled DP writes carry their latched ALU
result and restore intent into `S_DP_SHIFT`; they never consult the next instruction's
live datapath. The 11-family pin-level proof is
`tb/integration/arm7tdmis_pc_write_alignment_tb.sv`.

## Stall mechanism

`e_busy = (state_q != S_EXEC)`. Used to:
- Gate `d_advance` (D doesn't consume fd_q while E is in a substate).
- Implicit in `issue_fetch` (which requires `state_next == S_EXEC` → impossible mid-substate unless transitioning out).

CLKEN propagates from the top level — when CLKEN=0, no flop in the core advances. Used in two places:
- Bus wait states (memory controller asserts CLKEN=0 to extend a transfer).
- Debug halt (ICE-RT drops CLKEN to freeze the core).

## `de_q` staleness traps (caught the hard way)

`de_q` advances each cycle when `!e_busy` (= every S_EXEC cycle). For multi-cycle ops, this means **`de_q.dec` is the NEXT instruction, not the executing one, during substate cycles**. References to `dec.*` in substate code read stale values from the next instruction.

Three places this matters:

### 1. UMLAL/SMLAL S_MULL_ACC

The cycle reads RdHi via port A (needs `dec.rn`), reads multiplier operands via ports B/C (needs `dec.rm`, `dec.rs`), and commits RdLo via the regfile write port (needs `dec.rd`). All four would be wrong without latches.

Snapshots at S_EXEC end (`mull_accum_take_cycle` path):
```
mull_rdhi_q   := dec.rn
mull_rdlo_q   := dec.rd
mull_op_a_q   := rf_rb_data
mull_op_b_q   := rf_rc_data
mull_signed_q := dec.mul_signed
acc_lo_q      := rf_ra_data  // = RdLo from port A
```

Multiplier inputs muxed in S_MULL_ACC: op_a/op_b from latches, acc_lo from latch, acc_hi from current port-A read (now reading `mull_rdhi_q`).

### 2. LDM/STM substate latches

`block_remaining_q`, `block_curr_addr_q`, `block_curr_reg_q`, `block_load_q`, `block_user_mode_q`, `block_has_pc_q`, `block_writeback_q`, `block_writeback_addr_q`, `block_rn_q` are all snapshots of `dec` fields and derived addresses at S_EXEC end.

### 3. LDR/STR `ls_*_q` latches

Same idea: `ls_data_addr_q`, `ls_rd_q`, `ls_byte_q`, `ls_halfword_q`, `ls_signed_q`, `ls_load_q`, `ls_addr_lo_q` snapshot the LDR/STR's parameters.

### Heuristic

If you find yourself writing a substate cycle that references `dec.*` or any signal that depends on `dec.*` (like `rf_ra_data` via `ra_addr_eff`), you almost certainly have a `de_q` staleness bug. Latch what you need at S_EXEC.

## TB-observability mirror

`pc_q` is *not* an architectural register in the pipelined core (the PC for the executing instruction is `de_q.pc`). But the testbench's regression-assertion infrastructure expects a stable `pc_q` it can compare against absolute addresses, especially in self-loop steady states.

The core exports a `pc_q` register that updates on every committed instruction:

```systemverilog
always_ff @(posedge CLK) if (CLKEN && state_q == S_EXEC && de_q.valid)
    pc_q <= de_q.pc;
```

This is the "PC of the most recently committed instruction." Stable in self-loops (where the same instr commits every few cycles). Has no architectural role.
