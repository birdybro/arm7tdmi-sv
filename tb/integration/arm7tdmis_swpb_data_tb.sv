// ISA-012 / VER-010 regression: SWPB returns the old addressed byte,
// writes the new byte, and holds LOCK over exactly the read/write pair.
// This isolates the broad smoke test's stale final-register expectation:
// its later BL subroutine overwrites r12 after SWPB has completed.

module arm7tdmis_swpb_data_tb
    import arm7tdmis_bus_pkg::*;
;

    logic CLK;
    logic nRESET;

    arm7tdmis_test_fixture #(
        .CYCLE_LIMIT (160),
        .INIT_HEX    ("../tb/programs/swpb_data_test.hex"),
        .TEST_NAME   ("swpb_data"),
        .FST_FILE    ("swpb_data.fst")
    ) u_fixture (
        .CFGBIGEND   (1'b0),
        .CLKEN       (1'b1),
        .nIRQ        (1'b1),
        .nFIQ        (1'b1),
        .inject_abort(1'b0),
        .CLK         (CLK),
        .nRESET      (nRESET)
    );

    int unsigned locked_active_cycles;

    always_ff @(posedge CLK) begin
        if (!nRESET) begin
            locked_active_cycles <= 0;
        end else if (u_fixture.LOCK
                     && ((u_fixture.TRANS == 2'(TRANS_N))
                         || (u_fixture.TRANS == 2'(TRANS_S)))) begin
            locked_active_cycles <= locked_active_cycles + 1;
        end
    end

    int unsigned errors = 0;

    initial begin
        wait (nRESET);
        repeat (100) @(posedge CLK);

        if (u_fixture.u_dut.u_core.u_regfile.regs[3] !== 32'h00000005) begin
            $display("[swpb_data] FAIL Rd expected old byte 0x05, got %08x",
                     u_fixture.u_dut.u_core.u_regfile.regs[3]);
            errors = errors + 1;
        end

        if (u_fixture.u_mem.mem[64] !== 32'h00000007) begin
            $display("[swpb_data] FAIL memory expected new byte 0x07, got %08x",
                     u_fixture.u_mem.mem[64]);
            errors = errors + 1;
        end

        if (locked_active_cycles != 2) begin
            $display("[swpb_data] FAIL expected 2 locked active cycles, got %0d",
                     locked_active_cycles);
            errors = errors + 1;
        end

        if (u_fixture.LOCK !== 1'b0) begin
            $display("[swpb_data] FAIL LOCK remained asserted after completion");
            errors = errors + 1;
        end

        if (errors != 0)
            $fatal(1, "[swpb_data] FAIL (%0d errors)", errors);
        $display("[swpb_data] PASS");
        $finish;
    end

endmodule
