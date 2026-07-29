// BUS-001 regression: in big-endian configuration the Thumb instruction at
// word address +0 occupies RDATA[31:16], and the instruction at +2 occupies
// RDATA[15:0]. Dependent operations make an accidental swapped execution
// order architecturally visible.

module arm7tdmis_endian_thumb_tb;

    logic CLK;
    logic nRESET;

    arm7tdmis_test_fixture #(
        .CYCLE_LIMIT (200),
        .INIT_HEX    ("../tb/programs/endian_thumb_test.hex"),
        .TEST_NAME   ("endian_thumb"),
        .FST_FILE    ("endian_thumb.fst")
    ) u_fixture (
        .CFGBIGEND   (1'b1),
        .CLKEN       (1'b1),
        .nIRQ        (1'b1),
        .nFIQ        (1'b1),
        .inject_abort(1'b0),
        .CLK         (CLK),
        .nRESET      (nRESET)
    );

    int unsigned errors = 0;

    task automatic check_reg(
        input logic [4:0] idx,
        input logic [31:0] expected,
        input string label
    );
        if (u_fixture.u_dut.u_core.u_regfile.regs[idx] !== expected) begin
            $display("[endian_thumb] FAIL %s: expected %08x, got %08x",
                     label, expected,
                     u_fixture.u_dut.u_core.u_regfile.regs[idx]);
            errors = errors + 1;
        end
    endtask

    initial begin
        wait (nRESET);
        repeat (130) @(posedge CLK);

        check_reg(1, 32'h00000011, "first high-halfword MOV");
        check_reg(2, 32'h00000012, "dependent low-halfword ADD");
        check_reg(3, 32'h00000013, "next high-halfword ADD");
        check_reg(4, 32'h00000055, "completion marker");
        check_reg(7, 32'h00000000, "ARM fall-through remained flushed");

        if (u_fixture.u_dut.u_core.cpsr.t !== 1'b1) begin
            $display("[endian_thumb] FAIL core did not remain in Thumb state");
            errors = errors + 1;
        end

        if (errors != 0)
            $fatal(1, "[endian_thumb] FAIL (%0d errors)", errors);
        $display("[endian_thumb] PASS");
        $finish;
    end

endmodule
