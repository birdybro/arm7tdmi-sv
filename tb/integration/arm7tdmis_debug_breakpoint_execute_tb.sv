// DBG-004 end-to-end breakpoint Execute/restart regression.
//
// WP0 marks a condition-failed instruction and WP1 marks a normal ADD.
// ARM7TDMI-S takes both breakpoints before their Execute effects regardless
// of the condition result. After the debugger disables the corresponding
// comparator and issues RESTART, each stopped instruction is processed once
// and execution continues without immediately retriggering its stale tag.

`timescale 1ns/1ps

module arm7tdmis_debug_breakpoint_execute_tb
    import arm7tdmis_debug_pkg::*;
;

    localparam int CYCLE_LIMIT = 2200;

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
        .INIT_HEX ("../tb/programs/debug_breakpoint_execute_test.hex")
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

    task automatic program_breakpoint(
        input logic       wp1,
        input logic [31:0] address
    );
        logic [4:0] base;
        base = wp1 ? 5'h10 : 5'h08;
        write_ice(base + 5'd0, address);
        write_ice(base + 5'd1, 32'h0000_0003);
        write_ice(base + 5'd2, 32'h0000_0000);
        write_ice(base + 5'd3, 32'hFFFF_FFFF);
        write_ice(base + 5'd4, 32'h0000_0114);
        write_ice(base + 5'd5, 32'h0000_00E0);
    endtask

    int unsigned errors = 0;
    bit wp0_range_seen;
    bit wp1_range_seen;
    bit first_halt;
    bit second_halt;
    bit completed;

    task automatic fail(input string description);
        $display("[debug_breakpoint_execute] FAIL %s", description);
        errors = errors + 1;
    endtask

    initial begin : run_test
        $dumpfile("debug_breakpoint_execute.fst");
        $dumpvars(0, arm7tdmis_debug_breakpoint_execute_tb);

        repeat (2) @(posedge CLK);
        DBGnTRST = 1'b1;
        tck(1'b0, 1'b0);
        select_chain2();

        // 0x28 is MOVEQ with Z=0; 0x30 is ADD r3,r3,#1.
        program_breakpoint(1'b0, 32'h0000_0028);
        program_breakpoint(1'b1, 32'h0000_0030);

        CLKEN = 1'b1;
        wp0_range_seen = 1'b0;
        wp1_range_seen = 1'b0;
        first_halt = 1'b0;
        for (int i = 0; i < 240; i++) begin
            @(posedge CLK);
            if (DBGRNG[0])
                wp0_range_seen = 1'b1;
            if (DBGRNG[1])
                wp1_range_seen = 1'b1;
            if (DBGACK) begin
                #1;
                first_halt = 1'b1;
                break;
            end
        end
        if (!wp0_range_seen)
            fail("WP0 never matched the condition-failed opcode");
        if (!first_halt)
            fail("WP0 did not enter debug");
        if (u_dut.u_core.de_q.pc !== 32'h0000_0028)
            fail($sformatf("WP0 halted at pc %08x", u_dut.u_core.de_q.pc));
        if (u_dut.u_core.condition_pass !== 1'b0)
            fail("WP0 instruction was not condition-failed");
        if (u_dut.u_core.u_regfile.regs[1] !== 32'h0)
            fail("condition-failed breakpoint instruction changed r1");
        if (u_dut.u_core.u_regfile.regs[2] !== 32'h0)
            fail("instruction following WP0 executed before halt");

        // Disable only WP0, then resume the stopped condition-failed
        // instruction. WP1 must subsequently stop the ADD at 0x30.
        write_ice(5'h0C, 32'h0000_0014);
        load_ir(4'(IR_RESTART));
        second_halt = 1'b0;
        for (int i = 0; i < 160; i++) begin
            @(posedge CLK);
            if (DBGRNG[1])
                wp1_range_seen = 1'b1;
            if (DBGACK) begin
                #1;
                if (u_dut.u_core.de_q.pc == 32'h0000_0030)
                    second_halt = 1'b1;
                break;
            end
        end
        if (!wp1_range_seen)
            fail("WP1 never matched after WP0 restart");
        if (!second_halt)
            fail($sformatf("WP0 restart retriggered or halted at pc %08x",
                           u_dut.u_core.de_q.pc));
        if (u_dut.u_core.u_regfile.regs[1] !== 32'h0)
            fail("condition-failed WP0 instruction executed after restart");
        if (u_dut.u_core.u_regfile.regs[2] !== 32'h22)
            fail("instruction between breakpoints did not execute");
        if (u_dut.u_core.u_regfile.regs[3] !== 32'h0)
            fail("WP1 ADD executed before halt");
        if (u_dut.u_core.u_regfile.regs[4] !== 32'h0)
            fail("instruction following WP1 executed before halt");

        // Disable WP1 and resume. The stopped ADD must execute once.
        select_chain2();
        write_ice(5'h14, 32'h0000_0014);
        load_ir(4'(IR_RESTART));
        completed = 1'b0;
        for (int i = 0; i < 120; i++) begin
            @(posedge CLK);
            if (u_dut.u_core.u_regfile.regs[4] == 32'h44) begin
                completed = 1'b1;
                break;
            end
        end
        if (!completed)
            fail("WP1 restart did not reach the completion marker");
        if (u_dut.u_core.u_regfile.regs[3] !== 32'h1)
            fail($sformatf("stopped ADD executed %0d times",
                           u_dut.u_core.u_regfile.regs[3]));

        repeat (12) @(posedge CLK);
        if (u_dut.u_core.u_regfile.regs[3] !== 32'h1)
            fail("stopped ADD repeated after normal execution resumed");

        if (errors != 0)
            $fatal(1, "[debug_breakpoint_execute] FAIL (%0d errors)", errors);
        $display("[debug_breakpoint_execute] PASS");
        $finish;
    end

    initial begin
        repeat (CYCLE_LIMIT) @(posedge CLK);
        $fatal(1, "[debug_breakpoint_execute] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, ADDR, WRITE, SIZE, PROT, LOCK, TRANS, WDATA,
        CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI, DBGnEXEC,
        DBGINSTRVALID, DBGCOMMTX, DBGCOMMRX, DBGnTDOEN, DMORE,
        ignored_scan};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
