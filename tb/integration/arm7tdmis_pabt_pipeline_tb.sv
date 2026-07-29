// EXC-008 / ERR-002 regression for instruction-associated Prefetch Abort
// metadata:
//   0. a taken branch discards an aborted instruction in its shadow,
//   1. an exception flush discards an aborted younger instruction, and
//   2. corrected-default r4p3 erratum 11 behavior takes PABT, not UNDEF,
//      when the aborted instruction follows a condition-failed UDF, and
//   3. corrected-default r4p3 erratum 11 behavior takes SWI, not UNDEF,
//      when SWI follows a condition-failed UDF.

`timescale 1ns/1ps

/* verilator lint_off DECLFILENAME */
module arm7tdmis_pabt_pipeline_scenario #(
    parameter int    CASE_ID  = 0,
    parameter string FST_FILE = "pabt_pipeline.fst"
) (
    output logic done,
    output logic failed
);
    import arm7tdmis_types_pkg::*;
    import arm7tdmis_instr_pkg::*;

    localparam int CASE_BRANCH  = 0;
    localparam int CASE_SWI     = 1;
    localparam int CASE_ERRATUM = 2;
    localparam int CASE_UDF_SWI = 3;

    logic CLK;
    logic nRESET;
    logic inject_abort;

    arm7tdmis_test_fixture #(
        .CYCLE_LIMIT (240),
        .INIT_HEX    ("../tb/programs/pabt_pipeline_test.hex"),
        .TEST_NAME   ("pabt_pipeline"),
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

    // Patch the instruction at 0x20 while reset is asserted:
    //   B 0x40; SWI #0; or UDFEQ (reserved ARMv4T encoding).
    // The fourth case also patches 0x24 to an unconditional SWI.
    initial begin
        @(posedge CLK);
        unique case (CASE_ID)
            CASE_BRANCH:  u_fixture.u_mem.mem[8] = 32'hEA000006;
            CASE_SWI:     u_fixture.u_mem.mem[8] = 32'hEF000000;
            default:      u_fixture.u_mem.mem[8] = 32'h07F000F0;
        endcase
        if (CASE_ID == CASE_UDF_SWI)
            u_fixture.u_mem.mem[9] = 32'hEF000000;
    end

    // ABORT is data-timed. Qualify from the memory model's latched
    // address phase so it belongs exactly to the fetch at 0x24.  The
    // UDF-then-SWI scenario deliberately completes that fetch normally.
    assign inject_abort = (CASE_ID != CASE_UDF_SWI)
                       && u_fixture.u_mem.is_active_q
                       && !u_fixture.u_mem.write_q
                       && (u_fixture.u_mem.addr_q == 32'h00000024);

    logic seen_aborted_fetch;
    logic seen_ccfail_undef;
    logic seen_expected_follower;
    logic wrong_exception_source;
    always_ff @(posedge CLK or negedge nRESET) begin
        if (!nRESET) begin
            seen_aborted_fetch <= 1'b0;
            seen_ccfail_undef <= 1'b0;
            seen_expected_follower <= 1'b0;
            wrong_exception_source <= 1'b0;
        end else begin
            if (u_fixture.ABORT)
                seen_aborted_fetch <= 1'b1;

            if ((CASE_ID == CASE_ERRATUM || CASE_ID == CASE_UDF_SWI)
                && (u_fixture.u_dut.u_core.state_q == 5'd0)
                && u_fixture.u_dut.u_core.de_q.valid
                && (u_fixture.u_dut.u_core.de_q.pc == 32'h00000020)
                && (u_fixture.u_dut.u_core.de_q.dec.instr_class
                    == INSTR_UNDEF)
                && !u_fixture.u_dut.u_core.condition_pass) begin
                seen_ccfail_undef <= 1'b1;
                if (u_fixture.u_dut.u_core.any_exc_fires)
                    wrong_exception_source <= 1'b1;
            end

            if ((CASE_ID == CASE_ERRATUM)
                && (u_fixture.u_dut.u_core.state_q == 5'd0)
                && u_fixture.u_dut.u_core.de_q.valid
                && (u_fixture.u_dut.u_core.de_q.pc == 32'h00000024)) begin
                if (u_fixture.u_dut.u_core.pabt_fires)
                    seen_expected_follower <= 1'b1;
                if (u_fixture.u_dut.u_core.undef_fires
                    || u_fixture.u_dut.u_core.swi_fires)
                    wrong_exception_source <= 1'b1;
            end

            if ((CASE_ID == CASE_UDF_SWI)
                && (u_fixture.u_dut.u_core.state_q == 5'd0)
                && u_fixture.u_dut.u_core.de_q.valid
                && (u_fixture.u_dut.u_core.de_q.pc == 32'h00000024)) begin
                if (u_fixture.u_dut.u_core.swi_fires)
                    seen_expected_follower <= 1'b1;
                if (u_fixture.u_dut.u_core.undef_fires
                    || u_fixture.u_dut.u_core.pabt_fires)
                    wrong_exception_source <= 1'b1;
            end
        end
    end

    int unsigned errors;
    string case_name;

    initial begin
        done   = 1'b0;
        failed = 1'b0;
        errors = 0;
        unique case (CASE_ID)
            CASE_BRANCH:  case_name = "branch-flush";
            CASE_SWI:     case_name = "exception-flush";
            CASE_ERRATUM: case_name = "ccfail-undef-then-pabt";
            default:      case_name = "ccfail-undef-then-swi";
        endcase

        wait (nRESET);
        repeat (165) @(posedge CLK);

        if ((CASE_ID != CASE_UDF_SWI) && !seen_aborted_fetch) begin
            $display("[pabt_pipeline/%s] FAIL did not abort fetch 0x24",
                     case_name);
            errors = errors + 1;
        end
        if ((CASE_ID == CASE_UDF_SWI) && seen_aborted_fetch) begin
            $display("[pabt_pipeline/%s] FAIL unexpectedly aborted SWI fetch",
                     case_name);
            errors = errors + 1;
        end
        if ((CASE_ID == CASE_ERRATUM || CASE_ID == CASE_UDF_SWI)
            && (!seen_ccfail_undef || !seen_expected_follower
                || wrong_exception_source)) begin
            $display("[pabt_pipeline/%s] FAIL sequence ccfail/follower/wrong=%0b/%0b/%0b",
                     case_name, seen_ccfail_undef,
                     seen_expected_follower, wrong_exception_source);
            errors = errors + 1;
        end

        unique case (CASE_ID)
            CASE_BRANCH: begin
                if (u_fixture.u_dut.u_core.u_regfile.regs[8]
                    !== 32'h000000A1
                    || u_fixture.u_dut.u_core.u_regfile.regs[9] !== 32'h0
                    || u_fixture.u_dut.u_core.cpsr.m
                       !== 5'(MODE_SUPERVISOR)) begin
                    $display("[pabt_pipeline/%s] FAIL target=%08x pabt=%08x mode=%05b",
                             case_name,
                             u_fixture.u_dut.u_core.u_regfile.regs[8],
                             u_fixture.u_dut.u_core.u_regfile.regs[9],
                             u_fixture.u_dut.u_core.cpsr.m);
                    errors = errors + 1;
                end
            end
            CASE_SWI: begin
                if (u_fixture.u_dut.u_core.u_regfile.regs[10]
                    !== 32'h0000005C
                    || u_fixture.u_dut.u_core.u_regfile.regs[9] !== 32'h0
                    || u_fixture.u_dut.u_core.cpsr.m
                       !== 5'(MODE_SUPERVISOR)) begin
                    $display("[pabt_pipeline/%s] FAIL swi=%08x pabt=%08x mode=%05b",
                             case_name,
                             u_fixture.u_dut.u_core.u_regfile.regs[10],
                             u_fixture.u_dut.u_core.u_regfile.regs[9],
                             u_fixture.u_dut.u_core.cpsr.m);
                    errors = errors + 1;
                end
            end
            CASE_ERRATUM: begin
                if (u_fixture.u_dut.u_core.u_regfile.regs[9]
                    !== 32'h000000AB
                    || u_fixture.u_dut.u_core.u_regfile.regs[11] !== 32'h0
                    || u_fixture.u_dut.u_core.u_regfile.regs[28]
                       !== 32'h00000028
                    || u_fixture.u_dut.u_core.cpsr.m
                       !== 5'(MODE_ABORT)) begin
                    $display("[pabt_pipeline/%s] FAIL pabt=%08x undef=%08x lr=%08x mode=%05b",
                             case_name,
                             u_fixture.u_dut.u_core.u_regfile.regs[9],
                             u_fixture.u_dut.u_core.u_regfile.regs[11],
                             u_fixture.u_dut.u_core.u_regfile.regs[28],
                             u_fixture.u_dut.u_core.cpsr.m);
                    errors = errors + 1;
                end
            end
            default: begin
                if (u_fixture.u_dut.u_core.u_regfile.regs[10]
                    !== 32'h0000005C
                    || u_fixture.u_dut.u_core.u_regfile.regs[11] !== 32'h0
                    || u_fixture.u_dut.u_core.u_regfile.regs[9] !== 32'h0
                    || u_fixture.u_dut.u_core.u_regfile.regs[26]
                       !== 32'h00000028
                    || u_fixture.u_dut.u_core.u_psr.spsr_q[2]
                       !== 32'h000000D3
                    || u_fixture.u_dut.u_core.cpsr.m
                       !== 5'(MODE_SUPERVISOR)) begin
                    $display("[pabt_pipeline/%s] FAIL swi=%08x undef=%08x pabt=%08x lr=%08x spsr=%08x mode=%05b",
                             case_name,
                             u_fixture.u_dut.u_core.u_regfile.regs[10],
                             u_fixture.u_dut.u_core.u_regfile.regs[11],
                             u_fixture.u_dut.u_core.u_regfile.regs[9],
                             u_fixture.u_dut.u_core.u_regfile.regs[26],
                             u_fixture.u_dut.u_core.u_psr.spsr_q[2],
                             u_fixture.u_dut.u_core.cpsr.m);
                    errors = errors + 1;
                end
            end
        endcase

        failed = (errors != 0);
        done   = 1'b1;
    end
endmodule
/* verilator lint_on DECLFILENAME */

module arm7tdmis_pabt_pipeline_tb;
    logic done0, done1, done2, done3;
    logic fail0, fail1, fail2, fail3;

    arm7tdmis_pabt_pipeline_scenario #(
        .CASE_ID  (0),
        .FST_FILE ("pabt_pipeline_branch.fst")
    ) u_branch (.done(done0), .failed(fail0));

    arm7tdmis_pabt_pipeline_scenario #(
        .CASE_ID  (1),
        .FST_FILE ("pabt_pipeline_exception.fst")
    ) u_exception (.done(done1), .failed(fail1));

    arm7tdmis_pabt_pipeline_scenario #(
        .CASE_ID  (2),
        .FST_FILE ("pabt_pipeline_erratum11.fst")
    ) u_erratum (.done(done2), .failed(fail2));

    arm7tdmis_pabt_pipeline_scenario #(
        .CASE_ID  (3),
        .FST_FILE ("pabt_pipeline_erratum11_swi.fst")
    ) u_erratum_swi (.done(done3), .failed(fail3));

    initial begin
        wait (done0 && done1 && done2 && done3);
        if (fail0 || fail1 || fail2 || fail3)
            $fatal(1, "[pabt_pipeline] FAIL");
        $display("[pabt_pipeline] PASS");
        $finish;
    end
endmodule
