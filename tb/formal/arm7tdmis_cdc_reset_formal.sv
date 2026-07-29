// VAL-007 reset-release and same-clock debug-transport assumptions.

module arm7tdmis_cdc_reset_formal (
    input logic CLK,
    input logic PORT_ENABLE,
    input logic STEP_VALID,
    input logic STEP_TMS,
    input logic STEP_TDI,
    input logic STEP_RSP_READY,
    input logic DBGTDO,
    input logic DBGnTDOEN
);
    logic [3:0] f_cycle = 4'd0;
    logic       f_past_valid = 1'b0;
    wire        nRESET = (f_cycle != 4'd0);
    logic       core_nreset;
    logic       STEP_READY;
    logic       STEP_RSP_VALID;
    logic       STEP_TDO;
    logic       STEP_TDO_OE;
    logic       DBGTCKEN;
    logic       DBGTMS;
    logic       DBGTDI;

    arm7tdmis_reset_sync u_reset (
        .CLK,
        .nRESET,
        .core_nreset
    );
    arm7tdmis_sync_debug_port u_transport (
        .CLK,
        .nRESET,
        .PORT_ENABLE,
        .STEP_VALID,
        .STEP_READY,
        .STEP_TMS,
        .STEP_TDI,
        .STEP_RSP_VALID,
        .STEP_RSP_READY,
        .STEP_TDO,
        .STEP_TDO_OE,
        .DBGTCKEN,
        .DBGTMS,
        .DBGTDI,
        .DBGTDO,
        .DBGnTDOEN
    );

    always_ff @(posedge CLK) begin
        f_past_valid <= 1'b1;
        if (f_cycle != 4'hf)
            f_cycle <= f_cycle + 4'd1;

        assert (!core_nreset || u_reset.q1);
        assert (!DBGTCKEN || (STEP_VALID && STEP_READY));
        assert (!DBGTMS || DBGTCKEN);
        assert (!DBGTDI || DBGTCKEN);
        if (!PORT_ENABLE) begin
            assert (!STEP_READY);
            assert (!STEP_RSP_VALID);
            assert (!STEP_TDO);
            assert (!STEP_TDO_OE);
        end
        if (f_past_valid) begin
            if (!$past(nRESET)) begin
                assert (!core_nreset);
                assert (!STEP_RSP_VALID);
            end
            if ($past(nRESET) && !$past(u_reset.q1))
                assert (!core_nreset);
            if ($past(STEP_RSP_VALID && !STEP_RSP_READY
                      && PORT_ENABLE) && PORT_ENABLE) begin
                assert (STEP_RSP_VALID);
                assert (STEP_TDO == $past(STEP_TDO));
                assert (STEP_TDO_OE == $past(STEP_TDO_OE));
            end
        end
    end
endmodule
