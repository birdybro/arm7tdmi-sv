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
        end else begin
            dec.instr_class = INSTR_UNDEF;
        end
    end

    assign is_dataproc      = (dec.instr_class == INSTR_DP);
    assign is_unimplemented = (dec.instr_class == INSTR_UNDEF);

endmodule
