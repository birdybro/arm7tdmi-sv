// Instruction-encoding constants and decoded-instruction struct.
// Field-position constants are kept minimal at §1; classification and the
// full normalized micro-op land here in §8 so every downstream execute unit
// can consume the same shape.

package arm7tdmis_instr_pkg;

    import arm7tdmis_types_pkg::*;

    // ---- Condition codes (instr[31:28] in ARM state) ----
    // NV (4'hF) is UNPREDICTABLE in ARMv4 and is assigned the stable policy
    // of a precise Undefined trap here. It is named explicitly so no ARMv5+
    // unconditional encoding can enter an ARM7TDMI-S execute path.
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

    // ---- Instruction classification (TASKS.md §8) ----
    // Coarse class of the decoded instruction. Execute units route on this
    // enum; field interpretation is class-dependent.
    typedef enum logic [3:0] {
        INSTR_UNDEF      = 4'h0,
        INSTR_DP         = 4'h1,   // data processing (imm or register form)
        INSTR_MSR        = 4'h2,   // MSR CPSR/SPSR
        INSTR_MRS        = 4'h3,   // MRS CPSR/SPSR -> Rd
        INSTR_MUL        = 4'h4,   // MUL / MLA (32-bit)
        INSTR_MULL       = 4'h5,   // UMULL / UMLAL / SMULL / SMLAL (64-bit)
        INSTR_BRANCH     = 4'h6,   // B / BL
        INSTR_BX         = 4'h7,   // BX (branch and exchange — ARM↔Thumb)
        INSTR_LDR_STR    = 4'h8,   // single word/byte transfer
        INSTR_LDRH_STRH  = 4'h9,   // halfword / signed-byte / signed-halfword
        INSTR_LDM_STM    = 4'hA,   // block transfer
        INSTR_SWP        = 4'hB,   // word/byte swap
        INSTR_SWI        = 4'hC,   // software interrupt
        INSTR_CDP        = 4'hD,   // coprocessor data op
        INSTR_MCR_MRC    = 4'hE,   // coprocessor register transfer
        INSTR_LDC_STC    = 4'hF    // coprocessor load/store
    } instr_class_e;

    // ---- Normalized decoded instruction. The decoder produces one of
    //      these per cycle; execute units pick the fields relevant to
    //      their class. Fields not relevant to the current instr_class
    //      are valid in the SystemVerilog sense (defined bits) but
    //      semantically meaningless — execute logic must gate on
    //      instr_class first.
    typedef struct packed {
        instr_class_e instr_class;
        cond_e        cond;

        // Common register addresses
        logic [3:0]   rd;            // also RdLo for MULL
        logic [3:0]   rn;            // also RdHi for MULL
        logic [3:0]   rm;
        logic [3:0]   rs;

        // DP / multiply
        alu_op_e      alu_op;        // DP only
        logic         s_bit;         // DP / multiply
        logic         is_test_op;    // TST/TEQ/CMP/CMN — no Rd writeback

        // Operand2 routing for DP
        logic         dp_use_imm;    // 1 = use dp_imm_value; 0 = shift Rm
        logic         dp_use_raw_imm; // §15m: bypass shifter — use dp_imm_value
                                      //       directly as op_b. Used for Thumb BL
                                      //       prefix where the addend (hi << 12)
                                      //       can't be expressed as imm8 ROR.
        logic         dp_pc_align;   // §15.12 Thumb fmt12 PC-form: read Rn=15
                                      //       and mask bits[1:0] to force a
                                      //       word-aligned base (TRM/ARM ARM
                                      //       "PC AND ~3" for ADD Rd, PC, #imm).
        logic [31:0]  dp_imm_value;  // imm8 ROR (2*rot4) — DP-imm path
        shift_op_e    shifter_op;
        logic [7:0]   shifter_amount;
        logic         shifter_is_rrx;
        logic         shifter_use_rs; // DP-reg: shift amount comes from Rs

        // Multiply
        logic         mul_accumulate; // A bit (MLA / UMLAL / SMLAL)
        logic         mul_signed;     // U bit cleared (signed for SMULL/SMLAL)

        // Branch
        logic         branch_link;
        logic [31:0]  branch_offset;  // sign-extended (offset24 << 2)
        // §15m Thumb BL extensions:
        logic         branch_use_rn_base;  // target = rf_ra_data + branch_offset
                                            //          (rather than pc_q + 4/8 + offset)
        logic         branch_thumb_link;   // LR write = (pc_q + 2) | 1
                                            //          (Thumb BL suffix's return-addr form)

        // Load/Store single
        logic         ls_pre_index;
        logic         ls_up;
        logic         ls_byte;
        logic         ls_writeback;
        logic         ls_load;
        logic         ls_use_imm;
        logic [11:0]  ls_imm_offset;

        // Halfword / signed transfer specifics
        logic         hs_signed;
        logic         hs_halfword;
        logic         hs_use_imm;
        logic [7:0]   hs_imm_offset;

        // Block transfer
        logic         block_pre_index;
        logic         block_up;
        logic         block_user_mode;  // S bit
        logic         block_writeback;
        logic         block_load;
        logic [15:0]  block_reg_list;

        // PSR transfer
        logic         psr_use_spsr;     // R bit
        logic [3:0]   msr_field_mask;   // {f,s,x,c}
        logic         msr_use_imm;

        // SWI
        logic [23:0]  swi_comment;

        // Coprocessor (placeholder — full fields come in §19)
        logic [3:0]   cp_num;

    } decoded_t;

endpackage
