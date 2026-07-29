// CP-002 regression: CP14 is internal, but only its documented register
// transfers are implemented.  Broad aliases must enter Undefined instead of
// being accepted as DCC operations or silently retired as no-ops.
//
// The program first executes all five valid register-transfer forms:
//   MRC p14,0,Rd,c0,c0,0       DCC control
//   MRC/MCR p14,0,Rd,c1,c0,0   DCC RX/TX data
//   MRC/MCR p14,0,Rd,c2,c0,0   debug abort status
// It then executes eight unsupported CP14 encodings.  The Undefined handler
// increments r12 and returns to the instruction after each offender.

module arm7tdmis_cp14_decode_tb;

    logic CLK;
    logic nRESET;

    arm7tdmis_test_fixture #(
        .CYCLE_LIMIT (420),
        .INIT_HEX    ("../tb/programs/cp14_decode_test.hex"),
        .TEST_NAME   ("cp14_decode"),
        .FST_FILE    ("cp14_decode.fst")
    ) u_fixture (
        .CFGBIGEND    (1'b0),
        .CLKEN        (1'b1),
        .nIRQ         (1'b1),
        .nFIQ         (1'b1),
        .inject_abort (1'b0),
        .CLK          (CLK),
        .nRESET       (nRESET)
    );

    int unsigned errors = 0;

    initial begin
        wait (nRESET);
        repeat (360) @(posedge CLK);

        if (u_fixture.u_dut.u_core.u_regfile.regs[12] !== 32'd8) begin
            $display("[cp14_decode] FAIL expected 8 Undefined entries, got %08x",
                     u_fixture.u_dut.u_core.u_regfile.regs[12]);
            errors = errors + 1;
        end

        if (u_fixture.u_dut.u_core.u_regfile.regs[0] !== 32'd8) begin
            $display("[cp14_decode] FAIL completion marker expected 8, got %08x",
                     u_fixture.u_dut.u_core.u_regfile.regs[0]);
            errors = errors + 1;
        end

        if (u_fixture.u_dut.u_core.cpsr.m !== 5'b10011) begin
            $display("[cp14_decode] FAIL handler did not return to SVC mode: %05b",
                     u_fixture.u_dut.u_core.cpsr.m);
            errors = errors + 1;
        end

        // The final unsupported instruction is at 0x54.  LR_und must point
        // to its successor and remain banked after exception return.
        if (u_fixture.u_dut.u_core.u_regfile.regs[30] !== 32'h00000058) begin
            $display("[cp14_decode] FAIL final LR_und expected 0x58, got %08x",
                     u_fixture.u_dut.u_core.u_regfile.regs[30]);
            errors = errors + 1;
        end

        if (errors != 0)
            $fatal(1, "[cp14_decode] FAIL (%0d errors)", errors);
        $display("[cp14_decode] PASS");
        $finish;
    end

endmodule
