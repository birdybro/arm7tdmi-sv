// BUS-001 regression: byte-addressed contents are interpreted according to
// CFGBIGEND on every byte, halfword, and word data access.  Two identical
// cores run the same ARM program against independent little- and big-endian
// memories so instruction behavior and address order stay directly paired.

module arm7tdmis_endian_data_tb;

    logic clk_le;
    logic reset_le;
    logic clk_be;
    logic reset_be;

    wire _unused_clk_be = clk_be;

    arm7tdmis_test_fixture #(
        .CYCLE_LIMIT (280),
        .INIT_HEX    ("../tb/programs/endian_data_test.hex"),
        .TEST_NAME   ("endian_data_le"),
        .FST_FILE    ("endian_data_le.fst")
    ) u_le (
        .CFGBIGEND   (1'b0),
        .CLKEN       (1'b1),
        .nIRQ        (1'b1),
        .nFIQ        (1'b1),
        .inject_abort(1'b0),
        .CLK         (clk_le),
        .nRESET      (reset_le)
    );

    arm7tdmis_test_fixture #(
        .CYCLE_LIMIT (280),
        .INIT_HEX    ("../tb/programs/endian_data_test.hex"),
        .TEST_NAME   ("endian_data_be"),
        .FST_FILE    ("endian_data_be.fst")
    ) u_be (
        .CFGBIGEND   (1'b1),
        .CLKEN       (1'b1),
        .nIRQ        (1'b1),
        .nFIQ        (1'b1),
        .inject_abort(1'b0),
        .CLK         (clk_be),
        .nRESET      (reset_be)
    );

    int unsigned errors = 0;

    task automatic check_value(
        input logic [31:0] actual,
        input logic [31:0] expected,
        input string label
    );
        if (actual !== expected) begin
            $display("[endian_data] FAIL %s: expected %08x, got %08x",
                     label, expected, actual);
            errors = errors + 1;
        end
    endtask

    initial begin
        wait (reset_le && reset_be);
        repeat (190) @(posedge clk_le);

        check_value(u_le.u_dut.u_core.u_regfile.regs[2],
                    32'h00000011, "LE LDRB address +0");
        check_value(u_le.u_dut.u_core.u_regfile.regs[3],
                    32'h00000022, "LE LDRB address +1");
        check_value(u_le.u_dut.u_core.u_regfile.regs[4],
                    32'h00000033, "LE LDRB address +2");
        check_value(u_le.u_dut.u_core.u_regfile.regs[5],
                    32'h00000044, "LE LDRB address +3");
        check_value(u_le.u_dut.u_core.u_regfile.regs[6],
                    32'h00002211, "LE LDRH address +0");
        check_value(u_le.u_dut.u_core.u_regfile.regs[7],
                    32'h00004433, "LE LDRH address +2");
        check_value(u_le.u_dut.u_core.u_regfile.regs[8],
                    32'h44332211, "LE LDR word");
        check_value(u_le.u_mem.mem[64],
                    32'h44332211, "LE physical byte lanes");
        check_value(u_le.u_dut.u_core.u_regfile.regs[9],
                    32'h00000055, "LE completion marker");

        check_value(u_be.u_dut.u_core.u_regfile.regs[2],
                    32'h00000011, "BE LDRB address +0");
        check_value(u_be.u_dut.u_core.u_regfile.regs[3],
                    32'h00000022, "BE LDRB address +1");
        check_value(u_be.u_dut.u_core.u_regfile.regs[4],
                    32'h00000033, "BE LDRB address +2");
        check_value(u_be.u_dut.u_core.u_regfile.regs[5],
                    32'h00000044, "BE LDRB address +3");
        check_value(u_be.u_dut.u_core.u_regfile.regs[6],
                    32'h00001122, "BE LDRH address +0");
        check_value(u_be.u_dut.u_core.u_regfile.regs[7],
                    32'h00003344, "BE LDRH address +2");
        check_value(u_be.u_dut.u_core.u_regfile.regs[8],
                    32'h11223344, "BE LDR word");
        check_value(u_be.u_mem.mem[64],
                    32'h11223344, "BE physical byte lanes");
        check_value(u_be.u_dut.u_core.u_regfile.regs[9],
                    32'h00000055, "BE completion marker");

        if (errors != 0)
            $fatal(1, "[endian_data] FAIL (%0d errors)", errors);
        $display("[endian_data] PASS");
        $finish;
    end

endmodule
