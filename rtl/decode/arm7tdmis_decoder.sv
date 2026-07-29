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
    import arm7tdmis_types_pkg::*, arm7tdmis_instr_pkg::*;
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
                end else if ((instr[7:4] == 4'b1011)
                          || (instr[20]
                           && ((instr[7:4] == 4'b1101)
                            || (instr[7:4] == 4'b1111)))) begin
                    // ARMv4T extra transfers: STRH/LDRH use 1011;
                    // signed byte/halfword forms (1101/1111) are loads
                    // only. The L=0 signed patterns were allocated as
                    // doubleword transfers only by later architectures.
                    c = INSTR_LDRH_STRH;
                end else if (instr[7] && instr[4]) begin
                    // Unallocated multiply/extra-transfer decode row.
                    c = INSTR_UNDEF;
                end else if ((instr[24:23] == 2'b10) && !instr[20]) begin
                    // Opcode 10xx with S=0 is control-extension space,
                    // not ordinary DP. Exact ARMv4T MRS/MSR/BX masks
                    // were accepted above; every other row is Undefined.
                    c = INSTR_UNDEF;
                end else begin
                    // Anything legal left in the 000 bucket is DP register form.
                    // The shift-by-register sub-form has bit[7]=0 && bit[4]=1;
                    // shift-by-immediate has bit[4]=0. Both → INSTR_DP.
                    c = INSTR_DP;
                end
            end

            3'b001: begin
                // 001 group: DP-imm or MSR-imm
                if ((instr[27:20] == 8'h32) || (instr[27:20] == 8'h36)) begin
                    // A malformed SBO field shares MSR decode bits and is
                    // architecturally UNPREDICTABLE. The core's stable
                    // policy is to trap it instead of executing it as DP.
                    c = (instr[15:12] == 4'b1111) ? INSTR_MSR : INSTR_UNDEF;
                end else if ((instr[27:20] == 8'h30)
                          || (instr[27:20] == 8'h34)) begin
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
            3'b110: begin
                // 11000x0x is the later MCRR/MRRC coprocessor extension
                // space. It is unconditionally Undefined in ARMv4T and
                // must not be offered to an external coprocessor.
                c = ((instr[27:23] == 5'b11000) && !instr[21])
                  ? INSTR_UNDEF : INSTR_LDC_STC;
            end

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

        // ARMv4T assigns several single-transfer register combinations
        // UNPREDICTABLE behavior.  This implementation gives every
        // statically detectable case one deterministic outcome: a precise
        // Undefined-instruction trap before any data cycle is issued.
        //
        // Post-indexed transfers always write the base; pre-indexed
        // transfers write it only when W=1.  Rm is an operand only in the
        // register-offset form (I=1 for mode 2, I=0 for mode 3).
        if (c == INSTR_LDR_STR) begin
            if (((!instr[24] || instr[21])
              && ((instr[19:16] == instr[15:12])
               || (instr[19:16] == 4'hF)))
             || (instr[25]
              && ((instr[3:0] == 4'hF)
               || ((!instr[24] || instr[21])
                && (instr[19:16] == instr[3:0]))))
             || (instr[22] && (instr[15:12] == 4'hF)))
                c = INSTR_UNDEF;
        end else if (c == INSTR_LDRH_STRH) begin
            if ((instr[15:12] == 4'hF)
             || (!instr[22] && (instr[11:8] != 4'h0))
             || ((!instr[24] || instr[21])
              && ((instr[19:16] == instr[15:12])
               || (instr[19:16] == 4'hF)))
             || (!instr[22]
              && ((instr[3:0] == 4'hF)
               || ((!instr[24] || instr[21])
                && (instr[19:16] == instr[3:0])))))
                c = INSTR_UNDEF;
        end

        // Allocated instruction rows still contain architecturally
        // constrained operand/SBZ fields. ARMv4T calls violations
        // UNPREDICTABLE rather than Undefined; this implementation gives
        // every statically detectable violation the same safe outcome as
        // the transfer policies above: a precise Undefined trap.
        if (c == INSTR_DP) begin
            // TST/TEQ/CMP/CMN require Rd=0000. MOV/MVN require Rn=0000.
            // (Their required S values are already enforced by the
            // control-extension decode above.)
            if ((((instr[24:21] == 4'h8)
               || (instr[24:21] == 4'h9)
               || (instr[24:21] == 4'hA)
               || (instr[24:21] == 4'hB))
                 && (instr[15:12] != 4'h0))
             || (((instr[24:21] == 4'hD) || (instr[24:21] == 4'hF))
                  && (instr[19:16] != 4'h0)))
                c = INSTR_UNDEF;
        end else if (c == INSTR_MUL) begin
            // MUL's unused accumulator field is SBZ. All four MLA
            // operands, or all three MUL operands, exclude r15.
            if ((instr[19:16] == 4'hF)
             || (instr[11:8]  == 4'hF)
             || (instr[3:0]   == 4'hF)
             || (instr[21] && (instr[15:12] == 4'hF))
             || (!instr[21] && (instr[15:12] != 4'h0)))
                c = INSTR_UNDEF;
        end else if (c == INSTR_MULL) begin
            if ((instr[19:16] == 4'hF)
             || (instr[15:12] == 4'hF)
             || (instr[11:8]  == 4'hF)
             || (instr[3:0]   == 4'hF)
             || (instr[19:16] == instr[15:12]))
                c = INSTR_UNDEF;
        end else if (c == INSTR_MRS) begin
            if (instr[15:12] == 4'hF)
                c = INSTR_UNDEF;
        end else if (c == INSTR_MSR) begin
            // The assembly syntax requires one or more selected fields.
            // The register source likewise excludes the PC on r4p3.
            if ((instr[19:16] == 4'h0)
             || (!instr[25] && (instr[3:0] == 4'hF)))
                c = INSTR_UNDEF;
        end else if (c == INSTR_LDC_STC) begin
            // Offset/unindexed Rn=pc is defined as pc+8. Either indexed
            // form (W=1) would write back to r15 and is UNPREDICTABLE.
            if (instr[21] && (instr[19:16] == 4'hF))
                c = INSTR_UNDEF;
        end

        // ARMv4 defines cond=1111 as UNPREDICTABLE. ARMv5+ reuses it for
        // unconditional extensions, none of which exist on ARM7TDMI-S.
        // The selected deterministic policy is a precise Undefined trap.
        if (instr[31:28] == 4'hF)
            c = INSTR_UNDEF;
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
            // In ARM's immediate form an all-zero field encodes 32 for
            // LSR/ASR.  LSL keeps the literal zero and ROR #0 is selected
            // separately as RRX below.
            // shift-by-register: amount = Rs[7:0] — the core picks this up
            // when shifter_use_rs=1.
            if (!instr[4] && instr[11:7] == 5'h00
                && ((instr[6:5] == 2'b01) || (instr[6:5] == 2'b10)))
                dec.shifter_amount = 8'd32;
            else
                dec.shifter_amount = instr[4] ? 8'h00
                                              : {3'h0, instr[11:7]};
            // ROR #0 (imm-shift) is encoded as RRX.
            dec.shifter_is_rrx  = ((instr[27:25] == 3'b000)
                                || (instr[27:25] == 3'b011))
                                && (instr[4] == 1'b0)
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
    //        §11 → LDR/STR (immediate offset, pre-indexed, no writeback)
    //        §11b+→ post-index / writeback / register offset / halfword
    //        §12+→ LDM/STM, MUL, SWP, MSR/MRS, SWI, coproc
    //      The core further restricts LDR_STR to the supported subset.
    assign is_dataproc      = (c == INSTR_DP);
    assign is_unimplemented = !((c == INSTR_DP)
                              || (c == INSTR_BRANCH)
                              || (c == INSTR_BX)
                              || (c == INSTR_LDR_STR)
                              || (c == INSTR_LDM_STM)
                              || (c == INSTR_SWP)
                              || (c == INSTR_SWI)
                              || (c == INSTR_MUL)
                              || (c == INSTR_MULL)
                              || (c == INSTR_MSR)
                              || (c == INSTR_MRS)
                              || (c == INSTR_LDRH_STRH)
                              || (c == INSTR_CDP)
                              || (c == INSTR_MCR_MRC)
                              || (c == INSTR_LDC_STC));

endmodule
