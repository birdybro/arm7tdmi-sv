// ARM instruction decoder (TASKS.md §8 — minimal DP-immediate subset
// landed for §7 integration). Returns a normalized micro-op for the
// integrating core to drive its datapath primitives.
//
// §7 scope: data-processing immediate (instr[27:25] == 3'b001) only.
// The shifter operand inputs are produced for direct connection to
// arm7tdmis_shifter — the core wires this output to the shifter without
// a second decode step. Everything else (DP register form, branch,
// load/store, multiply, PSR transfer, coproc, undef) is signaled via
// `is_unimplemented` and treated as NOP by the core for now.
//
// §8 will replace this stub with the full table.

module arm7tdmis_decoder
    import arm7tdmis_types_pkg::*;
    import arm7tdmis_instr_pkg::*;
(
    input  logic [31:0] instr,

    // Common decoded fields (always valid)
    output cond_e       cond,
    output alu_op_e     alu_op,
    output logic        s_bit,
    output logic [3:0]  rd,
    output logic [3:0]  rn,
    output logic [3:0]  rm,

    // Shifter-input wiring for the operand2 path. The core feeds these
    // directly into an arm7tdmis_shifter; for DP-imm the values rotate
    // an 8-bit immediate by 2*rot4.
    output logic [31:0] shifter_in,
    output shift_op_e   shifter_op,
    output logic [7:0]  shifter_amount,
    output logic        shifter_is_rrx,

    // Type flags
    output logic        is_dataproc,        // a recognized DP instruction
    output logic        is_test_op,         // TST/TEQ/CMP/CMN — flags only, no Rd write
    output logic        is_unimplemented    // §7 catches everything not DP-imm here
);

    // ---- Common fields ----
    assign cond  = cond_e'(instr[31:28]);
    assign alu_op = alu_op_e'(instr[24:21]);
    assign s_bit = instr[20];
    assign rn    = instr[19:16];
    assign rd   = instr[15:12];
    assign rm    = instr[3:0];

    // ---- Pattern detection ----
    // DP-immediate: bits [27:25] = 3'b001
    wire is_dp_imm = (instr[27:25] == 3'b001);

    assign is_dataproc      = is_dp_imm;
    assign is_unimplemented = !is_dp_imm;

    // TST/TEQ/CMP/CMN suppress destination-register writeback even in
    // the dataproc path. ALU still asserts flag_we=4'b1110.
    function automatic logic alu_is_test(input alu_op_e a);
        unique case (a)
            ALU_TST, ALU_TEQ, ALU_CMP, ALU_CMN: return 1'b1;
            default:                            return 1'b0;
        endcase
    endfunction

    assign is_test_op = alu_is_test(alu_op);

    // ---- Shifter inputs for DP-immediate operand2 ----
    // imm8 zero-extended, ROR by 2*rot4. The shifter's amount=0 path
    // returns input unchanged with carry=carry_in (CPSR.C), which is
    // the correct ARM behavior for rot4=0. For rot4>0 the shifter's
    // standard ROR rule (carry=data[amount-1]) coincides with "carry =
    // bit 31 of result" since result[31] of (data ROR amount) equals
    // data[amount-1]. So no special-casing is needed in the core.
    assign shifter_in     = {24'h0, instr[7:0]};
    assign shifter_op     = SHIFT_ROR;
    assign shifter_amount = {3'h0, instr[11:8], 1'b0};   // 2 * rot4
    assign shifter_is_rrx = 1'b0;

endmodule
