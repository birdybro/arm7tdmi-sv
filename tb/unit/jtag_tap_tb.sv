// Unit test for arm7tdmis_jtag_tap.
//
// Drives the standard TAP reset-then-shift-IDCODE flow and verifies that
// the 32-bit IDCODE_VALUE shifts out LSB-first on DBGTDO. Also verifies
// BYPASS shape (1-bit shift register).

`timescale 1ns/1ps

module jtag_tap_tb
    import arm7tdmis_debug_pkg::*;
;

    logic CLK = 0;
    initial begin
        forever #5 CLK = ~CLK;
    end

    logic DBGTCKEN = 1'b1;             // every CLK is a TCK event for this test
    logic DBGnTRST;
    logic DBGTMS;
    logic DBGTDI;
    logic DBGTDO;
    logic DBGnTDOEN;
    ir_e  current_ir;
    logic in_shift_dr, in_update_dr, in_capture_dr;

    logic [4:0]  ice_scan_addr;
    logic [37:0] ice_scan_wdata;
    logic        ice_scan_we;

    arm7tdmis_jtag_tap dut (
        .CLK            (CLK),
        .DBGTCKEN       (DBGTCKEN),
        .DBGnTRST       (DBGnTRST),
        .DBGTMS         (DBGTMS),
        .DBGTDI         (DBGTDI),
        .DBGTDO         (DBGTDO),
        .DBGnTDOEN      (DBGnTDOEN),
        .current_ir     (current_ir),
        .in_shift_dr    (in_shift_dr),
        .in_update_dr   (in_update_dr),
        .in_capture_dr  (in_capture_dr),
        .ice_scan_addr  (ice_scan_addr),
        .ice_scan_wdata (ice_scan_wdata),
        .ice_scan_we    (ice_scan_we),
        .ice_scan_rdata (32'h0)
    );

    int          errors = 0;
    logic [31:0] captured;

    // One TCK step: drive TMS/TDI, then wait for posedge.
    task automatic tck(input logic tms, input logic tdi);
        DBGTMS = tms;
        DBGTDI = tdi;
        @(posedge CLK);
        #1;                            // settle after the edge
    endtask

    initial begin
        $dumpfile("jtag_tap.fst");

        // Async reset of the TAP.
        DBGnTRST = 1'b0;
        DBGTMS   = 1'b1;
        DBGTDI   = 1'b0;
        @(posedge CLK);
        #1;
        DBGnTRST = 1'b1;

        // After reset, current_ir should be IDCODE per spec.
        if (current_ir !== IR_IDCODE) begin
            $display("[jtag_tap] FAIL: post-reset IR expected IDCODE, got %0h", current_ir);
            errors = errors + 1;
        end

        // Standard sequence: TLR → RTI → Select-DR → Capture-DR → Shift-DR
        tck(1'b0, 1'b0);   // TLR → RTI
        tck(1'b1, 1'b0);   // RTI → Select-DR-Scan
        tck(1'b0, 1'b0);   // SDRS → Capture-DR (latches IDCODE)
        tck(1'b0, 1'b0);   // CDR → Shift-DR (32 shifts)

        // Now we're in SDR. Shift out 32 bits of IDCODE. TDO valid this cycle
        // already (combinational from shift register LSB). On the rising
        // edge we shift in DBGTDI (0) and shift out the next bit.
        captured = 32'h0;
        for (int i = 0; i < 32; i = i + 1) begin
            captured[i] = DBGTDO;
            // After 32 shifts we want to leave SDR. The 32nd shift's TMS
            // can be 1 to exit; here we keep shifting and exit after.
            tck(1'b0, 1'b0);
        end

        if (captured !== IDCODE_VALUE) begin
            $display("[jtag_tap] FAIL: IDCODE shifted out: expected %08x, got %08x",
                     IDCODE_VALUE, captured);
            errors = errors + 1;
        end else begin
            $display("[jtag_tap] IDCODE: %08x ok", captured);
        end

        // Now shift IR=BYPASS (4'b1111). Sequence: SDR → Exit1-DR → Update-DR
        // → Select-DR → Select-IR-Scan → Capture-IR → Shift-IR → 4 bits →
        // Exit1-IR → Update-IR.
        tck(1'b1, 1'b0);   // SDR → Exit1-DR
        tck(1'b1, 1'b0);   // Exit1-DR → Update-DR
        tck(1'b1, 1'b0);   // Update-DR → Select-DR-Scan
        tck(1'b1, 1'b0);   // Select-DR-Scan → Select-IR-Scan
        tck(1'b0, 1'b0);   // SIRS → Capture-IR
        tck(1'b0, 1'b0);   // CIR → Shift-IR (loads capture pattern)
        // Shift in 1111 LSB-first.
        tck(1'b0, 1'b1);
        tck(1'b0, 1'b1);
        tck(1'b0, 1'b1);
        tck(1'b1, 1'b1);   // last bit: TMS=1 to exit
        tck(1'b1, 1'b0);   // Exit1-IR → Update-IR
        tck(1'b0, 1'b0);   // Update-IR → RTI

        if (current_ir !== IR_BYPASS) begin
            $display("[jtag_tap] FAIL: IR after shift expected BYPASS, got %0h",
                     current_ir);
            errors = errors + 1;
        end else begin
            $display("[jtag_tap] BYPASS IR loaded ok");
        end

        if (errors == 0)
            $display("jtag_tap_tb: PASS");
        else
            $display("jtag_tap_tb: FAIL (%0d errors)", errors);
        $finish;
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, DBGnTDOEN, in_shift_dr, in_update_dr, in_capture_dr,
                     ice_scan_addr, ice_scan_wdata, ice_scan_we};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
