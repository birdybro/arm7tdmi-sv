// JTAG-003 scan-chain-1 entry-cause regression.
//
// The first chain-1 Capture-DR after debug entry reports DBGBREAK=0 for an
// opcode breakpoint and DBGBREAK=1 for a data watchpoint. This test takes
// both paths in one program through scan-programmed WP0/WP1 comparators and
// samples bit 33 in its physical position (the first bit shifted out).

`timescale 1ns/1ps

module arm7tdmis_debug_entry_cause_tb
    import arm7tdmis_debug_pkg::*;
    import arm7tdmis_jtag_tb_pkg::*;
;

    localparam int CYCLE_LIMIT = 2200;
    localparam logic [31:0] DEBUG_NOP = 32'hE1A0_0000;

    logic CLK = 1'b0;
    initial forever #5 CLK = ~CLK;

    logic nRESET = 1'b0;

    logic CLKEN = 1'b0;
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
    logic [31:0] RDATA;
    logic        ABORT;
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
        .INIT_HEX ("../tb/programs/debug_entry_cause_test.hex")
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

    int errors = 0;

    task automatic fail(input string description);
        $display("[debug_entry_cause] FAIL: %s", description);
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
        input  int unsigned width,
        input  logic [37:0] serial_in,
        output logic [37:0] serial_out
    );
        serial_out = '0;
        tck(1'b1, 1'b0);
        tck(1'b0, 1'b0);
        tck(1'b0, 1'b0);
        for (int i = 0; i < width; i++) begin
            serial_out[i] = DBGTDO;
            tck(i == (width - 1), serial_in[i]);
        end
        tck(1'b1, 1'b0);
        tck(1'b0, 1'b0);
    endtask

    task automatic select_chain(input logic [3:0] chain);
        logic [37:0] ignored;
        load_ir(4'(IR_SCAN_N));
        shift_dr(4, {34'h0, chain}, ignored);
        if (&{1'b0, ignored})
            fail("unreachable SCAN_N sentinel");
        load_ir(4'(IR_INTEST));
    endtask

    task automatic write_ice(
        input logic [4:0]  address,
        input logic [31:0] data
    );
        logic [37:0] ignored;
        shift_dr(38, chain2_serial_in(1'b1, address, data), ignored);
        if (&{1'b0, ignored})
            fail("unreachable chain-2 sentinel");
    endtask

    task automatic capture_entry_cause(output logic watchpoint_cause);
        logic [37:0] captured;
        select_chain(4'd1);
        shift_dr(33, chain1_serial_in(DEBUG_NOP, 1'b0), captured);
        watchpoint_cause = captured[0];
        if (&{1'b0, captured[37:1]})
            fail("unreachable chain-1 sentinel");

        // The same Update-DR injects DEBUG_NOP. Wait for its real retirement
        // so the following scan-chain change cannot overlap the handshake.
        for (int i = 0; i < 80; i++) begin
            @(posedge CLK);
            #1;
            if (!u_dut.u_ice.dbg_inject_active)
                return;
        end
        fail("capturing entry cause did not retire the paired debug NOP");
    endtask

    task automatic wait_for_halt(input string description);
        for (int i = 0; i < 280; i++) begin
            @(posedge CLK);
            #1;
            if (DBGACK)
                return;
        end
        fail(description);
    endtask

    initial begin : run_test
        logic breakpoint_cause;
        logic watchpoint_cause;
        logic consumed_cause;

        $dumpfile("debug_entry_cause.fst");
        $dumpvars(0, arm7tdmis_debug_entry_cause_tb);
        u_mem.mem[64] = 32'hDEAD_BEEF;

        repeat (4) @(posedge CLK);
        nRESET = 1'b1;
        repeat (2) @(posedge CLK);
        DBGnTRST = 1'b1;
        tck(1'b0, 1'b0);
        select_chain(4'd2);

        // WP0: exact privileged ARM opcode fetch at 0x24.
        write_ice(5'h08, 32'h0000_0024);
        write_ice(5'h09, 32'h0000_0003);
        write_ice(5'h0A, 32'h0000_0000);
        write_ice(5'h0B, 32'hFFFF_FFFF);
        write_ice(5'h0C, 32'h0000_0114);
        write_ice(5'h0D, 32'h0000_00E0);

        // WP1: exact privileged word read at 0x100.
        write_ice(5'h10, 32'h0000_0100);
        write_ice(5'h11, 32'h0000_0000);
        write_ice(5'h12, 32'h0000_0000);
        write_ice(5'h13, 32'hFFFF_FFFF);
        write_ice(5'h14, 32'h0000_011C);
        write_ice(5'h15, 32'h0000_00E0);

        CLKEN = 1'b1;
        wait_for_halt("opcode breakpoint did not enter debug");
        capture_entry_cause(breakpoint_cause);
        if (breakpoint_cause !== 1'b0)
            fail("opcode breakpoint did not scan out entry cause zero");

        // Reset between the independent entry paths. Reading chain 1 also
        // loads a debug instruction, so a conformant debugger would restore
        // state and branch on exit; reset avoids conflating that separate
        // exit-PC protocol with this entry-cause test.
        CLKEN = 1'b0;
        nRESET = 1'b0;
        DBGnTRST = 1'b0;
        repeat (3) @(posedge CLK);
        nRESET = 1'b1;
        repeat (3) @(posedge CLK);
        DBGnTRST = 1'b1;
        tck(1'b0, 1'b0);
        select_chain(4'd2);

        // Configure only WP1 for the fresh data-watchpoint run.
        write_ice(5'h10, 32'h0000_0100);
        write_ice(5'h11, 32'h0000_0000);
        write_ice(5'h12, 32'h0000_0000);
        write_ice(5'h13, 32'hFFFF_FFFF);
        write_ice(5'h14, 32'h0000_011C);
        write_ice(5'h15, 32'h0000_00E0);

        CLKEN = 1'b1;
        wait_for_halt("data watchpoint did not enter debug");
        if (u_dut.u_core.u_regfile.regs[2] !== 32'hDEAD_BEEF)
            fail("watchpoint halted before the LDR destination committed");

        capture_entry_cause(watchpoint_cause);
        if (watchpoint_cause !== 1'b1)
            fail("data watchpoint did not scan out entry cause one");
        capture_entry_cause(consumed_cause);
        if (consumed_cause !== 1'b0)
            fail("watchpoint entry cause remained set after first capture");

        // No architectural instruction after the watched LDR may retire.
        if (u_dut.u_core.u_regfile.regs[3] !== 32'h0000_0000)
            fail("instruction after watchpoint retired before debug");

        if (errors != 0)
            $fatal(1, "[debug_entry_cause] FAIL (%0d errors)", errors);
        $display("[debug_entry_cause] PASS");
        $finish;
    end

    initial begin
        repeat (CYCLE_LIMIT) @(posedge CLK);
        $fatal(1, "[debug_entry_cause] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI,
        DBGnEXEC, DBGINSTRVALID, DBGRNG, DBGCOMMTX, DBGCOMMRX, DBGnTDOEN,
        DMORE};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
