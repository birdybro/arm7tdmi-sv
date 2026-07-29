// Shared pin-level fixture for focused integration regressions.
//
// The fixture deliberately exposes the raw ARM7TDMI-S bus through hierarchy
// and does not peek into the core to drive behavior. Tests may inspect
// architectural state through u_dut until VER-009's retirement interface
// replaces those read-only hierarchical checks.

module arm7tdmis_test_fixture
    import arm7tdmis_bus_pkg::*;
#(
    parameter int    RESET_CYCLES = 4,
    parameter int    CYCLE_LIMIT  = 256,
    parameter int    MEMORY_WORDS = 4096,
    parameter string INIT_HEX     = "",
    parameter string TEST_NAME    = "integration",
    parameter string FST_FILE     = "integration.fst"
) (
    input  logic CFGBIGEND,
    input  logic CLKEN,
    input  logic nIRQ,
    input  logic nFIQ,
    input  logic inject_abort,
    output logic CLK,
    output logic nRESET
);

    localparam int CLK_HALF_PERIOD = 5;

    initial begin
        CLK = 1'b0;
        forever #(CLK_HALF_PERIOD) CLK = ~CLK;
    end

    initial begin
        nRESET = 1'b0;
        repeat (RESET_CYCLES) @(posedge CLK);
        nRESET = 1'b1;
    end

    logic [31:0] ADDR;
    logic        WRITE;
    logic [1:0]  SIZE;
    logic [1:0]  PROT;
    logic        LOCK;
    logic [1:0]  TRANS;
    logic [31:0] WDATA;
    logic [31:0] RDATA;
    logic        ABORT;

    logic CPnMREQ;
    logic CPSEQ;
    logic CPnTRANS;
    logic CPnOPC;
    logic CPTBIT;
    logic CPnI;

    logic       DBGACK;
    logic       DBGnEXEC;
    logic       DBGINSTRVALID;
    logic [1:0] DBGRNG;
    logic       DBGCOMMTX;
    logic       DBGCOMMRX;
    logic       DBGTDO;
    logic       DBGnTDOEN;
    logic       DMORE;

    arm7tdmis_top u_dut (
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
        .CPA            (1'b1),
        .CPB            (1'b1),
        .DBGEN          (1'b0),
        .DBGRQ          (1'b0),
        .DBGBREAK       (1'b0),
        .DBGACK         (DBGACK),
        .DBGnEXEC       (DBGnEXEC),
        .DBGINSTRVALID  (DBGINSTRVALID),
        .DBGEXT         (2'b00),
        .DBGRNG         (DBGRNG),
        .DBGCOMMTX      (DBGCOMMTX),
        .DBGCOMMRX      (DBGCOMMRX),
        .DBGTCKEN       (1'b0),
        .DBGTMS         (1'b0),
        .DBGTDI         (1'b0),
        .DBGTDO         (DBGTDO),
        .DBGnTRST       (1'b1),
        .DBGnTDOEN      (DBGnTDOEN),
        .DMORE          (DMORE)
    );

    arm7tdmis_memory #(
        .WORDS    (MEMORY_WORDS),
        .INIT_HEX (INIT_HEX)
    ) u_mem (
        .CLK          (CLK),
        .CLKEN        (CLKEN),
        .nRESET       (nRESET),
        .CFGBIGEND    (CFGBIGEND),
        .ADDR         (ADDR),
        .WRITE        (WRITE),
        .SIZE         (SIZE),
        .PROT         (PROT),
        .LOCK         (LOCK),
        .TRANS        (TRANS),
        .WDATA        (WDATA),
        .RDATA        (RDATA),
        .ABORT        (ABORT),
        .inject_abort (inject_abort)
    );

    arm7tdmis_assertions u_assert (
        .CLK    (CLK),
        .nRESET (nRESET),
        .SIZE   (SIZE),
        .ABORT  (ABORT),
        .TRANS  (TRANS)
    );

    initial begin
        $dumpfile(FST_FILE);
        $dumpvars(0, arm7tdmis_test_fixture);
    end

    initial begin
        repeat (CYCLE_LIMIT) @(posedge CLK);
        $fatal(1, "[%s] TIMEOUT after %0d cycles", TEST_NAME, CYCLE_LIMIT);
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused_outputs = &{1'b0,
        CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI,
        DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG,
        DBGCOMMTX, DBGCOMMRX, DBGTDO, DBGnTDOEN, DMORE
    };
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
