// Top-level ARM7TDMI-S r4p3. Pin names match the TRM exactly per
// TASKS.md §1.4 / AGENTS.md so downstream tests, the ETM wrapper (§24),
// and the scan wrapper (§25) all line up.
//
// At §7 the top instantiates a synchronized reset and the simple
// non-pipelined core. Coprocessor (§19), debug (§22), JTAG (§23), and
// ETM (§24) outputs are still tied to safe idle defaults — those
// subsystems land in their own milestones.

module arm7tdmis_top
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_debug_pkg::*;
  #(
    parameter logic [3:0]  JTAG_VERSION = JTAG_DEFAULT_VERSION,
    parameter logic [15:0] JTAG_PART_NUMBER = JTAG_DEFAULT_PART_NUMBER,
    parameter logic [10:0] JTAG_MANUFACTURER_ID =
        JTAG_DEFAULT_MANUFACTURER_ID
  )
(
    // Clock, clock-enable, reset, endianness configuration
    input  logic        CLK,
    input  logic        CLKEN,
    input  logic        nRESET,
    input  logic        CFGBIGEND,

    // Interrupts and bus exception
    input  logic        nIRQ,
    input  logic        nFIQ,
    input  logic        ABORT,

    // Memory bus
    output logic [31:0] ADDR,
    output logic        WRITE,
    output logic [1:0]  SIZE,
    output logic [1:0]  PROT,
    output logic        LOCK,
    output logic [1:0]  TRANS,
    output logic [31:0] WDATA,
    input  logic [31:0] RDATA,

    // Coprocessor handshake
    output logic        CPnMREQ,
    output logic        CPSEQ,
    output logic        CPnTRANS,
    output logic        CPnOPC,
    output logic        CPTBIT,
    output logic        CPnI,
    input  logic        CPA,
    input  logic        CPB,

    // Debug + EmbeddedICE-RT control/status
    input  logic        DBGEN,
    input  logic        DBGRQ,
    input  logic        DBGBREAK,
    output logic        DBGACK,
    output logic        DBGnEXEC,
    output logic        DBGINSTRVALID,
    input  logic [1:0]  DBGEXT,
    output logic [1:0]  DBGRNG,
    output logic        DBGCOMMTX,
    output logic        DBGCOMMRX,

    // JTAG TAP
    input  logic        DBGTCKEN,
    input  logic        DBGTMS,
    input  logic        DBGTDI,
    output logic        DBGTDO,
    input  logic        DBGnTRST,
    output logic        DBGnTDOEN,

    // LDM/STM continuation hint to memory controllers
    output logic        DMORE
);

    // ---- Reset synchronizer (§4) ----
    logic core_nreset;
    arm7tdmis_reset_sync u_rst (
        .CLK         (CLK),
        .nRESET      (nRESET),
        .core_nreset (core_nreset)
    );

    // ---- Core (§16 — 3-stage Fetch/Decode/Execute pipeline) ----
    // §22: IFEN from the ICE-RT macrocell gates the IRQ/FIQ inputs.
    // IFEN=0 forces nIRQ_eff/nFIQ_eff HIGH (= no interrupt pending), which
    // is how INTDIS in the Debug Control Register masks interrupts even
    // outside debug state. With DBGEN=0 the ICE drives IFEN=1, so this
    // is a pass-through.
    //
    // core_halt freezes normal pipeline progress by gating its CLKEN.
    // Reset remains independent of CLKEN so architectural state can
    // always be cleared while the debugger has the core halted. The
    // memory model still ticks with the unmodified CLKEN so a debugger
    // can drive bus accesses via scan-chain-2 / chain-1 without losing
    // the core's frozen state.
    wire nIRQ_eff   = nIRQ | ~ice_ifen;
    wire nFIQ_eff   = nFIQ | ~ice_ifen;
    wire core_clken = CLKEN && !ice_core_halt;

    arm7tdmis_core_pipelined u_core (
        .CLK       (CLK),
        .CLKEN     (core_clken),
        .nRESET    (core_nreset),
        .CFGBIGEND (CFGBIGEND),
        .nIRQ      (nIRQ_eff),
        .nFIQ      (nFIQ_eff),
        .ABORT     (ABORT),
        .ADDR      (ADDR),
        .WRITE     (WRITE),
        .SIZE      (SIZE),
        .PROT      (PROT),
        .LOCK      (LOCK),
        .TRANS     (TRANS),
        .WDATA     (WDATA),
        .RDATA     (RDATA),
        .DMORE     (DMORE),
        .CPnMREQ   (CPnMREQ),
        .CPSEQ     (CPSEQ),
        .CPnTRANS  (CPnTRANS),
        .CPnOPC    (CPnOPC),
        .CPTBIT    (CPTBIT),
        .CPnI      (CPnI),
        .CPA       (CPA),
        .CPB       (CPB),
        .DBGnEXEC      (DBGnEXEC),
        .DBGINSTRVALID (DBGINSTRVALID),
        .core_dcc_we      (core_dcc_we),
        .core_dcc_re      (core_dcc_re),
        .core_dcc_wdata   (core_dcc_wdata),
        .core_dcc_control (core_dcc_control),
        .core_dcc_rdata   (core_dcc_rdata),
        .core_dbgabt_we    (core_dbgabt_we),
        .core_dbgabt_wdata (core_dbgabt_wdata),
        .core_dbgabt_rdata (core_dbgabt_rdata),
        .dbg_inject_we    (dbg_inject_we),
        .dbg_inject_instr (dbg_inject_instr),
        .dbg_inject_active(dbg_inject_active),
        .dbg_inject_accept(dbg_inject_accept),
        .dbg_inject_retire(dbg_inject_retire),
        .dbg_reg_we      (dbg_reg_we),
        .dbg_reg_addr    (dbg_reg_addr),
        .dbg_reg_wdata   (tap_inject_instr),
        .dbg_reg_force_user(dbg_reg_force_user),
        .dbg_reg_rdata   (dbg_reg_rdata),
        .dbg_halt_req     (ice_halt_request),
        .dbg_halted       (ice_core_halt),
        .dbg_breakpoint_fetch(ice_breakpoint_fetch),
        .dbg_halt_boundary(ice_halt_boundary),
        .dbg_breakpoint_execute(ice_breakpoint_execute)
    );

    // ---- EmbeddedICE-RT (§22 scaffold) ----
    // Watchpoint comparators only at this milestone — full debug-state
    // FSM, CHAIN/RANGE coupling, and scan-chain-2 wiring land later.
    logic       ice_dbg_break;
    logic [1:0] ice_dbgrng;

    logic ice_dbg_ack;
    logic ice_ifen;
    logic ice_halt_request;
    logic ice_halt_boundary;
    logic ice_core_halt;
    logic ice_breakpoint_fetch;
    logic ice_breakpoint_execute;
    logic tap_restart_req;
    logic        core_dcc_we;
    logic        core_dcc_re;
    logic [31:0] core_dcc_wdata;
    logic [31:0] core_dcc_control;
    logic [31:0] core_dcc_rdata;
    logic        core_dbgabt_we;
    logic        core_dbgabt_wdata;
    logic [31:0] core_dbgabt_rdata;
    logic        dcc_tx_empty;
    logic        dcc_rx_full;
    logic        dbg_inject_we;
    logic [31:0] dbg_inject_instr;
    logic        dbg_inject_active;
    logic        dbg_inject_accept;
    logic        dbg_inject_retire;
    logic        tap_chain1_capture;
    logic        ice_chain1_capture_break;
    logic        ice_entry_breakpoint;
    logic        ice_data_write_q;
    logic [31:0] ice_watch_data;

    // The address-class WRITE output leads its WDATA/RDATA phase by one
    // enabled cycle. Delay only the direction bit so the ICE comparator's
    // data input is selected for the transaction metadata it captures.
    always_ff @(posedge CLK) begin
        if (!core_nreset)
            ice_data_write_q <= 1'b0;
        else if (CLKEN)
            ice_data_write_q <= WRITE;
    end
    assign ice_watch_data = ice_data_write_q ? WDATA : RDATA;

    arm7tdmis_ice_rt u_ice (
        .CLK                (CLK),
        .CLKEN              (CLKEN),
        .DBGnTRST           (DBGnTRST),
        .DBGEN              (DBGEN),
        .watch_addr         (ADDR),
        .watch_data         (ice_watch_data),
        .watch_nopc         (PROT[0]),         // PROT[0]=1 → data access
        .watch_nrw          (WRITE),
        .watch_size         (SIZE),
        .watch_tbit         (CPTBIT),
        .watch_extern       (DBGEXT),
        .watch_priv         (PROT[1]),     // address-phase privilege bit
        .core_trans1        (TRANS[1]),    // live Debug Status[3]
        .core_halt_boundary (ice_halt_boundary),
        .core_breakpoint_execute(ice_breakpoint_execute),
        .dbg_rq_in          (DBGRQ),       // §22: synchronized inside ICE-RT
        .dbg_break_in       (DBGBREAK),    // §22: synchronized inside ICE-RT
        .tap_restart_req    (tap_restart_req),
        .tap_chain1_capture (tap_chain1_capture),
        .chain1_capture_break(ice_chain1_capture_break),
        .entry_breakpoint   (ice_entry_breakpoint),
        .dbg_break_internal (ice_dbg_break),
        .breakpoint_fetch   (ice_breakpoint_fetch),
        .dbg_ack            (ice_dbg_ack),
        .ifen               (ice_ifen),
        .halt_request       (ice_halt_request),
        .core_halt          (ice_core_halt),
        .DBGRNG             (ice_dbgrng),
        .scan_we            (ice_scan_we),
        .scan_re            (ice_scan_re),
        .scan_addr          (ice_scan_addr),
        .scan_wdata         (ice_scan_wdata),
        .scan_rdata         (ice_scan_rdata),
        .scan_raddr         (ice_scan_raddr),
        .core_dcc_we        (core_dcc_we),
        .core_dcc_re        (core_dcc_re),
        .core_dcc_wdata     (core_dcc_wdata),
        .core_dcc_control   (core_dcc_control),
        .core_dcc_rdata     (core_dcc_rdata),
        .core_dbgabt_we     (core_dbgabt_we),
        .core_dbgabt_wdata  (core_dbgabt_wdata),
        .core_dbgabt_rdata  (core_dbgabt_rdata),
        .debug_abort_set    (1'b0),
        .dcc_tx_empty       (dcc_tx_empty),
        .dcc_rx_full        (dcc_rx_full),
        .tap_inject_we      (tap_inject_we_to_ice),
        .tap_inject_instr   (tap_inject_instr),
        .tap_inject_break   (tap_inject_break),
        .core_inject_accept (dbg_inject_accept),
        .core_inject_retire (dbg_inject_retire),
        .dbg_inject_we      (dbg_inject_we),
        .dbg_inject_instr   (dbg_inject_instr),
        .dbg_inject_active  (dbg_inject_active)
    );

    assign DBGRNG = ice_dbgrng;
    assign DBGACK = ice_dbg_ack;

    // Appendix A polarity: TX is HIGH while the processor-to-debugger
    // register is empty; RX is HIGH while debugger data is pending.
    // Both status pins are suppressed when external debug is disabled.
    assign DBGCOMMTX = DBGEN && dcc_tx_empty;
    assign DBGCOMMRX = DBGEN && dcc_rx_full;

    // ICE-generated break signal not yet routed back into the core's
    // debug-entry path (no debug-state FSM yet).
    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused_ice = &{1'b0, ice_dbg_break};
    /* verilator lint_on UNUSEDSIGNAL */

    // ---- JTAG TAP (§23) + Scan chain 2 to EmbeddedICE-RT ----
    ir_e          tap_current_ir;
    logic         tap_in_shift_dr;
    logic         tap_in_update_dr;
    logic         tap_in_capture_dr;
    logic [4:0]   ice_scan_addr;
    logic [37:0]  ice_scan_wdata;
    logic         ice_scan_we;
    logic         ice_scan_re;
    logic [31:0]  ice_scan_rdata;
    logic [4:0]   ice_scan_raddr;

    logic [31:0] tap_inject_instr;
    logic        tap_inject_break;
    logic        tap_inject_we;
    logic        tap_tdo;
    logic        tap_ntdoen;
    logic        dbg_reg_we;
    logic [3:0]  dbg_reg_addr;
    logic        dbg_reg_force_user;
    logic [31:0] dbg_reg_rdata;

    // ARM7TDMI debug-speed LDM/STM uses scan chain 1 itself as the data
    // bus. OpenOCD loads the block instruction, clocks two pipeline NOPs,
    // then shifts one word per selected register. Keep this path entirely
    // inside the core: no external memory cycle is issued while DBGACK is
    // HIGH. System-speed transfers use W=1 in the published debugger
    // sequence and continue through the normal staged/RESTART path.
    logic        dbg_block_setup_q;
    logic [1:0]  dbg_block_setup_left_q;
    logic        dbg_block_active_q;
    logic        dbg_block_load_q;
    logic        dbg_block_force_user_q;
    logic [15:0] dbg_block_remaining_q;
    logic [3:0]  dbg_block_reg_q;

    function automatic logic [3:0] debug_lowest_reg(
        input logic [15:0] mask
    );
        for (int i = 0; i < 16; i++) begin
            if (mask[i])
                return 4'(i);
        end
        return 4'd0;
    endfunction

    wire tap_debug_block_instr = (tap_inject_instr[31:28] == 4'hE)
                               && (tap_inject_instr[27:25] == 3'b100)
                               && !tap_inject_instr[24]
                               && tap_inject_instr[23]
                               && !tap_inject_instr[21]
                               && (tap_inject_instr[15:0] != 16'h0);
    wire dbg_block_start = tap_inject_we && ice_dbg_ack
                         && !tap_inject_break
                         && !dbg_block_setup_q && !dbg_block_active_q
                         && tap_debug_block_instr;
    wire dbg_block_consumes_scan = dbg_block_start
                                 || dbg_block_setup_q
                                 || dbg_block_active_q;
    wire [15:0] dbg_block_after_current =
        dbg_block_remaining_q & ~(16'h1 << dbg_block_reg_q);

    always_ff @(posedge CLK or negedge DBGnTRST) begin
        if (!DBGnTRST) begin
            dbg_block_setup_q       <= 1'b0;
            dbg_block_setup_left_q  <= 2'd0;
            dbg_block_active_q      <= 1'b0;
            dbg_block_load_q        <= 1'b0;
            dbg_block_force_user_q  <= 1'b0;
            dbg_block_remaining_q   <= 16'h0;
            dbg_block_reg_q         <= 4'h0;
        end else if (!DBGEN) begin
            dbg_block_setup_q       <= 1'b0;
            dbg_block_setup_left_q  <= 2'd0;
            dbg_block_active_q      <= 1'b0;
            dbg_block_load_q        <= 1'b0;
            dbg_block_force_user_q  <= 1'b0;
            dbg_block_remaining_q   <= 16'h0;
            dbg_block_reg_q         <= 4'h0;
        end else if (dbg_block_start) begin
            dbg_block_setup_q       <= 1'b1;
            dbg_block_setup_left_q  <= 2'd2;
            dbg_block_active_q      <= 1'b0;
            dbg_block_load_q        <= tap_inject_instr[20];
            dbg_block_force_user_q  <= tap_inject_instr[22];
            dbg_block_remaining_q   <= tap_inject_instr[15:0];
            dbg_block_reg_q         <=
                debug_lowest_reg(tap_inject_instr[15:0]);
        end else if (tap_inject_we && dbg_block_setup_q) begin
            if (dbg_block_setup_left_q == 2'd1) begin
                dbg_block_setup_q      <= 1'b0;
                dbg_block_setup_left_q <= 2'd0;
                dbg_block_active_q     <= 1'b1;
            end else begin
                dbg_block_setup_left_q <= dbg_block_setup_left_q - 2'd1;
            end
        end else if (tap_inject_we && dbg_block_active_q) begin
            dbg_block_remaining_q <= dbg_block_after_current;
            if (dbg_block_after_current == 16'h0) begin
                dbg_block_active_q <= 1'b0;
            end else begin
                dbg_block_reg_q <=
                    debug_lowest_reg(dbg_block_after_current);
            end
        end
    end

    assign dbg_reg_we = tap_inject_we && dbg_block_active_q
                      && dbg_block_load_q;
    assign dbg_reg_addr = dbg_block_reg_q;
    assign dbg_reg_force_user = dbg_block_force_user_q;

    // The direct stream adapter consumes the STM plus its two pipeline
    // NOPs without executing them in the core. A physical ARM7TDMI has
    // advanced r15 by three ARM words when the first register reaches
    // the scan data bus, so restore that visible bias for r15 only.
    wire [31:0] dbg_block_capture_data =
        (dbg_block_reg_q == 4'd15) ? (dbg_reg_rdata + 32'd12
                                     + (ice_entry_breakpoint ? 32'd4 : 32'd0))
                                   : dbg_reg_rdata;
    wire [31:0] tap_chain1_capture_data = dbg_block_active_q
                                       && !dbg_block_load_q
                                       ? dbg_block_capture_data : WDATA;
    wire tap_inject_we_to_ice = tap_inject_we
                              && !dbg_block_consumes_scan;

    // Appendix A: the complete external scan transport is enabled only when
    // DBGEN is HIGH. DBGnTRST remains independent so the TAP and ICE D-types
    // can always be cleared asynchronously. Output isolation is combinational
    // so dropping DBGEN cannot leave the shared TDO pad driven until another
    // CLK edge.
    wire tap_tcken = DBGEN && DBGTCKEN;
    wire tap_tms   = DBGEN && DBGTMS;
    wire tap_tdi   = DBGEN && DBGTDI;
    assign DBGTDO    = DBGEN ? tap_tdo : 1'b0;
    assign DBGnTDOEN = !DBGEN || tap_ntdoen;

    arm7tdmis_jtag_tap #(
        .JTAG_VERSION         (JTAG_VERSION),
        .JTAG_PART_NUMBER     (JTAG_PART_NUMBER),
        .JTAG_MANUFACTURER_ID (JTAG_MANUFACTURER_ID)
    ) u_tap (
        .CLK              (CLK),
        .DBGTCKEN         (tap_tcken),
        .DBGnTRST         (DBGnTRST),
        .DBGTMS           (tap_tms),
        .DBGTDI           (tap_tdi),
        .DBGTDO           (tap_tdo),
        .DBGnTDOEN        (tap_ntdoen),
        .current_ir       (tap_current_ir),
        .in_shift_dr      (tap_in_shift_dr),
        .in_update_dr     (tap_in_update_dr),
        .in_capture_dr    (tap_in_capture_dr),
        .ice_scan_addr    (ice_scan_addr),
        .ice_scan_wdata   (ice_scan_wdata),
        .ice_scan_we      (ice_scan_we),
        .ice_scan_re      (ice_scan_re),
        .ice_scan_rdata   (ice_scan_rdata),
        .ice_scan_raddr   (ice_scan_raddr),
        .ice_chain1_capture_data(tap_chain1_capture_data),
        .ice_chain1_capture_break(ice_chain1_capture_break),
        .ice_chain1_capture(tap_chain1_capture),
        .ice_inject_instr (tap_inject_instr),
        .ice_inject_break (tap_inject_break),
        .ice_inject_we    (tap_inject_we),
        .tap_restart_req  (tap_restart_req)
    );

    // TAP observers used by §22 debug FSM later — silence lint for now.
    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused_tap = &{1'b0,
        tap_current_ir, tap_in_shift_dr, tap_in_update_dr, tap_in_capture_dr
    };
    /* verilator lint_on UNUSEDSIGNAL */

    // All major DBG* inputs now consumed; nothing to drain.

endmodule
