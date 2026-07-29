// BUS-005/BUS-011 regression: the first opcode access after reset is
// nonsequential, a taken branch advertises its discarded pc+2i prefetch as
// N, and Table 7-3 explicitly classifies both target refill fetches as S.

module arm7tdmis_fetch_sequence_tb
    import arm7tdmis_bus_pkg::*;
;

    logic CLK;
    logic nRESET;

    arm7tdmis_test_fixture #(
        .CYCLE_LIMIT (160),
        .INIT_HEX    ("../tb/programs/fetch_sequence_test.hex"),
        .TEST_NAME   ("fetch_sequence"),
        .FST_FILE    ("fetch_sequence.fst")
    ) u_fixture (
        .CFGBIGEND   (1'b0),
        .CLKEN       (1'b1),
        .nIRQ        (1'b1),
        .nFIQ        (1'b1),
        .inject_abort(1'b0),
        .CLK         (CLK),
        .nRESET      (nRESET)
    );

    logic seen_first;
    logic [31:0] first_addr;
    logic [1:0] first_trans;
    logic seen_source_n;
    logic seen_target_s;
    logic seen_following_s;

    always_ff @(posedge CLK or negedge nRESET) begin
        if (!nRESET) begin
            seen_first       <= 1'b0;
            first_addr       <= 32'h0;
            first_trans      <= TRANS_I;
            seen_source_n    <= 1'b0;
            seen_target_s    <= 1'b0;
            seen_following_s <= 1'b0;
        end else if (u_fixture.u_dut.core_nreset
                     && (u_fixture.TRANS inside {TRANS_N, TRANS_S})) begin
            if (!seen_first) begin
                seen_first  <= 1'b1;
                first_addr  <= u_fixture.ADDR;
                first_trans <= u_fixture.TRANS;
            end
            if (u_fixture.ADDR == 32'h00000008
                && u_fixture.TRANS == TRANS_N)
                seen_source_n <= 1'b1;
            if (seen_source_n
                && u_fixture.ADDR == 32'h00000020
                && u_fixture.TRANS == TRANS_S)
                seen_target_s <= 1'b1;
            if (seen_target_s
                && u_fixture.ADDR == 32'h00000024
                && u_fixture.TRANS == TRANS_S)
                seen_following_s <= 1'b1;
        end
    end

    int unsigned errors = 0;

    initial begin
        wait (nRESET);
        repeat (100) @(posedge CLK);

        if (!seen_first || first_addr !== 32'h00000000
            || first_trans !== TRANS_N) begin
            $display("[fetch_sequence] FAIL first access seen=%b addr=%08x TRANS=%b",
                     seen_first, first_addr, first_trans);
            errors = errors + 1;
        end

        if (!seen_source_n) begin
            $display("[fetch_sequence] FAIL discarded branch pc+8 was not N");
            errors = errors + 1;
        end

        if (!seen_target_s) begin
            $display("[fetch_sequence] FAIL branch target 0x20 was not S");
            errors = errors + 1;
        end

        if (!seen_following_s) begin
            $display("[fetch_sequence] FAIL following fetch 0x24 was not S");
            errors = errors + 1;
        end

        if (u_fixture.u_dut.u_core.u_regfile.regs[0] !== 32'h00000001
            || u_fixture.u_dut.u_core.u_regfile.regs[1] !== 32'h00000002) begin
            $display("[fetch_sequence] FAIL program markers r0=%08x r1=%08x",
                     u_fixture.u_dut.u_core.u_regfile.regs[0],
                     u_fixture.u_dut.u_core.u_regfile.regs[1]);
            errors = errors + 1;
        end

        if (errors != 0)
            $fatal(1, "[fetch_sequence] FAIL (%0d errors)", errors);
        $display("[fetch_sequence] PASS");
        $finish;
    end

endmodule
