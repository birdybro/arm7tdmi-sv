// Full ARM instruction decoder (TASKS.md §8).
//
// One pass over the 32-bit instruction word produces a `decoded_t` micro-op
// classifying the instruction into one of 16 categories and extracting the
// fields each execute unit will need. The decode tree is hierarchical:
// branch on instr[27:25] for the coarse group, then refine with bit
// patterns specific to each form.
//
// Encoding references (ARM ARM B.1 / TRM Ch. 7):
//   BX         : cond 0001 0010 1111 1111 1111 0001 Rm
//   MRS        : cond 0001 0R00 1111 Rd   0000 0000 0000
//   MSR reg    : cond 0001 0R10 mask 1111 0000 0000 Rm
//   MSR imm    : cond 0011 0R10 mask 1111 rot4 imm8
//   MUL  / MLA : cond 0000 00AS Rd   Rn   Rs   1001 Rm
//   MULL       : cond 0000 1UAS RdHi RdLo Rs   1001 Rm
//   SWP        : cond 0001 0B00 Rn   Rd   0000 1001 Rm
//   LDRH/STRH  : cond 000P U_WL Rn   Rd   offs 1SH1 Rm/offs  (S/H from bits[6:5])
//   DP         : cond 00Iopc S  Rn   Rd   operand2
//   LDR/STR    : cond 01IP UBWL Rn   Rd   offset
//   LDM/STM    : cond 100P USWL Rn   register_list
//   B / BL     : cond 101L offset24
//   LDC/STC    : cond 110P UNWL Rn   CRd  CP#  offset8
//   CDP        : cond 1110 op1 0 CRn CRd CP# op2 0 CRm
//   MCR/MRC    : cond 1110 op1 L CRn Rd  CP# op2 1 CRm
//   SWI        : cond 1111 comment24

module arm7tdmis_decoder
    import arm7tdmis_types_pkg::*;
    import arm7tdmis_instr_pkg::*;
