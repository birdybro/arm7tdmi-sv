// DBG-004 breakpoint pipeline-kill regression.
//
// The instruction at 0x24 is fetched behind a taken branch at 0x20. WP0 is
// programmed as a hardware breakpoint on 0x24. EmbeddedICE-RT may report
// the fetch on DBGRNG, but the branch flush must cancel its breakpoint tag:
// no debug entry and no fall-through instruction may execute.

`timescale 1ns/1ps

module arm7tdmis_debug_breakpoint_flush_tb
    import arm7tdmis_debug_pkg::*;
;

    localparam int CYCLE_LIMIT = 1400;

    logic CLK;
    initial begin
        CLK = 1'b0;
        forever #5 CLK = ~CLK;
    end

    logic nRESET;
    initial begin
        nRESET = 1'b0;
        repeat (4) @(posedge CLK);
        nRESET = 1'b1;
    end

    logic CLKEN = 1'b0;
    logic ABORT;
    logic DBGTCKEN = 1'b0;
    logic DBGTMS = 1'b1;
    logic DBGTDI = 1'b0;
    logic DBGnTRST = 1'b0;
    logic [31:0] ADDR, WDATA, RDATA;
    logic WRITE;
    logic [1:0] SIZE, PROT, TRANS;
    logic LOCK;
    logic CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI;
    logic DBGACK, DBGnEXEC, DBGINSTRVALID;
    logic [1:0] DBGRNG;
    logic DBGCOMMTX, DBGCOMMRX, DBGTDO, DBGnTDOEN, DMORE;

    arm7tdmis_top u_dut (
        .CLK,
        .CLKEN,
        .nRESET,
        .CFGBIGEND        (1'b0),
        .nIRQ             (1'b1),
        .nFIQ             (1'b1),
        .ABORT,
        .ADDR, .WRITE, .SIZE, .PROT, .LOCK, .TRANS, .WDATA, .RDATA,
        .CPnMREQ, .CPSEQ, .CPnTRANS, .CPnOPC, .CPTBIT, .CPnI,
        .CPA              (1'b1),
        .CPB              (1'b1),
        .DBGEN            (1'b1),
        .DBGRQ            (1'b0),
        .DBGBREAK         (1'b0),
        .DBGACK,
        .DBGnEXEC,
        .DBGINSTRVALID,
        .DBGEXT           (2'b00),
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

    arm7tdmis_memory #(
        .WORDS    (128),
        .INIT_HEX ("../tb/programs/debug_breakpoint_flush_test.hex")
    ) u_mem (
        .CLK,
        .CLKEN,
        .nRESET,
        .CFGBIGEND        (1'b0),
        .ADDR, .WRITE, .SIZE, .PROT, .LOCK, .TRANS, .WDATA, .RDATA,
        .ABORT,
        .inject_abort     (1'b0)
    );

    logic [37:0] ignored_scan;

    task automatic tck(input logic tms, input logic tdi);
        @(negedge CLK);
        DBGTMS   = tms;
        DBGTDI   = tdi;
        DBGTCKEN = 1'b1;
        @(posedge CLK);
        #1;
        DBGTCKEN = 1'b0;
    endtask

    task automatic load_ir(input logic [3:0] instruction);
        tck(1'b1, 1'b0);
        tck(1'b1, 1'b0);
        tck(1'b0, 1'b0);
        tck(1'b0, 1'b0);
        for (int i = 0; i < 4; i++)
            tck(i == 3, instruction[i]);
        tck(1'b1, 1'b0);
        tck(1'b0, 1'b0);
    endtask

    task automatic shift_dr(
        input int unsigned width,
        input logic [37:0] scan_in
    );
        tck(1'b1, 1'b0);
        tck(1'b0, 1'b0);
        tck(1'b0, 1'b0);
        for (int i = 0; i < width; i++) begin
            ignored_scan[i] = DBGTDO;
            tck(i == (width - 1), scan_in[i]);
        end
        tck(1'b1, 1'b0);
        tck(1'b0, 1'b0);
    endtask

    task automatic select_chain2;
        load_ir(4'(IR_SCAN_N));
        shift_dr(4, 38'd2);
        load_ir(4'(IR_INTEST));
    endtask

    task automatic write_ice(
        input logic [4:0] addr,
        input logic [31:0] data
    );
        shift_dr(38, {1'b1, addr, data});
    endtask

    int unsigned errors = 0;
    bit range_seen;
    bit completed;

    initial begin : run_test
        $dumpfile("debug_breakpoint_flush.fst");
        $dumpvars(0, arm7tdmis_debug_breakpoint_flush_tb);

        repeat (2) @(posedge CLK);
        DBGnTRST = 1'b1;
        tck(1'b0, 1'b0); // TLR -> RTI
        select_chain2();

        // Exact address 0x24; data ignored; exact privileged ARM opcode read.
        write_ice(5'h08, 32'h0000_0024);
        write_ice(5'h09, 32'h0000_0003); // ignore word-alignment address bits
        write_ice(5'h0A, 32'h0000_0000);
        write_ice(5'h0B, 32'hFFFF_FFFF);
        write_ice(5'h0C, 32'h0000_0114);
        write_ice(5'h0D, 32'h0000_00E0);

        CLKEN = 1'b1;
        range_seen = 1'b0;
        completed = 1'b0;
        for (int i = 0; i < 220; i++) begin
            @(posedge CLK);
            if (DBGRNG[0])
                range_seen = 1'b1;
            if (DBGACK) begin
                $display("[debug_breakpoint_flush] FAIL flushed breakpoint entered debug");
                errors = errors + 1;
                break;
            end
            if (u_dut.u_core.u_regfile.regs[2] == 32'h22) begin
                completed = 1'b1;
                break;
            end
        end

        if (!range_seen) begin
            $display("[debug_breakpoint_flush] FAIL fall-through fetch never matched");
            errors = errors + 1;
        end
        if (!completed) begin
            $display("[debug_breakpoint_flush] FAIL taken-branch target did not complete");
            errors = errors + 1;
        end
        if (u_dut.u_core.u_regfile.regs[1] !== 32'h0) begin
            $display("[debug_breakpoint_flush] FAIL flushed instruction changed r1=%08x",
                     u_dut.u_core.u_regfile.regs[1]);
            errors = errors + 1;
        end

        if (errors != 0)
            $fatal(1, "[debug_breakpoint_flush] FAIL (%0d errors)", errors);
        $display("[debug_breakpoint_flush] PASS");
        $finish;
    end

    initial begin
        repeat (CYCLE_LIMIT) @(posedge CLK);
        $fatal(1, "[debug_breakpoint_flush] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, ADDR, WRITE, SIZE, PROT, LOCK, TRANS, WDATA,
        CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI, DBGnEXEC,
        DBGINSTRVALID, DBGRNG[1], DBGCOMMTX, DBGCOMMRX, DBGnTDOEN, DMORE,
        ignored_scan};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
