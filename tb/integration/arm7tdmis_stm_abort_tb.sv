// EXC-005 regression: STM continues every transfer after a Data Abort and
// commits requested base writeback. The selected failed store does not
// modify the test memory; the other independent beats do.

/* verilator lint_off DECLFILENAME */
module arm7tdmis_stm_abort_scenario #(
    parameter logic [31:0] ABORT_ADDR = 32'h00000100,
    parameter string       FST_FILE   = "stm_abort.fst"
) (
    output logic done,
    output logic failed
);
    import arm7tdmis_bus_pkg::*;

    logic CLK;
    logic nRESET;
    logic inject_abort;

    arm7tdmis_test_fixture #(
        .CYCLE_LIMIT (240),
        .INIT_HEX    ("../tb/programs/stm_abort_test.hex"),
        .TEST_NAME   ("stm_abort"),
        .FST_FILE    (FST_FILE)
    ) u_fixture (
        .CFGBIGEND   (1'b0),
        .CLKEN       (1'b1),
        .nIRQ        (1'b1),
        .nFIQ        (1'b1),
        .inject_abort(inject_abort),
        .CLK         (CLK),
        .nRESET      (nRESET)
    );

    always_comb begin
        inject_abort = u_fixture.u_mem.is_active_q
                    && u_fixture.u_mem.write_q
                    && (u_fixture.u_mem.addr_q == ABORT_ADDR);
    end

    logic [3:0] seen_beats;
    logic       seen_abort;

    always_ff @(posedge CLK or negedge nRESET) begin
        if (!nRESET) begin
            seen_beats <= 4'b0000;
            seen_abort <= 1'b0;
        end else begin
            if ((u_fixture.TRANS inside {TRANS_N, TRANS_S})
                && u_fixture.PROT[0] && u_fixture.WRITE) begin
                unique case (u_fixture.ADDR)
                    32'h00000100: seen_beats[0] <= 1'b1;
                    32'h00000104: seen_beats[1] <= 1'b1;
                    32'h00000108: seen_beats[2] <= 1'b1;
                    32'h0000010C: seen_beats[3] <= 1'b1;
                    default: ;
                endcase
            end
            if (u_fixture.ABORT)
                seen_abort <= 1'b1;
        end
    end

    int unsigned errors;

    task automatic check_word(
        input int unsigned beat,
        input logic [31:0] stored,
        input logic [31:0] original
    );
        logic [31:0] expected;
        expected = (ABORT_ADDR == (32'h00000100 + (32'(beat) << 2)))
                 ? original : stored;
        if (u_fixture.u_mem.mem[64 + beat] !== expected) begin
            $display("[stm_abort/%08x] FAIL mem beat %0d expected %08x got %08x",
                     ABORT_ADDR, beat, expected,
                     u_fixture.u_mem.mem[64 + beat]);
            errors = errors + 1;
        end
    endtask

    initial begin
        done   = 1'b0;
        failed = 1'b0;
        errors = 0;

        wait (nRESET);
        repeat (180) @(posedge CLK);

        check_word(0, 32'h00000011, 32'hAAAA0000);
        check_word(1, 32'h00000022, 32'hBBBB0001);
        check_word(2, 32'h00000033, 32'hCCCC0002);
        check_word(3, 32'h00000044, 32'hDDDD0003);

        if (u_fixture.u_dut.u_core.u_regfile.regs[5] !== 32'h00000110) begin
            $display("[stm_abort/%08x] FAIL r5 writeback expected 00000110 got %08x",
                     ABORT_ADDR,
                     u_fixture.u_dut.u_core.u_regfile.regs[5]);
            errors = errors + 1;
        end
        if (u_fixture.u_dut.u_core.u_regfile.regs[8] !== 32'h00000000
            || u_fixture.u_dut.u_core.u_regfile.regs[9] !== 32'h000000EE) begin
            $display("[stm_abort/%08x] FAIL control-flow markers r8=%08x r9=%08x",
                     ABORT_ADDR,
                     u_fixture.u_dut.u_core.u_regfile.regs[8],
                     u_fixture.u_dut.u_core.u_regfile.regs[9]);
            errors = errors + 1;
        end
        if (u_fixture.u_dut.u_core.u_regfile.regs[28] !== 32'h0000003C) begin
            $display("[stm_abort/%08x] FAIL r14_abt expected 0000003c got %08x",
                     ABORT_ADDR,
                     u_fixture.u_dut.u_core.u_regfile.regs[28]);
            errors = errors + 1;
        end
        if (!seen_abort || seen_beats !== 4'b1111) begin
            $display("[stm_abort/%08x] FAIL abort=%b completed beats=%04b",
                     ABORT_ADDR, seen_abort, seen_beats);
            errors = errors + 1;
        end
        if (u_fixture.u_dut.u_core.cpsr.m !== 5'b10111
            || u_fixture.u_dut.u_core.pc_q !== 32'h00000054) begin
            $display("[stm_abort/%08x] FAIL final mode/PC mode=%05b pc=%08x",
                     ABORT_ADDR, u_fixture.u_dut.u_core.cpsr.m,
                     u_fixture.u_dut.u_core.pc_q);
            errors = errors + 1;
        end

        failed = (errors != 0);
        done   = 1'b1;
    end
endmodule
/* verilator lint_on DECLFILENAME */

module arm7tdmis_stm_abort_tb;
    logic done0, done1, done2, done3;
    logic fail0, fail1, fail2, fail3;

    arm7tdmis_stm_abort_scenario #(
        .ABORT_ADDR (32'h00000100),
        .FST_FILE   ("stm_abort_beat0.fst")
    ) u_beat0 (.done(done0), .failed(fail0));

    arm7tdmis_stm_abort_scenario #(
        .ABORT_ADDR (32'h00000104),
        .FST_FILE   ("stm_abort_beat1.fst")
    ) u_beat1 (.done(done1), .failed(fail1));

    arm7tdmis_stm_abort_scenario #(
        .ABORT_ADDR (32'h00000108),
        .FST_FILE   ("stm_abort_beat2.fst")
    ) u_beat2 (.done(done2), .failed(fail2));

    arm7tdmis_stm_abort_scenario #(
        .ABORT_ADDR (32'h0000010C),
        .FST_FILE   ("stm_abort_beat3.fst")
    ) u_beat3 (.done(done3), .failed(fail3));

    initial begin
        wait (done0 && done1 && done2 && done3);
        if (fail0 || fail1 || fail2 || fail3)
            $fatal(1, "[stm_abort] FAIL");
        $display("[stm_abort] PASS (all four abort beats)");
        $finish;
    end
endmodule
