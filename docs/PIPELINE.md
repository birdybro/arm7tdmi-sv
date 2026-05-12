# 3-stage Pipeline Architecture

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

### Why `pabort` rides the pipeline

ABORT is sampled at the F-stage RDATA latch, not at E-stage execute. Without `pabort` per-instruction, the abort signal would be lost between fetch and execute (the original ARM7TDMI memory bus model has them many cycles apart in the steady state). When the aborted instruction reaches E, `pabt_fires` triggers via `executing && de_q.pabort`.

## Bus protocol

ARM7TDMI has a **pipelined bus**: address-class signals (ADDR/WRITE/SIZE/PROT/LOCK/TRANS) drive in cycle N, the matching data appears (or commits, for stores) in cycle N+1. The memory model (`tb/integration/arm7tdmis_memory.sv`) latches addr-class at posedge and produces RDATA combinationally next cycle.

This means a single cycle on the bus is doing **two** transfers' worth of work:
- Addr-class for the *next* transfer.
- Data for the *previous* transfer.

The §18 bus-overlap refactor folds this into the E-stage substate FSM (see below).

## E-stage substate FSM

Nine states:

```
S_EXEC      — single-cycle execute. Drives the addr-class of any
              memory substate entered this cycle.
S_DDATA     — LDR/STR data cycle. Drives next instr fetch addr.
S_BLOCK_DATA— LDM/STM beat iteration. Drives next beat addr (or
              next instr fetch on the last beat).
S_BLOCK_WB  — LDM/STM Rn writeback cycle. Deferred from S_EXEC
              for DABT restart safety.
S_SWP_RDATA — SWP read data + drive write addr.
S_SWP_WDATA — SWP write data + drive next instr fetch.
S_MULL_HI   — UMULL/SMULL/UMLAL/SMLAL RdHi writeback cycle.
S_MULL_ACC  — UMLAL/SMLAL accumulator-read cycle (port-A reads RdHi
              while the multiplier sees latched RdLo as acc_lo).
S_MUL_BUSY  — Multiplier internal cycles (1..4 per the m param).
```

The non-pipelined model had separate `S_DADDR`, `S_BLOCK_ADDR`, `S_SWP_RADDR`, `S_SWP_WADDR` states for "drive the addr-class" — these are gone now. Their work folded into the *previous* state's bus drive (S_EXEC for the first addr; the iteration state itself for subsequent beats).

### Cycle counts (TRM-aligned)

| Instruction | E cycles | Bus cycles total | TRM target |
|---|---|---|---|
| DP, MOV, branch | 1 (S_EXEC) | 1 (overlap with next F) | 1S |
| LDR/STR | 2 (S_EXEC + S_DDATA) | 3 | 1S+1N+1I |
| SWP | 3 | 4 | 1S+2N+1I |
| LDM/STM n regs, W=0 | n+1 | n+1 (last beat overlaps fetch) | 1S+(n-1)S+1N+1I |
| LDM/STM n regs, W=1 | n+1 | n+1 (S_BLOCK_WB overlaps fetch) | same |
| MUL | 1+m | (depends on m=1..4) | 1S+mI |
| UMULL/SMULL | 2+m | | 1S+(m+1)I |
| UMLAL/SMLAL | 3+m | | 1S+(m+1)I + extra acc-read cycle |

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
| LDR to PC | `(state_q == S_DDATA) && ls_load_q && (ls_rd_q == 15)` |
| LDM with PC in list | `(state_q == S_BLOCK_DATA) && block_load_q && (block_curr_reg_q == 15)` |

On `flush`:
- `fetch_pc_q := flush_target_pc`
- `inflight_valid_q := 0` (kill any in-flight prefetch)
- `fd_q.valid := 0` (kill captured-but-not-yet-decoded instr)
- `de_q.valid := 0` (kill in-execute instr — but its writeback already fired this cycle)

`flush_target_pc` priority: `ddata_writes_pc → load_value`, `block_writes_pc → RDATA`, else `pc_target_exec`.

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
