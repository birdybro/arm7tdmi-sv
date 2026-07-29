// Chip-level wrapper around arm7tdmis_top (TASKS.md §25).
//
// Adds the DFT (Design For Test) pin set that production scan-insertion
// tools (Quartus Test Bench Generator, Mentor TBX, or Tessent ScanPro)
// would consume. At the RTL level the scan chain is empty — the wrapper
// just exposes the pins. Actual scan-flop stitching happens during synth
// when the tool sees the SE/SI/SO ports and the design's flops.
//
// Pin set:
//   SE  — Scan enable. HIGH switches all scan-DFT flops from functional
//         to scan mode. Drive from the FPGA pin per §30.25.1.
//   SI  — Scan in. Per the scan order produced by the synth tool.
//   SO  — Scan out. Endpoint of the longest scan chain.
//
// For our greenfield (no scan-DFT insertion yet) SO is tied LOW and
// SE/SI are sunk into the unused-signal drain. The pin shapes are
// stable so that a real scan-insertion flow can swap in later
// without changing the top-level chip pin list.

module arm7tdmis_chip
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

    // DFT pins (TASKS.md §25)
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
    );

    // Pre-DFT-insertion: SO ties LOW, SE/SI sunk.
    assign SO = 1'b0;
    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused_dft = &{1'b0, SE, SI};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
