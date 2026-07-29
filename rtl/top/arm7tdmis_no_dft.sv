// Explicit no-DFT compatibility wrapper around arm7tdmis_top.
//
// This facade preserves the legacy SE/SI/SO pin shape for a containing
// project that needs a deterministic non-scan build. It does not implement,
// infer, or claim a scan chain: SE and SI are ignored and SO is always LOW.
// It is excluded from the FPGA source package. A future ASIC DFT profile
// requires its own insertion specification, generated chain manifest, and
// structural/shift proof; this wrapper is not a substitute for that work.

module arm7tdmis_no_dft
    import arm7tdmis_bus_pkg::*, arm7tdmis_debug_pkg::*;
  #(
    parameter logic [3:0]  JTAG_VERSION = JTAG_DEFAULT_VERSION,
    parameter logic [15:0] JTAG_PART_NUMBER = JTAG_DEFAULT_PART_NUMBER,
    parameter logic [10:0] JTAG_MANUFACTURER_ID =
        JTAG_DEFAULT_MANUFACTURER_ID
  )
(
    // Same pin list as arm7tdmis_top, in the same order
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
    output logic        DMORE,

    // Deliberately nonfunctional legacy scan-shaped pins.
    input  logic        SE,
    input  logic        SI,
    output logic        SO
);

    arm7tdmis_top #(
        .JTAG_VERSION         (JTAG_VERSION),
        .JTAG_PART_NUMBER     (JTAG_PART_NUMBER),
        .JTAG_MANUFACTURER_ID (JTAG_MANUFACTURER_ID)
    ) u_top (
        .CLK            (CLK),
        .CLKEN          (CLKEN),
        .nRESET         (nRESET),
        .CFGBIGEND      (CFGBIGEND),
        .nIRQ           (nIRQ),
        .nFIQ           (nFIQ),
        .ABORT          (ABORT),
        .ADDR           (ADDR),
        .WRITE          (WRITE),
        .SIZE           (SIZE),
        .PROT           (PROT),
        .LOCK           (LOCK),
        .TRANS          (TRANS),
        .WDATA          (WDATA),
        .RDATA          (RDATA),
        .CPnMREQ        (CPnMREQ),
        .CPSEQ          (CPSEQ),
        .CPnTRANS       (CPnTRANS),
        .CPnOPC         (CPnOPC),
        .CPTBIT         (CPTBIT),
        .CPnI           (CPnI),
        .CPA            (CPA),
        .CPB            (CPB),
        .DBGEN          (DBGEN),
        .DBGRQ          (DBGRQ),
        .DBGBREAK       (DBGBREAK),
        .DBGACK         (DBGACK),
        .DBGnEXEC       (DBGnEXEC),
        .DBGINSTRVALID  (DBGINSTRVALID),
        .DBGEXT         (DBGEXT),
        .DBGRNG         (DBGRNG),
        .DBGCOMMTX      (DBGCOMMTX),
        .DBGCOMMRX      (DBGCOMMRX),
        .DBGTCKEN       (DBGTCKEN),
        .DBGTMS         (DBGTMS),
        .DBGTDI         (DBGTDI),
        .DBGTDO         (DBGTDO),
        .DBGnTRST       (DBGnTRST),
        .DBGnTDOEN      (DBGnTDOEN),
        .DMORE          (DMORE)
`ifdef ARM7TDMIS_VERIFICATION
        ,
        .VER_RETIRE_VALID(ver_retire_unused[0]),
        .VER_RETIRE_PC(ver_retire_unused[32:1]),
        .VER_RETIRE_OPCODE(ver_retire_unused[64:33]),
        .VER_RETIRE_THUMB(ver_retire_unused[65]),
        .VER_RETIRE_CONDITION_PASS(ver_retire_unused[66]),
        .VER_RETIRE_INJECTED(ver_retire_unused[67]),
        .VER_RETIRE_EXCEPTION_VALID(ver_retire_unused[68]),
        .VER_RETIRE_EXCEPTION(ver_retire_unused[71:69]),
        .VER_RETIRE_GPRS(ver_retire_unused[1063:72]),
        .VER_RETIRE_CPSR(ver_retire_unused[1095:1064]),
        .VER_RETIRE_SPSRS(ver_retire_unused[1255:1096])
`endif
    );

`ifdef ARM7TDMIS_VERIFICATION
    wire [1255:0] ver_retire_unused;
    wire _unused_ver_retire = &{1'b0, ver_retire_unused};
`endif

    // No DFT implementation: deterministic tie-off by contract.
    assign SO = 1'b0;
    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused_no_dft = &{1'b0, SE, SI};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
