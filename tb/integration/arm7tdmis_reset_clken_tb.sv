// EXC-009/MIST-002 regression: reset must take effect while CLKEN is low.
// Run into User mode, stop the core, apply a complete reset pulse, and
// require reset architectural/control state plus a restart fetch at zero.

module arm7tdmis_reset_clken_tb
    import arm7tdmis_bus_pkg::*;
;

    localparam int CLK_HALF_PERIOD = 5;

    logic CLK;
    initial begin
        CLK = 1'b0;
        forever #(CLK_HALF_PERIOD) CLK = ~CLK;
    end

    logic nRESET;
    logic CLKEN;
    logic [31:0] ADDR;
    logic        WRITE;
    logic [1:0]  SIZE;
    logic [1:0]  PROT;
    logic        LOCK;
    logic [1:0]  TRANS;
    logic [31:0] WDATA;
    logic [31:0] RDATA;
    logic        ABORT;
    logic        DMORE;
    logic CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI;
    logic DBGACK, DBGnEXEC, DBGINSTRVALID;
    logic [1:0] DBGRNG;
    logic DBGCOMMTX, DBGCOMMRX, DBGTDO, DBGnTDOEN;

    arm7tdmis_top u_dut (
        .CLK, .CLKEN, .nRESET,
        .CFGBIGEND(1'b0),
        .nIRQ(1'b1), .nFIQ(1'b1), .ABORT,
        .ADDR, .WRITE, .SIZE, .PROT, .LOCK, .TRANS, .WDATA, .RDATA,
        .CPnMREQ, .CPSEQ, .CPnTRANS, .CPnOPC, .CPTBIT, .CPnI,
        .CPA(1'b1), .CPB(1'b1),
        .DBGEN(1'b0), .DBGRQ(1'b0), .DBGBREAK(1'b0),
        .DBGACK, .DBGnEXEC, .DBGINSTRVALID,
        .DBGEXT(2'b00), .DBGRNG, .DBGCOMMTX, .DBGCOMMRX,
        .DBGTCKEN(1'b0), .DBGTMS(1'b0), .DBGTDI(1'b0),
        .DBGTDO, .DBGnTRST(1'b1), .DBGnTDOEN, .DMORE
    );

    arm7tdmis_memory #(
        .WORDS    (4096),
        .INIT_HEX ("../tb/programs/cpntrans_test.hex")
    ) u_mem (
        .CLK, .CLKEN, .nRESET,
        .CFGBIGEND(1'b0),
        .ADDR, .WRITE, .SIZE, .PROT, .LOCK, .TRANS,
        .WDATA, .RDATA, .ABORT,
        .inject_abort(1'b0)
    );

    arm7tdmis_assertions u_assert (
        .CLK, .nRESET, .SIZE, .ABORT, .TRANS
    );

    logic capture_first;
    logic seen_first;
    logic [31:0] first_addr;

    always_ff @(posedge CLK) begin
        if (!nRESET) begin
            seen_first <= 1'b0;
            first_addr <= 32'h0;
        end else if (capture_first && !seen_first
                     && (TRANS inside {TRANS_N, TRANS_S})) begin
            seen_first <= 1'b1;
            first_addr <= ADDR;
        end
    end

    int unsigned errors = 0;

    initial begin
        nRESET       = 1'b0;
        CLKEN        = 1'b1;
        capture_first = 1'b0;
        repeat (4) @(posedge CLK);
        nRESET = 1'b1;

        wait (u_dut.u_core.cpsr.m == 5'b10000
              && u_dut.u_core.u_regfile.regs[3] == 32'h00000003);

        @(negedge CLK);
        CLKEN  = 1'b0;
        nRESET = 1'b0;
        repeat (3) @(posedge CLK);
        #1;

        if (u_dut.u_core.cpsr.m !== 5'b10011
            || u_dut.u_core.cpsr.i !== 1'b1
            || u_dut.u_core.cpsr.f !== 1'b1
            || u_dut.u_core.cpsr.t !== 1'b0) begin
            $display("[reset_clken] FAIL reset CPSR while stopped: %08x",
                     u_dut.u_core.cpsr);
            errors = errors + 1;
        end

        if (TRANS !== TRANS_I || LOCK !== 1'b0 || DMORE !== 1'b0) begin
            $display("[reset_clken] FAIL reset bus TRANS=%b LOCK=%b DMORE=%b",
                     TRANS, LOCK, DMORE);
            errors = errors + 1;
        end

        @(negedge CLK);
        nRESET = 1'b1;
        repeat (3) @(posedge CLK);
        #1;

        if (u_dut.u_core.cpsr.m !== 5'b10011) begin
            $display("[reset_clken] FAIL reset state lost before CLKEN resumed");
            errors = errors + 1;
        end

        capture_first = 1'b1;
        @(negedge CLK);
        CLKEN = 1'b1;
        repeat (8) @(posedge CLK);
        #1;

        if (!seen_first || first_addr !== 32'h00000000) begin
            $display("[reset_clken] FAIL first fetch seen=%b address=%08x",
                     seen_first, first_addr);
            errors = errors + 1;
        end

        repeat (45) @(posedge CLK);
        if (u_dut.u_core.cpsr.m !== 5'b10000
            || u_dut.u_core.u_regfile.regs[3] !== 32'h00000003) begin
            $display("[reset_clken] FAIL program did not restart from reset");
            errors = errors + 1;
        end

        if (errors != 0)
            $fatal(1, "[reset_clken] FAIL (%0d errors)", errors);
        $display("[reset_clken] PASS");
        $finish;
    end

    initial begin
        repeat (360) @(posedge CLK);
        $fatal(1, "[reset_clken] TIMEOUT");
    end

    initial begin
        $dumpfile("reset_clken.fst");
        $dumpvars(0, arm7tdmis_reset_clken_tb);
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT,
                     CPnI, DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG,
                     DBGCOMMTX, DBGCOMMRX, DBGTDO, DBGnTDOEN};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
