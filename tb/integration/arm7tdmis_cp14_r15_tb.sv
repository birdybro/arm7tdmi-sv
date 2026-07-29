// CP-002/006 regression: architected r15 register-transfer semantics apply
// equally to ARM7TDMI-S's internal CP14 path. MCR sends instruction PC+12
// to DCC TX. The r4p3 DCC control value has version 0111 in bits[31:28],
// so an MRC flags form must make NZCV=0111 without changing the PC.

`timescale 1ns/1ps

module arm7tdmis_cp14_r15_tb;

    logic CLK;
    logic nRESET;

    arm7tdmis_test_fixture #(
        .CYCLE_LIMIT (180),
        .INIT_HEX    ("../tb/programs/cp14_r15_test.hex"),
        .TEST_NAME   ("cp14_r15"),
        .FST_FILE    ("cp14_r15.fst")
    ) u_fixture (
        .CFGBIGEND   (1'b0),
        .CLKEN       (1'b1),
        .nIRQ        (1'b1),
        .nFIQ        (1'b1),
        .inject_abort(1'b0),
        .CLK,
        .nRESET
    );

    int unsigned errors;

    initial begin
        errors = 0;
        wait (nRESET);
        repeat (120) @(posedge CLK);
        #1;

        if (u_fixture.u_dut.u_ice.dcc_tx_data_q !== 32'h0000_002C) begin
            $display("[cp14_r15] FAIL MCR pc expected 0000002c got %08x",
                     u_fixture.u_dut.u_ice.dcc_tx_data_q);
            errors = errors + 1;
        end

        if ({u_fixture.u_dut.u_core.cpsr.n,
             u_fixture.u_dut.u_core.cpsr.z,
             u_fixture.u_dut.u_core.cpsr.c,
             u_fixture.u_dut.u_core.cpsr.v} !== 4'b0111) begin
            $display("[cp14_r15] FAIL NZCV=%b%b%b%b",
                     u_fixture.u_dut.u_core.cpsr.n,
                     u_fixture.u_dut.u_core.cpsr.z,
                     u_fixture.u_dut.u_core.cpsr.c,
                     u_fixture.u_dut.u_core.cpsr.v);
            errors = errors + 1;
        end

        if (u_fixture.u_dut.u_core.u_regfile.regs[0] !== 32'h1
            || u_fixture.u_dut.u_core.u_regfile.regs[1] !== 32'h1
            || u_fixture.u_dut.u_core.u_regfile.regs[2] !== 32'h1
            || u_fixture.u_dut.u_core.u_regfile.regs[3] !== 32'h1) begin
            $display("[cp14_r15] FAIL conditional markers r0-r3=%08x/%08x/%08x/%08x",
                     u_fixture.u_dut.u_core.u_regfile.regs[0],
                     u_fixture.u_dut.u_core.u_regfile.regs[1],
                     u_fixture.u_dut.u_core.u_regfile.regs[2],
                     u_fixture.u_dut.u_core.u_regfile.regs[3]);
            errors = errors + 1;
        end
        if (u_fixture.u_dut.u_core.u_regfile.regs[4] !== 32'h44) begin
            $display("[cp14_r15] FAIL completion marker r4=%08x",
                     u_fixture.u_dut.u_core.u_regfile.regs[4]);
            errors = errors + 1;
        end
        if (u_fixture.u_dut.u_core.u_regfile.regs[10] !== 32'h0) begin
            $display("[cp14_r15] FAIL unexpected Undefined r10=%08x",
                     u_fixture.u_dut.u_core.u_regfile.regs[10]);
            errors = errors + 1;
        end

        if (errors != 0)
            $fatal(1, "[cp14_r15] FAIL (%0d errors)", errors);
        $display("[cp14_r15] PASS");
        $finish;
    end

endmodule
