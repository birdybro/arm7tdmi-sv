// ISA-003 regression: UMLALS/SMLALS commit N/Z from the final accumulated
// 64-bit value, after both RdLo and RdHi have been read.
//
// In both cases the product and RdLo are zero while RdHi is negative.
// A premature flag calculation sees zero (N=0,Z=1); the architectural
// final result is nonzero and negative (N=1,Z=0). C and V are preserved.

module arm7tdmis_mull_flags_tb;

    logic CLK;
    logic nRESET;

    arm7tdmis_test_fixture #(
        .CYCLE_LIMIT (200),
        .INIT_HEX    ("../tb/programs/mull_flags_test.hex"),
        .TEST_NAME   ("mull_flags"),
        .FST_FILE    ("mull_flags.fst")
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

    task automatic check_nz(
        input logic [4:0] reg_idx,
        input string label
    );
        if (u_fixture.u_dut.u_core.u_regfile.regs[reg_idx][31:30] !== 2'b10) begin
            $display("[mull_flags] FAIL %s expected N/Z=10, got %02b",
                     label,
                     u_fixture.u_dut.u_core.u_regfile.regs[reg_idx][31:30]);
            errors = errors + 1;
        end
    endtask

    initial begin
        wait (nRESET);
        repeat (140) @(posedge CLK);

        check_nz(4, "UMLALS saved CPSR");
        check_nz(5, "SMLALS saved CPSR");

        if (u_fixture.u_dut.u_core.u_regfile.regs[2] !== 32'h00000000
            || u_fixture.u_dut.u_core.u_regfile.regs[3] !== 32'hFFFFFFFF) begin
            $display("[mull_flags] FAIL final SMLALS result expected FFFFFFFF:00000000, got %08x:%08x",
                     u_fixture.u_dut.u_core.u_regfile.regs[3],
                     u_fixture.u_dut.u_core.u_regfile.regs[2]);
            errors = errors + 1;
        end

        if ({u_fixture.u_dut.u_core.cpsr.n,
             u_fixture.u_dut.u_core.cpsr.z,
             u_fixture.u_dut.u_core.cpsr.c,
             u_fixture.u_dut.u_core.cpsr.v} !== 4'b1000) begin
            $display("[mull_flags] FAIL final NZCV expected 1000, got %04b",
                     {u_fixture.u_dut.u_core.cpsr.n,
                      u_fixture.u_dut.u_core.cpsr.z,
                      u_fixture.u_dut.u_core.cpsr.c,
                      u_fixture.u_dut.u_core.cpsr.v});
            errors = errors + 1;
        end

        if (errors != 0)
            $fatal(1, "[mull_flags] FAIL (%0d errors)", errors);
        $display("[mull_flags] PASS");
        $finish;
    end

endmodule
