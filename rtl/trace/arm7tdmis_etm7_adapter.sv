// ARM7TDMI-S Rev 4 to external ETM7 signal adapter.
//
// This is the transparent wiring contract from ARM DDI 0234B Table 6-1.
// It is not an ETM implementation and stores no trace.  An integrator
// instantiates an ETM7-compatible macrocell beside the raw processor and
// connects that macrocell through these explicitly named ports.

module arm7tdmis_etm7_adapter (
    // ARM7TDMI-S-side signals.
    input  logic        CLK,
    input  logic        CLKEN,
    input  logic        nRESET,
    input  logic        DBGnTRST,
    input  logic        CFGBIGEND,
    input  logic [31:0] ADDR,
    input  logic        ABORT,
    input  logic        CPA,
    input  logic        CPB,
    input  logic        DBGACK,
    input  logic        CPnMREQ,
    input  logic        CPSEQ,
    input  logic [1:0]  SIZE,
    input  logic        CPnI,
    input  logic        DBGnEXEC,
    input  logic        CPnOPC,
    input  logic        WRITE,
    input  logic [1:0]  DBGRNG,
    input  logic [31:0] RDATA,
    input  logic        CPTBIT,
    input  logic        DBGTCKEN,
    input  logic        DBGTDI,
    input  logic        DBGTDO,
    input  logic        DBGTMS,
    input  logic [31:0] WDATA,
    input  logic        DBGINSTRVALID,
    output logic        CPU_DBGRQ,

    // ETM7-side signals. ETM_DBGRQ is the macrocell's request output.
    input  logic        ETM_DBGRQ,
    output logic        ETM_CLK,
    output logic        ETM_TCK,
    output logic        ETM_CLKEN,
    output logic        ETM_nRESET,
    output logic        ETM_nTRST,
    output logic        ETM_BIGEND,
    output logic [31:0] ETM_A,
    output logic        ETM_ABORT,
    output logic        ETM_CPA,
    output logic        ETM_CPB,
    output logic        ETM_DBGACK,
    output logic        ETM_nMREQ,
    output logic        ETM_SEQ,
    output logic [1:0]  ETM_MAS,
    output logic        ETM_nCPI,
    output logic        ETM_nEXEC,
    output logic        ETM_nOPC,
    output logic        ETM_nRW,
    output logic [1:0]  ETM_RANGEOUT,
    output logic [31:0] ETM_RDATA,
    output logic        ETM_TBIT,
    output logic        ETM_TCKEN,
    output logic        ETM_TDI,
    output logic        ETM_TDO,
    output logic        ETM_ARMTDO,
    output logic        ETM_TMS,
    output logic [31:0] ETM_WDATA,
    output logic        ETM_INSTRVALID,
    output logic [31:0] ETM_PROCID,
    output logic        ETM_PROCIDWR
);

    assign ETM_CLK        = CLK;
    assign ETM_TCK        = CLK;
    assign ETM_CLKEN      = CLKEN;
    assign ETM_nRESET     = nRESET;
    assign ETM_nTRST      = DBGnTRST;
    assign ETM_BIGEND     = CFGBIGEND;
    assign ETM_A          = ADDR;
    assign ETM_ABORT      = ABORT;
    assign ETM_CPA        = CPA;
    assign ETM_CPB        = CPB;
    assign ETM_DBGACK     = DBGACK;
    assign CPU_DBGRQ      = ETM_DBGRQ;
    assign ETM_nMREQ      = CPnMREQ;
    assign ETM_SEQ        = CPSEQ;
    assign ETM_MAS        = SIZE;
    assign ETM_nCPI       = CPnI;
    assign ETM_nEXEC      = DBGnEXEC;
    assign ETM_nOPC       = CPnOPC;
    assign ETM_nRW        = WRITE;
    assign ETM_RANGEOUT   = DBGRNG;
    assign ETM_RDATA      = RDATA;
    assign ETM_TBIT       = CPTBIT;
    assign ETM_TCKEN      = DBGTCKEN;
    assign ETM_TDI        = DBGTDI;
    assign ETM_TDO        = DBGTDO;
    assign ETM_ARMTDO     = DBGTDO;
    assign ETM_TMS        = DBGTMS;
    assign ETM_WDATA      = WDATA;
    assign ETM_INSTRVALID = DBGINSTRVALID;

    // ARM7TDMI-S has no process/context ID source.
    assign ETM_PROCID     = 32'h0000_0000;
    assign ETM_PROCIDWR   = 1'b0;

endmodule
