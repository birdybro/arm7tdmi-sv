// ARM7TDMI-S multiplier (TASKS.md §5.3): MUL/MLA/UMULL/UMLAL/SMULL/SMLAL.
//
// Single-cycle 32×32 → 64 multiplier with optional accumulate. The bare `*`
// infers a Cyclone V variable-precision DSP block (per AGENTS.md); we
// don't hand-roll an array multiplier. Cycle-accurate behavior — the real
// macrocell is multi-cycle with early termination — is shaped externally
// by the cycle controller, which uses the `cycle_count` (m parameter)
// output to insert the right number of I-cycles. See §30.5.1.
//
// Operand convention: op_a = Rm, op_b = Rs. The m parameter is computed
// from Rs (op_b) per the TRM:
//   m = 1 if Rs[31:8]  is all 0 or all 1
//   m = 2 if Rs[31:16] is all 0 or all 1   (and m=1 didn't match)
//   m = 3 if Rs[31:24] is all 0 or all 1   (and m=1,2 didn't match)
//   m = 4 otherwise
// The total cycle count for each multiply form is then:
//   MUL          : m·I + S
//   MLA          : (m+1)·I + S
//   UMULL/SMULL  : (m+1)·I + S
//   UMLAL/SMLAL  : (m+2)·I + S
// — that "extra cycles for accumulate / long" mapping lives in the cycle
// controller, not here.
//
// Flag write mask (TRM §30.5 / ARMv4 ARM): only N and Z update on S
// variants. C is architecturally UNPREDICTABLE on ARMv4 multiplies — we
// preserve it (don't write); V is unaffected. flag_we = 4'b1100.
//
// Accumulate input convention:
//   - MLA   : 32-bit accumulator in acc_lo (Rn), acc_hi unused.
//   - UMLAL/SMLAL : 64-bit accumulator in {acc_hi, acc_lo} (RdHi, RdLo).

module arm7tdmis_multiplier (
    input  logic        is_signed,    // SMULL/SMLAL
    input  logic        is_long,      // UMULL/UMLAL/SMULL/SMLAL (vs MUL/MLA)
    input  logic        accumulate,   // MLA/UMLAL/SMLAL
    input  logic [31:0] op_a,         // Rm
    input  logic [31:0] op_b,         // Rs
    input  logic [31:0] acc_lo,       // Rn (MLA) or RdLo (long-accumulate)
    input  logic [31:0] acc_hi,       // RdHi (long-accumulate); unused on MLA
    output logic [31:0] result_lo,
    output logic [31:0] result_hi,
    output logic        n_out,
    output logic        z_out,
    output logic [3:0]  flag_we,
    output logic [2:0]  cycle_count   // m parameter, 1..4
);

    // ---- 64-bit-extended operands so the multiply produces a 64-bit
    //      product without truncation. Sign-extend for signed forms,
    //      zero-extend for unsigned (and for short MUL/MLA, where the
    //      sign-vs-unsigned distinction doesn't matter for the low 32
    //      bits we keep).
    logic [63:0] op_a_ext;
    logic [63:0] op_b_ext;
    logic [63:0] product;
    logic [63:0] accumulator;

    always_comb begin
        op_a_ext    = is_signed ? {{32{op_a[31]}}, op_a} : {32'h0, op_a};
        op_b_ext    = is_signed ? {{32{op_b[31]}}, op_b} : {32'h0, op_b};
        accumulator = accumulate
                        ? (is_long ? {acc_hi, acc_lo} : {32'h0, acc_lo})
                        : 64'h0;
        product     = (op_a_ext * op_b_ext) + accumulator;
    end

    assign result_lo = product[31:0];
    assign result_hi = is_long ? product[63:32] : 32'h0;

    // ---- Flags ----
    assign n_out   = is_long ? product[63] : product[31];
    assign z_out   = is_long ? (product == 64'h0) : (product[31:0] == 32'h0);
    assign flag_we = 4'b1100;     // N, Z update; C unpredictable (we preserve), V unaffected

    // ---- m parameter — early-termination cycle count. Only the top
    //      24 bits of Rs are inspected (low bits are immaterial), so
    //      the function takes that slice directly to keep lint clean.
    //      Indices below refer to Rs: bits 8..31 → rs_top 0..23.
    function automatic logic [2:0] compute_m(input logic [23:0] rs_top);
        // rs_top[23:0]  ↔ Rs[31:8]   → m=1 if all-0 or all-1
        // rs_top[23:8]  ↔ Rs[31:16]  → m=2 if all-0 or all-1
        // rs_top[23:16] ↔ Rs[31:24]  → m=3 if all-0 or all-1
        if      (rs_top         == 24'h0  || rs_top         == 24'hFFFFFF) return 3'd1;
        else if (rs_top[23:8]   == 16'h0  || rs_top[23:8]   == 16'hFFFF)   return 3'd2;
        else if (rs_top[23:16]  == 8'h0   || rs_top[23:16]  == 8'hFF)      return 3'd3;
        else                                                               return 3'd4;
    endfunction

    assign cycle_count = compute_m(op_b[31:8]);

endmodule
