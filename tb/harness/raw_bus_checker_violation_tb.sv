// Mutation matrix for the reusable raw-bus checker.  Select one case with
// +CASE=<name>.  Every case except "legal" deliberately violates exactly one
// checker rule and must terminate through that rule's assertion.

`timescale 1ns/1ps

module raw_bus_checker_violation_tb
    import arm7tdmis_bus_pkg::*;
;

    logic CLK = 1'b0;
    initial forever #5 CLK = ~CLK;

    logic nRESET = 1'b0;
    logic CFGBIGEND = 1'b0;
    logic CLKEN = 1'b1;
    logic [31:0] ADDR = 32'h0;
    logic WRITE = WRITE_READ;
    logic [1:0] SIZE = 2'(SIZE_WORD);
    logic [1:0] PROT = 2'(PROT_OPC_PRIV);
    logic LOCK = LOCK_FREE;
    logic [1:0] TRANS = 2'(TRANS_I);
    logic [31:0] WDATA = 32'h0;
    logic DMORE = 1'b0;
    logic CPnMREQ = 1'b1;
    logic CPSEQ = 1'b0;
    logic CPnOPC = 1'b0;
    logic CPnI = 1'b1;
    string test_case;

    arm7tdmis_raw_bus_checker u_checker (
        .CLK,
        .CLKEN,
        .nRESET,
        .CFGBIGEND,
        .ADDR,
        .WRITE,
        .SIZE,
        .PROT,
        .LOCK,
        .TRANS,
        .WDATA,
        .DMORE,
        .CPnMREQ,
        .CPSEQ,
        .CPnOPC,
        .CPnI
    );

    task automatic drive_phase(
        input logic [31:0] addr,
        input trans_e      trans,
        input size_e       size,
        input prot_e       prot,
        input logic        write,
        input logic        lock,
        input logic        dmore,
        input logic        cpni
    );
        @(negedge CLK);
        ADDR     = addr;
        TRANS    = 2'(trans);
        SIZE     = 2'(size);
        PROT     = 2'(prot);
        WRITE    = write;
        LOCK     = lock;
        DMORE    = dmore;
        CPnI     = cpni;
        CPnMREQ  = !(trans inside {TRANS_N, TRANS_S});
        CPSEQ    = trans[0];
        CPnOPC   = prot[PROT_BIT_DATA];
    endtask

    initial begin
        if (!$value$plusargs("CASE=%s", test_case))
            $fatal(1, "raw checker self-test requires +CASE=<name>");

        if (test_case == "reset_controls") begin
            @(negedge CLK);
            TRANS   = 2'(TRANS_N);
            CPnMREQ = 1'b0;
            repeat (3) @(posedge CLK);
            $fatal(1, "raw checker accepted active reset controls");
        end

        repeat (3) @(posedge CLK);
        @(negedge CLK);
        nRESET = 1'b1;
        repeat (2) @(posedge CLK);

        if (test_case == "cfg_change") begin
            @(negedge CLK);
            CFGBIGEND = 1'b1;
        end else if (test_case == "reserved_size") begin
            @(negedge CLK);
            SIZE = 2'(SIZE_RESERVED);
        end else if (test_case == "cpnmreq_mirror") begin
            @(negedge CLK);
            CPnMREQ = 1'b0;
        end else if (test_case == "cpseq_mirror") begin
            @(negedge CLK);
            CPSEQ = 1'b1;
        end else if (test_case == "cpnopc_mirror") begin
            @(negedge CLK);
            CPnOPC = 1'b1;
        end else if (test_case == "dmore_class") begin
            @(negedge CLK);
            DMORE = 1'b1;
        end else if (test_case == "sequential_history") begin
            drive_phase(32'h0000_0004, TRANS_S, SIZE_WORD, PROT_OPC_PRIV,
                        WRITE_READ, LOCK_FREE, 1'b0, 1'b1);
        end else if (test_case == "byte_burst") begin
            drive_phase(32'h0000_0004, TRANS_S, SIZE_BYTE, PROT_DAT_PRIV,
                        WRITE_READ, LOCK_FREE, 1'b0, 1'b1);
        end else if (test_case == "dmore_follower") begin
            drive_phase(32'h0000_0100, TRANS_N, SIZE_WORD, PROT_DAT_PRIV,
                        WRITE_READ, LOCK_FREE, 1'b1, 1'b1);
            drive_phase(32'h0000_0104, TRANS_I, SIZE_WORD, PROT_DAT_PRIV,
                        WRITE_READ, LOCK_FREE, 1'b0, 1'b1);
        end else if (test_case == "stall_mutation") begin
            drive_phase(32'h0000_0200, TRANS_N, SIZE_WORD, PROT_DAT_PRIV,
                        WRITE_READ, LOCK_FREE, 1'b0, 1'b1);
            @(negedge CLK);
            CLKEN = 1'b0;
            @(negedge CLK);
            #1 ADDR = 32'h0000_0204;
        end else if (test_case == "legal") begin
            // Ordinary N/S burst with DMORE address prediction.
            drive_phase(32'h0000_0100, TRANS_N, SIZE_WORD, PROT_DAT_PRIV,
                        WRITE_READ, LOCK_FREE, 1'b1, 1'b1);
            drive_phase(32'h0000_0104, TRANS_S, SIZE_WORD, PROT_DAT_PRIV,
                        WRITE_READ, LOCK_FREE, 1'b0, 1'b1);
            // Merged I/S prefetch.
            drive_phase(32'h0000_0200, TRANS_I, SIZE_HALFWORD, PROT_OPC_USR,
                        WRITE_READ, LOCK_FREE, 1'b0, 1'b1);
            drive_phase(32'h0000_0200, TRANS_S, SIZE_HALFWORD, PROT_OPC_USR,
                        WRITE_READ, LOCK_FREE, 1'b0, 1'b1);
            // First multiword LDC/STC S cycle after an accepted CP phase.
            drive_phase(32'h0000_0300, TRANS_C, SIZE_WORD, PROT_OPC_PRIV,
                        WRITE_READ, LOCK_FREE, 1'b0, 1'b0);
            drive_phase(32'h0000_0400, TRANS_S, SIZE_WORD, PROT_DAT_PRIV,
                        WRITE_READ, LOCK_FREE, 1'b0, 1'b1);
            // A stopped clock may hold a stable active address indefinitely.
            drive_phase(32'h0000_0404, TRANS_I, SIZE_WORD, PROT_OPC_PRIV,
                        WRITE_READ, LOCK_FREE, 1'b0, 1'b1);
            @(negedge CLK);
            CLKEN = 1'b0;
            repeat (3) @(negedge CLK);
            CLKEN = 1'b1;
            drive_phase(32'h0000_0500, TRANS_N, SIZE_WORD, PROT_OPC_PRIV,
                        WRITE_READ, LOCK_FREE, 1'b0, 1'b1);
            repeat (2) @(posedge CLK);
            $display("[raw-checker-self-test/legal] PASS");
            $finish;
        end else begin
            $fatal(1, "unknown raw checker self-test CASE=%s", test_case);
        end

        repeat (3) @(posedge CLK);
        $fatal(1, "raw checker accepted CASE=%s", test_case);
    end

endmodule
