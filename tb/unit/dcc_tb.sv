// CP-007/009 race and reset coverage for the EmbeddedICE-RT DCC and
// CP14 Debug Abort Status register.

`timescale 1ns/1ps

module dcc_tb;

    logic CLK;
    initial begin
        CLK = 1'b0;
        forever #5 CLK = ~CLK;
    end

    logic CLKEN;
    logic DBGnTRST;
    logic core_dcc_we;
    logic core_dcc_re;
    logic [31:0] core_dcc_wdata;
    logic [31:0] core_dcc_control;
    logic [31:0] core_dcc_rdata;
    logic core_dbgabt_we;
    logic core_dbgabt_wdata;
    logic [31:0] core_dbgabt_rdata;
    logic debug_abort_set;
    logic dcc_tx_empty;
    logic dcc_rx_full;
    logic scan_we;
    logic scan_re;
    logic [4:0] scan_addr;
    logic [37:0] scan_wdata;
    logic [31:0] scan_rdata;
    logic [4:0] scan_raddr;

    logic dbg_break_internal;
    logic breakpoint_fetch;
    logic dbg_ack;
    logic ifen;
    logic halt_request;
    logic core_halt;
    logic [1:0] DBGRNG;
    logic dbg_inject_we;
    logic [31:0] dbg_inject_instr;
    logic dbg_inject_active;

    arm7tdmis_ice_rt dut (
        .CLK,
        .CLKEN,
        .DBGnTRST,
        .DBGEN              (1'b0),
        .watch_addr         (32'h0),
        .watch_data         (32'h0),
        .watch_nopc         (1'b0),
        .watch_nrw          (1'b0),
        .watch_size         (2'b00),
        .watch_tbit         (1'b0),
        .watch_extern       (2'b00),
        .watch_priv         (1'b1),
        .core_trans1        (1'b0),
        .core_halt_boundary (1'b1),
        .core_breakpoint_execute(1'b0),
        .dbg_rq_in          (1'b0),
        .dbg_break_in       (1'b0),
        .tap_restart_req    (1'b0),
        .tap_chain1_capture (1'b0),
        .chain1_capture_break(tb_chain1_capture_break),
        .entry_breakpoint   (tb_entry_breakpoint),
        .core_dcc_we,
        .core_dcc_re,
        .core_dcc_wdata,
        .core_dcc_control,
        .core_dcc_rdata,
        .core_dbgabt_we,
        .core_dbgabt_wdata,
        .core_dbgabt_rdata,
        .debug_abort_set,
        .dcc_tx_empty,
        .dcc_rx_full,
        .tap_inject_we      (1'b0),
        .tap_inject_instr   (32'h0),
        .tap_inject_break   (1'b0),
        .core_inject_accept (1'b0),
        .core_inject_retire (1'b0),
        .dbg_inject_we,
        .dbg_inject_instr,
        .dbg_inject_active,
        .dbg_break_internal,
        .breakpoint_fetch,
        .dbg_ack,
        .ifen,
        .halt_request,
        .core_halt,
        .DBGRNG,
        .scan_we,
        .scan_re,
        .scan_addr,
        .scan_wdata,
        .scan_rdata,
        .scan_raddr
    );
    logic tb_chain1_capture_break;
    logic tb_entry_breakpoint;

    int unsigned errors = 0;

    task automatic tick;
        @(posedge CLK);
        #1;
    endtask

    task automatic check(
        input logic condition,
        input string description
    );
        if (condition !== 1'b1) begin
            $display("[dcc] FAIL %s", description);
            errors = errors + 1;
        end
    endtask

    task automatic core_tx(input logic [31:0] data);
        @(negedge CLK);
        core_dcc_wdata = data;
        core_dcc_we    = 1'b1;
        tick();
        core_dcc_we    = 1'b0;
    endtask

    task automatic core_rx;
        @(negedge CLK);
        core_dcc_re = 1'b1;
        tick();
        core_dcc_re = 1'b0;
    endtask

    task automatic host_write(input logic [31:0] data);
        @(negedge CLK);
        scan_addr  = 5'h05;
        scan_wdata = {1'b1, 5'h05, data};
        scan_we    = 1'b1;
        tick();
        scan_we    = 1'b0;
    endtask

    task automatic host_read;
        @(negedge CLK);
        scan_addr = 5'h05;
        scan_re   = 1'b1;
        tick();
        scan_re   = 1'b0;
    endtask

    initial begin
        $dumpfile("dcc.fst");
        $dumpvars(0, dcc_tb);

        CLKEN             = 1'b1;
        DBGnTRST          = 1'b0;
        core_dcc_we       = 1'b0;
        core_dcc_re       = 1'b0;
        core_dcc_wdata    = 32'h0;
        core_dbgabt_we    = 1'b0;
        core_dbgabt_wdata = 1'b0;
        debug_abort_set   = 1'b0;
        scan_we           = 1'b0;
        scan_re           = 1'b0;
        scan_addr         = 5'h0;
        scan_wdata        = 38'h0;

        repeat (2) tick();
        DBGnTRST = 1'b1;
        tick();

        check(core_dcc_control == 32'h70000000,
              "reset control must report r4p3 version and empty buffers");
        check(dcc_tx_empty && !dcc_rx_full,
              "reset ownership must be TX-empty/RX-empty");

        core_tx(32'h11112222);
        scan_addr = 5'h05;
        #1;
        check(core_dcc_control == 32'h70000002,
              "CPU write must set W");
        check(scan_rdata == 32'h11112222,
              "host data read path must expose TX");
        host_read();
        check(core_dcc_control == 32'h70000000,
              "host read must clear W");

        // A CPU producer coincident with the host consuming the previous
        // word leaves the newly produced word pending.
        core_tx(32'h33334444);
        @(negedge CLK);
        scan_addr      = 5'h05;
        scan_re        = 1'b1;
        core_dcc_wdata = 32'h55556666;
        core_dcc_we    = 1'b1;
        tick();
        scan_re     = 1'b0;
        core_dcc_we = 1'b0;
        #1;
        check(core_dcc_control == 32'h70000002,
              "simultaneous TX produce/consume must keep W set");
        check(scan_rdata == 32'h55556666,
              "simultaneous TX race must retain the new word");
        host_read();

        host_write(32'hAAAABBBB);
        check(dcc_rx_full && core_dcc_rdata == 32'hAAAABBBB,
              "host write must fill RX with supplied data");
        core_rx();
        check(!dcc_rx_full, "CPU read must clear R");

        // A host producer coincident with CPU consumption leaves the new
        // host word pending.
        host_write(32'hCCCCDDDD);
        @(negedge CLK);
        scan_addr   = 5'h05;
        scan_wdata  = {1'b1, 5'h05, 32'hEEEEFFFF};
        scan_we     = 1'b1;
        core_dcc_re = 1'b1;
        tick();
        scan_we     = 1'b0;
        core_dcc_re = 1'b0;
        #1;
        check(dcc_rx_full && core_dcc_rdata == 32'hEEEEFFFF,
              "simultaneous RX produce/consume must retain the new word");

        // CLKEN freezes processor-side effects, but JTAG remains usable.
        CLKEN = 1'b0;
        core_rx();
        check(dcc_rx_full, "stalled CPU read must not consume RX");
        host_read();
        core_tx(32'hDEADBEEF);
        check(dcc_tx_empty, "stalled CPU write must not fill TX");
        host_write(32'h12345678);
        check(dcc_rx_full && core_dcc_rdata == 32'h12345678,
              "JTAG write must operate while CLKEN is low");
        CLKEN = 1'b1;
        core_rx();

        // Debug Abort Status is sticky; a debug event wins a coincident
        // software clear. A later software zero clears it.
        @(negedge CLK);
        debug_abort_set = 1'b1;
        tick();
        debug_abort_set = 1'b0;
        check(core_dbgabt_rdata == 32'h1,
              "debug abort event must set c2");

        @(negedge CLK);
        core_dbgabt_we    = 1'b1;
        core_dbgabt_wdata = 1'b0;
        debug_abort_set   = 1'b1;
        tick();
        core_dbgabt_we  = 1'b0;
        debug_abort_set = 1'b0;
        check(core_dbgabt_rdata == 32'h1,
              "debug set must win coincident software clear");

        @(negedge CLK);
        core_dbgabt_we    = 1'b1;
        core_dbgabt_wdata = 1'b0;
        tick();
        core_dbgabt_we = 1'b0;
        check(core_dbgabt_rdata == 32'h0,
              "software zero must clear c2");

        DBGnTRST = 1'b0;
        #1;
        check(core_dcc_control == 32'h70000000
              && core_dbgabt_rdata == 32'h0,
              "asynchronous DBGnTRST must clear DCC and c2");

        if (errors != 0)
            $fatal(1, "dcc_tb: FAIL (%0d errors)", errors);
        $display("dcc_tb: PASS");
        $finish;
    end

    initial begin
        #10000;
        $fatal(1, "dcc_tb: TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, dbg_break_internal, breakpoint_fetch,
                     dbg_ack, ifen, halt_request,
                     core_halt, DBGRNG, dbg_inject_we, dbg_inject_instr,
                     dbg_inject_active, tb_chain1_capture_break,
                     tb_entry_breakpoint,
                     scan_raddr};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
