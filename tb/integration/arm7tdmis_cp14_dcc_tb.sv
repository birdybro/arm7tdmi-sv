// CP-007/008/010 integration regression for the ARM7TDMI-S r4p3 Debug
// Communications Channel.
//
// The processor checks c0 control, sends one word through the c1 TX register,
// waits for the debugger to consume it through JTAG chain 2, waits for a host
// RX word, then consumes that through c1.  The test observes the documented
// W/R ownership transitions at both CP14 and the external DBGCOMM pins.

`timescale 1ns/1ps

module arm7tdmis_cp14_dcc_tb
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_debug_pkg::*;
    import arm7tdmis_jtag_tb_pkg::*;
;

    localparam int    CLK_HALF_PERIOD = 5;
    localparam int    RESET_CYCLES    = 4;
    localparam int    CYCLE_LIMIT     = 1200;
    localparam string INIT_HEX        = "../tb/programs/cp14_dcc_test.hex";
    localparam logic [31:0] CPU_TX_DATA  = 32'hA5000000;
    localparam logic [31:0] HOST_RX_DATA = 32'h5AA55AA5;
    localparam logic [31:0] DCC_IDLE_CTRL = 32'h70000000;

    logic CLK;
    initial begin
        CLK = 1'b0;
        forever #(CLK_HALF_PERIOD) CLK = ~CLK;
    end

    logic nRESET;
    initial begin
        nRESET = 1'b0;
        repeat (RESET_CYCLES) @(posedge CLK);
        nRESET = 1'b1;
    end

    logic CFGBIGEND = 1'b0;
    logic CLKEN     = 1'b0;
    logic nIRQ      = 1'b1;
    logic nFIQ      = 1'b1;
    logic ABORT;

    logic       DBGEN    = 1'b1;
    logic       DBGRQ    = 1'b0;
    logic       DBGBREAK = 1'b0;
    logic [1:0] DBGEXT   = 2'b00;
    logic       DBGTCKEN = 1'b0;
    logic       DBGTMS   = 1'b1;
    logic       DBGTDI   = 1'b0;
    logic       DBGnTRST = 1'b0;

    logic [31:0] ADDR;
    logic        WRITE;
    logic [1:0]  SIZE;
    logic [1:0]  PROT;
    logic        LOCK;
    logic [1:0]  TRANS;
    logic [31:0] WDATA;
    logic [31:0] RDATA;

    logic CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI;
    logic DBGACK, DBGnEXEC, DBGINSTRVALID;
    logic [1:0] DBGRNG;
    logic DBGCOMMTX, DBGCOMMRX;
    logic DBGTDO, DBGnTDOEN, DMORE;
    logic [37:0] scan_ignored;
    logic [37:0] captured;
    logic [37:0] tx_response;
    logic [37:0] empty_tx_response;
    logic [37:0] control_response;

    arm7tdmis_top u_dut (
        .CLK, .CLKEN, .nRESET, .CFGBIGEND, .nIRQ, .nFIQ, .ABORT,
        .ADDR, .WRITE, .SIZE, .PROT, .LOCK, .TRANS, .WDATA, .RDATA,
        .CPnMREQ, .CPSEQ, .CPnTRANS, .CPnOPC, .CPTBIT, .CPnI,
        .CPA(1'b1), .CPB(1'b1),
        .DBGEN, .DBGRQ, .DBGBREAK, .DBGACK, .DBGnEXEC, .DBGINSTRVALID,
        .DBGEXT, .DBGRNG, .DBGCOMMTX, .DBGCOMMRX,
        .DBGTCKEN, .DBGTMS, .DBGTDI, .DBGTDO, .DBGnTRST, .DBGnTDOEN,
        .DMORE
    );

    logic mem_inject_abort = 1'b0;
    arm7tdmis_memory #(
        .WORDS    (4096),
        .INIT_HEX (INIT_HEX)
    ) u_mem (
        .CLK, .CLKEN, .nRESET, .CFGBIGEND,
        .ADDR, .WRITE, .SIZE, .PROT, .LOCK, .TRANS, .WDATA, .RDATA,
        .ABORT, .inject_abort(mem_inject_abort)
    );

    int unsigned errors = 0;

    task automatic tck(input logic tms, input logic tdi);
        @(negedge CLK);
        DBGTMS   = tms;
        DBGTDI   = tdi;
        DBGTCKEN = 1'b1;
        @(posedge CLK);
        #1;
        DBGTCKEN = 1'b0;
    endtask

    // All public TAP transfers start and finish in Run-Test/Idle.
    task automatic load_ir(input logic [3:0] instruction);
        tck(1'b1, 1'b0); // RTI -> Select-DR
        tck(1'b1, 1'b0); // Select-DR -> Select-IR
        tck(1'b0, 1'b0); // Select-IR -> Capture-IR
        tck(1'b0, 1'b0); // Capture-IR -> Shift-IR
        for (int i = 0; i < 4; i++) begin
            tck(i == 3, instruction[i]);
        end
        tck(1'b1, 1'b0); // Exit1-IR -> Update-IR
        tck(1'b0, 1'b0); // Update-IR -> RTI, commit
    endtask

    task automatic shift_dr(
        input  int unsigned width,
        input  logic [37:0] scan_in,
        output logic [37:0] scan_out
    );
        scan_out = '0;
        tck(1'b1, 1'b0); // RTI -> Select-DR
        tck(1'b0, 1'b0); // Select-DR -> Capture-DR
        tck(1'b0, 1'b0); // Capture-DR -> Shift-DR
        for (int i = 0; i < width; i++) begin
            scan_out[i] = DBGTDO;
            tck(i == (width - 1), scan_in[i]);
        end
        tck(1'b1, 1'b0); // Exit1-DR -> Update-DR
        tck(1'b0, 1'b0); // Update-DR -> RTI, commit
    endtask

    task automatic select_chain2;
        load_ir(4'(IR_SCAN_N));
        shift_dr(4, 38'd2, scan_ignored);
        load_ir(4'(IR_INTEST));
    endtask

    task automatic chain2_request(
        input  logic        write,
        input  logic [4:0]  addr,
        input  logic [31:0] data,
        output logic [37:0] scan_result
    );
        logic [37:0] serial_result;
        shift_dr(38, chain2_serial_in(write, addr, data),
                 serial_result);
        scan_result = chain2_parallel_out(serial_result);
    endtask

    task automatic await_pin(
        input logic expected,
        input bit select_rx,
        input string description
    );
        bit matched;
        matched = 1'b0;
        for (int i = 0; i < 160; i++) begin
            @(posedge CLK);
            if ((select_rx ? DBGCOMMRX : DBGCOMMTX) === expected) begin
                matched = 1'b1;
                break;
            end
        end
        if (!matched) begin
            $display("[cp14_dcc] FAIL timeout waiting for %s", description);
            errors = errors + 1;
        end
    endtask

    task automatic check_reg(
        input int unsigned idx,
        input logic [31:0] expected,
        input string description
    );
        if (u_dut.u_core.u_regfile.regs[idx] !== expected) begin
            $display("[cp14_dcc] FAIL %s: r%0d expected %08x got %08x",
                     description, idx, expected,
                     u_dut.u_core.u_regfile.regs[idx]);
            errors = errors + 1;
        end
    endtask

    initial begin : run_test
        $dumpfile("cp14_dcc.fst");
        $dumpvars(0, arm7tdmis_cp14_dcc_tb);

        // Reset the TAP, enter RTI, and configure scan chain 2 while the CPU
        // is held by CLKEN. DBGnTRST resets only debug/JTAG state.
        repeat (2) @(posedge CLK);
        DBGnTRST = 1'b1;
        tck(1'b0, 1'b0); // TLR -> RTI
        select_chain2();

        if (DBGCOMMTX !== 1'b1 || DBGCOMMRX !== 1'b0) begin
            $display("[cp14_dcc] FAIL reset pins expected TX-empty=1 RX-full=0, got %b/%b",
                     DBGCOMMTX, DBGCOMMRX);
            errors = errors + 1;
        end

        CLKEN = 1'b1;

        // CPU writes c1: TX becomes full (DBGCOMMTX goes LOW).
        await_pin(1'b0, 1'b0, "DBGCOMMTX LOW after CPU TX write");

        // DBGEN gates both externally visible status pins without consuming
        // the pending processor word. Re-enabling debug must expose the
        // unchanged full-TX state immediately.
        DBGEN = 1'b0;
        #1;
        if (DBGCOMMTX !== 1'b0 || DBGCOMMRX !== 1'b0) begin
            $display("[cp14_dcc] FAIL DBGEN=0 did not gate pending-TX pins: %b/%b",
                     DBGCOMMTX, DBGCOMMRX);
            errors = errors + 1;
        end
        DBGEN = 1'b1;
        #1;
        if (DBGCOMMTX !== 1'b0 || DBGCOMMRX !== 1'b0) begin
            $display("[cp14_dcc] FAIL DBGEN restore lost pending-TX state: %b/%b",
                     DBGCOMMTX, DBGCOMMRX);
            errors = errors + 1;
        end

        // Submit a host read of DCC data (0x05). The following access shifts
        // out that response and consumes the pending TX word.
        chain2_request(1'b0, 5'h05, 32'h0, captured);
        chain2_request(1'b0, 5'h04, 32'h0, tx_response);
        if (tx_response[31:0] !== CPU_TX_DATA) begin
            $display("[cp14_dcc] FAIL JTAG TX expected %08x got %08x",
                     CPU_TX_DATA, tx_response[31:0]);
            errors = errors + 1;
        end
        if (tx_response[37:32] !== {1'b0, 5'b00101}) begin
            $display("[cp14_dcc] FAIL full TX response header expected 05, got %02x",
                     tx_response[37:32]);
            errors = errors + 1;
        end
        await_pin(1'b1, 1'b0, "DBGCOMMTX HIGH after host TX read");

        // Rev-4 single-access optimization: with no pending TX, the same
        // data-register read returns W=0 in address bit 0 (0010W).
        chain2_request(1'b0, 5'h05, 32'h0, captured);
        chain2_request(1'b0, 5'h04, 32'h0, empty_tx_response);
        if (empty_tx_response[37:32] !== {1'b0, 5'b00100}) begin
            $display("[cp14_dcc] FAIL empty TX response header expected 04, got %02x",
                     empty_tx_response[37:32]);
            errors = errors + 1;
        end

        // Deposit one debugger-to-processor word while the CPU is stalled so
        // the full-RX pin state can also be checked across DBGEN gating.
        CLKEN = 1'b0;
        chain2_request(1'b1, 5'h05, HOST_RX_DATA, captured);
        await_pin(1'b1, 1'b1, "DBGCOMMRX HIGH after host RX write");
        DBGEN = 1'b0;
        #1;
        if (DBGCOMMTX !== 1'b0 || DBGCOMMRX !== 1'b0) begin
            $display("[cp14_dcc] FAIL DBGEN=0 did not gate pending-RX pins: %b/%b",
                     DBGCOMMTX, DBGCOMMRX);
            errors = errors + 1;
        end
        DBGEN = 1'b1;
        #1;
        if (DBGCOMMTX !== 1'b1 || DBGCOMMRX !== 1'b1) begin
            $display("[cp14_dcc] FAIL DBGEN restore lost pending-RX state: %b/%b",
                     DBGCOMMTX, DBGCOMMRX);
            errors = errors + 1;
        end

        // Releasing the processor lets its polling loop consume the RX word.
        CLKEN = 1'b1;
        await_pin(1'b0, 1'b1, "DBGCOMMRX LOW after CPU RX read");

        // Read control over JTAG after both transfers. A second request
        // clocks the response out, as required by chain 2 pipelining.
        chain2_request(1'b0, 5'h04, 32'h0, captured);
        chain2_request(1'b0, 5'h04, 32'h0, control_response);

        repeat (80) @(posedge CLK);

        check_reg(0, DCC_IDLE_CTRL,       "initial c0 control");
        check_reg(1, CPU_TX_DATA,         "CPU TX source");
        check_reg(2, DCC_IDLE_CTRL | 2,   "W set after CPU write");
        check_reg(3, DCC_IDLE_CTRL,       "W clear after host read");
        check_reg(4, DCC_IDLE_CTRL | 1,   "R set after host write");
        check_reg(5, HOST_RX_DATA,        "CPU received host data");
        check_reg(6, DCC_IDLE_CTRL,       "R clear after CPU read");
        check_reg(7, 32'h00000077,        "program completion");
        check_reg(10, 32'h00000000,       "no Undefined exception");

        if (control_response[31:0] !== DCC_IDLE_CTRL) begin
            $display("[cp14_dcc] FAIL JTAG control expected %08x got %08x",
                     DCC_IDLE_CTRL, control_response[31:0]);
            errors = errors + 1;
        end
        if (control_response[37:32] !== {1'b0, 5'h04}) begin
            $display("[cp14_dcc] FAIL JTAG control header expected 04, got %02x",
                     control_response[37:32]);
            errors = errors + 1;
        end

        if (errors != 0)
            $fatal(1, "[cp14_dcc] FAIL (%0d errors)", errors);
        $display("[cp14_dcc] PASS");
        $finish;
    end

    initial begin
        repeat (CYCLE_LIMIT) @(posedge CLK);
        $fatal(1, "[cp14_dcc] TIMEOUT after %0d cycles", CYCLE_LIMIT);
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI,
        DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG, DBGnTDOEN, DMORE,
        scan_ignored, captured, empty_tx_response[31:0]};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
