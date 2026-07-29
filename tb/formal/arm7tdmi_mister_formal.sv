// VAL-007 proof harness for the canonical MiSTer request/response bridge.
//
// The environment may stop CPU_CE and may backpressure any request.  The
// only liveness assumptions are explicit bounded-fairness constraints; all
// request payloads and core behavior come from the real wrapper and core.

module arm7tdmi_mister_formal (
    input logic        CLK,
    input logic        CPU_CE,
    input logic        MEM_READY,
    input logic [31:0] MEM_RDATA,
    input logic        MEM_ERROR
);
    logic [7:0] f_cycle = 8'd0;
    logic       f_past_valid = 1'b0;
    wire        RESET_N = (f_cycle != 8'd0);

    logic        MEM_VALID;
    logic [31:0] MEM_ADDR;
    logic        MEM_WRITE;
    logic [31:0] MEM_WDATA;
    logic [3:0]  MEM_BYTE_ENABLE;
    logic        MEM_CODE;
    logic        MEM_PRIVILEGED;
    logic        MEM_LOCK;
    logic        MEM_SEQUENTIAL;
    logic        MEM_MORE;
    logic        CPnMREQ;
    logic        CPSEQ;
    logic        CPnTRANS;
    logic        CPnOPC;
    logic        CPTBIT;
    logic        CPnI;
    logic        DBG_STEP_READY;
    logic        DBG_STEP_RSP_VALID;
    logic        DBG_STEP_TDO;
    logic        DBG_STEP_TDO_OE;
    logic        DBGACK;
    logic        DBGnEXEC;
    logic        DBGINSTRVALID;
    logic [1:0]  DBGRNG;
    logic        DBGCOMMTX;
    logic        DBGCOMMRX;

    arm7tdmi_mister dut (
        .CLK,
        .RESET_N,
        .CPU_CE,
        .IRQ_ASYNC          (1'b0),
        .FIQ_ASYNC          (1'b0),
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
        .CPnMREQ,
        .CPSEQ,
        .CPnTRANS,
        .CPnOPC,
        .CPTBIT,
        .CPnI,
        .CPA                (1'b1),
        .CPB                (1'b1),
        .DEBUG_ENABLE_ASYNC (1'b0),
        .DBGRQ_ASYNC        (1'b0),
        .DBGBREAK_ASYNC     (1'b0),
        .DBGEXT_ASYNC       (2'b00),
        .DBG_STEP_VALID     (1'b0),
        .DBG_STEP_READY,
        .DBG_STEP_TMS       (1'b0),
        .DBG_STEP_TDI       (1'b0),
        .DBG_STEP_RSP_VALID,
        .DBG_STEP_RSP_READY (1'b1),
        .DBG_STEP_TDO,
        .DBG_STEP_TDO_OE,
        .DBGACK,
        .DBGnEXEC,
        .DBGINSTRVALID,
        .DBGRNG,
        .DBGCOMMTX,
        .DBGCOMMRX
    );

    wire completion = dut.core_clken && dut.bus_waiting
                    && dut.response_available;
    wire [73:0] request_payload = {
        MEM_ADDR, MEM_WRITE, MEM_WDATA, MEM_BYTE_ENABLE, MEM_CODE,
        MEM_PRIVILEGED, MEM_LOCK, MEM_SEQUENTIAL, MEM_MORE
    };

    logic [2:0] cpu_wait_q;
    logic [2:0] memory_wait_q;
    logic [3:0] bridge_wait_q;

    always_ff @(posedge CLK) begin
        f_past_valid <= 1'b1;
        if (f_cycle != 8'hff)
            f_cycle <= f_cycle + 8'd1;

        if (!RESET_N || CPU_CE)
            cpu_wait_q <= 3'd0;
        else
            cpu_wait_q <= cpu_wait_q + 3'd1;
        assume (cpu_wait_q < 3'd4);

        if (!RESET_N || !MEM_VALID || MEM_READY)
            memory_wait_q <= 3'd0;
        else
            memory_wait_q <= memory_wait_q + 3'd1;
        assume (memory_wait_q < 3'd4);

        if (!RESET_N || !dut.bus_waiting || completion)
            bridge_wait_q <= 4'd0;
        else
            bridge_wait_q <= bridge_wait_q + 4'd1;

        if (dut.wrapper_reset_n) begin
            assert (!(dut.request_valid_q && dut.response_valid_q));
            assert (!completion || dut.bus_waiting);
            assert (!dut.memory_accept || dut.request_valid_q);
            assert (bridge_wait_q < 4'd12);
        end

        if (f_past_valid && $past(dut.wrapper_reset_n)) begin
            // A captured request cannot disappear before target acceptance,
            // and no newly visible request can be manufactured while the
            // raw CPU interface is stopped.
            if ($past(dut.request_valid_q && !dut.memory_accept))
                assert (dut.request_valid_q);
            if (dut.request_valid_q && !$past(dut.request_valid_q))
                assert ($past(dut.core_clken));

            if ($past(MEM_VALID && !MEM_READY)) begin
                assert (MEM_VALID);
                assert (request_payload == $past(request_payload));
            end

            // A target response that arrives while the CPU is stopped is
            // buffered exactly once, and cannot disappear before an enabled
            // core edge consumes it.
            if ($past(dut.memory_accept && !dut.core_clken))
                assert (dut.response_valid_q);
            if ($past(dut.response_valid_q && !dut.core_clken)) begin
                assert (dut.response_valid_q);
                assert (dut.response_data_q == $past(dut.response_data_q));
                assert (dut.response_error_q == $past(dut.response_error_q));
            end
            if (dut.response_valid_q && !$past(dut.response_valid_q)) begin
                assert ($past(dut.memory_accept && !dut.core_clken));
            end
        end
    end
endmodule
