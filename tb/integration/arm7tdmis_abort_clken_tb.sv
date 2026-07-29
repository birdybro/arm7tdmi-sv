// BUS-007 regression: ABORT and RDATA are sampled only at the enabled
// end of an active S/N bus cycle. An ABORT pulse wholly contained inside
// a CLKEN-stretched STR response must neither perturb the visible bus nor
// become a Data Abort when that transfer later completes successfully.

`timescale 1ns/1ps

module arm7tdmis_abort_clken_tb
    import arm7tdmis_bus_pkg::*;
;

    logic CLK;
    logic nRESET;
    logic CLKEN;
    logic inject_abort;

    arm7tdmis_test_fixture #(
        .CYCLE_LIMIT (260),
        .INIT_HEX    ("../tb/programs/abort_clken_test.hex"),
        .TEST_NAME   ("abort_clken"),
        .FST_FILE    ("abort_clken.fst")
    ) u_fixture (
        .CFGBIGEND   (1'b0),
        .CLKEN       (CLKEN),
        .nIRQ        (1'b1),
        .nFIQ        (1'b1),
        .inject_abort(inject_abort),
        .CLK         (CLK),
        .nRESET      (nRESET)
    );

    int unsigned errors = 0;
    logic [72:0] stalled_bus;

    initial begin
        CLKEN        = 1'b1;
        inject_abort = 1'b0;

        wait (nRESET);
        wait (u_fixture.u_dut.u_core.state_q == 4'd1); // S_DDATA

        // Stop before the STR response completes. Allow one rising edge
        // with CLKEN low before taking the reference snapshot because the
        // r4p3 pin contract permits address-class outputs to change on the
        // edge where a wait state is first inserted.
        @(negedge CLK);
        CLKEN = 1'b0;
        @(posedge CLK);
        #1;
        stalled_bus = {
            u_fixture.ADDR,
            u_fixture.WRITE,
            u_fixture.SIZE,
            u_fixture.PROT,
            u_fixture.LOCK,
            u_fixture.TRANS,
            u_fixture.WDATA,
            u_fixture.DMORE
        };

        // ABORT is high for a complete clock edge, but that edge does not
        // end the stretched bus cycle because CLKEN remains low.
        @(negedge CLK);
        inject_abort = 1'b1;
        #1;
        if ({
            u_fixture.ADDR,
            u_fixture.WRITE,
            u_fixture.SIZE,
            u_fixture.PROT,
            u_fixture.LOCK,
            u_fixture.TRANS,
            u_fixture.WDATA,
            u_fixture.DMORE
        } !== stalled_bus) begin
            $display("[abort_clken] FAIL ABORT perturbed stalled bus");
            errors = errors + 1;
        end

        @(posedge CLK);
        #1;
        if (!u_fixture.ABORT) begin
            $display("[abort_clken] FAIL ABORT was not asserted in stalled active cycle");
            errors = errors + 1;
        end
        if ({
            u_fixture.ADDR,
            u_fixture.WRITE,
            u_fixture.SIZE,
            u_fixture.PROT,
            u_fixture.LOCK,
            u_fixture.TRANS,
            u_fixture.WDATA,
            u_fixture.DMORE
        } !== stalled_bus) begin
            $display("[abort_clken] FAIL bus changed at disabled ABORT edge");
            errors = errors + 1;
        end

        // Remove ABORT before the enabled completion edge.
        @(negedge CLK);
        inject_abort = 1'b0;
        @(negedge CLK);
        CLKEN = 1'b1;

        repeat (80) @(posedge CLK);

        if (u_fixture.u_mem.mem[64] !== 32'h00000055) begin
            $display("[abort_clken] FAIL store did not complete: mem=%08x",
                     u_fixture.u_mem.mem[64]);
            errors = errors + 1;
        end
        if (u_fixture.u_dut.u_core.u_regfile.regs[8] !== 32'h000000DD
            || u_fixture.u_dut.u_core.u_regfile.regs[9] !== 32'h0) begin
            $display("[abort_clken] FAIL flow markers r8=%08x r9=%08x",
                     u_fixture.u_dut.u_core.u_regfile.regs[8],
                     u_fixture.u_dut.u_core.u_regfile.regs[9]);
            errors = errors + 1;
        end
        if (u_fixture.u_dut.u_core.cpsr.m !== 5'b10011) begin
            $display("[abort_clken] FAIL unexpected exception mode=%05b",
                     u_fixture.u_dut.u_core.cpsr.m);
            errors = errors + 1;
        end

        if (errors != 0)
            $fatal(1, "[abort_clken] FAIL (%0d errors)", errors);
        $display("[abort_clken] PASS");
        $finish;
    end

endmodule
