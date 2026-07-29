// CP-001 regression: a bare ARM7TDMI-S has no internal CP15. With the
// fixture's external coprocessor handshake held absent (CPA=CPB=1),
// MRC p15,0,r0,c0,c0,0 must enter Undefined rather than fabricate an ID.

module arm7tdmis_cp15_undef_tb;

    logic CLK;
    logic nRESET;

    arm7tdmis_test_fixture #(
        .CYCLE_LIMIT (180),
        .INIT_HEX    ("../tb/programs/cp15_undef_test.hex"),
        .TEST_NAME   ("cp15_undef"),
        .FST_FILE    ("cp15_undef.fst")
    ) u_fixture (
        .CFGBIGEND   (1'b0),
        .CLKEN       (1'b1),
        .nIRQ        (1'b1),
        .nFIQ        (1'b1),
        .inject_abort(1'b0),
        .CLK         (CLK),
        .nRESET      (nRESET)
    );

    int unsigned errors = 0;

    initial begin
        wait (nRESET);
        repeat (120) @(posedge CLK);

        if (u_fixture.u_dut.u_core.u_regfile.regs[0] !== 32'h00000000) begin
            $display("[cp15_undef] FAIL MRC wrote fabricated value %08x",
                     u_fixture.u_dut.u_core.u_regfile.regs[0]);
            errors = errors + 1;
        end

        if (u_fixture.u_dut.u_core.u_regfile.regs[1] !== 32'h00000000) begin
            $display("[cp15_undef] FAIL fall-through instruction was not flushed");
            errors = errors + 1;
        end

        if (u_fixture.u_dut.u_core.u_regfile.regs[2] !== 32'h00000055) begin
            $display("[cp15_undef] FAIL Undefined handler marker expected 0x55, got %08x",
                     u_fixture.u_dut.u_core.u_regfile.regs[2]);
            errors = errors + 1;
        end

        if (u_fixture.u_dut.u_core.cpsr.m !== 5'b11011) begin
            $display("[cp15_undef] FAIL mode expected Undefined, got %05b",
                     u_fixture.u_dut.u_core.cpsr.m);
            errors = errors + 1;
        end

        if (u_fixture.u_dut.u_core.u_regfile.regs[30] !== 32'h00000028) begin
            $display("[cp15_undef] FAIL LR_und expected 0x28, got %08x",
                     u_fixture.u_dut.u_core.u_regfile.regs[30]);
            errors = errors + 1;
        end

        if (errors != 0)
            $fatal(1, "[cp15_undef] FAIL (%0d errors)", errors);
        $display("[cp15_undef] PASS");
        $finish;
    end

endmodule
