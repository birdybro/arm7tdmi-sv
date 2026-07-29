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
        .dbg_halt_req     (ice_halt_request),
        .dbg_halted       (ice_core_halt)
    );

    // ---- EmbeddedICE-RT (§22 scaffold) ----
    // Watchpoint comparators only at this milestone — full debug-state
    // FSM, CHAIN/RANGE coupling, and scan-chain-2 wiring land later.
    logic       ice_dbg_break;
    logic [1:0] ice_dbgrng;

    logic ice_dbg_ack;
    logic ice_ifen;
    logic ice_halt_request;
    logic ice_core_halt;
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
        .dbg_rq_in          (DBGRQ),       // §22: synchronized inside ICE-RT
        .dbg_break_in       (DBGBREAK),    // §22: synchronized inside ICE-RT
        .tap_restart_req    (tap_restart_req),
        .dbg_break_internal (ice_dbg_break),
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
        .tap_inject_we      (tap_inject_we),
        .tap_inject_instr   (tap_inject_instr),
        .dbg_inject_we      (dbg_inject_we),
        .dbg_inject_instr   (dbg_inject_instr)
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

    // tap_inject_break (DBGBREAK control cell from chain 1) consumed by
    // the debug-state FSM later; the actual instruction routing happens
    // through ice_rt → core via dbg_inject_we/instr.

    arm7tdmis_jtag_tap u_tap (
        .CLK              (CLK),
        .DBGTCKEN         (DBGTCKEN),
        .DBGnTRST         (DBGnTRST),
        .DBGTMS           (DBGTMS),
        .DBGTDI           (DBGTDI),
        .DBGTDO           (DBGTDO),
        .DBGnTDOEN        (DBGnTDOEN),
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
        .ice_inject_instr (tap_inject_instr),
        .ice_inject_break (tap_inject_break),
        .ice_inject_we    (tap_inject_we),
        .tap_restart_req  (tap_restart_req)
    );

    // tap_inject_break (DBGBREAK control cell from chain 1) is still a
    // placeholder consumed only by the future "system-speed vs debug-speed"
    // distinction in the debug-state FSM.
    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused_inject = &{1'b0, tap_inject_break};
    /* verilator lint_on UNUSEDSIGNAL */

    // TAP observers used by §22 debug FSM later — silence lint for now.
    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused_tap = &{1'b0,
        tap_current_ir, tap_in_shift_dr, tap_in_update_dr, tap_in_capture_dr
    };
    /* verilator lint_on UNUSEDSIGNAL */

    // All major DBG* inputs now consumed; nothing to drain.

endmodule
