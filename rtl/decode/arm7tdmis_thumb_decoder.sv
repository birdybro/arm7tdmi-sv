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

    // ---- Format detection (priority order) ----
    wire is_fmt3 = (thumb_instr[15:13] == 3'b001);                 // MOV/CMP/ADD/SUB imm
    wire is_fmt5_bx = (thumb_instr[15:8] == 8'b0100_0111);          // BX (also BLX in v5)

    // ---- Field extraction ----
    wire [1:0]  fmt3_op   = thumb_instr[12:11];
    wire [2:0]  fmt3_rd   = thumb_instr[10:8];
    wire [7:0]  fmt3_imm8 = thumb_instr[7:0];
    wire [3:0]  fmt5_rm   = thumb_instr[6:3];

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
        dec.cond = COND_AL;     // Thumb data-processing is unconditional

        if (is_fmt3) begin
            dec.instr_class    = INSTR_DP;
            dec.alu_op         = fmt3_alu_op(fmt3_op);
            dec.s_bit          = 1'b1;                       // Thumb DP always sets flags
            dec.is_test_op     = (fmt3_op == 2'b01);         // CMP — no Rd write
            dec.rd             = {1'b0, fmt3_rd};
            dec.rn             = {1'b0, fmt3_rd};            // both source and dest = Rd
            dec.dp_use_imm     = 1'b1;
            dec.dp_imm_value   = {24'h0, fmt3_imm8};
            dec.shifter_op     = SHIFT_ROR;
            dec.shifter_amount = 8'h00;
            dec.shifter_is_rrx = 1'b0;
            dec.shifter_use_rs = 1'b0;
        end else if (is_fmt5_bx) begin
            dec.instr_class = INSTR_BX;
            dec.rm          = fmt5_rm;
        end else begin
            dec.instr_class = INSTR_UNDEF;
        end
    end

    assign is_dataproc      = (dec.instr_class == INSTR_DP);
    assign is_unimplemented = (dec.instr_class == INSTR_UNDEF);

endmodule
