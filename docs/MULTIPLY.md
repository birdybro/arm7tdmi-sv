# Multiply Unit Architecture

> **Audit status:** Implemented and release-gated by `TASKS.md` ISA-003.

How MUL/MLA/UMULL/SMULL/UMLAL/SMLAL are sequenced through the E-stage substate FSM. The actual arithmetic lives in `rtl/datapath/arm7tdmis_multiplier.sv` (a single-cycle 32×32→64 multiplier with optional accumulate); this doc is about the control flow.

## Forms supported

| Mnemonic | Decoder class | Bit 22 (U) | Bit 21 (A) | Writes |
|---|---|---|---|---|
| MUL  | INSTR_MUL  | — | 0 | Rd |
| MLA  | INSTR_MUL  | — | 1 | Rd, accumulate from Rn |
| UMULL | INSTR_MULL | 0 | 0 | RdLo, RdHi |
| UMLAL | INSTR_MULL | 0 | 1 | RdLo, RdHi (with accumulate) |
| SMULL | INSTR_MULL | 1 | 0 | RdLo, RdHi |
| SMLAL | INSTR_MULL | 1 | 1 | RdLo, RdHi (with accumulate) |

Encoding bit positions (bits[19:16]=RdHi/Rd, bits[15:12]=RdLo/Rn, bits[11:8]=Rs, bits[3:0]=Rm) follow `decoded_t`:

| Decoder field | MUL/MLA | MULL forms |
|---|---|---|
| `dec.rn` | Rd (the destination) | RdHi |
| `dec.rd` | Rn (the accumulator) | RdLo |
| `dec.rm` | Rm | Rm |
| `dec.rs` | Rs | Rs |

This re-mapping is why the regfile's port-A mux reads `dec.rd` instead of `dec.rn` for the multiply class — `dec.rd` carries the accumulator slot for MUL/MLA and RdLo for UMLAL/SMLAL.

## m parameter (cycle-shaping per Rs)

The TRM lets the multiplier exit early when Rs's significant bits fit:

```
m = 1   if Rs[31:8]  is all 0 OR all 1
m = 2   if Rs[31:16] is all 0 OR all 1
m = 3   if Rs[31:24] is all 0 OR all 1
m = 4   otherwise
```

The multiplier exposes `cycle_count` (3 bits, 1..4). The core latches it at S_EXEC and counts down through `S_MUL_BUSY` for `m` cycles. Total E cycles:

| Form | E cycles |
|---|---|
| MUL/MLA | 1 + m |
| UMULL/SMULL | 1 + m + 1 (S_EXEC + S_MUL_BUSY + S_MULL_HI) |
| UMLAL/SMLAL | 1 + 1 + m + 1 (S_EXEC + S_MULL_ACC + S_MUL_BUSY + S_MULL_HI) |

Per-class totals match the TRM Tables 7-7 through 7-10 and are checked at the
architectural E-stage boundary.

## State transitions

```
                  ┌─────────────────────┐
                  │       S_EXEC        │
                  └─────────────────────┘
                          │
        ┌─────────────────┼─────────────────────┐
        │                 │                     │
        │ MUL/MLA         │ UMULL/SMULL         │ UMLAL/SMLAL
        │                 │                     │
        ▼                 ▼                     ▼
  ┌──────────┐      ┌──────────┐         ┌────────────┐
  │S_MUL_BUSY│      │S_MUL_BUSY│         │ S_MULL_ACC │
  │ (m cyc)  │      │ (m cyc)  │         │  (1 cyc)   │
  └──────────┘      └──────────┘         └────────────┘
        │                 │                     │
        │                 ▼                     ▼
        │           ┌──────────┐         ┌──────────┐
        │           │S_MULL_HI │         │S_MUL_BUSY│
        │           │ (1 cyc)  │         │ (m cyc)  │
        │           └──────────┘         └──────────┘
        │                 │                     │
        │                 │                     ▼
        │                 │               ┌──────────┐
        │                 │               │S_MULL_HI │
        │                 │               └──────────┘
        │                 │                     │
        ▼                 ▼                     ▼
                     S_EXEC (next)
```

The `mull_active_q` flag latched at S_EXEC distinguishes "go to S_MULL_HI after S_MUL_BUSY" (UMULL/SMULL/UMLAL/SMLAL) from "go directly to S_EXEC after S_MUL_BUSY" (MUL/MLA).

## Writeback timing

| Form | RdLo / Rd commit | RdHi commit |
|---|---|---|
| MUL/MLA | S_EXEC (`mul_writes_dest` path) | n/a |
| UMULL/SMULL | S_EXEC (`mull_writes_lo` path) | S_MULL_HI |
| UMLAL/SMLAL | S_MULL_ACC | S_MULL_HI |

The UMLAL/SMLAL RdLo commit happens at S_MULL_ACC because the result isn't final until the full 64-bit accumulator is fed to the multiplier — which doesn't happen until the second cycle.

## UMLAL/SMLAL: the 2-cycle accumulator read (load-bearing)

