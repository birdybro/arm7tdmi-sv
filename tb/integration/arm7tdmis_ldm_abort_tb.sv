// EXC-004 regression: an aborted LDM runs every bus beat to completion,
// suppresses the aborting and all later destination writes, preserves PC,
// and still commits requested base writeback. Four independent cores inject
// ABORT on each possible beat of LDMIA r5!, {r0-r2,pc}.

/* verilator lint_off DECLFILENAME */
module arm7tdmis_ldm_abort_scenario #(
    parameter logic [31:0] ABORT_ADDR = 32'h00000100,
    parameter string       FST_FILE   = "ldm_abort.fst"
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
        .INIT_HEX    ("../tb/programs/ldm_abort_test.hex"),
        .TEST_NAME   ("ldm_abort"),
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

    // Select the data phase by the memory model's latched address. This
    // aligns ABORT with RDATA for exactly one LDM beat.
    always_comb begin
        inject_abort = u_fixture.u_mem.is_active_q
                    && !u_fixture.u_mem.write_q
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
                && u_fixture.PROT[0] && !u_fixture.WRITE) begin
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
    logic [31:0] expected_r0;
    logic [31:0] expected_r1;
    logic [31:0] expected_r2;

    task automatic check_reg(
        input logic [4:0] idx,
        input logic [31:0] expected,
        input string label
    );
        if (u_fixture.u_dut.u_core.u_regfile.regs[idx] !== expected) begin
            $display("[ldm_abort/%08x] FAIL %s expected %08x got %08x",
                     ABORT_ADDR, label, expected,
                     u_fixture.u_dut.u_core.u_regfile.regs[idx]);
            errors = errors + 1;
        end
    endtask

    initial begin
        done   = 1'b0;
        failed = 1'b0;
        errors = 0;

        wait (nRESET);
        repeat (180) @(posedge CLK);

        expected_r0 = (ABORT_ADDR > 32'h00000100)
                    ? 32'h11111111 : 32'h000000A0;
        expected_r1 = (ABORT_ADDR > 32'h00000104)
                    ? 32'h22222222 : 32'h000000B1;
        expected_r2 = (ABORT_ADDR > 32'h00000108)
                    ? 32'h33333333 : 32'h000000C2;

        check_reg(0, expected_r0, "r0");
        check_reg(1, expected_r1, "r1");
        check_reg(2, expected_r2, "r2");
        check_reg(5, 32'h00000110, "r5 requested writeback");
        check_reg(8, 32'h00000000, "post-LDM instruction suppressed");
        check_reg(9, 32'h000000EE, "abort handler marker");
        check_reg(28, 32'h00000038, "r14_abt");

        if (!seen_abort) begin
            $display("[ldm_abort/%08x] FAIL selected ABORT never asserted",
                     ABORT_ADDR);
            errors = errors + 1;
        end
        if (seen_beats !== 4'b1111) begin
            $display("[ldm_abort/%08x] FAIL LDM did not complete all beats: %04b",
                     ABORT_ADDR, seen_beats);
            errors = errors + 1;
        end
        if (u_fixture.u_dut.u_core.cpsr.m !== 5'b10111) begin
            $display("[ldm_abort/%08x] FAIL expected Abort mode, got %05b",
                     ABORT_ADDR, u_fixture.u_dut.u_core.cpsr.m);
            errors = errors + 1;
        end
        // The last transfer is PC. It must remain suppressed even when the
        // abort occurred on an earlier register.
        if (u_fixture.u_dut.u_core.pc_q !== 32'h00000054) begin
            $display("[ldm_abort/%08x] FAIL PC was not preserved/handler did not loop: %08x",
                     ABORT_ADDR, u_fixture.u_dut.u_core.pc_q);
            errors = errors + 1;
        end

        failed = (errors != 0);
        done   = 1'b1;
    end
endmodule
/* verilator lint_on DECLFILENAME */

module arm7tdmis_ldm_abort_tb;
    logic done0, done1, done2, done3;
    logic fail0, fail1, fail2, fail3;

    arm7tdmis_ldm_abort_scenario #(
        .ABORT_ADDR (32'h00000100),
        .FST_FILE   ("ldm_abort_beat0.fst")
    ) u_beat0 (.done(done0), .failed(fail0));

    arm7tdmis_ldm_abort_scenario #(
        .ABORT_ADDR (32'h00000104),
        .FST_FILE   ("ldm_abort_beat1.fst")
    ) u_beat1 (.done(done1), .failed(fail1));

    arm7tdmis_ldm_abort_scenario #(
        .ABORT_ADDR (32'h00000108),
        .FST_FILE   ("ldm_abort_beat2.fst")
    ) u_beat2 (.done(done2), .failed(fail2));

    arm7tdmis_ldm_abort_scenario #(
        .ABORT_ADDR (32'h0000010C),
        .FST_FILE   ("ldm_abort_beat3.fst")
    ) u_beat3 (.done(done3), .failed(fail3));

    initial begin
        wait (done0 && done1 && done2 && done3);
        if (fail0 || fail1 || fail2 || fail3)
            $fatal(1, "[ldm_abort] FAIL");
        $display("[ldm_abort] PASS (all four abort beats)");
        $finish;
    end
endmodule
