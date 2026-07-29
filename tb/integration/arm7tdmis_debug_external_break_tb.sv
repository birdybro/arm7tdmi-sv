// DBG-001/DBG-004 synchronous external DBGBREAK regression.
//
// ARM7TDMI-S samples DBGBREAK on the same rising CLK edge as the memory
// access it marks (TRM §5.3 and §8.1.4). A one-cycle pulse on an opcode
// fetch must travel with that instruction to Execute. A one-cycle pulse on
// the final data beat of an LDM must remain a data watchpoint and halt only
// after every destination and base writeback completes. Delaying either
// pulse through a blanket synchronizer detaches it from the marked access.

`timescale 1ns/1ps

module arm7tdmis_debug_external_break_tb
    import arm7tdmis_debug_pkg::*;
    import arm7tdmis_jtag_tb_pkg::*;
;

    localparam int CYCLE_LIMIT = 1800;
    localparam logic [31:0] BREAKPOINT_PC = 32'h0000_0024;
    localparam logic [31:0] FINAL_LDM_BEAT = 32'h0000_010C;
    localparam logic [31:0] DEBUG_NOP = 32'hE1A0_0000;

    logic CLK = 1'b0;
    initial forever #5 CLK = ~CLK;

    logic nRESET = 1'b0;
    logic CLKEN = 1'b0;
    logic DBGBREAK = 1'b0;
    logic DBGTCKEN = 1'b0;
    logic DBGTMS = 1'b1;
    logic DBGTDI = 1'b0;
    logic DBGnTRST = 1'b0;

    logic [31:0] ADDR, WDATA, RDATA;
    logic WRITE;
    logic [1:0] SIZE, PROT, TRANS;
    logic LOCK, ABORT;
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
        .DBGBREAK,
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
        .INIT_HEX ("../tb/programs/debug_external_break_test.hex")
    ) u_mem (
        .CLK,
        .CLKEN,
        .nRESET,
        .CFGBIGEND        (1'b0),
        .ADDR, .WRITE, .SIZE, .PROT, .LOCK, .TRANS, .WDATA, .RDATA,
        .ABORT,
        .inject_abort     (1'b0)
    );

    int unsigned errors = 0;

    task automatic fail(input string description);
        $display("[debug_external_break] FAIL %s", description);
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

    task automatic shift_dr_capture(
        input  int unsigned width,
        input  logic [37:0] scan_in,
        output logic [37:0] scan_out
    );
        scan_out = '0;
        tck(1'b1, 1'b0);
        tck(1'b0, 1'b0);
        tck(1'b0, 1'b0);
        for (int i = 0; i < width; i++) begin
            scan_out[i] = DBGTDO;
            tck(i == (width - 1), scan_in[i]);
        end
        tck(1'b1, 1'b0);
        tck(1'b0, 1'b0);
    endtask

    task automatic select_chain1;
        logic [37:0] ignored;
        load_ir(4'(IR_SCAN_N));
        shift_dr_capture(4, 38'd1, ignored);
        if (&{1'b0, ignored})
            fail("unreachable SCAN_N sentinel");
        load_ir(4'(IR_INTEST));
    endtask

    task automatic capture_entry_cause(output logic watchpoint_cause);
        logic [37:0] captured;
        select_chain1();
        shift_dr_capture(
            SCAN_CHAIN1_WIDTH,
            chain1_serial_in(DEBUG_NOP, 1'b0),
            captured);
        watchpoint_cause = captured[0];
        if (&{1'b0, captured[37:1]})
            fail("unreachable chain-1 sentinel");
        for (int i = 0; i < 80; i++) begin
            @(posedge CLK);
            #1;
            if (!u_dut.u_ice.dbg_inject_active)
                return;
        end
        fail("entry-cause capture instruction did not retire");
    endtask

    task automatic pulse_break_on_access(
        input logic [31:0] address,
        input logic        data_access,
        input string       description
    );
        for (int i = 0; i < 240; i++) begin
            @(negedge CLK);
            if (TRANS[1] && (ADDR == address)
                && (PROT[0] == data_access)) begin
                DBGBREAK = 1'b1;
                @(negedge CLK);
                DBGBREAK = 1'b0;
                return;
            end
        end
        fail(description);
    endtask

    task automatic wait_for_halt(input string description);
        for (int i = 0; i < 160; i++) begin
            @(posedge CLK);
            #1;
            if (DBGACK)
                return;
        end
        fail(description);
    endtask

    task automatic check_reg(
        input int unsigned index,
        input logic [31:0] expected,
        input string description
    );
        if (u_dut.u_core.u_regfile.regs[index] !== expected)
            fail($sformatf("%s r%0d expected %08x got %08x",
                           description, index, expected,
                           u_dut.u_core.u_regfile.regs[index]));
    endtask

    initial begin : run_test
        logic entry_cause;

        $dumpfile("debug_external_break.fst");
        $dumpvars(0, arm7tdmis_debug_external_break_tb);

        u_mem.mem[64] = 32'h1111_1111;
        u_mem.mem[65] = 32'h2222_2222;
        u_mem.mem[66] = 32'h3333_3333;
        u_mem.mem[67] = 32'h4444_4444;

        repeat (4) @(posedge CLK);
        nRESET = 1'b1;
        repeat (2) @(posedge CLK);
        DBGnTRST = 1'b1;
        tck(1'b0, 1'b0);
        CLKEN = 1'b1;

        pulse_break_on_access(
            BREAKPOINT_PC, 1'b0,
            "target opcode fetch was not observed");
        wait_for_halt("one-cycle opcode DBGBREAK did not halt");
        check_reg(5, 32'h0, "breakpoint instruction executed before halt");
        check_reg(6, 32'h0, "post-breakpoint instruction executed before halt");
        if (u_dut.u_core.de_q.pc !== BREAKPOINT_PC)
            fail($sformatf("opcode pulse halted at pc %08x",
                           u_dut.u_core.de_q.pc));
        capture_entry_cause(entry_cause);
        if (entry_cause !== 1'b0)
            fail("opcode pulse reported a watchpoint entry cause");

        load_ir(4'(IR_RESTART));

        pulse_break_on_access(
            FINAL_LDM_BEAT, 1'b1,
            "final LDM data beat was not observed after restart");
        wait_for_halt("one-cycle data DBGBREAK did not halt");
        check_reg(5, 32'h1, "restarted breakpoint instruction count");
        check_reg(6, 32'h66, "post-breakpoint marker");
        check_reg(0, 32'h110, "LDM base writeback before watchpoint halt");
        check_reg(1, 32'h1111_1111, "LDM beat 0");
        check_reg(2, 32'h2222_2222, "LDM beat 1");
        check_reg(3, 32'h3333_3333, "LDM beat 2");
        check_reg(4, 32'h4444_4444, "watched final LDM beat");
        check_reg(9, 32'h0, "instruction after watched LDM retired");
        capture_entry_cause(entry_cause);
        if (entry_cause !== 1'b1)
            fail("data pulse did not report a watchpoint entry cause");

        if (errors != 0)
            $fatal(1, "[debug_external_break] FAIL (%0d errors)", errors);
        $display("[debug_external_break] PASS");
        $finish;
    end

    initial begin
        repeat (CYCLE_LIMIT) @(posedge CLK);
        $fatal(1, "[debug_external_break] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, WRITE, SIZE, LOCK, WDATA, CPnMREQ, CPSEQ,
        CPnTRANS, CPnOPC, CPTBIT, CPnI, DBGnEXEC, DBGINSTRVALID, DBGRNG,
        DBGCOMMTX, DBGCOMMRX, DBGnTDOEN, DMORE};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
