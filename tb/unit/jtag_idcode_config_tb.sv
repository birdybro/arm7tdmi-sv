// JTAG-002 configurable-IDCODE regression.
//
// The ARM7TDMI-S r4p3 macrocell value remains the default profile, but an
// FPGA product integrating the soft macrocell owns its IEEE 1149.1 identity.
// Prove that each public field can be configured without changing bit 0,
// reset selection, or serial ordering.

`timescale 1ns/1ps

module jtag_idcode_config_tb
    import arm7tdmis_debug_pkg::*;
;

    localparam logic [3:0]  TEST_VERSION      = 4'hA;
    localparam logic [15:0] TEST_PART_NUMBER  = 16'h2468;
    localparam logic [10:0] TEST_MANUFACTURER = 11'h155;
    localparam logic [31:0] TEST_IDCODE = {
        TEST_VERSION, TEST_PART_NUMBER, TEST_MANUFACTURER, 1'b1
    };

    logic CLK = 1'b0;
    initial forever #5 CLK = ~CLK;

    logic DBGTCKEN = 1'b1;
    logic DBGnTRST = 1'b1;
    logic DBGTMS = 1'b1;
    logic DBGTDI = 1'b0;
    logic DBGTDO;
    logic DBGnTDOEN;
    ir_e  current_ir;
    logic in_shift_dr;
    logic in_update_dr;
    logic in_capture_dr;
    logic tap_run_idle;
    logic [4:0] ice_scan_addr;
    logic [37:0] ice_scan_wdata;
    logic ice_scan_we;
    logic ice_scan_re;
    logic ice_chain1_capture;
    logic [31:0] ice_inject_instr;
    logic ice_inject_break;
    logic ice_inject_we;
    logic tap_restart_req;

    arm7tdmis_jtag_tap #(
        .JTAG_VERSION         (TEST_VERSION),
        .JTAG_PART_NUMBER     (TEST_PART_NUMBER),
        .JTAG_MANUFACTURER_ID (TEST_MANUFACTURER)
    ) dut (
        .CLK,
        .DBGTCKEN,
        .DBGnTRST,
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
        .ice_scan_rdata          (32'h0),
        .ice_scan_raddr          (5'h0),
        .ice_chain1_capture_data (32'h0),
        .ice_chain1_capture_break(1'b0),
        .ice_chain1_capture,
        .ice_inject_instr,
        .ice_inject_break,
        .ice_inject_we,
        .tap_restart_req
    );

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused_tap_run_idle = tap_run_idle;
    /* verilator lint_on UNUSEDSIGNAL */

    task automatic tck(input logic tms, input logic tdi);
        DBGTMS = tms;
        DBGTDI = tdi;
        @(posedge CLK);
        #1;
    endtask

    initial begin
        logic [31:0] observed;

        #1;
        // Asynchronous TAP reset must select IDCODE without a test clock.
        DBGnTRST = 1'b0;
        #1;
        if (current_ir != IR_IDCODE)
            $fatal(1, "jtag_idcode_config_tb: reset did not select IDCODE");
        DBGnTRST = 1'b1;

        // Test-Logic-Reset -> Run-Test/Idle -> Select-DR -> Capture -> Shift.
        tck(1'b0, 1'b0);
        tck(1'b1, 1'b0);
        tck(1'b0, 1'b0);
        tck(1'b0, 1'b0);
        observed = '0;
        for (int i = 0; i < 32; i++) begin
            if (DBGnTDOEN)
                $fatal(1, "jtag_idcode_config_tb: TDO disabled at bit %0d", i);
            observed[i] = DBGTDO;
            tck(i == 31, 1'b0);
        end

        if (observed !== TEST_IDCODE)
            $fatal(1,
                "jtag_idcode_config_tb: expected %08x, observed %08x",
                TEST_IDCODE, observed);
        if (observed[31:28] !== TEST_VERSION
            || observed[27:12] !== TEST_PART_NUMBER
            || observed[11:1] !== TEST_MANUFACTURER
            || observed[0] !== 1'b1)
            $fatal(1, "jtag_idcode_config_tb: field packing mismatch");

        $display("jtag_idcode_config_tb: PASS");
        $finish;
    end

    initial begin
        #10000;
        $fatal(1, "jtag_idcode_config_tb: TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, in_shift_dr, in_update_dr, in_capture_dr,
        ice_scan_addr, ice_scan_wdata, ice_scan_we, ice_scan_re,
        ice_chain1_capture, ice_inject_instr, ice_inject_break,
        ice_inject_we, tap_restart_req};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
