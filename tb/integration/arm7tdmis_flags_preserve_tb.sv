// ISA-002 regression: logical/test/move operations preserve CPSR.V, and
// an instruction with S clear preserves every flag.
//
// ADDS 0x80000000 + 0x80000000 establishes N=0,Z=1,C=1,V=1.
// MOVS r1,#1 must produce N=0,Z=0,C=1 while preserving V=1.
// ADD (S=0) then changes a register but no flags. MRS captures the result.

module arm7tdmis_flags_preserve_tb;

    logic CLK;
    logic nRESET;

    arm7tdmis_test_fixture #(
        .CYCLE_LIMIT (160),
        .INIT_HEX    ("../tb/programs/flags_preserve_test.hex"),
        .TEST_NAME   ("flags_preserve"),
        .FST_FILE    ("flags_preserve.fst")
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

    task automatic check_reg(
        input logic [4:0] idx,
        input logic [31:0] expected,
        input string label
    );
        if (u_fixture.u_dut.u_core.u_regfile.regs[idx] !== expected) begin
            $display("[flags_preserve] FAIL %s: expected %08x, got %08x",
                     label, expected,
                     u_fixture.u_dut.u_core.u_regfile.regs[idx]);
            errors = errors + 1;
        end
    endtask

    initial begin
        wait (nRESET);
        repeat (100) @(posedge CLK);

        check_reg(0, 32'h00000000, "overflowing ADDS result");
        check_reg(1, 32'h00000001, "MOVS result");
        check_reg(2, 32'h00000002, "S-clear ADD result");

        if (u_fixture.u_dut.u_core.u_regfile.regs[3][31:28] !== 4'b0011) begin
            $display("[flags_preserve] FAIL MRS NZCV expected 0011, got %04b",
                     u_fixture.u_dut.u_core.u_regfile.regs[3][31:28]);
            errors = errors + 1;
        end

        if ({u_fixture.u_dut.u_core.cpsr.n,
             u_fixture.u_dut.u_core.cpsr.z,
             u_fixture.u_dut.u_core.cpsr.c,
             u_fixture.u_dut.u_core.cpsr.v} !== 4'b0011) begin
            $display("[flags_preserve] FAIL final NZCV expected 0011, got %04b",
                     {u_fixture.u_dut.u_core.cpsr.n,
                      u_fixture.u_dut.u_core.cpsr.z,
                      u_fixture.u_dut.u_core.cpsr.c,
                      u_fixture.u_dut.u_core.cpsr.v});
            errors = errors + 1;
        end

        if (errors != 0)
            $fatal(1, "[flags_preserve] FAIL (%0d errors)", errors);
        $display("[flags_preserve] PASS");
        $finish;
    end

endmodule
