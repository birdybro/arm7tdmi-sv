// ERR-001 / ARM7TDMI-S erratum [6] Prefetch Abort sequence regression.
//
// The official conditions have two opcode-abort cases:
//   * a watched load followed immediately by a Prefetch Abort;
//   * a watched store whose second following instruction Prefetch Aborts.
//
// Debug entry for the completed watchpoint must occur first.  After WP0 is
// disabled and RESTART is scanned, the buffered aborted fetch must take the
// Prefetch Abort with its original instruction PC and corrected link value.
// Final-cycle watched-load IRQ/FIQ cases live in debug_watchpoint_priority.

`timescale 1ns/1ps

/* verilator lint_off DECLFILENAME */
module arm7tdmis_debug_watchpoint_pabt_sequence_scenario #(
    parameter bit WATCH_STORE = 1'b0
) (
    input  logic CLK,
    output logic done,
    output logic failed
);
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_types_pkg::*;
    import arm7tdmis_debug_pkg::*;
    import arm7tdmis_jtag_tb_pkg::*;

    localparam logic [31:0] WATCH_ADDR = 32'h0000_0100;
    localparam logic [31:0] PABT_PC = WATCH_STORE
                                               ? 32'h0000_0030
                                               : 32'h0000_002C;

    logic nRESET = 1'b0;
    logic CLKEN = 1'b0;
    logic DBGTCKEN = 1'b0;
    logic DBGTMS = 1'b1;
    logic DBGTDI = 1'b0;
    logic DBGnTRST = 1'b0;

    logic [31:0] ADDR, WDATA, RDATA;
    logic WRITE, LOCK, ABORT;
    logic [1:0] SIZE, PROT, TRANS;
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

    logic inject_abort;
    arm7tdmis_memory #(
        .WORDS (128)
    ) u_mem (
        .CLK,
        .CLKEN,
        .nRESET,
        .CFGBIGEND        (1'b0),
        .ADDR, .WRITE, .SIZE, .PROT, .LOCK, .TRANS, .WDATA, .RDATA,
        .ABORT,
        .inject_abort
    );

    assign inject_abort = u_mem.is_active_q
                       && !u_mem.write_q
                       && (u_mem.addr_q == PABT_PC);

    initial begin : initialize_program
        for (int i = 0; i < 128; i++)
            u_mem.mem[i] = 32'hE1A0_0000;
        u_mem.mem[0] = 32'hEA00_0006; // Reset: B 0x20
        u_mem.mem[3] = 32'hEA00_001B; // PABT: B 0x80

        u_mem.mem[8]  = 32'hE3A0_0C01; // MOV r0,#0x100
        u_mem.mem[9]  = 32'hE3A0_1055; // MOV r1,#0x55
        u_mem.mem[10] = WATCH_STORE
                      ? 32'hE580_1000   // STR r1,[r0]
                      : 32'hE590_2000;  // LDR r2,[r0]
        u_mem.mem[11] = 32'hE3A0_3033; // first following instruction
        u_mem.mem[12] = 32'hE3A0_4044; // second following instruction
        u_mem.mem[13] = 32'hEAFF_FFFE;

        u_mem.mem[32] = 32'hE3A0_7066; // PABT handler marker
        u_mem.mem[33] = 32'hEAFF_FFFE;
        u_mem.mem[64] = 32'hCAFE_BABE;
    end

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
        input logic [4:0] address,
        input logic [31:0] data
    );
        shift_dr(38, chain2_serial_in(1'b1, address, data));
    endtask

    bit range_seen;
    bit abort_seen;
    bit pabt_before_halt;
    bit pabt_after_restart;
    bit restarted;
    always_ff @(posedge CLK) begin
        if (!nRESET) begin
            range_seen        <= 1'b0;
            abort_seen        <= 1'b0;
            pabt_before_halt   <= 1'b0;
            pabt_after_restart <= 1'b0;
        end else begin
            if (DBGRNG[0])
                range_seen <= 1'b1;
            if (ABORT)
                abort_seen <= 1'b1;
            if (u_dut.u_core.pabt_fires) begin
                if (restarted)
                    pabt_after_restart <= 1'b1;
                else
                    pabt_before_halt <= 1'b1;
            end
        end
    end

    int unsigned errors;
    string scenario_name;
    task automatic fail(input string description);
        $display("[debug_watchpoint_pabt_sequence/%s] FAIL %s",
                 scenario_name, description);
        errors++;
    endtask

    initial begin : run_test
        bit halted;
        bit handler_seen;

        done   = 1'b0;
        failed = 1'b0;
        errors = 0;
        restarted = 1'b0;
        scenario_name = WATCH_STORE ? "store-second" : "load-next";

        repeat (4) @(posedge CLK);
        nRESET = 1'b1;
        repeat (2) @(posedge CLK);
        DBGnTRST = 1'b1;
        tck(1'b0, 1'b0);
        select_chain2();

        write_ice(5'h08, WATCH_ADDR);
        write_ice(5'h09, 32'h0000_0000);
        write_ice(5'h0A, 32'h0000_0000);
        write_ice(5'h0B, 32'hFFFF_FFFF);
        write_ice(5'h0C, WATCH_STORE ? 32'h0000_011D
                                     : 32'h0000_011C);
        write_ice(5'h0D, 32'h0000_00E0);

        CLKEN = 1'b1;
        halted = 1'b0;
        for (int i = 0; i < 260; i++) begin
            @(posedge CLK);
            #1;
            if (DBGACK) begin
                halted = 1'b1;
                break;
            end
        end

        if (!halted)
            fail("watchpoint did not enter debug");
        if (!range_seen)
            fail("watchpoint comparator never matched");
        if (!u_dut.u_ice.entry_watchpoint_q)
            fail("debug entry did not retain watchpoint cause");
        if (pabt_before_halt)
            fail("Prefetch Abort was taken before watchpoint debug entry");
        if (u_dut.u_core.cpsr.m !== 5'(MODE_SUPERVISOR))
            fail("watchpoint halt entered exception mode prematurely");
        if (u_dut.u_core.u_regfile.regs[3] !== 32'h0
            || u_dut.u_core.u_regfile.regs[4] !== 32'h0)
            fail("instruction after watched access retired before halt");
        if (WATCH_STORE) begin
            if (u_mem.mem[64] !== 32'h0000_0055)
                fail("watched store did not complete");
        end else if (u_dut.u_core.u_regfile.regs[2]
                     !== 32'hCAFE_BABE) begin
            fail("watched load did not complete");
        end

        write_ice(5'h0C, WATCH_STORE ? 32'h0000_001D
                                     : 32'h0000_001C);
        restarted = 1'b1;
        load_ir(4'(IR_RESTART));

        handler_seen = 1'b0;
        for (int i = 0; i < 220; i++) begin
            @(posedge CLK);
            if (u_dut.u_core.u_regfile.regs[7] == 32'h66) begin
                handler_seen = 1'b1;
                break;
            end
        end
        if (!abort_seen || !pabt_after_restart || !handler_seen)
            fail($sformatf("abort/pabt/handler=%0b/%0b/%0b",
                           abort_seen, pabt_after_restart, handler_seen));
        if (u_dut.u_core.u_regfile.regs[28]
            !== (PABT_PC + 32'd4))
            fail($sformatf("r14_abt expected %08x got %08x",
                           PABT_PC + 32'd4,
                           u_dut.u_core.u_regfile.regs[28]));
        if (u_dut.u_core.cpsr.m !== 5'(MODE_ABORT))
            fail("RESTART did not enter Abort mode");
        if (WATCH_STORE) begin
            if (u_dut.u_core.u_regfile.regs[3] !== 32'h33)
                fail("first store successor did not execute before PABT");
            if (u_dut.u_core.u_regfile.regs[4] !== 32'h0)
                fail("aborted second store successor executed");
        end else if (u_dut.u_core.u_regfile.regs[3] !== 32'h0) begin
            fail("aborted load successor executed");
        end

        failed = (errors != 0);
        done   = 1'b1;
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, WRITE, SIZE, PROT, LOCK, TRANS, WDATA, CPnMREQ,
        CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI, DBGnEXEC, DBGINSTRVALID,
        DBGRNG[1], DBGCOMMTX, DBGCOMMRX, DBGnTDOEN, DMORE, ignored_scan};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
/* verilator lint_on DECLFILENAME */

module arm7tdmis_debug_watchpoint_pabt_sequence_tb;
    logic CLK;
    logic [1:0] done;
    logic [1:0] failed;

    initial begin
        CLK = 1'b0;
        forever #5 CLK = ~CLK;
    end

    arm7tdmis_debug_watchpoint_pabt_sequence_scenario #(
        .WATCH_STORE (1'b0)
    ) u_load (.CLK, .done(done[0]), .failed(failed[0]));

    arm7tdmis_debug_watchpoint_pabt_sequence_scenario #(
        .WATCH_STORE (1'b1)
    ) u_store (.CLK, .done(done[1]), .failed(failed[1]));

    initial begin
        $dumpfile("debug_watchpoint_pabt_sequence.fst");
        $dumpvars(0, arm7tdmis_debug_watchpoint_pabt_sequence_tb);
        wait (&done);
        if (|failed)
            $fatal(1, "[debug_watchpoint_pabt_sequence] FAIL scenarios=%02b",
                   failed);
        $display("[debug_watchpoint_pabt_sequence] PASS");
        $finish;
    end

    initial begin
        repeat (1800) @(posedge CLK);
        $fatal(1, "[debug_watchpoint_pabt_sequence] TIMEOUT");
    end
endmodule
