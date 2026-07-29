// DBG-002/DBG-003 unit regression for the two EmbeddedICE-RT watchpoint
// comparators. The expected behavior comes from TRM §§5.20 and 5.26.
//
// This covers:
//   * address/data XNOR masks and exact lower-eight-bit control mapping;
//   * WRITE, SIZE, PROT[0], PROT[1], and each unit's own DBGEXT input;
//   * address-phase metadata aligned with following-cycle RDATA/WDATA;
//   * DBGRNG independent of ENABLE, but dependent on data and DBGEN;
//   * WP1 CHAINOUT latch and WP1 RANGEOUT feeding WP0;
//   * CLKEN hold behavior and suppression after the data phase.

`timescale 1ns/1ps

module ice_watchpoint_tb;

    localparam logic [4:0] WP0_ADDR_VAL  = 5'h08;
    localparam logic [4:0] WP0_ADDR_MASK = 5'h09;
    localparam logic [4:0] WP0_DATA_VAL  = 5'h0A;
    localparam logic [4:0] WP0_DATA_MASK = 5'h0B;
    localparam logic [4:0] WP0_CTRL_VAL  = 5'h0C;
    localparam logic [4:0] WP0_CTRL_MASK = 5'h0D;
    localparam logic [4:0] WP1_ADDR_VAL  = 5'h10;
    localparam logic [4:0] WP1_ADDR_MASK = 5'h11;
    localparam logic [4:0] WP1_DATA_VAL  = 5'h12;
    localparam logic [4:0] WP1_DATA_MASK = 5'h13;
    localparam logic [4:0] WP1_CTRL_VAL  = 5'h14;
    localparam logic [4:0] WP1_CTRL_MASK = 5'h15;

    localparam logic [31:0] EXACT_ADDR = 32'h1234_5678;
    localparam logic [31:0] EXACT_DATA = 32'hA55A_C33C;
    localparam logic [31:0] QUAL_ADDR  = 32'h2000_0040;
    localparam logic [31:0] QUAL_DATA  = 32'hCAFE_BABE;
    localparam logic [31:0] TARGET_ADDR = 32'h2000_0080;

    logic CLK;
    initial begin
        CLK = 1'b0;
        forever #5 CLK = ~CLK;
    end

    logic CLKEN;
    logic DBGnTRST;
    logic DBGEN;
    logic [31:0] watch_addr;
    logic [31:0] watch_data;
    logic watch_nopc;
    logic watch_nrw;
    logic [1:0] watch_size;
    logic watch_tbit;
    logic [1:0] watch_extern;
    logic watch_priv;
    logic core_trans1;
    logic dbg_break_internal;
    logic breakpoint_fetch;
    logic dbg_ack;
    logic ifen;
    logic halt_request;
    logic core_halt;
    logic [1:0] DBGRNG;
    logic scan_we;
    logic scan_re;
    logic [4:0] scan_addr;
    logic [37:0] scan_wdata;
    logic [31:0] scan_rdata;
    logic [4:0] scan_raddr;
    logic [31:0] core_dcc_control;
    logic [31:0] core_dcc_rdata;
    logic [31:0] core_dbgabt_rdata;
    logic dcc_tx_empty;
    logic dcc_rx_full;
    logic dbg_inject_we;
    logic [31:0] dbg_inject_instr;
    logic dbg_inject_active;

    arm7tdmis_ice_rt dut (
        .CLK,
        .CLKEN,
        .DBGnTRST,
        .DBGEN,
        .watch_addr,
        .watch_data,
        .watch_nopc,
        .watch_nrw,
        .watch_size,
        .watch_tbit,
        .watch_extern,
        .watch_priv,
        .core_trans1,
        .core_halt_boundary (1'b1),
        .core_breakpoint_execute(1'b0),
        .dbg_rq_in          (1'b0),
        .dbg_break_in       (1'b0),
        .tap_run_idle       (1'b0),
        .tap_restart_req    (1'b0),
        .tap_chain1_capture (1'b0),
        .chain1_capture_break(tb_chain1_capture_break),
        .entry_breakpoint   (tb_entry_breakpoint),
        .monitor_mode       (tb_monitor_mode),
        .monitor_data_abort (tb_monitor_data_abort),
        .core_dcc_we        (1'b0),
        .core_dcc_re        (1'b0),
        .core_dcc_wdata     (32'h0),
        .core_dcc_control,
        .core_dcc_rdata,
        .core_dbgabt_we     (1'b0),
        .core_dbgabt_wdata  (1'b0),
        .core_dbgabt_rdata,
        .debug_abort_set    (1'b0),
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
    logic tb_monitor_mode;
    logic tb_monitor_data_abort;

    int unsigned errors = 0;

    task automatic check(
        input logic condition,
        input string description
    );
        if (!condition) begin
            $display("[ice_watchpoint] FAIL %s", description);
            errors = errors + 1;
        end
    endtask

    task automatic write_reg(
        input logic [4:0] addr,
        input logic [31:0] data
    );
        @(negedge CLK);
        scan_addr  = addr;
        scan_wdata = {1'b1, addr, data};
        scan_we    = 1'b1;
        @(posedge CLK);
        #1;
        scan_we = 1'b0;
    endtask

    task automatic program_wp(
        input bit wp1,
        input logic [31:0] addr_val,
        input logic [31:0] addr_mask,
        input logic [31:0] data_val,
        input logic [31:0] data_mask,
        input logic [8:0] ctrl_val,
        input logic [7:0] ctrl_mask
    );
        logic [4:0] base;
        base = wp1 ? WP1_ADDR_VAL : WP0_ADDR_VAL;
        write_reg(base + 5'd0, addr_val);
        write_reg(base + 5'd1, addr_mask);
        write_reg(base + 5'd2, data_val);
        write_reg(base + 5'd3, data_mask);
        write_reg(base + 5'd4, {23'h0, ctrl_val});
        write_reg(base + 5'd5, {24'h0, ctrl_mask});
    endtask

    // Present the address-class fields before a rising edge. Immediately
    // after that edge, replace the live address pins with poison and drive
    // the corresponding data phase. A conformant implementation must match
    // the saved address/control metadata, not the poison address phase.
    task automatic expect_transfer(
        input logic [31:0] addr,
        input logic [31:0] data,
        input logic nopc,
        input logic nrw,
        input logic [1:0] size,
        input logic priv,
        input logic [1:0] extern_value,
        input logic [1:0] expected_range,
        input logic expected_break,
        input string description
    );
        @(negedge CLK);
        watch_addr   = addr;
        watch_data   = ~data;
        watch_nopc   = nopc;
        watch_nrw    = nrw;
        watch_size   = size;
        watch_priv   = priv;
        watch_extern = extern_value;
        core_trans1  = 1'b1;
        @(posedge CLK);
        #1;
        watch_addr   = 32'hDEAD_0000;
        watch_nopc   = ~nopc;
        watch_nrw    = ~nrw;
        watch_size   = 2'b11;
        watch_priv   = ~priv;
        watch_extern = ~extern_value;
        watch_data   = data;
        core_trans1  = 1'b0;
        #1;
        check(DBGRNG === expected_range,
              $sformatf("%s range expected %02b got %02b",
                        description, expected_range, DBGRNG));
        check(dbg_break_internal === expected_break,
              $sformatf("%s break expected %b got %b",
                        description, expected_break, dbg_break_internal));
        @(posedge CLK);
        #1;
        check(DBGRNG === 2'b00,
              $sformatf("%s stale range survived data phase", description));
    endtask

    // Like expect_transfer, but holds the data phase across disabled clocks.
    task automatic expect_stalled_transfer;
        @(negedge CLK);
        watch_addr   = EXACT_ADDR;
        watch_data   = ~EXACT_DATA;
        watch_nopc   = 1'b1;
        watch_nrw    = 1'b1;
        watch_size   = 2'b10;
        watch_priv   = 1'b1;
        watch_extern = 2'b01;
        core_trans1  = 1'b1;
        @(posedge CLK);
        #1;
        watch_data  = EXACT_DATA;
        core_trans1 = 1'b0;
        CLKEN       = 1'b0;
        repeat (3) begin
            @(posedge CLK);
            #1;
            check(DBGRNG[0] && dbg_break_internal,
                  "CLKEN stall did not hold aligned watchpoint match");
        end
        CLKEN = 1'b1;
        @(posedge CLK);
        #1;
        check(DBGRNG == 2'b00, "watchpoint match survived enabled completion");
    endtask

    task automatic expect_monitor_transfer(
        input logic [1:0] extern_value,
        input logic [1:0] expected_range,
        input logic expected_abort,
        input string description
    );
        @(negedge CLK);
        watch_addr   = EXACT_ADDR;
        watch_data   = ~EXACT_DATA;
        watch_nopc   = 1'b1;
        watch_nrw    = 1'b1;
        watch_size   = 2'b10;
        watch_priv   = 1'b1;
        watch_extern = extern_value;
        core_trans1  = 1'b1;
        @(posedge CLK);
        #1;
        watch_addr   = 32'hDEAD_0000;
        watch_data   = EXACT_DATA;
        core_trans1  = 1'b0;
        #1;
        check(tb_monitor_mode,
              $sformatf("%s monitor mode output was LOW", description));
        check(DBGRNG === expected_range,
              $sformatf("%s range expected %02b got %02b",
                        description, expected_range, DBGRNG));
        check(tb_monitor_data_abort === expected_abort,
              $sformatf("%s abort expected %b got %b",
                        description, expected_abort,
                        tb_monitor_data_abort));
        check(dbg_break_internal === expected_abort,
              $sformatf("%s internal event expected %b got %b",
                        description, expected_abort,
                        dbg_break_internal));
        @(posedge CLK);
        #1;
    endtask

    initial begin
        $dumpfile("ice_watchpoint.fst");
        $dumpvars(0, ice_watchpoint_tb);

        CLKEN        = 1'b1;
        DBGnTRST     = 1'b0;
        DBGEN        = 1'b1;
        watch_addr   = 32'h0;
        watch_data   = 32'h0;
        watch_nopc   = 1'b0;
        watch_nrw    = 1'b0;
        watch_size   = 2'b00;
        watch_tbit   = 1'b0;
        watch_extern = 2'b00;
        watch_priv   = 1'b0;
        core_trans1  = 1'b0;
        scan_we      = 1'b0;
        scan_re      = 1'b0;
        scan_addr    = 5'h0;
        scan_wdata   = 38'h0;

        repeat (2) @(posedge CLK);
        DBGnTRST = 1'b1;

        // WP0 exact privileged word store data watchpoint. RANGE and CHAIN
        // are masked; DBGEXT0 alone is selected.
        program_wp(1'b0, EXACT_ADDR, 32'h0, EXACT_DATA, 32'h0,
                   9'b1_00_1_11_10_1, 8'b11_0_0_0_00_0);
        expect_transfer(EXACT_ADDR, EXACT_DATA, 1'b1, 1'b1, 2'b10,
                        1'b1, 2'b01, 2'b01, 1'b1, "WP0 exact");
        expect_transfer(EXACT_ADDR, EXACT_DATA, 1'b1, 1'b1, 2'b10,
                        1'b1, 2'b11, 2'b01, 1'b1,
                        "WP0 ignores DBGEXT1");
        expect_transfer(EXACT_ADDR, EXACT_DATA, 1'b1, 1'b1, 2'b10,
                        1'b1, 2'b00, 2'b00, 1'b0, "WP0 DBGEXT0 mismatch");
        expect_transfer(EXACT_ADDR, EXACT_DATA, 1'b1, 1'b1, 2'b10,
                        1'b0, 2'b01, 2'b00, 1'b0, "WP0 privilege mismatch");
        expect_transfer(EXACT_ADDR, EXACT_DATA, 1'b0, 1'b1, 2'b10,
                        1'b1, 2'b01, 2'b00, 1'b0, "WP0 PROT0 mismatch");
        expect_transfer(EXACT_ADDR, EXACT_DATA, 1'b1, 1'b1, 2'b01,
                        1'b1, 2'b01, 2'b00, 1'b0, "WP0 size mismatch");
        expect_transfer(EXACT_ADDR, EXACT_DATA, 1'b1, 1'b0, 2'b10,
                        1'b1, 2'b01, 2'b00, 1'b0, "WP0 WRITE mismatch");
        expect_transfer(EXACT_ADDR + 32'd4, EXACT_DATA, 1'b1, 1'b1, 2'b10,
                        1'b1, 2'b01, 2'b00, 1'b0, "WP0 address mismatch");
        expect_transfer(EXACT_ADDR, ~EXACT_DATA, 1'b1, 1'b1, 2'b10,
                        1'b1, 2'b01, 2'b00, 1'b0, "WP0 data mismatch");

        // ENABLE never contributes to DBGRNG.
        write_reg(WP0_CTRL_VAL, 32'(9'b0_00_1_11_10_1));
        expect_transfer(EXACT_ADDR, EXACT_DATA, 1'b1, 1'b1, 2'b10,
                        1'b1, 2'b01, 2'b01, 1'b0,
                        "WP0 range independent of ENABLE");
        write_reg(WP0_CTRL_VAL, 32'(9'b1_00_1_11_10_1));
        DBGEN = 1'b0;
        expect_transfer(EXACT_ADDR, EXACT_DATA, 1'b1, 1'b1, 2'b10,
                        1'b1, 2'b01, 2'b00, 1'b0, "DBGEN gates WP outputs");
        DBGEN = 1'b1;

        // An all-ones XNOR mask ignores every address, data, and control bit.
        program_wp(1'b0, 32'h0, 32'hFFFF_FFFF, 32'h0, 32'hFFFF_FFFF,
                   9'h100, 8'hFF);
        expect_transfer(32'h89AB_CDEF, 32'h0123_4567, 1'b0, 1'b0, 2'b00,
                        1'b0, 2'b10, 2'b01, 1'b1, "WP0 all masked");

        // Restore the exact WP0 and prove wait states preserve the aligned
        // transfer rather than recapturing the poison next address phase.
        program_wp(1'b0, EXACT_ADDR, 32'h0, EXACT_DATA, 32'h0,
                   9'b1_00_1_11_10_1, 8'b11_0_0_0_00_0);
        expect_stalled_transfer();

        // WP1 has identical comparison fields but consumes DBGEXT1, not 0.
        write_reg(WP0_CTRL_VAL, 32'h0);
        program_wp(1'b1, EXACT_ADDR, 32'h0, EXACT_DATA, 32'h0,
                   9'b1_00_1_11_10_1, 8'b11_0_0_0_00_0);
        expect_transfer(EXACT_ADDR, EXACT_DATA, 1'b1, 1'b1, 2'b10,
                        1'b1, 2'b10, 2'b10, 1'b1, "WP1 exact");
        expect_transfer(EXACT_ADDR, EXACT_DATA, 1'b1, 1'b1, 2'b10,
                        1'b1, 2'b11, 2'b10, 1'b1,
                        "WP1 ignores DBGEXT0");
        expect_transfer(EXACT_ADDR, EXACT_DATA, 1'b1, 1'b1, 2'b10,
                        1'b1, 2'b01, 2'b00, 1'b0, "WP1 DBGEXT1 mismatch");

        // WP1 qualifier: exact privileged byte read at QUAL_ADDR records
        // whether QUAL_DATA matched. WP0 target requires CHAIN=1.
        program_wp(1'b1, QUAL_ADDR, 32'h0, QUAL_DATA, 32'h0,
                   9'b0_00_0_11_00_0, 8'b111_0_0_00_0);
        program_wp(1'b0, TARGET_ADDR, 32'h0, 32'h0, 32'hFFFF_FFFF,
                   9'b1_01_0_11_00_0, 8'b10_1_0_0_00_0);
        expect_transfer(TARGET_ADDR, 32'h1111_1111, 1'b1, 1'b0, 2'b00,
                        1'b1, 2'b00, 2'b00, 1'b0, "CHAIN before qualifier");
        expect_transfer(QUAL_ADDR, QUAL_DATA, 1'b1, 1'b0, 2'b00,
                        1'b1, 2'b00, 2'b10, 1'b0, "CHAIN qualifier");
        expect_transfer(TARGET_ADDR, 32'h2222_2222, 1'b1, 1'b0, 2'b00,
                        1'b1, 2'b00, 2'b01, 1'b1, "CHAIN after qualifier");
        write_reg(WP1_CTRL_VAL, 32'(9'b0_00_0_11_00_0));
        expect_transfer(TARGET_ADDR, 32'h3333_3333, 1'b1, 1'b0, 2'b00,
                        1'b1, 2'b00, 2'b00, 1'b0, "CHAIN clear on write");
        expect_transfer(QUAL_ADDR, ~QUAL_DATA, 1'b1, 1'b0, 2'b00,
                        1'b1, 2'b00, 2'b00, 1'b0,
                        "CHAIN data-mismatch qualifier");
        expect_transfer(TARGET_ADDR, 32'h4444_4444, 1'b1, 1'b0, 2'b00,
                        1'b1, 2'b00, 2'b00, 1'b0,
                        "CHAIN remains clear after data mismatch");

        // RANGE is combinational: WP0 requires WP1's complete current
        // range match, including the data comparator.
        program_wp(1'b1, TARGET_ADDR, 32'h0, QUAL_DATA, 32'h0,
                   9'b0_00_0_11_00_0, 8'b111_0_0_00_0);
        program_wp(1'b0, TARGET_ADDR, 32'h0, 32'h0, 32'hFFFF_FFFF,
                   9'b1_10_0_11_00_0, 8'b01_1_0_0_00_0);
        expect_transfer(TARGET_ADDR, QUAL_DATA, 1'b1, 1'b0, 2'b00,
                        1'b1, 2'b00, 2'b11, 1'b1, "RANGE complete match");
        expect_transfer(TARGET_ADDR, ~QUAL_DATA, 1'b1, 1'b0, 2'b00,
                        1'b1, 2'b00, 2'b00, 1'b0,
                        "RANGE includes WP1 data comparison");

        // Monitor mode supports address/control qualifiers but not
        // data-dependent or RANGE/CHAIN-coupled break/watchpoints.
        // Control[5] must suppress even a fully supported match while
        // registers are being reprogrammed.
        program_wp(1'b0, EXACT_ADDR, 32'h0, 32'h0, 32'hFFFF_FFFF,
                   9'b1_00_1_11_10_1, 8'b11_0_0_0_00_0);
        write_reg(5'h00, 32'h0000_0030);
        expect_monitor_transfer(2'b01, 2'b00, 1'b0,
                                "monitor ICE disable");

        write_reg(5'h00, 32'h0000_0010);
        expect_monitor_transfer(2'b01, 2'b01, 1'b1,
                                "monitor supported DBGEXT match");
        expect_monitor_transfer(2'b00, 2'b00, 1'b0,
                                "monitor DBGEXT mismatch");

        // The full comparator and DBGRNG still see the data match, but an
        // unsupported data-dependent setup must not generate an abort.
        program_wp(1'b0, EXACT_ADDR, 32'h0, EXACT_DATA, 32'h0,
                   9'b1_00_1_11_10_1, 8'b11_0_0_0_00_0);
        expect_monitor_transfer(2'b01, 2'b01, 1'b0,
                                "monitor rejects data dependency");

        // Likewise, selecting WP1 RANGE as a qualifier is unsupported in
        // monitor mode even when its current zero value makes the full
        // WP0 comparator match.
        program_wp(1'b0, EXACT_ADDR, 32'h0, 32'h0, 32'hFFFF_FFFF,
                   9'b1_00_1_11_10_1, 8'b01_0_0_0_00_0);
        expect_monitor_transfer(2'b01, 2'b01, 1'b0,
                                "monitor rejects RANGE coupling");

        program_wp(1'b0, EXACT_ADDR, 32'h0, 32'h0, 32'hFFFF_FFFF,
                   9'b1_00_1_11_10_1, 8'b10_0_0_0_00_0);
        expect_monitor_transfer(2'b01, 2'b01, 1'b0,
                                "monitor rejects CHAIN coupling");

        if (errors != 0)
            $fatal(1, "ice_watchpoint_tb: FAIL (%0d errors)", errors);
        $display("ice_watchpoint_tb: PASS");
        $finish;
    end

    initial begin
        #30000;
        $fatal(1, "ice_watchpoint_tb: TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, watch_tbit, dbg_ack, ifen, halt_request,
        core_halt, scan_re, scan_rdata, scan_raddr,
        breakpoint_fetch,
        core_dcc_control, core_dcc_rdata, core_dbgabt_rdata,
        dcc_tx_empty, dcc_rx_full, dbg_inject_we, dbg_inject_instr,
        dbg_inject_active, tb_chain1_capture_break, tb_entry_breakpoint,
        tb_monitor_mode, tb_monitor_data_abort,
        WP0_ADDR_MASK, WP0_DATA_VAL, WP0_DATA_MASK, WP0_CTRL_MASK,
        WP1_ADDR_MASK, WP1_DATA_VAL, WP1_DATA_MASK, WP1_CTRL_MASK};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
