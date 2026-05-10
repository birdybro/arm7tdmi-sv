// ARM7TDMI-S barrel shifter (TASKS.md §5.1).
//
// One combinational module that handles every Operand2 / load-store-offset
// shift form: LSL/LSR/ASR/ROR with either an immediate or register-supplied
// amount, plus RRX. Edge-case behavior follows the ARM ARM:
//
//   amount = 0          : pass-through; carry_out = carry_in
//                          (covers LSL #0 immediate and any register-form
//                          shift where Rs[7:0] happens to be zero)
//   LSL  #32             : result = 0,           carry = in[0]
//   LSL  #>32            : result = 0,           carry = 0
//   LSR  #32             : result = 0,           carry = in[31]
//   LSR  #>32            : result = 0,           carry = 0
//   ASR  #>=32           : result = sign-extended, carry = in[31]
//   ROR  amount[4:0] = 0 : result = in,          carry = in[31]
//                          (only reachable when amount is a non-zero
//                           multiple of 32 — register form only)
//   RRX                  : result = {carry_in, in[31:1]}, carry = in[0]
//
// Decoder responsibilities (NOT the shifter's):
//   - Translate immediate-form LSR/ASR #0 to amount = 32 before sending
//     here (the shifter's amount=0 branch is a pass-through, not a #32).
//   - Set is_rrx for immediate-form ROR #0 (encoded as RRX in ARMv4T).
//   - For register-form, pass Rs[7:0] verbatim; this module handles
//     amounts up to 255 internally.

module arm7tdmis_shifter
    import arm7tdmis_types_pkg::*;
(
    input  shift_op_e   op,
    input  logic [7:0]  amount,
    input  logic        is_rrx,
    input  logic [31:0] in_data,
    input  logic        carry_in,
    output logic [31:0] result,
    output logic        carry_out
);

    // (32 - amt) modulo 32 in pure 5-bit arithmetic: equivalent to (0 - amt)
    // in two's complement. For amt in [1,31] this gives 31..1, which is the
    // bit position popped off the MSB by an LSL of `amt`, and the equivalent
    // left-shift count for ROR.
    function automatic logic [4:0] msb_carry_index(input logic [4:0] amt);
        return 5'd0 - amt;
    endfunction

    always_comb begin
        result    = 32'h0;
        carry_out = 1'b0;

        if (is_rrx) begin
            result    = {carry_in, in_data[31:1]};
            carry_out = in_data[0];
        end else if (amount == 8'd0) begin
            result    = in_data;
            carry_out = carry_in;
        end else begin
            unique case (op)
                SHIFT_LSL: begin
                    if (amount == 8'd32) begin
                        result    = 32'h0;
                        carry_out = in_data[0];
                    end else if (amount > 8'd32) begin
                        result    = 32'h0;
                        carry_out = 1'b0;
                    end else begin
                        result    = in_data << amount[4:0];
                        carry_out = in_data[msb_carry_index(amount[4:0])];
                    end
                end

                SHIFT_LSR: begin
                    if (amount == 8'd32) begin
                        result    = 32'h0;
                        carry_out = in_data[31];
                    end else if (amount > 8'd32) begin
                        result    = 32'h0;
                        carry_out = 1'b0;
                    end else begin
                        result    = in_data >> amount[4:0];
                        carry_out = in_data[amount[4:0] - 5'd1];
                    end
                end

                SHIFT_ASR: begin
                    if (amount >= 8'd32) begin
                        result    = {32{in_data[31]}};
                        carry_out = in_data[31];
                    end else begin
                        result    = $signed(in_data) >>> amount[4:0];
                        carry_out = in_data[amount[4:0] - 5'd1];
                    end
                end

                SHIFT_ROR: begin
                    if (amount[4:0] == 5'd0) begin
                        // amount is a non-zero multiple of 32 — no rotation,
                        // carry is the new MSB (= original MSB).
                        result    = in_data;
                        carry_out = in_data[31];
                    end else begin
                        result    = (in_data >> amount[4:0]) |
                                    (in_data << msb_carry_index(amount[4:0]));
                        carry_out = in_data[amount[4:0] - 5'd1];
                    end
                end

                default: begin
                    result    = 32'h0;
                    carry_out = 1'b0;
                end
            endcase
        end
    end

endmodule
