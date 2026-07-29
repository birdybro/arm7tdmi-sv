// ISA-006 regression: a Thumb BX to an ARM target must issue the target
// fetch as a word transfer. The pre-fix core used the old Thumb T bit for
// SIZE during the early-flush fetch, truncating the first ARM opcode.
//
// Program:
//   ARM   0x20  r0 := 0x31 (Thumb target 0x30)
//         0x24  r2 := 0x40 (ARM return target)
//         0x28  BX r0
//         0x2c  r3 := 0xee (must be flushed)
//   Thumb 0x30  r1 := 0xaa
//         0x32  BX r2
//   ARM   0x40  r3 := 0x55
//         0x44  B 0x44

module arm7tdmis_bx_interwork_tb;

    logic CLK;
    logic nRESET;

    arm7tdmis_test_fixture #(
        .CYCLE_LIMIT (160),
        .INIT_HEX    ("../tb/programs/bx_interwork_test.hex"),
        .TEST_NAME   ("bx_interwork"),
        .FST_FILE    ("bx_interwork.fst")
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
            $display("[bx_interwork] FAIL %s: expected %08x, got %08x",
                     label, expected,
                     u_fixture.u_dut.u_core.u_regfile.regs[idx]);
            errors = errors + 1;
        end
    endtask

    initial begin
        wait (nRESET);
        repeat (100) @(posedge CLK);

        check_reg(1, 32'h000000AA, "Thumb target committed r1");
        check_reg(3, 32'h00000055, "ARM return target committed r3");

        if (u_fixture.u_dut.u_core.cpsr.t !== 1'b0) begin
            $display("[bx_interwork] FAIL final CPSR.T expected ARM state");
            errors = errors + 1;
        end

        if (u_fixture.u_dut.u_core.pc_q !== 32'h00000044) begin
            $display("[bx_interwork] FAIL final PC expected 0x44, got %08x",
                     u_fixture.u_dut.u_core.pc_q);
            errors = errors + 1;
        end

        if (errors != 0)
            $fatal(1, "[bx_interwork] FAIL (%0d errors)", errors);
        $display("[bx_interwork] PASS");
        $finish;
    end

endmodule
