// ERR-001 / ARM7TDMI-S erratum [4] corrected-behavior regression.
//
// Cover every official sequence:
//   * Undefined, absent/bounced coprocessor, or store Data Abort followed
//     by a breakpoint;
//   * a watched store followed by one ordinary instruction and then a
//     breakpoint.
//
// Exception handlers return to the breakpointed successor.  Each breakpoint
// must stop before its effect and RESTART at the exact instruction.  The
// watched-store row additionally enters debug once for the watchpoint, then
// reaches the second-successor breakpoint after its first RESTART.

`timescale 1ns/1ps

/* verilator lint_off DECLFILENAME */
module arm7tdmis_debug_exception_breakpoint_sequence_scenario #(
    parameter int unsigned SCENARIO = 0
) (
    input  logic CLK,
    output logic done,
    output logic failed
);
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_types_pkg::*;
    import arm7tdmis_debug_pkg::*;
    import arm7tdmis_jtag_tb_pkg::*;

    localparam int unsigned SC_UNDEF       = 0;
    localparam int unsigned SC_COPROC      = 1;
    localparam int unsigned SC_STORE_DABT  = 2;
    localparam int unsigned SC_WATCH_STORE = 3;
    localparam logic [31:0] DATA_ADDR = 32'h0000_0100;
    localparam logic [31:0] TRIGGER_OPCODE =
        (SCENARIO == SC_UNDEF)      ? 32'hE600_0010
      : (SCENARIO == SC_COPROC)     ? 32'hEE00_0700
                                     : 32'hE580_1000;
    localparam logic [31:0] BREAKPOINT_PC =
        (SCENARIO == SC_WATCH_STORE) ? 32'h0000_0038
                                     : 32'h0000_0034;

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

    assign inject_abort = (SCENARIO == SC_STORE_DABT)
                       && u_mem.is_active_q && u_mem.write_q
                       && (u_mem.addr_q == DATA_ADDR);

    initial begin : initialize_program
        for (int i = 0; i < 128; i++)
            u_mem.mem[i] = 32'hE1A0_0000;
        u_mem.mem[0] = 32'hEA00_0006; // Reset: B 0x20
        u_mem.mem[1] = 32'hEA00_001D; // Undef: B 0x80
        u_mem.mem[4] = 32'hEA00_001E; // DABT: B 0x90

        u_mem.mem[8]  = 32'hE3A0_0C01; // MOV r0,#0x100
        u_mem.mem[9]  = 32'hE3A0_1055; // MOV r1,#0x55
        u_mem.mem[10] = 32'hE1A0_0000;
        u_mem.mem[11] = 32'hE1A0_0000;
        u_mem.mem[12] = TRIGGER_OPCODE; // 0x30
        u_mem.mem[13] = 32'hE283_3001;  // 0x34 first successor
        u_mem.mem[14] = 32'hE284_4001;  // 0x38 second successor
        u_mem.mem[15] = 32'hE3A0_6066;  // completion marker
        u_mem.mem[16] = 32'hEAFF_FFFE;

        u_mem.mem[32] = 32'hE1B0_F00E; // Undef: MOVS pc,lr
        u_mem.mem[36] = 32'hE25E_F004; // DABT: SUBS pc,lr,#4
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

    task automatic program_breakpoint;
        write_ice(5'h08, BREAKPOINT_PC);
        write_ice(5'h09, 32'h0000_0003);
        write_ice(5'h0A, 32'h0000_0000);
        write_ice(5'h0B, 32'hFFFF_FFFF);
        write_ice(5'h0C, 32'h0000_0114);
        write_ice(5'h0D, 32'h0000_00E0);
    endtask

    task automatic program_store_watchpoint;
        write_ice(5'h10, DATA_ADDR);
        write_ice(5'h11, 32'h0000_0000);
        write_ice(5'h12, 32'h0000_0000);
        write_ice(5'h13, 32'hFFFF_FFFF);
        write_ice(5'h14, 32'h0000_011D);
        write_ice(5'h15, 32'h0000_00E0);
    endtask

    bit exception_seen;
    bit vector_seen;
    bit breakpoint_seen;
    bit watchpoint_seen;
    always_ff @(posedge CLK) begin
        if (!nRESET) begin
            exception_seen <= 1'b0;
            vector_seen    <= 1'b0;
            breakpoint_seen <= 1'b0;
            watchpoint_seen <= 1'b0;
        end else begin
            if (u_dut.u_core.undef_fires || u_dut.u_core.dabt_fires)
                exception_seen <= 1'b1;
            if (TRANS[1] && !PROT[0]
                && (ADDR == ((SCENARIO == SC_STORE_DABT)
                             ? 32'h0000_0010 : 32'h0000_0004)))
                vector_seen <= 1'b1;
            if (DBGRNG[0])
                breakpoint_seen <= 1'b1;
            if (DBGRNG[1])
                watchpoint_seen <= 1'b1;
        end
    end

    int unsigned errors;
    string scenario_name;
    task automatic fail(input string description);
        $display("[debug_exception_breakpoint_sequence/%s] FAIL %s",
                 scenario_name, description);
        errors++;
    endtask

    task automatic wait_halt(
        input logic [31:0] expected_pc,
        input string description
    );
        bit halted;
        halted = 1'b0;
        for (int i = 0; i < 280; i++) begin
            @(posedge CLK);
            #1;
            if (DBGACK) begin
                halted = 1'b1;
                break;
            end
        end
        if (!halted)
            fail({description, " did not halt"});
        else if (u_dut.u_core.de_q.pc !== expected_pc)
            fail($sformatf("%s halted at %08x expected %08x",
                           description, u_dut.u_core.de_q.pc, expected_pc));
    endtask

    initial begin : run_test
        bit completed;

        done   = 1'b0;
        failed = 1'b0;
        errors = 0;
        scenario_name = (SCENARIO == SC_UNDEF) ? "undefined"
                      : (SCENARIO == SC_COPROC) ? "coprocessor"
                      : (SCENARIO == SC_STORE_DABT) ? "store-dabt"
                                                    : "watched-store";

        repeat (4) @(posedge CLK);
        nRESET = 1'b1;
        repeat (2) @(posedge CLK);
        DBGnTRST = 1'b1;
        tck(1'b0, 1'b0);
        select_chain2();
        program_breakpoint();
        if (SCENARIO == SC_WATCH_STORE)
            program_store_watchpoint();

        CLKEN = 1'b1;

        if (SCENARIO == SC_WATCH_STORE) begin
            // A data watchpoint stops after the completed store boundary;
            // Execute therefore already names the first unretired successor.
            wait_halt(32'h0000_0034, "store watchpoint");
            if (!watchpoint_seen || !u_dut.u_ice.entry_watchpoint_q)
                fail("watched store did not retain watchpoint cause");
            if (u_mem.mem[64] !== 32'h0000_0055)
                fail("watched store did not commit before debug");
            if (u_dut.u_core.u_regfile.regs[3] !== 32'h0
                || u_dut.u_core.u_regfile.regs[4] !== 32'h0)
                fail("successor retired before watchpoint halt");

            write_ice(5'h14, 32'h0000_001D);
            load_ir(4'(IR_RESTART));
            wait_halt(32'h0000_0038, "second-successor breakpoint");
            if (!breakpoint_seen || !u_dut.u_ice.entry_breakpoint)
                fail("second-successor breakpoint cause was lost");
            if (u_dut.u_core.u_regfile.regs[3] !== 32'h1
                || u_dut.u_core.u_regfile.regs[4] !== 32'h0)
                fail("watched-store restart reached the wrong instruction");
        end else begin
            wait_halt(32'h0000_0034, "post-exception breakpoint");
            if (!exception_seen || !vector_seen)
                fail($sformatf("exception/vector=%0b/%0b",
                               exception_seen, vector_seen));
            if (!breakpoint_seen || !u_dut.u_ice.entry_breakpoint)
                fail("post-exception breakpoint cause was lost");
            if (u_dut.u_core.cpsr.m !== 5'(MODE_SUPERVISOR))
                fail("exception handler did not return before breakpoint");
            if (u_dut.u_core.u_regfile.regs[3] !== 32'h0)
                fail("post-exception breakpoint executed before debug");

            if (SCENARIO inside {SC_UNDEF, SC_COPROC}) begin
                if (u_dut.u_core.u_regfile.regs[30]
                    !== 32'h0000_0034)
                    fail("Undefined link did not identify successor");
            end else begin
                if (u_dut.u_core.u_regfile.regs[28]
                    !== 32'h0000_0038)
                    fail("Data Abort link did not identify store");
                if (u_mem.mem[64] !== 32'hCAFE_BABE)
                    fail("aborted store modified memory");
            end
        end

        write_ice(5'h0C, 32'h0000_0014);
        load_ir(4'(IR_RESTART));
        completed = 1'b0;
        for (int i = 0; i < 160; i++) begin
            @(posedge CLK);
            if (u_dut.u_core.u_regfile.regs[6] == 32'h66) begin
                completed = 1'b1;
                break;
            end
        end
        if (!completed)
            fail($sformatf(
                "final RESTART did not complete r3/r4/r6/pc/ack=%08x/%08x/%08x/%08x/%0b",
                u_dut.u_core.u_regfile.regs[3],
                u_dut.u_core.u_regfile.regs[4],
                u_dut.u_core.u_regfile.regs[6],
                u_dut.u_core.de_q.pc, DBGACK));
        if (u_dut.u_core.u_regfile.regs[3] !== 32'h1)
            fail("first successor did not execute exactly once");
        if (u_dut.u_core.u_regfile.regs[4] !== 32'h1)
            fail("second successor did not execute exactly once");

        failed = (errors != 0);
        done   = 1'b1;
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, WRITE, SIZE, LOCK, WDATA, CPnMREQ, CPSEQ,
        CPnTRANS, CPnOPC, CPTBIT, CPnI, DBGnEXEC, DBGINSTRVALID,
        DBGCOMMTX, DBGCOMMRX, DBGnTDOEN, DMORE, ignored_scan};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
/* verilator lint_on DECLFILENAME */

module arm7tdmis_debug_exception_breakpoint_sequence_tb;
    logic CLK;
    logic [3:0] done;
    logic [3:0] failed;

    initial begin
        CLK = 1'b0;
        forever #5 CLK = ~CLK;
    end

    arm7tdmis_debug_exception_breakpoint_sequence_scenario #(
        .SCENARIO (0)
    ) u_undef (.CLK, .done(done[0]), .failed(failed[0]));
    arm7tdmis_debug_exception_breakpoint_sequence_scenario #(
        .SCENARIO (1)
    ) u_coproc (.CLK, .done(done[1]), .failed(failed[1]));
    arm7tdmis_debug_exception_breakpoint_sequence_scenario #(
        .SCENARIO (2)
    ) u_store_dabt (.CLK, .done(done[2]), .failed(failed[2]));
    arm7tdmis_debug_exception_breakpoint_sequence_scenario #(
        .SCENARIO (3)
    ) u_watch_store (.CLK, .done(done[3]), .failed(failed[3]));

    initial begin
        $dumpfile("debug_exception_breakpoint_sequence.fst");
        $dumpvars(0, arm7tdmis_debug_exception_breakpoint_sequence_tb);
        wait (&done);
        if (|failed)
            $fatal(1,
                "[debug_exception_breakpoint_sequence] FAIL scenarios=%04b",
                failed);
        $display("[debug_exception_breakpoint_sequence] PASS");
        $finish;
    end

    initial begin
        repeat (3000) @(posedge CLK);
        $fatal(1, "[debug_exception_breakpoint_sequence] TIMEOUT");
    end
endmodule
