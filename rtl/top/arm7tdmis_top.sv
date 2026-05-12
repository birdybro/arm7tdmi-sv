// Top-level ARM7TDMI-S r4p3. Pin names match the TRM exactly per
// TASKS.md §1.4 / CLAUDE.md so downstream tests, the ETM wrapper (§24),
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
    // core_halt freezes the entire core pipeline by gating its CLKEN:
    // every internal always_ff in the core is `if (CLKEN) ...`, so a
    // single AND at the top suffices. The memory model still ticks with
    // the unmodified CLKEN so a debugger can drive bus accesses via
    // scan-chain-2 / chain-1 without losing the core's frozen state.
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
        .core_dcc_we    (core_dcc_we),
        .core_dcc_wdata (core_dcc_wdata),
        .core_dcc_rdata (core_dcc_rdata)
    );

    // ---- EmbeddedICE-RT (§22 scaffold) ----
    // Watchpoint comparators only at this milestone — full debug-state
    // FSM, CHAIN/RANGE coupling, and scan-chain-2 wiring land later.
    logic       ice_dbg_break;
    logic [1:0] ice_dbgrng;

    logic ice_dbg_ack;
    logic ice_ifen;
    logic ice_core_halt;
    logic tap_restart_req;
    logic        core_dcc_we;
    logic [31:0] core_dcc_wdata;
    logic [31:0] core_dcc_rdata;

    arm7tdmis_ice_rt u_ice (
        .CLK                (CLK),
        .CLKEN              (CLKEN),
        .DBGnTRST           (DBGnTRST),
        .DBGEN              (DBGEN),
        .watch_addr         (ADDR),
        .watch_data         (WRITE ? WDATA : RDATA),
        .watch_nopc         (PROT[0]),         // PROT[0]=1 → data access
        .watch_nrw          (WRITE),
        .watch_size         (SIZE),
        .watch_tbit         (CPTBIT),
        .watch_extern       (DBGEXT),
        .watch_priv         (PROT[1]),     // current privilege bit
        .dbg_rq_in          (DBGRQ),       // §22: synchronized inside ICE-RT
        .dbg_break_in       (DBGBREAK),    // §22: synchronized inside ICE-RT
        .tap_restart_req    (tap_restart_req),
        .dbg_break_internal (ice_dbg_break),
        .dbg_ack            (ice_dbg_ack),
        .ifen               (ice_ifen),
        .core_halt          (ice_core_halt),
        .DBGRNG             (ice_dbgrng),
        .scan_we            (ice_scan_we),
        .scan_addr          (ice_scan_addr),
        .scan_wdata         (ice_scan_wdata),
        .scan_rdata         (ice_scan_rdata),
        .core_dcc_we        (core_dcc_we),
        .core_dcc_wdata     (core_dcc_wdata),
        .core_dcc_rdata     (core_dcc_rdata)
    );

    assign DBGRNG = ice_dbgrng;
    assign DBGACK = ice_dbg_ack;

    // DBGCOMM* still tied off — CP14 DCC (§20) wires those when DCC data
    // transfer lands.
    assign DBGCOMMTX     = 1'b0;
    assign DBGCOMMRX     = 1'b0;

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
    logic [31:0]  ice_scan_rdata;

    logic [31:0] tap_inject_instr;
    logic        tap_inject_break;
    logic        tap_inject_we;

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
        .ice_scan_rdata   (ice_scan_rdata),
        .ice_inject_instr (tap_inject_instr),
        .ice_inject_break (tap_inject_break),
        .ice_inject_we    (tap_inject_we),
        .tap_restart_req  (tap_restart_req)
    );

    // §22 chain-1 instruction injection: the TAP latches the 33-bit
    // value on Update-DR; the core-side path that scans this into the
    // pipeline during halt-mode debug state lands when the debug-state
    // instruction-inject FSM does. For now the latch contents are
    // observable for testbench-level JTAG flows but don't yet affect
    // core execution.
    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused_inject = &{1'b0,
        tap_inject_instr, tap_inject_break, tap_inject_we
    };
    /* verilator lint_on UNUSEDSIGNAL */

    // TAP observers used by §22 debug FSM later — silence lint for now.
    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused_tap = &{1'b0,
        tap_current_ir, tap_in_shift_dr, tap_in_update_dr, tap_in_capture_dr
    };
    /* verilator lint_on UNUSEDSIGNAL */

    // All major DBG* inputs now consumed; nothing to drain.

endmodule
