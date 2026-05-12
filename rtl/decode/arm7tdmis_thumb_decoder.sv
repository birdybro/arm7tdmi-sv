// Thumb instruction decoder (TASKS.md §15).
//
// Produces the same decoded_t micro-op as the ARM decoder so the core's
// execute paths don't need a parallel Thumb-specific datapath — Thumb is
// just a more compact encoding that translates to ARM-equivalent ops.
//
// Minimum viable Thumb coverage in this commit:
//
//   Format 3  MOV/CMP/ADD/SUB immediate (Rd[7:0] from low 3 bits, imm8)
//   Format 5  BX (branch and exchange — also the way back to ARM)
//
// Other Thumb formats (1-2, 4, 6-19) fall to INSTR_UNDEF and will be
// added incrementally. All Thumb DP ops always update flags (no S bit),
// and Thumb is unconditional except for the conditional B variant.

module arm7tdmis_thumb_decoder
    import arm7tdmis_types_pkg::*;
    import arm7tdmis_instr_pkg::*;
(
    input  logic [15:0] thumb_instr,
    output decoded_t    dec,
    output logic        is_dataproc,
    output logic        is_unimplemented
);

    // ---- Format detection (priority order matters: Format 2 is a more
    //      specific subset of the bits-13:11=000 region than Format 1) ----
    wire is_fmt2     = (thumb_instr[15:11] == 5'b00011);            // ADD/SUB reg/imm
    wire is_fmt1     = (thumb_instr[15:13] == 3'b000) && !is_fmt2;  // MOV shifted reg
    wire is_fmt3     = (thumb_instr[15:13] == 3'b001);              // MOV/CMP/ADD/SUB imm
    wire is_fmt4     = (thumb_instr[15:10] == 6'b010000);           // ALU reg-reg
    wire is_fmt5_bx  = (thumb_instr[15:8] == 8'b0100_0111);          // BX (also BLX in v5)
    wire is_fmt9     = (thumb_instr[15:13] == 3'b011);              // L/S imm offset
    wire is_fmt11    = (thumb_instr[15:12] == 4'b1001);             // SP-rel L/S
    wire is_fmt12    = (thumb_instr[15:12] == 4'b1010);             // load address
    wire is_fmt13    = (thumb_instr[15:8]  == 8'b1011_0000);        // SP add/sub
    wire is_fmt14    = (thumb_instr[15:12] == 4'b1011)              // PUSH / POP
                     && (thumb_instr[10:9] == 2'b10);
    wire is_fmt15    = (thumb_instr[15:12] == 4'b1100);             // LDMIA / STMIA
    wire is_fmt16_17 = (thumb_instr[15:12] == 4'b1101);             // B-cond / SWI
    wire is_fmt17_swi = is_fmt16_17 && (thumb_instr[11:8] == 4'b1111);
    wire is_fmt16_b  = is_fmt16_17 && !is_fmt17_swi;
    wire is_fmt18_b  = (thumb_instr[15:11] == 5'b11100);            // B unconditional

    // ---- Field extraction ----
    wire [1:0]  fmt1_op    = thumb_instr[12:11];      // 00=LSL 01=LSR 10=ASR
    wire [4:0]  fmt1_imm5  = thumb_instr[10:6];
    wire [2:0]  fmt1_rs    = thumb_instr[5:3];
    wire [2:0]  fmt1_rd    = thumb_instr[2:0];

    wire        fmt2_imm   = thumb_instr[10];          // 0=register, 1=imm3
    wire        fmt2_op    = thumb_instr[9];           // 0=ADD, 1=SUB
    wire [2:0]  fmt2_rn3   = thumb_instr[8:6];         // Rn or imm3
    wire [2:0]  fmt2_rs    = thumb_instr[5:3];
    wire [2:0]  fmt2_rd    = thumb_instr[2:0];

    wire [1:0]  fmt3_op    = thumb_instr[12:11];
    wire [2:0]  fmt3_rd    = thumb_instr[10:8];
    wire [7:0]  fmt3_imm8  = thumb_instr[7:0];

    wire [3:0]  fmt4_op    = thumb_instr[9:6];
    wire [2:0]  fmt4_rs    = thumb_instr[5:3];
    wire [2:0]  fmt4_rd    = thumb_instr[2:0];

    // Format 4 op-class helpers.
    wire fmt4_is_shift = (fmt4_op == 4'b0010) || (fmt4_op == 4'b0011)
                       || (fmt4_op == 4'b0100) || (fmt4_op == 4'b0111);
    wire fmt4_is_neg   = (fmt4_op == 4'b1001);
    wire fmt4_is_test  = (fmt4_op == 4'b1000) || (fmt4_op == 4'b1010)
                       || (fmt4_op == 4'b1011);
    wire fmt4_is_mul   = (fmt4_op == 4'b1101);

    function automatic alu_op_e fmt4_alu(input logic [3:0] op);
        case (op)
            4'b0000: return ALU_AND;
            4'b0001: return ALU_EOR;
            4'b0010, 4'b0011, 4'b0100, 4'b0111: return ALU_MOV;   // shift via register
            4'b0101: return ALU_ADC;
            4'b0110: return ALU_SBC;
            4'b1000: return ALU_TST;
            4'b1001: return ALU_RSB;     // NEG Rd, Rs = RSB Rd, Rs, #0
            4'b1010: return ALU_CMP;
            4'b1011: return ALU_CMN;
            4'b1100: return ALU_ORR;
            4'b1110: return ALU_BIC;
            4'b1111: return ALU_MVN;
            default: return ALU_MOV;
        endcase
    endfunction

    function automatic shift_op_e fmt4_shift(input logic [3:0] op);
        case (op)
            4'b0010: return SHIFT_LSL;
            4'b0011: return SHIFT_LSR;
            4'b0100: return SHIFT_ASR;
            4'b0111: return SHIFT_ROR;
            default: return SHIFT_LSL;
        endcase
    endfunction

    wire [3:0]  fmt5_rm    = thumb_instr[6:3];

    // Format 9 (L/S with immediate offset): the 5-bit immediate is
    // scaled by 4 for word and by 1 for byte.
    wire        fmt9_byte  = thumb_instr[12];
    wire        fmt9_load  = thumb_instr[11];
    wire [4:0]  fmt9_imm5  = thumb_instr[10:6];
    wire [2:0]  fmt9_rb    = thumb_instr[5:3];
    wire [2:0]  fmt9_rd    = thumb_instr[2:0];
    wire [11:0] fmt9_off   = fmt9_byte ? {7'h0, fmt9_imm5}
                                       : {5'h0, fmt9_imm5, 2'b00};

    // Format 14 (PUSH/POP) — maps to STMDB SP!, {…} / LDMIA SP!, {…}.
    //   bit[11] = L : 0 = PUSH (store, DB), 1 = POP (load, IA)
    //   bit[8]  = R : when set, include LR for PUSH or PC for POP
    //   bits[7:0]   = r0..r7 mask
    wire        fmt14_load = thumb_instr[11];
    wire        fmt14_R    = thumb_instr[8];
    wire [7:0]  fmt14_lo   = thumb_instr[7:0];
    wire [15:0] fmt14_reglist = {fmt14_load && fmt14_R,        // PC for POP
                                  !fmt14_load && fmt14_R,      // LR for PUSH
                                  6'h0,
                                  fmt14_lo};

    // Format 11: SP-relative LDR/STR.  Rd word-access, offset = imm8 << 2.
    wire        fmt11_load = thumb_instr[11];
    wire [2:0]  fmt11_rd   = thumb_instr[10:8];
    wire [7:0]  fmt11_imm8 = thumb_instr[7:0];
    wire [11:0] fmt11_off  = {2'h0, fmt11_imm8, 2'b00};

    // Format 12: load address — Rd = (SP if S=1, else PC&~3) + imm8<<2.
    // We support only the SP form here; PC-relative would need PC[1:0]
    // masking on the DP-add path.
    wire        fmt12_sp   = thumb_instr[11];
    wire [2:0]  fmt12_rd   = thumb_instr[10:8];
    wire [7:0]  fmt12_imm8 = thumb_instr[7:0];
    wire [31:0] fmt12_imm  = {22'h0, fmt12_imm8, 2'b00};

    // Format 13: SP +/- imm7<<2 (NO flag update — exception to "Thumb DP
    // sets flags" rule for the ADD/SUB-SP variant).
    wire        fmt13_sub  = thumb_instr[7];
    wire [6:0]  fmt13_imm7 = thumb_instr[6:0];
    wire [31:0] fmt13_imm  = {23'h0, fmt13_imm7, 2'b00};

    // Format 15: LDMIA/STMIA Rb!, {r0..r7 mask}. Always IA, always
    // writeback. PC is not in the list (those are Format 14 POP).
    wire        fmt15_load = thumb_instr[11];
    wire [2:0]  fmt15_rb   = thumb_instr[10:8];
    wire [7:0]  fmt15_lo   = thumb_instr[7:0];
    wire [15:0] fmt15_reglist = {8'h0, fmt15_lo};

    // Format 18 unsigned offset is bits[10:0]; ARM ARM scales by 2 and
    // sign-extends to 32 bits. Final branch target = PC + 4 + offset.
    // We hand the core the 32-bit signed value; the core's
    // branch_pc_target adds pc_q + 4 (Thumb) or pc_q + 8 (ARM).
    wire [31:0] fmt18_offset = {{20{thumb_instr[10]}}, thumb_instr[10:0], 1'b0};

    // ---- ALU op for Format 3 ----
    function automatic alu_op_e fmt3_alu_op(input logic [1:0] op);
        case (op)
            2'b00:   return ALU_MOV;
            2'b01:   return ALU_CMP;
            2'b10:   return ALU_ADD;
            2'b11:   return ALU_SUB;
            default: return ALU_MOV;
        endcase
    endfunction

    always_comb begin
        dec = '0;
        dec.cond = COND_AL;     // Thumb DP/branch is unconditional

        if (is_fmt1) begin
            // Format 1: MOV Rd, Rs, <LSL/LSR/ASR> #imm5  (S=1 implicit)
            dec.instr_class    = INSTR_DP;
            dec.alu_op         = ALU_MOV;
            dec.s_bit          = 1'b1;
            dec.rd             = {1'b0, fmt1_rd};
            dec.rm             = {1'b0, fmt1_rs};
            dec.dp_use_imm     = 1'b0;            // operand2 = Rm shifted
            dec.shifter_op     = shift_op_e'(fmt1_op);
            dec.shifter_amount = {3'h0, fmt1_imm5};
            dec.shifter_is_rrx = 1'b0;
            dec.shifter_use_rs = 1'b0;
        end else if (is_fmt2) begin
            // Format 2: ADD/SUB Rd, Rs, {Rn | #imm3}     (S=1 implicit)
            dec.instr_class    = INSTR_DP;
            dec.alu_op         = fmt2_op ? ALU_SUB : ALU_ADD;
            dec.s_bit          = 1'b1;
            dec.rd             = {1'b0, fmt2_rd};
            dec.rn             = {1'b0, fmt2_rs};
            if (fmt2_imm) begin
                // 3-bit immediate, zero-extended
                dec.dp_use_imm     = 1'b1;
                dec.dp_imm_value   = {29'h0, fmt2_rn3};
                dec.shifter_op     = SHIFT_ROR;
                dec.shifter_amount = 8'h00;
            end else begin
                // Register form: operand2 = Rm = fmt2_rn3 (no shift)
                dec.rm             = {1'b0, fmt2_rn3};
                dec.dp_use_imm     = 1'b0;
                dec.shifter_op     = SHIFT_LSL;
                dec.shifter_amount = 8'h00;
            end
            dec.shifter_is_rrx = 1'b0;
            dec.shifter_use_rs = 1'b0;
        end else if (is_fmt4) begin
            // Format 4: ALU register-register, Rd op Rs → Rd  (S=1 implicit)
            dec.s_bit          = 1'b1;
            dec.is_test_op     = fmt4_is_test;
            if (fmt4_is_mul) begin
                // MUL: encoded into our INSTR_MUL path. Operand mapping
                // matches what the core's MUL execute path expects when
                // mul_accumulate=0: dec.rn = destination, dec.rm = Rm,
                // dec.rs = Rs. There's no accumulator.
                dec.instr_class    = INSTR_MUL;
                dec.rn             = {1'b0, fmt4_rd};       // destination
                dec.rd             = {1'b0, fmt4_rd};       // not read (accumulate=0)
                dec.rm             = {1'b0, fmt4_rd};       // multiplicand
                dec.rs             = {1'b0, fmt4_rs};       // multiplier
                dec.mul_accumulate = 1'b0;
                dec.mul_signed     = 1'b0;
            end else begin
                dec.instr_class    = INSTR_DP;
                dec.alu_op         = fmt4_alu(fmt4_op);
                dec.rd             = {1'b0, fmt4_rd};
                if (fmt4_is_shift) begin
                    // MOV Rd, Rd, <shift> Rs (register-shifted-register)
                    dec.rm             = {1'b0, fmt4_rd};
                    dec.rs             = {1'b0, fmt4_rs};
                    dec.dp_use_imm     = 1'b0;
                    dec.shifter_op     = fmt4_shift(fmt4_op);
                    dec.shifter_use_rs = 1'b1;
                    dec.shifter_amount = 8'h00;
                end else if (fmt4_is_neg) begin
                    // NEG Rd, Rs = RSB Rd, Rs, #0
                    dec.rn             = {1'b0, fmt4_rs};
                    dec.dp_use_imm     = 1'b1;
                    dec.dp_imm_value   = 32'h0;
                    dec.shifter_op     = SHIFT_ROR;
                    dec.shifter_amount = 8'h00;
                end else begin
                    // Plain DP: Rd <- Rd <op> Rs
                    dec.rn             = {1'b0, fmt4_rd};
                    dec.rm             = {1'b0, fmt4_rs};
                    dec.dp_use_imm     = 1'b0;
                    dec.shifter_op     = SHIFT_LSL;
                    dec.shifter_amount = 8'h00;
                end
                dec.shifter_is_rrx = 1'b0;
            end
        end else if (is_fmt3) begin
            // Format 3: MOV/CMP/ADD/SUB Rd, #imm8        (S=1 implicit)
            dec.instr_class    = INSTR_DP;
            dec.alu_op         = fmt3_alu_op(fmt3_op);
            dec.s_bit          = 1'b1;
            dec.is_test_op     = (fmt3_op == 2'b01);       // CMP — no Rd write
            dec.rd             = {1'b0, fmt3_rd};
            dec.rn             = {1'b0, fmt3_rd};
            dec.dp_use_imm     = 1'b1;
            dec.dp_imm_value   = {24'h0, fmt3_imm8};
            dec.shifter_op     = SHIFT_ROR;
            dec.shifter_amount = 8'h00;
            dec.shifter_is_rrx = 1'b0;
            dec.shifter_use_rs = 1'b0;
        end else if (is_fmt9) begin
            // Format 9: LDR/STR/LDRB/STRB Rd, [Rb, #imm5*(4|1)]
            //           — pre-indexed, no writeback, no shift on offset.
            dec.instr_class    = INSTR_LDR_STR;
            dec.rd             = {1'b0, fmt9_rd};
            dec.rn             = {1'b0, fmt9_rb};
            dec.ls_pre_index   = 1'b1;
            dec.ls_up          = 1'b1;
            dec.ls_byte        = fmt9_byte;
            dec.ls_writeback   = 1'b0;
            dec.ls_load        = fmt9_load;
            dec.ls_use_imm     = 1'b1;
            dec.ls_imm_offset  = fmt9_off;
        end else if (is_fmt11) begin
            // SP-relative LDR/STR (word only).
            dec.instr_class    = INSTR_LDR_STR;
            dec.rd             = {1'b0, fmt11_rd};
            dec.rn             = 4'd13;                  // SP
            dec.ls_pre_index   = 1'b1;
            dec.ls_up          = 1'b1;
            dec.ls_byte        = 1'b0;
            dec.ls_writeback   = 1'b0;
            dec.ls_load        = fmt11_load;
            dec.ls_use_imm     = 1'b1;
            dec.ls_imm_offset  = fmt11_off;
        end else if (is_fmt12 && fmt12_sp) begin
            // SP-form load-address: Rd = SP + imm8<<2 (no flag update).
            dec.instr_class    = INSTR_DP;
            dec.alu_op         = ALU_ADD;
            dec.s_bit          = 1'b0;
            dec.rd             = {1'b0, fmt12_rd};
            dec.rn             = 4'd13;                  // SP
            dec.dp_use_imm     = 1'b1;
            dec.dp_imm_value   = fmt12_imm;
            dec.shifter_op     = SHIFT_ROR;
            dec.shifter_amount = 8'h00;
        end else if (is_fmt13) begin
            // SP += or -= imm7<<2  (no flag update).
            dec.instr_class    = INSTR_DP;
            dec.alu_op         = fmt13_sub ? ALU_SUB : ALU_ADD;
            dec.s_bit          = 1'b0;
            dec.rd             = 4'd13;
            dec.rn             = 4'd13;
            dec.dp_use_imm     = 1'b1;
            dec.dp_imm_value   = fmt13_imm;
            dec.shifter_op     = SHIFT_ROR;
            dec.shifter_amount = 8'h00;
        end else if (is_fmt14) begin
            // Format 14: PUSH = STMDB SP!, {regs}; POP = LDMIA SP!, {regs}.
            //   PUSH (load=0): P=1, U=0 (DB), W=1.
            //   POP  (load=1): P=0, U=1 (IA), W=1.
            // R bit pulls in LR for PUSH (bit 14) or PC for POP (bit 15).
            // PC-in-list is handled by §12c (pc_q ← RDATA during the
            // S_BLOCK_DATA tail).
            dec.instr_class      = INSTR_LDM_STM;
            dec.rn               = 4'd13;                  // SP = r13 (banked)
            dec.block_load       = fmt14_load;
            dec.block_pre_index  = !fmt14_load;             // PUSH=1, POP=0
            dec.block_up         = fmt14_load;              // PUSH=0, POP=1
            dec.block_writeback  = 1'b1;
            dec.block_user_mode  = 1'b0;
            dec.block_reg_list   = fmt14_reglist;
        end else if (is_fmt15) begin
            // Format 15: LDMIA/STMIA Rb!, {r0..r7 mask}.
            dec.instr_class      = INSTR_LDM_STM;
            dec.rn               = {1'b0, fmt15_rb};
            dec.block_load       = fmt15_load;
            dec.block_pre_index  = 1'b0;
            dec.block_up         = 1'b1;
            dec.block_writeback  = 1'b1;
            dec.block_user_mode  = 1'b0;
            dec.block_reg_list   = fmt15_reglist;
        end else if (is_fmt5_bx) begin
            dec.instr_class = INSTR_BX;
            dec.rm          = fmt5_rm;
        end else if (is_fmt18_b) begin
            // Unconditional Thumb branch — target = PC + 4 + offset
            // The core's branch_pc_target adds pc_q + 4 (when T=1) +
            // dec.branch_offset, so we just pass the scaled signed offset.
            dec.instr_class    = INSTR_BRANCH;
            dec.branch_link    = 1'b0;
            dec.branch_offset  = fmt18_offset;
        end else if (is_fmt16_b) begin
            // Format 16: conditional B with 8-bit signed offset.
            // The core's condition unit evaluates dec.cond against CPSR
            // flags; on fail the branch is skipped (pc_q sequential advance).
            dec.instr_class    = INSTR_BRANCH;
            dec.cond           = cond_e'(thumb_instr[11:8]);
            dec.branch_link    = 1'b0;
            dec.branch_offset  = {{23{thumb_instr[7]}}, thumb_instr[7:0], 1'b0};
        end else if (is_fmt17_swi) begin
            // Format 17: SWI in Thumb mode. SWI handler runs in ARM
            // state (T=0) per architecture; the §14 exception-entry
            // path already drives exc_new_cpsr.t = 0.
            dec.instr_class    = INSTR_SWI;
            dec.swi_comment    = {16'h0, thumb_instr[7:0]};
        end else begin
            dec.instr_class = INSTR_UNDEF;
        end
    end

    assign is_dataproc      = (dec.instr_class == INSTR_DP);
    assign is_unimplemented = (dec.instr_class == INSTR_UNDEF);

endmodule
