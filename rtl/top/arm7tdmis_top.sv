// Top-level ARM7TDMI-S r4p3 port shell. Pin names match the TRM exactly
// (uppercase, with lowercase `n` prefix for active-low signals) per
// TASKS.md §1.4 and CLAUDE.md. Downstream tests, the ETM wrapper (§24),
// and the scan wrapper (§25) all assume these names.
//
// At §1 this module is a port shell only: outputs tied to safe idle
// defaults, inputs declared but unused. Real drivers replace the
// defaults starting in §3 (programmer state) and roll forward through
// the milestones.

module arm7tdmis_top
    import arm7tdmis_bus_pkg::*;
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

    // Memory bus (address-class signals lead the data cycle by one bus cycle)
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

    // ---- Memory bus: idle, post-reset shape ----
    assign ADDR  = 32'h0;
    assign WRITE = WRITE_READ;
    assign SIZE  = 2'(SIZE_WORD);
    assign PROT  = 2'(PROT_OPC_PRIV);   // privileged opcode fetch
    assign LOCK  = LOCK_FREE;
    assign TRANS = 2'(TRANS_I);         // idle until execution begins
    assign WDATA = 32'h0;

    // ---- Coprocessor: no request, ARM state, active-low signals deasserted ----
    assign CPnMREQ  = 1'b1;
    assign CPSEQ    = 1'b0;
    assign CPnTRANS = 1'b1;             // privileged
    assign CPnOPC   = 1'b1;
    assign CPTBIT   = 1'b0;             // ARM state
    assign CPnI     = 1'b1;             // not a coprocessor instruction

    // ---- Debug status ----
    assign DBGACK        = 1'b0;
    assign DBGnEXEC      = 1'b1;        // HIGH = no instruction in Execute
    assign DBGINSTRVALID = 1'b0;
    assign DBGRNG        = 2'b00;
    assign DBGCOMMTX     = 1'b0;
    assign DBGCOMMRX     = 1'b0;

    // ---- JTAG TAP ----
    assign DBGTDO    = 1'b0;
    assign DBGnTDOEN = 1'b1;            // HiZ until the TAP drives

    // ---- LDM/STM continuation hint ----
    assign DMORE = 1'b0;

    // Inputs are intentionally unused at this milestone. Reduction-XOR them
    // into a discarded wire to keep both the linter and a future grep happy.
    // Remove this block once §3 starts wiring real logic.
    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused_inputs = &{1'b0,
        CLK, CLKEN, nRESET, CFGBIGEND, nIRQ, nFIQ, ABORT, RDATA,
        CPA, CPB,
        DBGEN, DBGRQ, DBGBREAK, DBGEXT,
        DBGTCKEN, DBGTMS, DBGTDI, DBGnTRST
    };
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