(
    input  logic [31:0] instr,
    output decoded_t    dec,

    // Scalar shortcuts for the §7 core's writeback gating. is_test_op is
    // available via dec.is_test_op directly; classification scalars stay
    // separate so the core doesn't need to import the decode-class enum.
    output logic        is_dataproc,
    output logic        is_unimplemented
);

    // ---- Class detection ----
    instr_class_e c;

    always_comb begin
        c = INSTR_UNDEF;

        unique case (instr[27:25])
            3'b000: begin
                // 000 group: DP-reg, multiply, swap, halfword, MRS/MSR-reg, BX
                if (instr[27:4] == 24'h12FFF1) begin
                    c = INSTR_BX;
                end else if (instr[27:22] == 6'b000000 && instr[7:4] == 4'b1001) begin
                    c = INSTR_MUL;
                end else if (instr[27:23] == 5'b00001 && instr[7:4] == 4'b1001) begin
                    c = INSTR_MULL;
                end else if (instr[27:23] == 5'b00010 && instr[21:20] == 2'b00
                          && instr[11:4] == 8'b0000_1001) begin
                    c = INSTR_SWP;
                end else if (instr[27:23] == 5'b00010 && instr[21:20] == 2'b00
                          && instr[19:16] == 4'b1111 && instr[11:0] == 12'h000) begin
                    c = INSTR_MRS;
                end else if (instr[27:23] == 5'b00010 && instr[21:20] == 2'b10
                          && instr[15:12] == 4'b1111 && instr[11:4] == 8'h00) begin
                    c = INSTR_MSR;
                end else if (instr[7] == 1'b1 && instr[4] == 1'b1
                          && instr[6:5] != 2'b00) begin
                    // Halfword / signed: bits[6:5] = SH != 00
                    c = INSTR_LDRH_STRH;
                end else begin
                    // Anything left in the 000 bucket is DP register form.
                    // The shift-by-register sub-form has bit[7]=0 && bit[4]=1;
                    // shift-by-immediate has bit[4]=0. Both → INSTR_DP.
                    c = INSTR_DP;
                end
            end

            3'b001: begin
                // 001 group: DP-imm or MSR-imm
                if (instr[24:23] == 2'b10 && instr[21:20] == 2'b10
                  && instr[15:12] == 4'b1111) begin
                    c = INSTR_MSR;
                end else if (instr[24:23] == 2'b10 && instr[21:20] == 2'b00) begin
                    // The 001 1 0R00 ... encoding has no defined meaning
                    // in ARMv4T (the matching reg-form is MRS, which lives
                    // in the 000 group). Treat as undefined.
                    c = INSTR_UNDEF;
                end else begin
                    c = INSTR_DP;
                end
            end

            3'b010: c = INSTR_LDR_STR;                                // LDR/STR imm offset

            3'b011: c = (instr[4] == 1'b0) ? INSTR_LDR_STR            // LDR/STR reg offset
                                            : INSTR_UNDEF;            // bit 4 = 1 reserved

            3'b100: c = INSTR_LDM_STM;
            3'b101: c = INSTR_BRANCH;
            3'b110: c = INSTR_LDC_STC;

            3'b111: begin
                if (instr[24] == 1'b1) begin
                    c = INSTR_SWI;
                end else if (instr[4] == 1'b0) begin
                    c = INSTR_CDP;
                end else begin
                    c = INSTR_MCR_MRC;
                end
            end

            default: c = INSTR_UNDEF;
        endcase
    end

    // ---- Field extraction. Most fields just slice the instruction word;
    //      the few that depend on class (immediate construction, branch
    //      sign extension) are computed once and routed.

    // Sign-extend B/BL offset: instr[23:0] << 2, then sign-extend to 32 bits.
    // The architectural definition adds this to PC (which is +8 ahead in
    // ARM state due to the prefetch pipeline) to form the branch target.
    wire signed [31:0] branch_off_signed = {{6{instr[23]}}, instr[23:0], 2'b00};

    // DP-imm operand2: 8-bit value rotated right by 2*rot4. The shifter's
    // amount-0 path passes input through with carry=carry_in, which is
    // exactly the ARM rule for rot4=0 — so no special-case logic needed in
    // the core. The decoder simply hands the shifter the imm and amount.
    function automatic logic [31:0] ror_imm(input logic [7:0] imm8,
                                            input logic [4:0] amt);
        if (amt == 5'd0) return {24'h0, imm8};
        else             return ({24'h0, imm8} >> amt) | ({24'h0, imm8} << (5'd0 - amt));
    endfunction

    wire [4:0]  dp_imm_rot  = {instr[11:8], 1'b0};   // 2 * rot4
    wire [31:0] dp_imm_full = ror_imm(instr[7:0], dp_imm_rot);

    // Halfword/signed S/H bits (instr[6:5]):
    //   01 = LDRH/STRH       (H=1, S=0)
    //   10 = LDRSB           (H=0, S=1)
    //   11 = LDRSH           (H=1, S=1)
    wire hs_signed_bit    = instr[6];
    wire hs_halfword_bit  = instr[5];

    // ---- Stitch the struct ----
    always_comb begin
        dec = '0;

        dec.instr_class = c;
        dec.cond        = cond_e'(instr[31:28]);

        dec.rd          = instr[15:12];
        dec.rn          = instr[19:16];
        dec.rm          = instr[3:0];
        dec.rs          = instr[11:8];

        // DP / multiply
        dec.alu_op      = alu_op_e'(instr[24:21]);
        dec.s_bit       = instr[20];

        case (alu_op_e'(instr[24:21]))
            ALU_TST, ALU_TEQ, ALU_CMP, ALU_CMN: dec.is_test_op = 1'b1;
            default:                            dec.is_test_op = 1'b0;
        endcase

        // Operand2 routing for DP. The DP-imm path (bits[27:25]=001) carries
        // an immediate; the DP-reg path (000) uses Rm + optional shift.
        dec.dp_use_imm   = (instr[27:25] == 3'b001);
        dec.dp_imm_value = dp_imm_full;

        // Shifter control for DP-imm. For DP-reg the shift op/amount live in
        // instr[6:5] and instr[11:7] (imm-shift) or instr[11:8]=Rs (reg-shift).
        if (dec.dp_use_imm) begin
            // DP-imm: feed shifter the imm value through a ROR by 2*rot4.
            // Equivalent to letting the decoder pre-rotate (dp_imm_value)
            // but we expose the raw shifter recipe too for the §9 core.
            dec.shifter_op      = SHIFT_ROR;
            dec.shifter_amount  = {3'h0, dp_imm_rot};
            dec.shifter_is_rrx  = 1'b0;
            dec.shifter_use_rs  = 1'b0;
        end else begin
            dec.shifter_op      = shift_op_e'(instr[6:5]);
            // shift-by-immediate: amount in instr[11:7].
            // shift-by-register: amount = Rs[7:0] — the core picks this up
            // when shifter_use_rs=1.
            dec.shifter_amount  = (instr[4]) ? 8'h00 : {3'h0, instr[11:7]};
            // ROR #0 (imm-shift) is encoded as RRX.
            dec.shifter_is_rrx  = (instr[27:25] == 3'b000) && (instr[4] == 1'b0)
                                && (instr[6:5] == 2'b11) && (instr[11:7] == 5'b00000);
            dec.shifter_use_rs  = (instr[27:25] == 3'b000) && (instr[4] == 1'b1)
                                && (instr[7] == 1'b0);
        end

        // Multiply
        dec.mul_accumulate = instr[21];
        dec.mul_signed     = (c == INSTR_MULL) ? ~instr[22] : 1'b0;  // U=0 → signed

        // Branch
        dec.branch_link    = instr[24];
        dec.branch_offset  = branch_off_signed;

        // Load/Store single
        dec.ls_pre_index   = instr[24];
        dec.ls_up          = instr[23];
        dec.ls_byte        = instr[22];
        dec.ls_writeback   = instr[21];
        dec.ls_load        = instr[20];
        dec.ls_use_imm     = (instr[27:25] == 3'b010);
        dec.ls_imm_offset  = instr[11:0];

        // Halfword / signed
        dec.hs_signed      = hs_signed_bit;
        dec.hs_halfword    = hs_halfword_bit;
        dec.hs_use_imm     = instr[22];                  // bit 22 picks imm vs reg form
        dec.hs_imm_offset  = {instr[11:8], instr[3:0]};  // split-immediate

        // Block transfer
        dec.block_pre_index  = instr[24];
        dec.block_up         = instr[23];
        dec.block_user_mode  = instr[22];                // S bit
        dec.block_writeback  = instr[21];
        dec.block_load       = instr[20];
        dec.block_reg_list   = instr[15:0];

        // PSR transfer
        dec.psr_use_spsr     = instr[22];                // R bit
        dec.msr_field_mask   = instr[19:16];
        dec.msr_use_imm      = (instr[27:25] == 3'b001);

        // SWI
        dec.swi_comment      = instr[23:0];

        // Coprocessor — placeholder field, more come in §19.
        dec.cp_num           = instr[11:8];
    end

    // ---- Scalar shortcuts. The core's "unimplemented" gate expands as
    //      each milestone wires its execute path:
    //        §7  → DP-imm
    //        §9  → DP register-form
    //        §10 → BRANCH (B/BL) and BX
    //        §11+→ LDR/STR, LDM/STM, MUL, SWP, MSR/MRS, SWI, coproc
    assign is_dataproc      = (c == INSTR_DP);
    assign is_unimplemented = !((c == INSTR_DP)
                              || (c == INSTR_BRANCH)
                              || (c == INSTR_BX));

endmodule
