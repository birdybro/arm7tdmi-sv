// Unit test for arm7tdmis_ice_rt.
//
// Verifies:
//   - Register bank can be written via the scan_we/scan_addr/scan_wdata port
//     and read back via scan_rdata at the same address.
//   - DBGnTRST clears the bank.
//   - Watchpoint comparator fires DBGRNG and dbg_break_internal when
//     watch_addr/watch_data match the programmed WP0 value with ENABLE=1
//     and DBGEN=1.

`timescale 1ns/1ps

module ice_rt_tb
    import arm7tdmis_debug_pkg::*;
;

    logic CLK = 0;
    initial begin
        forever #5 CLK = ~CLK;
    end

    logic        CLKEN = 1'b1;
    logic        DBGnTRST;
    logic        DBGEN;

    logic [31:0] watch_addr;
    logic [31:0] watch_data;
    logic        watch_nopc;
    logic        watch_nrw;
    logic [1:0]  watch_size;
    logic        watch_tbit;
    logic [1:0]  watch_extern;
    logic        watch_priv;
    logic        dbg_rq_in;
    logic        dbg_break_in;
    logic        tap_restart_req;
    logic        core_halt;

    logic        dbg_break_internal;
    logic        dbg_ack;
    logic        ifen;
    logic [1:0]  DBGRNG;

    logic        scan_we;
    logic [4:0]  scan_addr;
    logic [37:0] scan_wdata;
    logic [31:0] scan_rdata;

    arm7tdmis_ice_rt dut (
        .CLK                (CLK),
        .CLKEN              (CLKEN),
        .DBGnTRST           (DBGnTRST),
        .DBGEN              (DBGEN),
        .watch_addr         (watch_addr),
        .watch_data         (watch_data),
        .watch_nopc         (watch_nopc),
        .watch_nrw          (watch_nrw),
        .watch_size         (watch_size),
        .watch_tbit         (watch_tbit),
        .watch_extern       (watch_extern),
        .watch_priv         (watch_priv),
        .dbg_rq_in          (dbg_rq_in),
        .dbg_break_in       (dbg_break_in),
        .tap_restart_req    (tap_restart_req),
        .core_halt          (core_halt),
        .dbg_break_internal (dbg_break_internal),
        .dbg_ack            (dbg_ack),
        .ifen               (ifen),
        .DBGRNG             (DBGRNG),
        .scan_we            (scan_we),
        .scan_addr          (scan_addr),
        .scan_wdata         (scan_wdata),
        .scan_rdata         (scan_rdata),
        .core_dcc_we        (1'b0),
        .core_dcc_wdata     (32'h0),
        .core_dcc_rdata     (tb_dcc_rdata),
        .tap_inject_we      (1'b0),
        .tap_inject_instr   (32'h0),
        .dbg_inject_we      (tb_inject_we),
        .dbg_inject_instr   (tb_inject_instr)
    );
    logic [31:0] tb_dcc_rdata;
    logic        tb_inject_we;
    logic [31:0] tb_inject_instr;

    int errors = 0;

    task automatic write_reg(input logic [4:0] addr, input logic [31:0] data);
        @(negedge CLK);
        scan_we    = 1'b1;
        scan_addr  = addr;
        scan_wdata = {1'b1, addr, data};
        @(posedge CLK);
        #1;
        scan_we    = 1'b0;
    endtask

    task automatic check_reg(input logic [4:0] addr, input logic [31:0] expected,
                             input string name);
        scan_addr = addr;
        #1;
        if (scan_rdata !== expected) begin
            $display("[ice_rt] FAIL %s: addr=%02x expected %08x got %08x",
                     name, addr, expected, scan_rdata);
            errors = errors + 1;
        end
    endtask

    initial begin
        $dumpfile("ice_rt.fst");

        DBGnTRST     = 1'b0;
        DBGEN        = 1'b0;
        watch_addr   = 32'h0;
        watch_data   = 32'h0;
        watch_nopc   = 1'b0;
        watch_nrw    = 1'b0;
        watch_size   = 2'b00;
        watch_tbit   = 1'b0;
        watch_extern = 2'b00;
        watch_priv      = 1'b1;
        dbg_rq_in       = 1'b0;
        dbg_break_in    = 1'b0;
        tap_restart_req = 1'b0;
        scan_we         = 1'b0;
        scan_addr    = 5'h0;
        scan_wdata   = 38'h0;

        @(posedge CLK);
        @(posedge CLK);
        DBGnTRST = 1'b1;

        // After reset, all regs should be zero.
        check_reg(5'h08, 32'h0, "WP0 ADDR_VAL post-reset");
        check_reg(5'h0C, 32'h0, "WP0 CTRL_VAL post-reset");

        // Program WP0 to match address 0x12345678 with all data bits don't-
        // care and ENABLE bit set.
        write_reg(5'h08, 32'h12345678);   // WP0_ADDR_VAL
        write_reg(5'h09, 32'h00000000);   // WP0_ADDR_MASK (exact match)
        write_reg(5'h0A, 32'h00000000);   // WP0_DATA_VAL
        write_reg(5'h0B, 32'hFFFFFFFF);   // WP0_DATA_MASK (don't care)
        write_reg(5'h0C, 32'h00000100);   // WP0_CTRL_VAL: ENABLE=1
        write_reg(5'h0D, 32'h0000FFFF);   // WP0_CTRL_MASK: don't-care all ctrl bits

        check_reg(5'h08, 32'h12345678, "WP0 ADDR_VAL written");
        check_reg(5'h0C, 32'h00000100, "WP0 CTRL_VAL written");

        // Drive bus with a non-matching address; expect no break.
        watch_addr = 32'h00000000;
        watch_data = 32'hAAAAAAAA;
        DBGEN      = 1'b1;
        #1;
        if (dbg_break_internal !== 1'b0) begin
            $display("[ice_rt] FAIL: non-match should not break, got %b",
                     dbg_break_internal);
            errors = errors + 1;
        end

        // Now drive the matching address. Expect DBGRNG[0] AND
        // dbg_break_internal asserted.
        watch_addr = 32'h12345678;
        #1;
        if (DBGRNG[0] !== 1'b1) begin
            $display("[ice_rt] FAIL: DBGRNG[0] expected 1 on match");
            errors = errors + 1;
        end
        if (dbg_break_internal !== 1'b1) begin
            $display("[ice_rt] FAIL: dbg_break expected 1 on match");
            errors = errors + 1;
        end

        // DBGEN=0 must force dbg_break_internal low even when matching.
        DBGEN = 1'b0;
        #1;
        if (dbg_break_internal !== 1'b0) begin
            $display("[ice_rt] FAIL: DBGEN=0 should suppress break");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("ice_rt_tb: PASS");
        else
            $display("ice_rt_tb: FAIL (%0d errors)", errors);
        $finish;
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, DBGRNG[1], dbg_ack, ifen, core_halt, tb_dcc_rdata,
                     tb_inject_we, tb_inject_instr};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
