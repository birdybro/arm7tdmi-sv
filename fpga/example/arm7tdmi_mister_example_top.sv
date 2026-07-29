// Minimal public-boundary example for a host memory controller.
//
// All ports are in CLK's domain except RESET_N and the explicitly named
// asynchronous interrupt levels. Debug and an external coprocessor are trimmed
// here; a host that needs either can instantiate arm7tdmi_mister directly.

module arm7tdmi_mister_example_top #(
    parameter bit BIG_ENDIAN = 1'b0
) (
    input  logic        CLK,
    input  logic        RESET_N,
    input  logic        CPU_CE,
    input  logic        IRQ_ASYNC,
    input  logic        FIQ_ASYNC,

    output logic        MEM_VALID,
    input  logic        MEM_READY,
    output logic [31:0] MEM_ADDR,
    output logic        MEM_WRITE,
    output logic [31:0] MEM_WDATA,
    output logic [3:0]  MEM_BYTE_ENABLE,
    output logic        MEM_CODE,
    output logic        MEM_PRIVILEGED,
    output logic        MEM_LOCK,
    output logic        MEM_SEQUENTIAL,
    output logic        MEM_MORE,
    input  logic [31:0] MEM_RDATA,
    input  logic        MEM_ERROR
);

    logic       cpnmreq_unused;
    logic       cpseq_unused;
    logic       cpntrans_unused;
    logic       cpnopc_unused;
    logic       cptbit_unused;
    logic       cpni_unused;
    logic       dbg_step_ready_unused;
    logic       dbg_step_rsp_valid_unused;
    logic       dbg_step_tdo_unused;
    logic       dbg_step_tdo_oe_unused;
    logic       dbgack_unused;
    logic       dbgnexec_unused;
    logic       dbginstrvalid_unused;
    logic [1:0] dbgrng_unused;
    logic       dbgcommtx_unused;
    logic       dbgcommrx_unused;

    arm7tdmi_mister #(
        .BIG_ENDIAN       (BIG_ENDIAN),
        .ENABLE_DEBUG     (1'b0),
        .ENABLE_COPROCESSOR(1'b0)
    ) u_cpu (
        .CLK,
        .RESET_N,
        .CPU_CE,
        .IRQ_ASYNC,
        .FIQ_ASYNC,
        .MEM_VALID,
        .MEM_READY,
        .MEM_ADDR,
        .MEM_WRITE,
        .MEM_WDATA,
        .MEM_BYTE_ENABLE,
        .MEM_CODE,
        .MEM_PRIVILEGED,
        .MEM_LOCK,
        .MEM_SEQUENTIAL,
        .MEM_MORE,
        .MEM_RDATA,
        .MEM_ERROR,
        .CPnMREQ          (cpnmreq_unused),
        .CPSEQ            (cpseq_unused),
        .CPnTRANS         (cpntrans_unused),
        .CPnOPC           (cpnopc_unused),
        .CPTBIT           (cptbit_unused),
        .CPnI             (cpni_unused),
        .CPA              (1'b1),
        .CPB              (1'b1),
        .DEBUG_ENABLE_ASYNC(1'b0),
        .DBGRQ_ASYNC      (1'b0),
        .DBGBREAK_ASYNC   (1'b0),
        .DBGEXT_ASYNC     (2'b00),
        .DBG_STEP_VALID   (1'b0),
        .DBG_STEP_READY   (dbg_step_ready_unused),
        .DBG_STEP_TMS     (1'b0),
        .DBG_STEP_TDI     (1'b0),
        .DBG_STEP_RSP_VALID(dbg_step_rsp_valid_unused),
        .DBG_STEP_RSP_READY(1'b1),
        .DBG_STEP_TDO     (dbg_step_tdo_unused),
        .DBG_STEP_TDO_OE  (dbg_step_tdo_oe_unused),
        .DBGACK           (dbgack_unused),
        .DBGnEXEC         (dbgnexec_unused),
        .DBGINSTRVALID    (dbginstrvalid_unused),
        .DBGRNG           (dbgrng_unused),
        .DBGCOMMTX        (dbgcommtx_unused),
        .DBGCOMMRX        (dbgcommrx_unused)
    );

    // These are deliberately unused in the trimmed example profile.
    wire _unused_optional_outputs = &{
        1'b0,
        cpnmreq_unused,
        cpseq_unused,
        cpntrans_unused,
        cpnopc_unused,
        cptbit_unused,
        cpni_unused,
        dbg_step_ready_unused,
        dbg_step_rsp_valid_unused,
        dbg_step_tdo_unused,
        dbg_step_tdo_oe_unused,
        dbgack_unused,
        dbgnexec_unused,
        dbginstrvalid_unused,
        dbgrng_unused,
        dbgcommtx_unused,
        dbgcommrx_unused
    };

endmodule
