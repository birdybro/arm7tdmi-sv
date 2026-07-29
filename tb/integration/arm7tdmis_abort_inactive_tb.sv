// BUS-007 regression: ABORT has no meaning in an internal (I) or
// coprocessor (C) cycle and must be ignored.  A multi-cycle UMLAL creates
// consecutive I cycles; the shared fixture asserts ABORT only when the
// latched response phase is inactive, never for an N/S response.

module arm7tdmis_abort_inactive_tb
    import arm7tdmis_bus_pkg::*;
;

    logic CLK;
    logic nRESET;

    arm7tdmis_test_fixture #(
        .CYCLE_LIMIT           (180),
        .INIT_HEX              ("../tb/programs/abort_inactive_test.hex"),
        .TEST_NAME             ("abort_inactive"),
        .FST_FILE              ("abort_inactive.fst"),
        .ABORT_DURING_INACTIVE (1'b1)
    ) u_fixture (
        .CFGBIGEND   (1'b0),
        .CLKEN       (1'b1),
        .nIRQ        (1'b1),
        .nFIQ        (1'b1),
        .inject_abort(1'b0),
        .CLK         (CLK),
        .nRESET      (nRESET)
    );

    logic seen_abort_i;

    always_ff @(posedge CLK or negedge nRESET) begin
        if (!nRESET)
            seen_abort_i <= 1'b0;
        else if (u_fixture.ABORT
                 && u_fixture.u_mem.trans_q == TRANS_I)
            seen_abort_i <= 1'b1;
    end

    int unsigned errors = 0;

    initial begin
        wait (nRESET);
        repeat (110) @(posedge CLK);

        if (!seen_abort_i) begin
            $display("[abort_inactive] FAIL did not inject ABORT during I");
            errors = errors + 1;
        end

        if (u_fixture.u_dut.u_core.u_regfile.regs[4] !== 32'h00000055) begin
            $display("[abort_inactive] FAIL post-UMLAL marker expected 0x55, got %08x",
                     u_fixture.u_dut.u_core.u_regfile.regs[4]);
            errors = errors + 1;
        end

        if (u_fixture.u_dut.u_core.u_regfile.regs[5] !== 32'h00000000) begin
            $display("[abort_inactive] FAIL exception handler ran, marker=%08x",
                     u_fixture.u_dut.u_core.u_regfile.regs[5]);
            errors = errors + 1;
        end

        if (u_fixture.u_dut.u_core.cpsr.m !== 5'b10011) begin
            $display("[abort_inactive] FAIL mode changed from SVC to %05b",
                     u_fixture.u_dut.u_core.cpsr.m);
            errors = errors + 1;
        end

        if (errors != 0)
            $fatal(1, "[abort_inactive] FAIL (%0d errors)", errors);
        $display("[abort_inactive] PASS");
        $finish;
    end

endmodule
