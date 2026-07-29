// EXC-004 base-in-list regression: an aborted LDM with writeback must
// leave the requested modified base in Rn, even when an earlier completed
// beat loaded Rn from memory. Abort each beat of:
//   LDMIA r1!, {r0-r2,pc}

`timescale 1ns/1ps

/* verilator lint_off DECLFILENAME */
module arm7tdmis_ldm_abort_base_list_scenario #(
    parameter logic [31:0] ABORT_ADDR = 32'h00000100,
    parameter string       FST_FILE   = "ldm_abort_base_list.fst"
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
        .INIT_HEX    ("../tb/programs/ldm_abort_base_list_test.hex"),
        .TEST_NAME   ("ldm_abort_base_list"),
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

    assign inject_abort = u_fixture.u_mem.is_active_q
                       && !u_fixture.u_mem.write_q
                       && (u_fixture.u_mem.addr_q == ABORT_ADDR);

    logic [3:0] seen_beats;
    logic seen_abort;
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
    logic [31:0] expected_r2;

    initial begin
        done   = 1'b0;
        failed = 1'b0;
        errors = 0;

        wait (nRESET);
        repeat (180) @(posedge CLK);

        expected_r0 = (ABORT_ADDR > 32'h00000100)
                    ? 32'h11111111 : 32'h000000A0;
        expected_r2 = (ABORT_ADDR > 32'h00000108)
                    ? 32'h33333333 : 32'h000000C2;

        if (u_fixture.u_dut.u_core.u_regfile.regs[0]
            !== expected_r0
            || u_fixture.u_dut.u_core.u_regfile.regs[2]
               !== expected_r2) begin
            $display("[ldm_abort_base_list/%08x] FAIL r0=%08x/%08x r2=%08x/%08x",
                     ABORT_ADDR,
                     u_fixture.u_dut.u_core.u_regfile.regs[0], expected_r0,
                     u_fixture.u_dut.u_core.u_regfile.regs[2], expected_r2);
            errors = errors + 1;
        end
        if (u_fixture.u_dut.u_core.u_regfile.regs[1]
            !== 32'h00000110) begin
            $display("[ldm_abort_base_list/%08x] FAIL restored base expected 00000110 got %08x",
                     ABORT_ADDR,
                     u_fixture.u_dut.u_core.u_regfile.regs[1]);
            errors = errors + 1;
        end
        if (!seen_abort || seen_beats !== 4'b1111) begin
            $display("[ldm_abort_base_list/%08x] FAIL abort=%b beats=%04b",
                     ABORT_ADDR, seen_abort, seen_beats);
            errors = errors + 1;
        end
        if (u_fixture.u_dut.u_core.u_regfile.regs[8] !== 32'h0
            || u_fixture.u_dut.u_core.u_regfile.regs[9]
               !== 32'h000000EE
            || u_fixture.u_dut.u_core.u_regfile.regs[28]
               !== 32'h00000038
            || u_fixture.u_dut.u_core.cpsr.m !== 5'b10111
            || u_fixture.u_dut.u_core.pc_q !== 32'h00000054) begin
            $display("[ldm_abort_base_list/%08x] FAIL flow r8=%08x r9=%08x lr=%08x mode=%05b pc=%08x",
                     ABORT_ADDR,
                     u_fixture.u_dut.u_core.u_regfile.regs[8],
                     u_fixture.u_dut.u_core.u_regfile.regs[9],
                     u_fixture.u_dut.u_core.u_regfile.regs[28],
                     u_fixture.u_dut.u_core.cpsr.m,
                     u_fixture.u_dut.u_core.pc_q);
            errors = errors + 1;
        end

        failed = (errors != 0);
        done   = 1'b1;
    end
endmodule
/* verilator lint_on DECLFILENAME */

module arm7tdmis_ldm_abort_base_list_tb;
    logic done0, done1, done2, done3;
    logic fail0, fail1, fail2, fail3;

    arm7tdmis_ldm_abort_base_list_scenario #(
        .ABORT_ADDR(32'h00000100),
        .FST_FILE("ldm_abort_base_list_beat0.fst")
    ) u_beat0 (.done(done0), .failed(fail0));

    arm7tdmis_ldm_abort_base_list_scenario #(
        .ABORT_ADDR(32'h00000104),
        .FST_FILE("ldm_abort_base_list_beat1.fst")
    ) u_beat1 (.done(done1), .failed(fail1));

    arm7tdmis_ldm_abort_base_list_scenario #(
        .ABORT_ADDR(32'h00000108),
        .FST_FILE("ldm_abort_base_list_beat2.fst")
    ) u_beat2 (.done(done2), .failed(fail2));

    arm7tdmis_ldm_abort_base_list_scenario #(
        .ABORT_ADDR(32'h0000010C),
        .FST_FILE("ldm_abort_base_list_beat3.fst")
    ) u_beat3 (.done(done3), .failed(fail3));

    initial begin
        wait (done0 && done1 && done2 && done3);
        if (fail0 || fail1 || fail2 || fail3)
            $fatal(1, "[ldm_abort_base_list] FAIL");
        $display("[ldm_abort_base_list] PASS (all four abort beats)");
        $finish;
    end
endmodule
