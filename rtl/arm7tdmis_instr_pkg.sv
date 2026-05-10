// Instruction-encoding constants. Kept minimal at §1 — fuller decode tables
// (data-processing/load-store/multiply/branch/PSR-transfer field maps) land
// in §8/§15 alongside the decoders.

package arm7tdmis_instr_pkg;

    // ---- Condition codes (instr[31:28] in ARM state) ----
    // NV (4'hF) is reserved in ARMv4T and must trap as Undefined; it is
    // intentionally listed so decoders can name it explicitly.
    typedef enum logic [3:0] {
        COND_EQ = 4'h0, COND_NE = 4'h1, COND_CS = 4'h2, COND_CC = 4'h3,
        COND_MI = 4'h4, COND_PL = 4'h5, COND_VS = 4'h6, COND_VC = 4'h7,
        COND_HI = 4'h8, COND_LS = 4'h9, COND_GE = 4'hA, COND_LT = 4'hB,
        COND_GT = 4'hC, COND_LE = 4'hD, COND_AL = 4'hE, COND_NV = 4'hF
    } cond_e;

    // ---- Register indices: r13/r14/r15 names ----
    localparam logic [3:0] REG_SP = 4'd13;
    localparam logic [3:0] REG_LR = 4'd14;
    localparam logic [3:0] REG_PC = 4'd15;

    // ---- PC pipeline offsets (TRM §2.4 / TASKS.md §0).
    // The executing instruction reads PC ahead of itself by 2 instructions
    // due to the prefetch pipeline: +8 in ARM state, +4 in Thumb state.
    localparam logic [31:0] PC_AHEAD_ARM   = 32'd8;
    localparam logic [31:0] PC_AHEAD_THUMB = 32'd4;

endpackage
