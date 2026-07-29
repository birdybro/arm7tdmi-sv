// Synchronous FPGA transport for the ARM7TDMI-S DBGTCKEN TAP interface.
//
// This is deliberately not an asynchronous JTAG/TCK bridge. The command and
// response channels are both synchronous to CLK, so an FPGA framework can
// serialize JTAG operations from a soft host without introducing another
// clock domain. One accepted STEP command emits one DBGTCKEN pulse. DBGTDO
// and DBGnTDOEN are sampled on that same CLK edge before the TAP advances,
// matching the serial value visible for the requested virtual TCK edge.
//
// A one-entry elastic response buffer applies backpressure to STEP_READY.
// When PORT_ENABLE is low, requests are refused, pending response data is
// hidden/cleared, and all raw request pins are held low. Connect PORT_ENABLE
// to the same policy signal used for the wrapped core's DBGEN input.

module arm7tdmis_sync_debug_port (
    input  logic CLK,
    input  logic nRESET,
    input  logic PORT_ENABLE,

    input  logic STEP_VALID,
    output logic STEP_READY,
    input  logic STEP_TMS,
    input  logic STEP_TDI,

    output logic STEP_RSP_VALID,
    input  logic STEP_RSP_READY,
    output logic STEP_TDO,
    output logic STEP_TDO_OE,

    output logic DBGTCKEN,
    output logic DBGTMS,
    output logic DBGTDI,
    input  logic DBGTDO,
    input  logic DBGnTDOEN
);

    logic response_valid_q;
    logic response_tdo_q;
    logic response_tdo_oe_q;

    wire response_slot_available = !response_valid_q || STEP_RSP_READY;
    wire step_accept = STEP_VALID && STEP_READY;

    // No raw input is exposed unless the corresponding virtual TCK edge is
    // accepted. This makes idle/backpressured behavior deterministic.
    assign STEP_READY = nRESET && PORT_ENABLE && response_slot_available;
    assign DBGTCKEN   = step_accept;
    assign DBGTMS     = step_accept && STEP_TMS;
    assign DBGTDI     = step_accept && STEP_TDI;

    // PORT_ENABLE is also an immediate output-isolation boundary. Registered
    // state is cleared on the next CLK edge, while no stale response is
    // observable during the intervening fraction of a cycle.
    assign STEP_RSP_VALID = PORT_ENABLE && response_valid_q;
    assign STEP_TDO       = (PORT_ENABLE && response_valid_q)
                          ? response_tdo_q : 1'b0;
    assign STEP_TDO_OE    = PORT_ENABLE && response_valid_q
                          && response_tdo_oe_q;

    always_ff @(posedge CLK or negedge nRESET) begin
        if (!nRESET) begin
            response_valid_q  <= 1'b0;
            response_tdo_q    <= 1'b0;
            response_tdo_oe_q <= 1'b0;
        end else if (!PORT_ENABLE) begin
            response_valid_q  <= 1'b0;
            response_tdo_q    <= 1'b0;
            response_tdo_oe_q <= 1'b0;
        end else if (response_slot_available) begin
            response_valid_q <= step_accept;
            if (step_accept) begin
                response_tdo_q    <= DBGTDO;
                response_tdo_oe_q <= !DBGnTDOEN;
            end else begin
                response_tdo_q    <= 1'b0;
                response_tdo_oe_q <= 1'b0;
            end
        end
    end

endmodule