The regfile has 3 read ports (A, B, C). UMLAL needs Rm + Rs + RdLo + RdHi = 4 source operands. The fix: read RdLo in S_EXEC, latch it, read RdHi in a new S_MULL_ACC cycle.

### S_EXEC (UMLAL/SMLAL)

`ra_addr_eff = dec.rd` (= RdLo for MULL accum forms, via `instr_is_mull_accum_decoder`).

`rf_ra_data = regs[dec.rd] = RdLo's current value`.

Latches at end:
```
acc_lo_q       := rf_ra_data       // = RdLo
mull_rdhi_q    := dec.rn           // RdHi register address
mull_rdlo_q    := dec.rd           // RdLo register address (for S_MULL_ACC writeback)
mull_op_a_q    := rf_rb_data       // = Rm  (operand A for multiplier)
mull_op_b_q    := rf_rc_data       // = Rs  (operand B for multiplier)
mull_signed_q  := dec.mul_signed   // SMLAL = 1, UMLAL = 0
mull_active_q  := 1                // → S_MULL_HI after S_MUL_BUSY
```

### S_MULL_ACC

`ra_addr_eff = mull_rdhi_q` (= RdHi register, dec is stale by now).

`rf_ra_data = regs[mull_rdhi_q] = RdHi's current value`.

Multiplier inputs muxed for this state:
```
op_a    = mull_op_a_q   // latched Rm
op_b    = mull_op_b_q   // latched Rs
acc_lo  = acc_lo_q      // latched RdLo
acc_hi  = rf_ra_data    // live RdHi
is_long = 1
accumulate = 1
is_signed = mull_signed_q
```

Multiplier output:
```
result_lo = (Rm * Rs + {RdHi, RdLo})[31:0]  ← final RdLo value
result_hi = (Rm * Rs + {RdHi, RdLo})[63:32] ← final RdHi value
```

Commit at this cycle's posedge:
```
regs[mull_rdlo_q] := mul_result_lo       // RdLo writeback
mull_result_hi_q  := mul_result_hi       // latch RdHi for S_MULL_HI
mul_busy_remaining_q := mul_cycle_count  // arm S_MUL_BUSY countdown
```

### Why latches are mandatory

`de_q.dec` advances at the posedge ending S_EXEC because `!e_busy` is true that cycle (E is in S_EXEC, not yet in S_MULL_ACC) — so D consumes `fd_q` and produces a new `de_q.dec` for the next instruction.

By S_MULL_ACC, references to `dec.rn`, `dec.rd`, `dec.rm`, `dec.rs` would read the *following* instruction's fields. The 5 latches above (plus `mull_signed_q`) freeze the necessary UMLAL state so S_MULL_ACC sees correct values.

This is the same `de_q` staleness trap discussed in PIPELINE.md — UMLAL is the worst case because it needs four operand-related fields, more than any other multi-cycle op.

### What if we just suppressed D advance?

Alternative considered and rejected: gate `d_advance` to not fire when entering S_MULL_ACC. This would keep `de_q.dec` valid through the substate, eliminating the latches. But it cascades — D not advancing means `fd_q` doesn't drain, F can't latch a new fetch, and the pipeline goes 1 cycle slower. Not worth it for a corner case.

The latches are local to MULL handling and don't perturb the general pipeline shape.

## Flag updates (S bit set)

When the S bit is set:

| Form | N | Z | C | V |
|---|---|---|---|---|
| MUL/MLA | result[31] | result[31:0] == 0 | unchanged | unchanged |
| UMULL/SMULL/UMLAL/SMLAL | result_hi[31] | full result == 0 | unchanged | unchanged |

The multiplier exposes `n_out` and `z_out` computed from the 64-bit product width (`is_long ? product[63] : product[31]`, `is_long ? (product == 0) : (product[31:0] == 0)`). The core's CPSR write mux uses these via the `flags_from_mul` path.

Flag update timing for UMLAL/SMLAL is deferred to `S_MULL_ACC`, after both
accumulator halves have been read and the final 64-bit sum is present. The core
latches the instruction's S bit in `mull_s_q`, so advancing Decode cannot either
lose or spuriously create that later flag commit. Non-accumulating multiply forms
commit flags from their already-final result in `S_EXEC`.

## Files

- `rtl/datapath/arm7tdmis_multiplier.sv` — the multiplier itself.
- `rtl/core/arm7tdmis_core_pipelined.sv` — substate FSM, latches, writeback mux.
- `tb/unit/multiplier_tb.sv` — unit tests for the multiplier datapath.
- `tb/integration/arm7tdmis_umull_tb.sv` — end-to-end UMULL with 2^32 product.
- `tb/integration/arm7tdmis_umlal_tb.sv` — end-to-end UMLAL with non-zero accumulator.
- `tb/integration/arm7tdmis_mull_flags_tb.sv` — final accumulated N/Z timing.
- `tb/integration/arm7tdmis_multiply_matrix_tb.sv` — all forms, S settings,
  defined aliases, extrema, and m=1/2/3/4 architectural timing.
