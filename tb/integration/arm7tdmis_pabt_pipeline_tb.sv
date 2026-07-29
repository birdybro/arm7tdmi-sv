// EXC-008 / ERR-002 regression for instruction-associated Prefetch Abort
// metadata:
//   0. a taken branch discards an aborted instruction in its shadow,
//   1. an exception flush discards an aborted younger instruction, and
//   2. corrected-default r4p3 erratum 11 behavior takes PABT, not UNDEF,
//      when the aborted instruction follows a condition-failed UDF.

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

    localparam int CASE_BRANCH  = 0;
    localparam int CASE_SWI     = 1;
    localparam int CASE_ERRATUM = 2;

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
    initial begin
        @(posedge CLK);
        unique case (CASE_ID)
            CASE_BRANCH:  u_fixture.u_mem.mem[8] = 32'hEA000006;
            CASE_SWI:     u_fixture.u_mem.mem[8] = 32'hEF000000;
            default:      u_fixture.u_mem.mem[8] = 32'h07F000F0;
        endcase
    end

    // ABORT is data-timed. Qualify from the memory model's latched
    // address phase so it belongs exactly to the fetch at 0x24.
    assign inject_abort = u_fixture.u_mem.is_active_q
                       && !u_fixture.u_mem.write_q
                       && (u_fixture.u_mem.addr_q == 32'h00000024);

    logic seen_aborted_fetch;
    always_ff @(posedge CLK or negedge nRESET) begin
        if (!nRESET)
            seen_aborted_fetch <= 1'b0;
        else if (u_fixture.ABORT)
            seen_aborted_fetch <= 1'b1;
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
            default:      case_name = "ccfail-undef-then-pabt";
        endcase

        wait (nRESET);
        repeat (165) @(posedge CLK);

        if (!seen_aborted_fetch) begin
            $display("[pabt_pipeline/%s] FAIL did not abort fetch 0x24",
                     case_name);
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
            default: begin
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
        endcase

        failed = (errors != 0);
        done   = 1'b1;
    end
endmodule
/* verilator lint_on DECLFILENAME */

module arm7tdmis_pabt_pipeline_tb;
    logic done0, done1, done2;
    logic fail0, fail1, fail2;

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

    initial begin
        wait (done0 && done1 && done2);
        if (fail0 || fail1 || fail2)
            $fatal(1, "[pabt_pipeline] FAIL");
        $display("[pabt_pipeline] PASS");
        $finish;
    end
endmodule
