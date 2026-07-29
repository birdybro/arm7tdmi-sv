// DBG-007/JTAG-005 scan-driven PC restore and debug-exit regression.
//
// Reproduce OpenOCD's ARM7TDMI write_pc() and branch_resume() sequences:
// load r15 through a debug-speed one-register LDM, scan the synchronization
// NOP/bit33 and B -6 pair, then issue RESTART. The requested target must be
// the first resumed program and ordinary exit must not auto-reenter debug.

`timescale 1ns/1ps

module arm7tdmis_debug_pc_resume_tb
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_debug_pkg::*;
    import arm7tdmis_jtag_tb_pkg::*;
;

    localparam int CYCLE_LIMIT = 5000;
    localparam logic [31:0] DEBUG_LDM_PC = 32'hE890_8000;
    localparam logic [31:0] DEBUG_NOP = 32'hE1A0_8008;
    localparam logic [31:0] DEBUG_RETURN_BRANCH = 32'hEAFF_FFFA;
    localparam logic [31:0] RESUME_PC = 32'h0000_0080;

    logic CLK = 1'b0;
    initial forever #5 CLK = ~CLK;

    logic nRESET = 1'b0;
    logic CLKEN = 1'b0;
    logic DBGRQ = 1'b1;
    logic ABORT;
    logic DBGTCKEN = 1'b0;
    logic DBGTMS = 1'b1;
    logic DBGTDI = 1'b0;
    logic DBGnTRST = 1'b0;
    logic [31:0] ADDR;
    logic [31:0] WDATA;
    logic [31:0] RDATA;
    logic WRITE;
    logic [1:0] SIZE;
    logic [1:0] PROT;
    logic [1:0] TRANS;
    logic LOCK;
    logic CPnMREQ;
    logic CPSEQ;
    logic CPnTRANS;
    logic CPnOPC;
    logic CPTBIT;
    logic CPnI;
    logic DBGACK;
    logic DBGnEXEC;
    logic DBGINSTRVALID;
    logic [1:0] DBGRNG;
    logic DBGCOMMTX;
    logic DBGCOMMRX;
    logic DBGTDO;
    logic DBGnTDOEN;
    logic DMORE;

    arm7tdmis_top u_dut (
        .CLK,
        .CLKEN,
        .nRESET,
        .CFGBIGEND        (1'b0),
        .nIRQ             (1'b1),
        .nFIQ             (1'b1),
        .ABORT,
        .ADDR,
        .WRITE,
        .SIZE,
        .PROT,
        .LOCK,
        .TRANS,
        .WDATA,
        .RDATA,
        .CPnMREQ,
        .CPSEQ,
        .CPnTRANS,
        .CPnOPC,
        .CPTBIT,
        .CPnI,
        .CPA              (1'b1),
        .CPB              (1'b1),
        .DBGEN            (1'b1),
        .DBGRQ,
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
        .WORDS    (256),
        .INIT_HEX ("../tb/programs/debug_pc_resume_test.hex")
    ) u_mem (
        .CLK,
        .CLKEN,
        .nRESET,
        .CFGBIGEND        (1'b0),
        .ADDR,
        .WRITE,
        .SIZE,
        .PROT,
        .LOCK,
        .TRANS,
        .WDATA,
        .RDATA,
        .ABORT,
        .inject_abort     (1'b0)
    );

    int unsigned errors = 0;

    task automatic fail(input string description);
        $display("[debug_pc_resume] FAIL: %s", description);
        errors = errors + 1;
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
        input logic [37:0] serial_in,
        output logic [37:0] serial_out
    );
        serial_out = '0;
        tck(1'b1, 1'b0);
        tck(1'b0, 1'b0);
        tck(1'b0, 1'b0);
        for (int i = 0; i < SCAN_CHAIN1_WIDTH; i++) begin
            serial_out[i] = DBGTDO;
            tck(i == (SCAN_CHAIN1_WIDTH - 1), serial_in[i]);
        end
        tck(1'b1, 1'b0);
        tck(1'b0, 1'b0);
    endtask

    task automatic select_chain1;
        load_ir(4'(IR_SCAN_N));
        // SCAN_N is only four bits, so use its dedicated short scan.
        tck(1'b1, 1'b0);
        tck(1'b0, 1'b0);
        tck(1'b0, 1'b0);
        for (int i = 0; i < 4; i++)
            tck(i == 3, i == 0);
        tck(1'b1, 1'b0);
        tck(1'b0, 1'b0);
        load_ir(4'(IR_INTEST));
    endtask

    task automatic clock_out(
        input logic [31:0] data,
        input logic        break_bit
    );
        logic [37:0] ignored;
        shift_dr(chain1_serial_in(data, break_bit), ignored);
        if (&{1'b0, ignored})
            fail("unreachable clock-out sentinel");
    endtask

    initial begin : run_test
        bit target_executed;

        $dumpfile("debug_pc_resume.fst");
        $dumpvars(0, arm7tdmis_debug_pc_resume_tb);

        // Requested resume target: MOV r6,#0x66; B .
        u_mem.mem[RESUME_PC >> 2] = 32'hE3A0_6066;
        u_mem.mem[(RESUME_PC >> 2) + 1] = 32'hEAFF_FFFE;

        repeat (4) @(posedge CLK);
        nRESET = 1'b1;
        repeat (2) @(posedge CLK);
        DBGnTRST = 1'b1;
        CLKEN = 1'b1;

        for (int i = 0; i < 120; i++) begin
            @(posedge CLK);
            #1;
            if (DBGACK)
                break;
        end
        if (!DBGACK)
            fail("DBGRQ did not enter debug state");
        DBGRQ = 1'b0;

        tck(1'b0, 1'b0);
        select_chain1();

        // OpenOCD arm7tdmi_write_pc().
        clock_out(DEBUG_LDM_PC, 1'b0);
        clock_out(DEBUG_NOP, 1'b0);
        clock_out(DEBUG_NOP, 1'b0);
        clock_out(RESUME_PC, 1'b0);
        repeat (4)
            clock_out(DEBUG_NOP, 1'b0);

        // OpenOCD arm7tdmi_branch_resume(), followed by RESTART.
        clock_out(DEBUG_NOP, 1'b1);
        clock_out(DEBUG_RETURN_BRANCH, 1'b0);
        load_ir(4'(IR_RESTART));

        target_executed = 1'b0;
        for (int i = 0; i < 160; i++) begin
            @(posedge CLK);
            #1;
            if (u_dut.u_core.u_regfile.regs[6] == 32'h0000_0066) begin
                target_executed = 1'b1;
                break;
            end
        end
        if (!target_executed)
            fail($sformatf("resume target did not execute (r6=%08x)",
                           u_dut.u_core.u_regfile.regs[6]));
        if (DBGACK)
            fail("ordinary debug exit automatically reentered debug");

        repeat (32) begin
            @(posedge CLK);
            #1;
            if (DBGACK)
                fail("DBGACK reasserted after ordinary resume");
        end

        if (errors != 0)
            $fatal(1, "[debug_pc_resume] FAIL (%0d errors)", errors);
        $display("[debug_pc_resume] PASS");
        $finish;
    end

    initial begin
        repeat (CYCLE_LIMIT) @(posedge CLK);
        $fatal(1, "[debug_pc_resume] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, ADDR, WDATA, WRITE, SIZE, PROT, LOCK, TRANS,
        CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI,
        DBGnEXEC, DBGINSTRVALID, DBGRNG, DBGCOMMTX, DBGCOMMRX,
        DBGnTDOEN, DMORE};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
