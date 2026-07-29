// Nondeterministic raw-core model for proving the MiSTer bridge in isolation.
//
// Every raw output may change on every clock.  The bridge therefore cannot
// rely on implementation-specific CPU behavior to keep a captured request or
// write-data phase stable; it must own all externally advertised state.

module arm7tdmis_top
    import arm7tdmis_debug_pkg::*;
  #(
    parameter logic [3:0]  JTAG_VERSION = JTAG_DEFAULT_VERSION,
    parameter logic [15:0] JTAG_PART_NUMBER = JTAG_DEFAULT_PART_NUMBER,
    parameter logic [10:0] JTAG_MANUFACTURER_ID =
        JTAG_DEFAULT_MANUFACTURER_ID
  )
(
    input  logic        CLK,
    input  logic        CLKEN,
    input  logic        nRESET,
    input  logic        CFGBIGEND,
    input  logic        nIRQ,
    input  logic        nFIQ,
    input  logic        ABORT,
    output logic [31:0] ADDR,
    output logic        WRITE,
    output logic [1:0]  SIZE,
    output logic [1:0]  PROT,
    output logic        LOCK,
    output logic [1:0]  TRANS,
    output logic [31:0] WDATA,
    input  logic [31:0] RDATA,
    output logic        CPnMREQ,
    output logic        CPSEQ,
    output logic        CPnTRANS,
    output logic        CPnOPC,
    output logic        CPTBIT,
    output logic        CPnI,
    input  logic        CPA,
    input  logic        CPB,
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
    input  logic        DBGTCKEN,
    input  logic        DBGTMS,
    input  logic        DBGTDI,
    output logic        DBGTDO,
    input  logic        DBGnTRST,
    output logic        DBGnTDOEN,
    output logic        DMORE
);
    (* anyseq *) logic [87:0] f_core_outputs;

    assign {
        ADDR,
        WRITE,
        SIZE,
        PROT,
        LOCK,
        TRANS,
        WDATA,
        CPnMREQ,
        CPSEQ,
        CPnTRANS,
        CPnOPC,
        CPTBIT,
        CPnI,
        DBGACK,
        DBGnEXEC,
        DBGINSTRVALID,
        DBGRNG,
        DBGCOMMTX,
        DBGCOMMRX,
        DBGTDO,
        DBGnTDOEN,
        DMORE
    } = f_core_outputs;

    wire _unused_inputs = &{
        1'b0, CLK, CLKEN, nRESET, CFGBIGEND, nIRQ, nFIQ, ABORT, RDATA,
        CPA, CPB, DBGEN, DBGRQ, DBGBREAK, DBGEXT, DBGTCKEN, DBGTMS,
        DBGTDI, DBGnTRST, JTAG_VERSION, JTAG_PART_NUMBER,
        JTAG_MANUFACTURER_ID
    };
endmodule
