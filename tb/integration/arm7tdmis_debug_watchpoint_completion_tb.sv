// DBG-004 end-to-end watchpoint completion regression.
//
// A scan-chain-2 programmed WP0 matches the second data beat of:
//     LDMIA r0!, {r1-r4}
// TRM §5.3.2 requires the whole current instruction to complete before
// halt: every destination and base writeback must be committed. The next
// MOV must remain pending until the debugger issues RESTART.

`timescale 1ns/1ps

module arm7tdmis_debug_watchpoint_completion_tb
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_debug_pkg::*;
    import arm7tdmis_jtag_tb_pkg::*;
;

    localparam int CYCLE_LIMIT = 1800;
    localparam logic [31:0] WATCHED_INSTR_PC = 32'h0000_0024;
    localparam logic [31:0] DEBUG_STM_PC = 32'hE880_8000;
    localparam logic [31:0] DEBUG_NOP = 32'hE1A0_8008;

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
        .WORDS    (256),
        .INIT_HEX ("../tb/programs/debug_watchpoint_completion_test.hex")
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
        tck(1'b1, 1'b0); // RTI -> Select-DR
        tck(1'b1, 1'b0); // Select-DR -> Select-IR
        tck(1'b0, 1'b0); // Select-IR -> Capture-IR
        tck(1'b0, 1'b0); // Capture-IR -> Shift-IR
        for (int i = 0; i < 4; i++)
            tck(i == 3, instruction[i]);
        tck(1'b1, 1'b0); // Exit1-IR -> Update-IR
        tck(1'b0, 1'b0); // Update-IR -> RTI
    endtask

    task automatic shift_dr(
        input int unsigned width,
        input logic [37:0] scan_in
    );
        tck(1'b1, 1'b0); // RTI -> Select-DR
        tck(1'b0, 1'b0); // Select-DR -> Capture-DR
        tck(1'b0, 1'b0); // Capture-DR -> Shift-DR
        for (int i = 0; i < width; i++) begin
            ignored_scan[i] = DBGTDO;
            tck(i == (width - 1), scan_in[i]);
        end
        tck(1'b1, 1'b0); // Exit1-DR -> Update-DR
        tck(1'b0, 1'b0); // Update-DR -> RTI
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

    task automatic select_chain2;
        load_ir(4'(IR_SCAN_N));
        shift_dr(4, 38'd2);
        load_ir(4'(IR_INTEST));
    endtask

    task automatic select_chain1;
        load_ir(4'(IR_SCAN_N));
        shift_dr(4, 38'd1);
        load_ir(4'(IR_INTEST));
    endtask

    task automatic write_ice(
        input logic [4:0] addr,
        input logic [31:0] data
    );
        shift_dr(38, chain2_serial_in(1'b1, addr, data));
    endtask

    int unsigned errors = 0;
    bit range_seen;
    bit halted;
    bit resumed;

    task automatic check_reg(
        input int unsigned index,
        input logic [31:0] expected,
        input string description
    );
        if (u_dut.u_core.u_regfile.regs[index] !== expected) begin
            $display("[debug_watchpoint_completion] FAIL %s r%0d expected %08x got %08x",
                     description, index, expected,
                     u_dut.u_core.u_regfile.regs[index]);
            errors = errors + 1;
        end
    endtask

    initial begin : run_test
        logic [37:0] captured;
        logic [31:0] scanned_r15;
        logic [31:0] corrected_pc;

        $dumpfile("debug_watchpoint_completion.fst");
        $dumpvars(0, arm7tdmis_debug_watchpoint_completion_tb);

        // Data consumed by the four LDM beats.
        u_mem.mem[64] = 32'h1111_1111;
        u_mem.mem[65] = 32'h2222_2222;
        u_mem.mem[66] = 32'h3333_3333;
        u_mem.mem[67] = 32'h4444_4444;

        repeat (2) @(posedge CLK);
        DBGnTRST = 1'b1;
        tck(1'b0, 1'b0); // TLR -> RTI
        select_chain2();

        // Exact address 0x104; ignore data; exact privileged data-word read.
        write_ice(5'h08, 32'h0000_0104);
        write_ice(5'h09, 32'h0000_0000);
        write_ice(5'h0A, 32'h0000_0000);
        write_ice(5'h0B, 32'hFFFF_FFFF);
        write_ice(5'h0C, 32'h0000_011C);
        write_ice(5'h0D, 32'h0000_00E0);

        CLKEN = 1'b1;
        range_seen = 1'b0;
        halted = 1'b0;
        for (int i = 0; i < 240; i++) begin
            @(posedge CLK);
            if (DBGRNG[0])
                range_seen = 1'b1;
            if (DBGACK) begin
                halted = 1'b1;
                break;
            end
        end

        if (!range_seen) begin
            $display("[debug_watchpoint_completion] FAIL watchpoint never matched");
            errors = errors + 1;
        end
        if (!halted) begin
            $display("[debug_watchpoint_completion] FAIL core never entered debug");
            errors = errors + 1;
        end

        // These checks occur at the first observed DBGACK edge.
        check_reg(0, 32'h0000_0110, "LDM base writeback before halt");
        check_reg(1, 32'h1111_1111, "LDM beat 0 before halt");
        check_reg(2, 32'h2222_2222, "watchpointed beat before halt");
        check_reg(3, 32'h3333_3333, "post-watchpoint beat 2 before halt");
        check_reg(4, 32'h4444_4444, "post-watchpoint beat 3 before halt");
        check_reg(9, 32'h0000_0000, "following instruction blocked by halt");
        if (TRANS !== 2'(TRANS_I)) begin
            $display("[debug_watchpoint_completion] FAIL halted TRANS=%02b", TRANS);
            errors = errors + 1;
        end

        // OpenOCD arm7tdmi_read_core_regs() for r15. Its common
        // three-word STM correction plus normal watchpoint correction
        // must recover the LDM's own address, even though the full LDM
        // has completed architecturally.
        select_chain1();
        shift_dr(SCAN_CHAIN1_WIDTH,
                 chain1_serial_in(DEBUG_STM_PC, 1'b0));
        shift_dr(SCAN_CHAIN1_WIDTH,
                 chain1_serial_in(DEBUG_NOP, 1'b0));
        shift_dr(SCAN_CHAIN1_WIDTH,
                 chain1_serial_in(DEBUG_NOP, 1'b0));
        shift_dr_capture(
            SCAN_CHAIN1_WIDTH,
            chain1_serial_in(32'h0, 1'b0),
            captured);
        scanned_r15 = chain1_parallel_data(captured);
        corrected_pc = scanned_r15 - 32'd12 - 32'd12;
        if (corrected_pc !== WATCHED_INSTR_PC) begin
            $display("[debug_watchpoint_completion] FAIL corrected PC expected %08x got %08x (scanned %08x)",
                     WATCHED_INSTR_PC, corrected_pc, scanned_r15);
            errors = errors + 1;
        end

        // RESTART is committed at Update-IR and must resume at the following
        // instruction exactly once.
        load_ir(4'(IR_RESTART));
        resumed = 1'b0;
        for (int i = 0; i < 120; i++) begin
            @(posedge CLK);
            if (u_dut.u_core.u_regfile.regs[9] == 32'h0000_0099) begin
                resumed = 1'b1;
                break;
            end
        end
        if (!resumed) begin
            $display("[debug_watchpoint_completion] FAIL RESTART did not execute following instruction");
            errors = errors + 1;
        end

        if (errors != 0)
            $fatal(1, "[debug_watchpoint_completion] FAIL (%0d errors)", errors);
        $display("[debug_watchpoint_completion] PASS");
        $finish;
    end

    initial begin
        repeat (CYCLE_LIMIT) @(posedge CLK);
        $fatal(1, "[debug_watchpoint_completion] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, ADDR, WRITE, SIZE, PROT, LOCK, WDATA, CPnMREQ,
        CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI, DBGnEXEC, DBGINSTRVALID,
        DBGRNG[1], DBGCOMMTX, DBGCOMMRX, DBGnTDOEN, DMORE, ignored_scan};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
