// VAL-008 bounded reachability harness for the actual EmbeddedICE-RT state
// machine. Inputs are arbitrary synchronous environment actions; reset is
// deterministic so every cover starts from the architected RUNNING state.

module arm7tdmis_debug_cover_formal
    import arm7tdmis_debug_pkg::*;
(
    input logic        CLK,
    input logic        CLKEN,
    input logic        DBGEN,
    input logic [31:0] watch_addr,
    input logic [31:0] watch_data,
    input logic        watch_nopc,
    input logic        watch_nrw,
    input logic [1:0]  watch_size,
    input logic        watch_tbit,
    input logic        watch_bigend,
    input logic [1:0]  watch_extern,
    input logic        watch_priv,
    input logic        core_trans1,
    input logic        core_halt_boundary,
    input logic        core_breakpoint_execute,
    input logic        core_exception_pending,
    input logic        core_breakpoint_interrupt_pending,
    input logic        core_exception_entry,
    input logic        core_exception_vector_ready,
    input logic        dbg_rq_in,
    input logic        dbg_break_in,
    input logic        tap_run_idle,
    input logic        tap_restart_req,
    input logic        tap_chain1_capture,
    input logic        tap_inject_we,
    input logic [31:0] tap_inject_instr,
    input logic        tap_inject_break,
    input logic        core_inject_accept,
    input logic        core_inject_retire,
    input logic        scan_we,
    input logic        scan_re,
    input logic [4:0]  scan_addr,
    input logic [37:0] scan_wdata
);
    logic [7:0] f_cycle = 8'd0;
    logic       f_past_valid = 1'b0;
    wire        DBGnTRST = (f_cycle != 8'd0);

    logic        chain1_capture_break;
    logic        entry_breakpoint;
    logic        entry_exception;
    logic        debug_session_active;
    logic        system_speed_active;
    logic        monitor_mode;
    logic        monitor_data_abort;
    logic [31:0] core_dcc_control;
    logic [31:0] core_dcc_rdata;
    logic [31:0] core_dbgabt_rdata;
    logic        dcc_tx_empty;
    logic        dcc_rx_full;
    logic        dbg_inject_we;
    logic [31:0] dbg_inject_instr;
    logic        dbg_inject_active;
    logic        dbg_break_internal;
    logic        breakpoint_fetch;
    logic        halt_watchpoint_event;
    logic        dbg_ack;
    logic        ifen;
    logic        halt_request;
    logic        core_halt;
    logic [1:0]  DBGRNG;
    logic [31:0] scan_rdata;
    logic [4:0]  scan_raddr;

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
        .watch_bigend,
        .watch_extern,
        .watch_priv,
        .core_trans1,
        .core_halt_boundary,
        .core_breakpoint_execute,
        .core_exception_pending,
        .core_breakpoint_interrupt_pending,
        .core_exception_entry,
        .core_exception_vector_ready,
        .dbg_rq_in,
        .dbg_break_in,
        .tap_run_idle,
        .tap_restart_req,
        .tap_chain1_capture,
        .chain1_capture_break,
        .entry_breakpoint,
        .entry_exception,
        .debug_session_active,
        .system_speed_active,
        .monitor_mode,
        .monitor_data_abort,
        .core_dcc_we          (1'b0),
        .core_dcc_re          (1'b0),
        .core_dcc_wdata       (32'h0),
        .core_dcc_control,
        .core_dcc_rdata,
        .core_dbgabt_we       (1'b0),
        .core_dbgabt_wdata    (1'b0),
        .core_dbgabt_rdata,
        .debug_abort_set      (1'b0),
        .dcc_tx_empty,
        .dcc_rx_full,
        .tap_inject_we,
        .tap_inject_instr,
        .tap_inject_break,
        .core_inject_accept,
        .core_inject_retire,
        .dbg_inject_we,
        .dbg_inject_instr,
        .dbg_inject_active,
        .dbg_break_internal,
        .breakpoint_fetch,
        .halt_watchpoint_event,
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

    logic saw_dbgrq_q;
    logic saw_external_break_q;
    logic saw_system_speed_q;
    always_ff @(posedge CLK) begin
        f_past_valid <= 1'b1;
        if (f_cycle != 8'hff)
            f_cycle <= f_cycle + 8'd1;

        if (!DBGnTRST || !DBGEN || debug_session_active) begin
            saw_dbgrq_q <= 1'b0;
            saw_external_break_q <= 1'b0;
        end else begin
            saw_dbgrq_q <= saw_dbgrq_q || dbg_rq_in;
            saw_external_break_q <= saw_external_break_q || dbg_break_in;
        end
        if (!DBGnTRST || !DBGEN)
            saw_system_speed_q <= 1'b0;
        else
            saw_system_speed_q <= saw_system_speed_q || system_speed_active;
    end

    cover_debug_entry_breakpoint: cover property
        (@(posedge CLK) DBGnTRST && debug_session_active
         && entry_breakpoint);
    cover_debug_entry_watchpoint: cover property
        (@(posedge CLK) DBGnTRST && debug_session_active
         && chain1_capture_break);
    cover_debug_entry_dbgrq: cover property
        (@(posedge CLK) DBGnTRST && debug_session_active && saw_dbgrq_q);
    cover_debug_entry_external_break: cover property
        (@(posedge CLK) DBGnTRST && debug_session_active
         && saw_external_break_q);
    cover_debug_return_restart: cover property
        (@(posedge CLK) DBGnTRST && f_past_valid
         && $past(debug_session_active && tap_restart_req)
         && !debug_session_active);
    cover_debug_return_pc_resume: cover property
        (@(posedge CLK) DBGnTRST && dut.breakpoint_resume_q);
    cover_debug_return_system_speed: cover property
        (@(posedge CLK) DBGnTRST && saw_system_speed_q
         && !system_speed_active && debug_session_active);
endmodule
