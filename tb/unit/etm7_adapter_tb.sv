// ETM-002: exact TRM Table 6-1 external ETM7 wiring contract.

`timescale 1ns/1ps

module etm7_adapter_tb;
    logic CLK = 1'b0;
    initial forever #5 CLK = ~CLK;

    logic        CLKEN;
    logic        nRESET;
    logic        DBGnTRST;
    logic        CFGBIGEND;
    logic [31:0] ADDR;
    logic        ABORT;
    logic        CPA;
    logic        CPB;
    logic        DBGACK;
    logic        CPnMREQ;
    logic        CPSEQ;
    logic [1:0]  SIZE;
    logic        CPnI;
    logic        DBGnEXEC;
    logic        CPnOPC;
    logic        WRITE;
    logic [1:0]  DBGRNG;
    logic [31:0] RDATA;
    logic        CPTBIT;
    logic        DBGTCKEN;
    logic        DBGTDI;
    logic        DBGTDO;
    logic        DBGTMS;
    logic [31:0] WDATA;
    logic        DBGINSTRVALID;
    logic        ETM_DBGRQ;

    logic        ETM_CLK;
    logic        ETM_TCK;
    logic        ETM_CLKEN;
    logic        ETM_nRESET;
    logic        ETM_nTRST;
    logic        ETM_BIGEND;
    logic [31:0] ETM_A;
    logic        ETM_ABORT;
    logic        ETM_CPA;
    logic        ETM_CPB;
    logic        ETM_DBGACK;
    logic        CPU_DBGRQ;
    logic        ETM_nMREQ;
    logic        ETM_SEQ;
    logic [1:0]  ETM_MAS;
    logic        ETM_nCPI;
    logic        ETM_nEXEC;
    logic        ETM_nOPC;
    logic        ETM_nRW;
    logic [1:0]  ETM_RANGEOUT;
    logic [31:0] ETM_RDATA;
    logic        ETM_TBIT;
    logic        ETM_TCKEN;
    logic        ETM_TDI;
    logic        ETM_TDO;
    logic        ETM_ARMTDO;
    logic        ETM_TMS;
    logic [31:0] ETM_WDATA;
    logic        ETM_INSTRVALID;
    logic [31:0] ETM_PROCID;
    logic        ETM_PROCIDWR;

    arm7tdmis_etm7_adapter u_dut (.*);

    int unsigned errors = 0;

    task automatic check_equal(
        input logic [31:0] actual,
        input logic [31:0] expected,
        input string       label
    );
        if (actual !== expected) begin
            $display("[etm7_adapter] FAIL %s expected %08x got %08x",
                     label, expected, actual);
            errors++;
        end
    endtask

    initial begin
        CLKEN = 1'b0;
        nRESET = 1'b0;
        DBGnTRST = 1'b0;
        CFGBIGEND = 1'b0;
        ADDR = 32'h0123_4567;
        ABORT = 1'b0;
        CPA = 1'b1;
        CPB = 1'b1;
        DBGACK = 1'b0;
        CPnMREQ = 1'b1;
        CPSEQ = 1'b0;
        SIZE = 2'b10;
        CPnI = 1'b1;
        DBGnEXEC = 1'b1;
        CPnOPC = 1'b0;
        WRITE = 1'b0;
        DBGRNG = 2'b00;
        RDATA = 32'h89ab_cdef;
        CPTBIT = 1'b0;
        DBGTCKEN = 1'b0;
        DBGTDI = 1'b0;
        DBGTDO = 1'b0;
        DBGTMS = 1'b0;
        WDATA = 32'h7654_3210;
        DBGINSTRVALID = 1'b0;
        ETM_DBGRQ = 1'b0;
        #1;

        check_equal(ETM_PROCID, 32'h0, "PROCID reset tie-off");
        check_equal({31'h0, ETM_PROCIDWR}, 32'h0, "PROCIDWR tie-off");
        check_equal({30'h0, ETM_nRESET, ETM_nTRST}, 32'h0,
                    "reset propagation low");
        check_equal(ETM_A, ADDR, "address direct");
        check_equal(ETM_RDATA, RDATA, "RDATA direct");
        check_equal(ETM_WDATA, WDATA, "WDATA direct");

        CLKEN = 1'b1;
        nRESET = 1'b1;
        DBGnTRST = 1'b1;
        CFGBIGEND = 1'b1;
        ADDR = 32'hfedc_ba98;
        ABORT = 1'b1;
        CPA = 1'b0;
        CPB = 1'b0;
        DBGACK = 1'b1;
        CPnMREQ = 1'b0;
        CPSEQ = 1'b1;
        SIZE = 2'b01;
        CPnI = 1'b0;
        DBGnEXEC = 1'b0;
        CPnOPC = 1'b1;
        WRITE = 1'b1;
        DBGRNG = 2'b10;
        RDATA = 32'h1357_9bdf;
        CPTBIT = 1'b1;
        DBGTCKEN = 1'b1;
        DBGTDI = 1'b1;
        DBGTDO = 1'b1;
        DBGTMS = 1'b1;
        WDATA = 32'h2468_ace0;
        DBGINSTRVALID = 1'b1;
        ETM_DBGRQ = 1'b1;
        #1;

        check_equal({
            ETM_CLKEN, ETM_nRESET, ETM_nTRST, ETM_BIGEND,
            ETM_ABORT, ETM_CPA, ETM_CPB, ETM_DBGACK,
            CPU_DBGRQ, ETM_nMREQ, ETM_SEQ, ETM_MAS,
            ETM_nCPI, ETM_nEXEC, ETM_nOPC, ETM_nRW,
            ETM_RANGEOUT, ETM_TBIT, ETM_TCKEN, ETM_TDI,
            ETM_TDO, ETM_ARMTDO, ETM_TMS, ETM_INSTRVALID
        }, {
            CLKEN, nRESET, DBGnTRST, CFGBIGEND,
            ABORT, CPA, CPB, DBGACK,
            ETM_DBGRQ, CPnMREQ, CPSEQ, SIZE,
            CPnI, DBGnEXEC, CPnOPC, WRITE,
            DBGRNG, CPTBIT, DBGTCKEN, DBGTDI,
            DBGTDO, DBGTDO, DBGTMS, DBGINSTRVALID
        }, "scalar and control mapping");
        check_equal(ETM_A, ADDR, "changed address direct");
        check_equal(ETM_RDATA, RDATA, "changed RDATA direct");
        check_equal(ETM_WDATA, WDATA, "changed WDATA direct");
        check_equal(ETM_PROCID, 32'h0, "PROCID permanent tie-off");
        check_equal({31'h0, ETM_PROCIDWR}, 32'h0,
                    "PROCIDWR permanent tie-off");

        @(posedge CLK);
        #1;
        if (ETM_CLK !== CLK || ETM_TCK !== CLK) begin
            $display("[etm7_adapter] FAIL CLK/TCK high mapping");
            errors++;
        end
        @(negedge CLK);
        #1;
        if (ETM_CLK !== CLK || ETM_TCK !== CLK) begin
            $display("[etm7_adapter] FAIL CLK/TCK low mapping");
            errors++;
        end

        if (errors != 0)
            $fatal(1, "[etm7_adapter] FAIL (%0d errors)", errors);
        $display("[etm7_adapter] PASS (TRM Table 6-1)");
        $finish;
    end

    initial begin
        repeat (20) @(posedge CLK);
        $fatal(1, "[etm7_adapter] TIMEOUT");
    end
endmodule
