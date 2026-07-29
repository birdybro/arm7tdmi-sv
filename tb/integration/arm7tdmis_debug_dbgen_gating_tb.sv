// JTAG-004 top-level DBGEN gating regression.
//
// Appendix A specifies DBGTCKEN, DBGTMS, DBGTDI, and DBGTDO as enabled only
// while DBGEN is HIGH. With debug disabled the TAP must not advance, TDO must
// be quiescent, and nTDOEN must force the external pad to HiZ. DBGnTRST remains
// an asynchronous reset independent of DBGEN.

`timescale 1ns/1ps

module arm7tdmis_debug_dbgen_gating_tb;

    localparam logic [3:0] TLR  = 4'h0;
    localparam logic [3:0] RTI  = 4'h1;
    localparam logic [3:0] SDRS = 4'h2;
    localparam logic [3:0] CDR  = 4'h3;
    localparam logic [3:0] SDR  = 4'h4;
    localparam logic [3:0] E1DR = 4'h5;

    logic CLK = 1'b0;
    initial forever #5 CLK = ~CLK;

    logic CLKEN = 1'b0;
    logic nRESET = 1'b0;
    logic DBGEN = 1'b0;
    logic DBGRQ = 1'b1;
    logic DBGBREAK = 1'b1;
    logic DBGTCKEN = 1'b0;
    logic DBGTMS = 1'b1;
    logic DBGTDI = 1'b0;
    logic DBGnTRST = 1'b0;

    logic [31:0] ADDR;
    logic        WRITE;
    logic [1:0]  SIZE;
    logic [1:0]  PROT;
    logic        LOCK;
    logic [1:0]  TRANS;
    logic [31:0] WDATA;
    logic        CPnMREQ;
    logic        CPSEQ;
    logic        CPnTRANS;
    logic        CPnOPC;
    logic        CPTBIT;
    logic        CPnI;
    logic        DBGACK;
    logic        DBGnEXEC;
    logic        DBGINSTRVALID;
    logic [1:0]  DBGRNG;
    logic        DBGCOMMTX;
    logic        DBGCOMMRX;
    logic        DBGTDO;
    logic        DBGnTDOEN;
    logic        DMORE;

    arm7tdmis_top u_dut (
        .CLK,
        .CLKEN,
        .nRESET,
        .CFGBIGEND        (1'b0),
        .nIRQ             (1'b1),
        .nFIQ             (1'b1),
        .ABORT            (1'b0),
        .ADDR,
        .WRITE,
        .SIZE,
        .PROT,
        .LOCK,
        .TRANS,
        .WDATA,
        .RDATA            (32'hE7FF_FFFE),
        .CPnMREQ,
        .CPSEQ,
        .CPnTRANS,
        .CPnOPC,
        .CPTBIT,
        .CPnI,
        .CPA              (1'b1),
        .CPB              (1'b1),
        .DBGEN,
        .DBGRQ,
        .DBGBREAK,
        .DBGACK,
        .DBGnEXEC,
        .DBGINSTRVALID,
        .DBGEXT           (2'b11),
        .DBGRNG,
        .DBGCOMMTX,
        .DBGCOMMRX,
        .DBGTCKEN,
        .DBGTMS,
        .DBGTDI,
        .DBGTDO,
        .DBGnTRST,
        .DBGnTDOEN,
        .DMORE
    );

    int errors = 0;

    task automatic check(input logic condition, input string description);
        if (!condition) begin
            $display("[debug_dbgen_gating] FAIL: %s", description);
            errors = errors + 1;
        end
    endtask

    task automatic tck(input logic tms, input logic tdi);
        @(negedge CLK);
        DBGTMS   = tms;
        DBGTDI   = tdi;
        DBGTCKEN = 1'b1;
        @(posedge CLK);
        #1;
        DBGTCKEN = 1'b0;
    endtask

    task automatic check_state(
        input logic [3:0] expected,
        input string      description
    );
        check($unsigned(u_dut.u_tap.tap_q) == expected, description);
    endtask

    initial begin
        $dumpfile("debug_dbgen_gating.fst");
        $dumpvars(0, arm7tdmis_debug_dbgen_gating_tb);

        repeat (2) @(posedge CLK);
        nRESET = 1'b1;
        DBGnTRST = 1'b1;
        #1;

        // A complete path toward Shift-DR must be ignored while DBGEN=0.
        tck(1'b0, 1'b0);
        tck(1'b1, 1'b0);
        tck(1'b0, 1'b0);
        tck(1'b0, 1'b0);
        check_state(TLR, "disabled JTAG clocks advanced the TAP");
        check(DBGTDO == 1'b0, "DBGTDO was not quiescent with DBGEN=0");
        check(DBGnTDOEN == 1'b1,
              "DBGnTDOEN enabled the pad with DBGEN=0");
        check(DBGACK == 1'b0 && DBGRNG == 2'b00
              && DBGCOMMTX == 1'b0 && DBGCOMMRX == 1'b0,
              "debug status outputs were enabled with DBGEN=0");

        // Enabling debug permits a normal IDCODE Shift-DR path.
        // Reset first so failures in the disabled-path check cannot cascade
        // into the independent enabled-path assertions.
        DBGnTRST = 1'b0;
        #1;
        check_state(TLR, "DBGnTRST did not recover the disabled TAP attempt");
        DBGnTRST = 1'b1;
        #1;
        DBGEN = 1'b1;
        tck(1'b0, 1'b0);
        check_state(RTI, "enabled TAP did not enter Run-Test/Idle");
        tck(1'b1, 1'b0);
        check_state(SDRS, "enabled TAP did not enter Select-DR-Scan");
        tck(1'b0, 1'b0);
        check_state(CDR, "enabled TAP did not enter Capture-DR");
        tck(1'b0, 1'b0);
        check_state(SDR, "enabled TAP did not enter Shift-DR");
        check(DBGnTDOEN == 1'b0 && DBGTDO == 1'b1,
              "enabled IDCODE path did not drive its least-significant bit");

        // Dropping DBGEN is an immediate external-output gate and freezes the
        // current scan position. Re-enabling resumes from that exact state.
        DBGEN = 1'b0;
        #1;
        check(DBGTDO == 1'b0 && DBGnTDOEN == 1'b1,
              "falling DBGEN did not immediately disable TDO");
        tck(1'b1, 1'b1);
        check_state(SDR, "disabled clock changed a partially shifted TAP");

        DBGEN = 1'b1;
        #1;
        if ($unsigned(u_dut.u_tap.tap_q) == SDR) begin
            check(DBGnTDOEN == 1'b0,
                  "re-enabled TAP did not restore Shift-DR output enable");
            tck(1'b1, 1'b0);
            check_state(E1DR, "re-enabled TAP did not resume Shift-DR");
        end

        // DBGnTRST remains asynchronous and effective even with DBGEN LOW.
        DBGEN = 1'b0;
        DBGnTRST = 1'b0;
        #1;
        check_state(TLR, "DBGnTRST was gated by DBGEN");
        check(DBGTDO == 1'b0 && DBGnTDOEN == 1'b1,
              "reset disabled-port outputs were not safe");

        if (errors != 0)
            $fatal(1, "[debug_dbgen_gating] FAIL (%0d errors)", errors);
        $display("[debug_dbgen_gating] PASS");
        $finish;
    end

    initial begin
        #10000;
        $fatal(1, "[debug_dbgen_gating] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, ADDR, WRITE, SIZE, PROT, LOCK, TRANS, WDATA,
        CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI, DBGnEXEC,
        DBGINSTRVALID, DMORE};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
