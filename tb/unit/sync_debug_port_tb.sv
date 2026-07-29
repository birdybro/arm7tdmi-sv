// JTAG-004/JTAG-006 regression for the explicitly synchronous FPGA debug
// transport. Every STEP request and response is in CLK's domain. The adapter
// must emit exactly one DBGTCKEN event per accepted request, preserve a
// response under backpressure, isolate the raw pins while disabled, and carry
// a complete IDCODE scan through the real TAP without an asynchronous TCK.

`timescale 1ns/1ps

module sync_debug_port_tb
    import arm7tdmis_debug_pkg::*;
;

    logic CLK;
    initial CLK = 1'b0;
    always #5 CLK = ~CLK;

    logic nRESET;
    logic PORT_ENABLE;
    logic STEP_VALID;
    logic STEP_READY;
    logic STEP_TMS;
    logic STEP_TDI;
    logic STEP_RSP_VALID;
    logic STEP_RSP_READY;
    logic STEP_TDO;
    logic STEP_TDO_OE;

    logic DBGTCKEN;
    logic DBGTMS;
    logic DBGTDI;
    logic DBGTDO;
    logic DBGnTDOEN;

    arm7tdmis_sync_debug_port u_transport (
        .CLK,
        .nRESET,
        .PORT_ENABLE,
        .STEP_VALID,
        .STEP_READY,
        .STEP_TMS,
        .STEP_TDI,
        .STEP_RSP_VALID,
        .STEP_RSP_READY,
        .STEP_TDO,
        .STEP_TDO_OE,
        .DBGTCKEN,
        .DBGTMS,
        .DBGTDI,
        .DBGTDO,
        .DBGnTDOEN
    );

    ir_e         current_ir;
    logic        in_shift_dr;
    logic        in_update_dr;
    logic        in_capture_dr;
    logic        tap_run_idle;
    logic [4:0]  ice_scan_addr;
    logic [37:0] ice_scan_wdata;
    logic        ice_scan_we;
    logic        ice_scan_re;
    logic        ice_chain1_capture;
    logic [31:0] ice_inject_instr;
    logic        ice_inject_break;
    logic        ice_inject_we;
    logic        tap_restart_req;

    arm7tdmis_jtag_tap u_tap (
        .CLK,
        .DBGTCKEN,
        .DBGnTRST                  (nRESET),
        .DBGTMS,
        .DBGTDI,
        .DBGTDO,
        .DBGnTDOEN,
        .current_ir,
        .in_shift_dr,
        .in_update_dr,
        .in_capture_dr,
        .tap_run_idle,
        .ice_scan_addr,
        .ice_scan_wdata,
        .ice_scan_we,
        .ice_scan_re,
        .ice_scan_rdata           (32'h0000_0000),
        .ice_scan_raddr           (5'h00),
        .ice_chain1_capture_data  (32'h0000_0000),
        .ice_chain1_capture_break (1'b0),
        .ice_chain1_capture,
        .ice_inject_instr,
        .ice_inject_break,
        .ice_inject_we,
        .tap_restart_req
    );

    integer errors;
    integer raw_clock_count;

    always_ff @(posedge CLK or negedge nRESET) begin
        if (!nRESET)
            raw_clock_count <= 0;
        else if (DBGTCKEN)
            raw_clock_count <= raw_clock_count + 1;
    end

    task automatic check(input logic condition, input string description);
        if (!condition) begin
            $display("[sync_debug_port] FAIL: %s", description);
            errors++;
        end
    endtask

    task automatic consume_response;
        @(negedge CLK);
        STEP_VALID     = 1'b0;
        STEP_RSP_READY = 1'b1;
        @(posedge CLK);
        #1;
        check(!STEP_RSP_VALID, "response did not retire when ready");
        @(negedge CLK);
        STEP_RSP_READY = 1'b0;
    endtask

    task automatic step(
        input  logic tms,
        input  logic tdi,
        output logic tdo,
        output logic tdo_oe
    );
        integer clocks_before;
        @(negedge CLK);
        clocks_before = raw_clock_count;
        STEP_TMS      = tms;
        STEP_TDI      = tdi;
        STEP_VALID    = 1'b1;
        check(STEP_READY, "idle transport did not accept a step");
        @(posedge CLK);
        #1;
        check(raw_clock_count == clocks_before + 1,
              "accepted step did not emit exactly one raw clock event");
        check(STEP_RSP_VALID, "accepted step produced no response");
        tdo    = STEP_TDO;
        tdo_oe = STEP_TDO_OE;
        consume_response();
    endtask

    task automatic move_step(input logic tms);
        logic ignored_tdo;
        logic ignored_oe;
        step(tms, 1'b0, ignored_tdo, ignored_oe);
        check(!$isunknown({ignored_tdo, ignored_oe}),
              "control step returned an unknown response");
    endtask

    initial begin
        logic first_tdo;
        logic first_oe;
        logic sampled_tdo;
        logic sampled_oe;
        logic [31:0] idcode;
        integer clocks_before;

        errors         = 0;
        nRESET         = 1'b0;
        PORT_ENABLE    = 1'b0;
        STEP_VALID     = 1'b0;
        STEP_TMS       = 1'b0;
        STEP_TDI       = 1'b0;
        STEP_RSP_READY = 1'b0;

        repeat (3) @(posedge CLK);
        @(negedge CLK);
        nRESET      = 1'b1;
        PORT_ENABLE = 1'b1;

        // One-entry response buffer: a held request clocks only once until
        // its response is consumed, and its payload remains stable.
        @(negedge CLK);
        clocks_before = raw_clock_count;
        STEP_VALID = 1'b1;
        STEP_TMS   = 1'b0;
        STEP_TDI   = 1'b1;
        @(posedge CLK);
        #1;
        check(STEP_RSP_VALID, "first request produced no buffered response");
        check(raw_clock_count == clocks_before + 1,
              "first request emitted the wrong number of clocks");
        first_tdo = STEP_TDO;
        first_oe  = STEP_TDO_OE;

        @(negedge CLK);
        STEP_TMS = 1'b1;
        STEP_TDI = 1'b1;
        check(!STEP_READY, "transport accepted while response was blocked");
        check(!DBGTCKEN && !DBGTMS && !DBGTDI,
              "blocked transport did not isolate raw request pins");
        repeat (3) begin
            @(posedge CLK);
            #1;
            check(raw_clock_count == clocks_before + 1,
                  "blocked request emitted a duplicate clock");
            check(STEP_RSP_VALID
                  && STEP_TDO == first_tdo
                  && STEP_TDO_OE == first_oe,
                  "blocked response changed");
        end

        // Consuming and replacing in one clock is legal and must still
        // generate precisely one new TAP event.
        @(negedge CLK);
        STEP_RSP_READY = 1'b1;
        #1;
        check(STEP_READY && DBGTCKEN,
              "transport could not replace a consumed response");
        @(posedge CLK);
        #1;
        check(raw_clock_count == clocks_before + 2,
              "response replacement emitted the wrong number of clocks");
        check(STEP_RSP_VALID, "replacement response was lost");
        consume_response();

        // A disabled port refuses requests, emits no raw activity, returns
        // no response, and does not expose a stale serial value.
        @(negedge CLK);
        PORT_ENABLE = 1'b0;
        STEP_VALID  = 1'b1;
        STEP_TMS    = 1'b1;
        STEP_TDI    = 1'b1;
        clocks_before = raw_clock_count;
        repeat (2) begin
            @(posedge CLK);
            #1;
            check(!STEP_READY && !DBGTCKEN && !DBGTMS && !DBGTDI,
                  "disabled transport accepted or drove a request");
            check(!STEP_RSP_VALID && !STEP_TDO && !STEP_TDO_OE,
                  "disabled transport exposed a response");
            check(raw_clock_count == clocks_before,
                  "disabled transport advanced the TAP");
        end

        // Reset both transport and TAP, then prove the full synchronous path
        // by reading the r4p3 default IDCODE.
        @(negedge CLK);
        STEP_VALID  = 1'b0;
        PORT_ENABLE = 1'b1;
        nRESET      = 1'b0;
        repeat (2) @(posedge CLK);
        @(negedge CLK);
        nRESET = 1'b1;

        move_step(1'b0); // TLR -> Run-Test/Idle
        move_step(1'b1); // Select-DR-Scan
        move_step(1'b0); // Capture-DR
        move_step(1'b0); // Shift-DR, IDCODE is now captured

        idcode = 32'h0000_0000;
        for (int bit_index = 0; bit_index < 32; bit_index++) begin
            step(bit_index == 31, 1'b0, sampled_tdo, sampled_oe);
            idcode[bit_index] = sampled_tdo;
            check(sampled_oe,
                  $sformatf("TDO was not enabled for IDCODE bit %0d",
                            bit_index));
        end
        move_step(1'b1); // Exit1-DR -> Update-DR
        move_step(1'b0); // Update-DR -> Run-Test/Idle

        check(idcode == 32'h7F1F_0F0F,
              $sformatf("IDCODE mismatch: got %08x", idcode));
        check(current_ir == IR_IDCODE, "IDCODE instruction changed");
        check(tap_run_idle, "TAP did not return to Run-Test/Idle");
        check(!$isunknown({
                  in_shift_dr, in_update_dr, in_capture_dr,
                  ice_scan_addr, ice_scan_wdata, ice_scan_we, ice_scan_re,
                  ice_chain1_capture, ice_inject_instr, ice_inject_break,
                  ice_inject_we, tap_restart_req
              }), "TAP auxiliary outputs contained unknown state");

        if (errors != 0)
            $fatal(1, "sync_debug_port_tb: FAIL (%0d errors)", errors);
        $display("sync_debug_port_tb: PASS");
        $finish;
    end

    initial begin
        #200_000;
        $fatal(1, "sync_debug_port_tb: TIMEOUT");
    end

endmodule
