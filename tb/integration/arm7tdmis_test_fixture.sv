// Shared pin-level fixture for focused integration regressions.
//
// The fixture deliberately exposes the raw ARM7TDMI-S bus through hierarchy
// and does not peek into the core to drive behavior. Legacy directed tests
// retain read-only hierarchical checks; new architectural scoreboards use
// arm7tdmis_top's ARM7TDMIS_VERIFICATION retirement contract instead.

module arm7tdmis_test_fixture
    import arm7tdmis_bus_pkg::*;
#(
    parameter int    RESET_CYCLES = 4,
    parameter int    CYCLE_LIMIT  = 256,
    parameter int    MEMORY_WORDS = 4096,
    parameter string INIT_HEX     = "",
    parameter string TEST_NAME    = "integration",
    parameter string FST_FILE     = "integration.fst",
    parameter bit    ABORT_DURING_INACTIVE = 1'b0
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
    logic        mem_abort;

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
`ifdef ARM7TDMIS_SAVE_STATE
        ,
        .STATE_CAPTURE  (1'b0),
        .STATE_RESUME   (1'b0),
        .STATE_WRITE    (1'b0),
        .STATE_INDEX    (6'h00),
        .STATE_WDATA    (32'h0000_0000),
        .STATE_BOUNDARY (state_unused[0]),
        .STATE_RDATA    (state_unused[32:1])
`endif
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

`ifdef ARM7TDMIS_SAVE_STATE
    wire [32:0] state_unused;
    wire _unused_state = &{1'b0, state_unused};
`endif

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
        .ABORT        (mem_abort),
        .inject_abort (inject_abort)
    );

    // BUS-007 verification hook. ABORT is data-timed, so classify the
    // response with the memory model's latched TRANS rather than the core's
    // live address-class output. This deliberately drives ABORT only for an
    // I/C response and cannot feed the core's bus presentation back into its
    // exception selector.
    wire inactive_response = !u_mem.is_active_q;
    assign ABORT = mem_abort
                 | (ABORT_DURING_INACTIVE && nRESET && CLKEN
                    && inactive_response);

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
