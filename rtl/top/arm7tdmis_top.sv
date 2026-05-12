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
    arm7tdmis_core_pipelined u_core (
        .CLK       (CLK),
        .CLKEN     (CLKEN),
        .nRESET    (core_nreset),
        .CFGBIGEND (CFGBIGEND),
        .nIRQ      (nIRQ),
        .nFIQ      (nFIQ),
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
        .DBGINSTRVALID (DBGINSTRVALID)
    );

    // ---- Debug status (DBGACK / DBGRNG / DBGCOMM* land with §22 ICE-RT,
    //      §20 DCC; DBGnEXEC and DBGINSTRVALID are now driven by the core
    //      directly per §24).
    assign DBGACK        = 1'b0;
    assign DBGRNG        = 2'b00;
    assign DBGCOMMTX     = 1'b0;
    assign DBGCOMMRX     = 1'b0;

    // ---- JTAG TAP (§23) ----
    ir_e          tap_current_ir;
    logic         tap_in_shift_dr;
    logic         tap_in_update_dr;
    logic         tap_in_capture_dr;

    arm7tdmis_jtag_tap u_tap (
        .CLK           (CLK),
        .DBGTCKEN      (DBGTCKEN),
        .DBGnTRST      (DBGnTRST),
        .DBGTMS        (DBGTMS),
        .DBGTDI        (DBGTDI),
        .DBGTDO        (DBGTDO),
        .DBGnTDOEN     (DBGnTDOEN),
        .current_ir    (tap_current_ir),
        .in_shift_dr   (tap_in_shift_dr),
        .in_update_dr  (tap_in_update_dr),
        .in_capture_dr (tap_in_capture_dr)
    );

    // TAP observers used by §22 EmbeddedICE-RT later — silence lint for now.
    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused_tap = &{1'b0,
        tap_current_ir, tap_in_shift_dr, tap_in_update_dr, tap_in_capture_dr
    };
    /* verilator lint_on UNUSEDSIGNAL */

    // ---- Inputs not yet consumed (debug-status pins, until §22) ----
    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused_inputs = &{1'b0,
        DBGEN, DBGRQ, DBGBREAK, DBGEXT
    };
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
