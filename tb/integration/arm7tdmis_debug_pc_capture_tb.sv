// DBG-007/JTAG-005 DBGRQ program-counter capture regression.
//
// The program repeatedly executes MOV r0,pc, so the last completed
// instruction's architectural PC value is visible without peeking at an
// internal pipeline register. After DBGRQ, reproduce OpenOCD's STMIA scan
// and correction:
//   corrected_pc = scanned_r15 - (3 * 4) - (2 * 4)
// For ARM7TDMI the result must be the next program address, r0 - 4.

`timescale 1ns/1ps

module arm7tdmis_debug_pc_capture_tb
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_debug_pkg::*;
    import arm7tdmis_jtag_tb_pkg::*;
;

    localparam int CYCLE_LIMIT = 5000;
    localparam logic [31:0] DEBUG_STM_R0_PC = 32'hE880_8001;
    localparam logic [31:0] DEBUG_NOP = 32'hE1A0_8008;

    logic CLK = 1'b0;
    initial forever #5 CLK = ~CLK;

    logic nRESET = 1'b0;
    logic CLKEN = 1'b0;
    logic DBGRQ = 1'b0;
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
        .INIT_HEX ("../tb/programs/debug_pc_capture_test.hex")
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
    int unsigned external_debug_transfers;
    logic monitor_debug_bus = 1'b0;

    always @(posedge CLK) begin
        if (!nRESET)
            external_debug_transfers <= 0;
        else if (monitor_debug_bus && CLKEN
            && ((TRANS == 2'(TRANS_N)) || (TRANS == 2'(TRANS_S))))
            external_debug_transfers <= external_debug_transfers + 1;
    end

    task automatic fail(input string description);
        $display("[debug_pc_capture] FAIL: %s", description);
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

    task automatic select_chain1;
        logic [37:0] ignored;
        load_ir(4'(IR_SCAN_N));
        shift_dr(4, 38'd1, ignored);
        if (&{1'b0, ignored})
            fail("unreachable SCAN_N sentinel");
        load_ir(4'(IR_INTEST));
    endtask

    task automatic clock_out(input logic [31:0] data);
        logic [37:0] ignored;
        shift_dr(SCAN_CHAIN1_WIDTH, chain1_serial_in(data, 1'b0),
                 ignored);
        if (&{1'b0, ignored})
            fail("unreachable clock-out sentinel");
    endtask

    task automatic clock_data_in(output logic [31:0] data);
        logic [37:0] captured;
        shift_dr(SCAN_CHAIN1_WIDTH, chain1_serial_in(32'h0, 1'b0),
                 captured);
        data = chain1_parallel_data(captured);
    endtask

    initial begin : run_test
        logic [31:0] scanned_r0;
        logic [31:0] scanned_r15;
        logic [31:0] corrected_pc;
        logic [31:0] expected_next_pc;

        $dumpfile("debug_pc_capture.fst");
        $dumpvars(0, arm7tdmis_debug_pc_capture_tb);

        repeat (4) @(posedge CLK);
        nRESET = 1'b1;
        repeat (2) @(posedge CLK);
        DBGnTRST = 1'b1;
        CLKEN = 1'b1;

        // Enter the middle of the linear MOV r0,pc sequence before
        // requesting a halt, avoiding reset-fill boundary ambiguity.
        for (int i = 0; i < 80; i++) begin
            @(posedge CLK);
            #1;
            if (u_dut.u_core.u_regfile.regs[0] >= 32'h0000_0040) begin
                DBGRQ = 1'b1;
                break;
            end
        end
        if (!DBGRQ)
            fail("program did not reach DBGRQ trigger point");

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
        monitor_debug_bus = 1'b1;

        // OpenOCD arm7tdmi_read_core_regs(), reduced to r0 and r15.
        clock_out(DEBUG_STM_R0_PC);
        clock_out(DEBUG_NOP);
        clock_out(DEBUG_NOP);
        clock_data_in(scanned_r0);
        clock_data_in(scanned_r15);

        monitor_debug_bus = 1'b0;
        if (external_debug_transfers != 0)
            fail($sformatf(
                "debug-speed STM leaked %0d external accesses",
                external_debug_transfers));

        // MOV r0,pc at address A writes A+8. DBGRQ completes that
        // instruction, so execution must resume at A+4 == r0-4.
        expected_next_pc = scanned_r0 - 32'd4;
        corrected_pc = scanned_r15 - 32'd12 - 32'd8;
        if (corrected_pc !== expected_next_pc)
            fail($sformatf(
                "OpenOCD correction expected next PC %08x, got %08x (scanned r0=%08x r15=%08x)",
                expected_next_pc, corrected_pc, scanned_r0, scanned_r15));

        if (!DBGACK)
            fail("PC capture unexpectedly left debug state");

        if (errors != 0)
            $fatal(1, "[debug_pc_capture] FAIL (%0d errors)", errors);
        $display("[debug_pc_capture] PASS");
        $finish;
    end

    initial begin
        repeat (CYCLE_LIMIT) @(posedge CLK);
        $fatal(1, "[debug_pc_capture] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, ADDR, WDATA, WRITE, SIZE, PROT, LOCK,
        CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI,
        DBGnEXEC, DBGINSTRVALID, DBGRNG, DBGCOMMTX, DBGCOMMRX,
        DBGnTDOEN, DMORE};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
