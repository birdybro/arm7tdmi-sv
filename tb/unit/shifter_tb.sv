// Unit test for arm7tdmis_shifter (TASKS.md §5.1).
//
// Combinational module — no clock needed; settle with #1.
//
// Coverage hits every shifter edge case the ARM ARM specifies:
//   amount = 0 pass-through (LSL #0 immediate, register-form Rs[7:0]==0)
//   LSL #1 / #31 / #32 / >32      (incl. carry from bit 0 at #32)
//   LSR #1 / #31 / #32 / >32      (incl. carry from bit 31 at #32)
//   ASR #1 / #31 / #32 / >32      (sign extension for amount >= 32)
//   ROR #1 / #4 / #31 / #32 / #33 / #64 (wrap, mod-32 behavior)
//   RRX                           (with carry_in 0 and 1)
// Operand patterns chosen so MSB / LSB activity is observable and the
// expected carry_out can be derived by hand.

module shifter_tb
    import arm7tdmis_types_pkg::*;
;

    shift_op_e   op;
    logic [7:0]  amount;
    logic        is_rrx;
    logic [31:0] in_data;
    logic        carry_in;
    logic [31:0] result;
    logic        carry_out;

    arm7tdmis_shifter dut (.*);

    int errors;

    task automatic check(string label, logic [31:0] expected_r, logic expected_c);
        #1;
        if (result !== expected_r) begin
            $display("FAIL [%s]: expected result %08x, got %08x",
                     label, expected_r, result);
            errors = errors + 1;
        end
        if (carry_out !== expected_c) begin
            $display("FAIL [%s]: expected carry %0b, got %0b",
                     label, expected_c, carry_out);
            errors = errors + 1;
        end
    endtask

    initial begin
        errors  = 0;
        is_rrx  = 1'b0;
        op      = SHIFT_LSL;
        amount  = 8'd0;
        in_data = 32'h0;
        carry_in = 1'b0;

        // ---- amount = 0 pass-through ----
        op = SHIFT_LSL; amount = 8'd0; in_data = 32'hDEADBEEF; carry_in = 1'b1;
        check("LSL #0 pass-through c=1", 32'hDEADBEEF, 1'b1);
        op = SHIFT_LSL; amount = 8'd0; in_data = 32'h12345678; carry_in = 1'b0;
        check("LSL #0 pass-through c=0", 32'h12345678, 1'b0);
        op = SHIFT_ROR; amount = 8'd0; in_data = 32'hF0F0F0F0; carry_in = 1'b1;
        check("ROR #0 pass-through (decoder rewrites RRX, this is reg-form)",
              32'hF0F0F0F0, 1'b1);

        // ---- LSL ----
        op = SHIFT_LSL; amount = 8'd1;   in_data = 32'h80000001; carry_in = 1'b0;
        check("LSL #1",      32'h00000002, 1'b1);
        op = SHIFT_LSL; amount = 8'd31;  in_data = 32'h00000001; carry_in = 1'b0;
        check("LSL #31",     32'h80000000, 1'b0);
        op = SHIFT_LSL; amount = 8'd31;  in_data = 32'h00000003; carry_in = 1'b0;
        check("LSL #31 c=1", 32'h80000000, 1'b1);
        op = SHIFT_LSL; amount = 8'd32;  in_data = 32'hFFFFFFFF; carry_in = 1'b0;
        check("LSL #32 c=in[0]=1", 32'h00000000, 1'b1);
        op = SHIFT_LSL; amount = 8'd32;  in_data = 32'hFFFFFFFE; carry_in = 1'b0;
        check("LSL #32 c=in[0]=0", 32'h00000000, 1'b0);
        op = SHIFT_LSL; amount = 8'd33;  in_data = 32'hFFFFFFFF; carry_in = 1'b1;
        check("LSL #33",     32'h00000000, 1'b0);
        op = SHIFT_LSL; amount = 8'd100; in_data = 32'hFFFFFFFF; carry_in = 1'b1;
        check("LSL #100",    32'h00000000, 1'b0);

        // ---- LSR ----
        op = SHIFT_LSR; amount = 8'd1;  in_data = 32'h80000001; carry_in = 1'b0;
        check("LSR #1",      32'h40000000, 1'b1);
        op = SHIFT_LSR; amount = 8'd1;  in_data = 32'h80000000; carry_in = 1'b0;
        check("LSR #1 c=0",  32'h40000000, 1'b0);
        op = SHIFT_LSR; amount = 8'd31; in_data = 32'h80000000; carry_in = 1'b0;
        check("LSR #31",     32'h00000001, 1'b0);
        op = SHIFT_LSR; amount = 8'd32; in_data = 32'h80000000; carry_in = 1'b0;
        check("LSR #32 c=in[31]=1", 32'h00000000, 1'b1);
        op = SHIFT_LSR; amount = 8'd32; in_data = 32'h40000000; carry_in = 1'b0;
        check("LSR #32 c=in[31]=0", 32'h00000000, 1'b0);
        op = SHIFT_LSR; amount = 8'd33; in_data = 32'hFFFFFFFF; carry_in = 1'b1;
        check("LSR #33",     32'h00000000, 1'b0);

        // ---- ASR ----
        op = SHIFT_ASR; amount = 8'd1;  in_data = 32'h80000000; carry_in = 1'b0;
        check("ASR #1 negative", 32'hC0000000, 1'b0);
        op = SHIFT_ASR; amount = 8'd1;  in_data = 32'h40000000; carry_in = 1'b0;
        check("ASR #1 positive", 32'h20000000, 1'b0);
        op = SHIFT_ASR; amount = 8'd31; in_data = 32'h80000000; carry_in = 1'b0;
        check("ASR #31 negative", 32'hFFFFFFFF, 1'b0);
        op = SHIFT_ASR; amount = 8'd32; in_data = 32'h80000000; carry_in = 1'b0;
        check("ASR #32 negative", 32'hFFFFFFFF, 1'b1);
        op = SHIFT_ASR; amount = 8'd32; in_data = 32'h7FFFFFFF; carry_in = 1'b0;
        check("ASR #32 positive", 32'h00000000, 1'b0);
        op = SHIFT_ASR; amount = 8'd64; in_data = 32'h80000000; carry_in = 1'b0;
        check("ASR #64 negative", 32'hFFFFFFFF, 1'b1);

        // ---- ROR ----
        op = SHIFT_ROR; amount = 8'd1;  in_data = 32'h00000001; carry_in = 1'b0;
        check("ROR #1",      32'h80000000, 1'b1);
        op = SHIFT_ROR; amount = 8'd4;  in_data = 32'h12345678; carry_in = 1'b0;
        check("ROR #4",      32'h81234567, 1'b1);
        op = SHIFT_ROR; amount = 8'd31; in_data = 32'h00000001; carry_in = 1'b0;
        check("ROR #31",     32'h00000002, 1'b0);
        op = SHIFT_ROR; amount = 8'd32; in_data = 32'h80000001; carry_in = 1'b0;
        check("ROR #32",     32'h80000001, 1'b1);
        op = SHIFT_ROR; amount = 8'd33; in_data = 32'h80000001; carry_in = 1'b0;
        check("ROR #33",     32'hC0000000, 1'b1);
        op = SHIFT_ROR; amount = 8'd64; in_data = 32'h80000001; carry_in = 1'b0;
        check("ROR #64",     32'h80000001, 1'b1);

        // ---- RRX ----
        is_rrx = 1'b1; amount = 8'd0; op = SHIFT_ROR;
        in_data = 32'h00000003; carry_in = 1'b0;
        check("RRX c_in=0 in[0]=1", 32'h00000001, 1'b1);
        in_data = 32'h80000000; carry_in = 1'b1;
        check("RRX c_in=1 in[0]=0", 32'hC0000000, 1'b0);
        in_data = 32'h00000001; carry_in = 1'b1;
        check("RRX c_in=1 in[0]=1", 32'h80000000, 1'b1);
        is_rrx = 1'b0;

        if (errors == 0) begin
            $display("shifter_tb: PASS");
            $finish;
        end else begin
            $fatal(1, "shifter_tb: FAIL (%0d errors)", errors);
        end
    end

    initial begin
        #100000;
        $fatal(1, "shifter_tb: TIMEOUT");
    end

endmodule
