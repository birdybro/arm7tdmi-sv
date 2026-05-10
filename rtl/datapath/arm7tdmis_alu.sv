// ARM7TDMI-S ALU (TASKS.md §5.2). All 16 data-processing operations:
//
//   logic ops       (preserve V): AND EOR ORR BIC MOV MVN TST TEQ
//   arithmetic ops  (update all): ADD ADC CMN SUB SBC CMP RSB RSC
//
// One 33-bit adder handles every arithmetic form: invert op_b for the SUB
// family, swap operands for the RSB/RSC family, and pick the carry-in
// (1 for SUB/RSB, 0 for ADD, cpsr_c for ADC/SBC/RSC). V follows the
// canonical "carry-into-MSB XOR carry-out-of-MSB" rule, evaluated by
// running a parallel 31-bit add to expose the MSB carry-in.
//
// `flag_we` tells the consumer (the PSR / S-bit logic) which flags to
// actually write. Logic ops update N, Z, C and preserve V; arithmetic
// updates all four. The decoder enforces "is the S bit set / is this a
// TST/TEQ/CMP/CMN" — this module just produces the bits that would be
// written if S were set.
//
//   flag_we[3] = N enable
//   flag_we[2] = Z enable
//   flag_we[1] = C enable
//   flag_we[0] = V enable
//
// `c_out` is the shifter's carry-out for logic ops (passes `shifter_carry`
// through unchanged) and the adder's cout for arithmetic.

module arm7tdmis_alu
    import arm7tdmis_types_pkg::*;
(
    input  alu_op_e     op,
    input  logic [31:0] op_a,
    input  logic [31:0] op_b,
    input  logic        cpsr_c,        // current CPSR.C — for ADC/SBC/RSC carry-in
    input  logic        shifter_carry, // carry-out from upstream shifter — for logic-op c_out
    output logic [31:0] result,
    output logic        n_out,
    output logic        z_out,
    output logic        c_out,
    output logic        v_out,
    output logic [3:0]  flag_we
);

    // ---- Op-class helpers ----
    function automatic logic is_sub(input alu_op_e o);
        unique case (o)
            ALU_SUB, ALU_RSB, ALU_SBC, ALU_RSC, ALU_CMP: return 1'b1;
            default:                                     return 1'b0;
        endcase
    endfunction

    function automatic logic uses_cin(input alu_op_e o);
        unique case (o)
            ALU_ADC, ALU_SBC, ALU_RSC: return 1'b1;
            default:                   return 1'b0;
        endcase
    endfunction

    function automatic logic is_reverse(input alu_op_e o);
        unique case (o)
            ALU_RSB, ALU_RSC: return 1'b1;
            default:          return 1'b0;
        endcase
    endfunction

    function automatic logic is_arith(input alu_op_e o);
        unique case (o)
            ALU_ADD, ALU_ADC, ALU_CMN,
            ALU_SUB, ALU_SBC, ALU_CMP,
            ALU_RSB, ALU_RSC: return 1'b1;
            default:          return 1'b0;
        endcase
    endfunction

    // ---- Adder operand setup ----
    logic [31:0] adder_a;
    logic [31:0] adder_b_raw;
    logic [31:0] adder_b;
    logic        adder_cin;

    always_comb begin
        if (is_reverse(op)) begin
            adder_a     = op_b;
            adder_b_raw = op_a;
        end else begin
            adder_a     = op_a;
            adder_b_raw = op_b;
        end
        adder_b   = is_sub(op) ? ~adder_b_raw : adder_b_raw;
        adder_cin = uses_cin(op) ? cpsr_c : (is_sub(op) ? 1'b1 : 1'b0);
    end

    // ---- 33-bit add for result + carry-out. The carry INTO the MSB
    //      (needed for V) doesn't require a parallel adder: from the
    //      single-bit add identity result[31] = a[31] ^ b[31] ^ cin_to_msb,
    //      we can recover cin_to_msb as the XOR of the three.
    logic [32:0] sum_ext;
    logic        carry_into_msb;
    logic        v_arith;

    assign sum_ext        = {1'b0, adder_a} + {1'b0, adder_b} + {32'h0, adder_cin};
    assign carry_into_msb = sum_ext[31] ^ adder_a[31] ^ adder_b[31];
    assign v_arith        = sum_ext[32] ^ carry_into_msb;

    // ---- Result mux ----
    always_comb begin
        unique case (op)
            ALU_AND, ALU_TST: result = op_a & op_b;
            ALU_EOR, ALU_TEQ: result = op_a ^ op_b;
            ALU_ADD, ALU_CMN, ALU_ADC,
            ALU_SUB, ALU_CMP, ALU_SBC,
            ALU_RSB, ALU_RSC: result = sum_ext[31:0];
            ALU_ORR:          result = op_a | op_b;
            ALU_MOV:          result = op_b;
            ALU_BIC:          result = op_a & ~op_b;
            ALU_MVN:          result = ~op_b;
            default:          result = 32'h0;
        endcase
    end

    // ---- Flags ----
    assign n_out = result[31];
    assign z_out = (result == 32'h0);
    assign c_out = is_arith(op) ? sum_ext[32] : shifter_carry;
    assign v_out = is_arith(op) ? v_arith    : 1'b0;

    // ---- Flag write-enable mask. Logic ops preserve V; arithmetic
    //      updates everything. TST/TEQ/CMP/CMN look like data-processing
    //      ops here — the decoder is responsible for suppressing the
    //      destination-register write for those four.
    always_comb begin
        unique case (op)
            ALU_AND, ALU_EOR, ALU_TST, ALU_TEQ,
            ALU_ORR, ALU_MOV, ALU_BIC, ALU_MVN: flag_we = 4'b1110;
            ALU_ADD, ALU_ADC, ALU_CMN,
            ALU_SUB, ALU_SBC, ALU_CMP,
            ALU_RSB, ALU_RSC:                   flag_we = 4'b1111;
            default:                            flag_we = 4'b0000;
        endcase
    end

endmodule
