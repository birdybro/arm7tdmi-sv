// Reusable ARM7TDMI-S raw-bus protocol checker.
//
// Instantiate beside arm7tdmis_top in simulation or formal harnesses. This
// checker constrains no input other than the static CFGBIGEND integration
// contract; ABORT and RDATA remain unrestricted environment responses.

module arm7tdmis_raw_bus_checker
    import arm7tdmis_bus_pkg::*;
(
    input logic        CLK,
    input logic        CLKEN,
    input logic        nRESET,
    input logic        CFGBIGEND,

    input logic [31:0] ADDR,
    input logic        WRITE,
    input logic [1:0]  SIZE,
    input logic [1:0]  PROT,
    input logic        LOCK,
    input logic [1:0]  TRANS,
    input logic [31:0] WDATA,
    input logic        DMORE,

    input logic        CPnMREQ,
    input logic        CPSEQ,
    input logic        CPnOPC,
    input logic        CPnI
);

    logic        cfg_valid_q;
    logic        cfg_bigend_q;
    logic        reset_low_q;
    logic        enabled_since_reset_q;
    logic        stopped_edge_q;

    logic        phase_valid_q;
    logic [31:0] phase_addr_q;
    logic        phase_write_q;
    logic [1:0]  phase_size_q;
    logic [1:0]  phase_prot_q;
    logic        phase_lock_q;
    logic [1:0]  phase_trans_q;
    logic        phase_dmore_q;
    logic        phase_cpni_q;

    logic        stall_seen_q;
    logic [72:0] stalled_bus_q;

    wire active = TRANS inside {TRANS_N, TRANS_S};
    wire phase_active_q = phase_trans_q inside {TRANS_N, TRANS_S};
    wire controls_match = (WRITE == phase_write_q)
                       && (SIZE  == phase_size_q)
                       && (PROT  == phase_prot_q)
                       && (LOCK  == phase_lock_q);
    wire [31:0] step = (SIZE == SIZE_WORD) ? 32'd4
                           : (SIZE == SIZE_HALFWORD) ? 32'd2 : 32'd0;
    wire active_continuation = phase_valid_q
                            && phase_active_q
                            && controls_match
                            && (SIZE inside {SIZE_HALFWORD, SIZE_WORD})
                            && (ADDR == (phase_addr_q + step));
    wire merged_is = phase_valid_q
                  && (phase_trans_q == TRANS_I)
                  && controls_match
                  && (SIZE inside {SIZE_HALFWORD, SIZE_WORD})
                  && (ADDR == phase_addr_q);
    // Tables 7-18/7-19 make the first word of a multiword LDC/STC an S
    // cycle. It follows the accepted coprocessor phase (CPnI LOW), then
    // CPnI returns HIGH while memory performs the word transfer. This is
    // the one specified S-cycle start that is not ordinary +4/+2 history.
    wire coprocessor_stream_start = phase_valid_q
                                  && !phase_cpni_q
                                  && CPnI
                                  && PROT[PROT_BIT_DATA]
                                  && SIZE == SIZE_WORD
                                  && !LOCK;

    // Static configuration and per-address-phase protocol.
    always_ff @(posedge CLK) begin
        if (!nRESET) begin
            cfg_valid_q    <= 1'b0;
            cfg_bigend_q   <= CFGBIGEND;
            reset_low_q    <= 1'b1;
            enabled_since_reset_q <= 1'b0;
            stopped_edge_q <= 1'b0;
            phase_valid_q  <= 1'b0;
            phase_addr_q   <= 32'h0;
            phase_write_q  <= WRITE_READ;
            phase_size_q   <= 2'(SIZE_WORD);
            phase_prot_q   <= 2'(PROT_OPC_PRIV);
            phase_lock_q   <= LOCK_FREE;
            phase_trans_q  <= 2'(TRANS_I);
            phase_dmore_q  <= 1'b0;
            phase_cpni_q   <= 1'b1;

            // nRESET must be held LOW for at least two rising edges. Skip
            // the first, which may coincide with the external assertion
            // in a testbench active region, then verify the settled pins.
            if (reset_low_q) begin
                assert (TRANS == 2'(TRANS_I))
                    else $fatal(1, "raw bus: reset must drive TRANS=I");
                assert (WRITE == WRITE_READ && SIZE == 2'(SIZE_WORD)
                        && LOCK == LOCK_FREE && DMORE == 1'b0)
                    else $fatal(1,
                        "raw bus: reset controls are not benign");
            end
        end else begin
            reset_low_q <= 1'b0;
            stopped_edge_q <= !CLKEN;
            if (CLKEN)
                enabled_since_reset_q <= 1'b1;

            if (!cfg_valid_q) begin
                cfg_valid_q  <= 1'b1;
                cfg_bigend_q <= CFGBIGEND;
            end else begin
                assert (CFGBIGEND == cfg_bigend_q)
                    else $fatal(1,
                        "raw bus: CFGBIGEND changed outside reset");
            end

            assert (SIZE != 2'(SIZE_RESERVED))
                else $fatal(1, "raw bus: SIZE=2'b11 is reserved");
            assert (CPnMREQ == !active)
                else $fatal(1, "raw bus: CPnMREQ does not mirror TRANS active");
            assert (CPSEQ == TRANS[0])
                else $fatal(1, "raw bus: CPSEQ does not mirror TRANS[0]");
            assert (CPnOPC == PROT[PROT_BIT_DATA])
                else $fatal(1, "raw bus: CPnOPC does not mirror PROT[0]");

            if (DMORE) begin
                assert (active && PROT[PROT_BIT_DATA]
                        && SIZE == 2'(SIZE_WORD) && !LOCK)
                    else $fatal(1,
                        "raw bus: DMORE outside an unlocked word data address");
            end

            if (CLKEN) begin
                if (TRANS == 2'(TRANS_S)) begin
                    assert (active_continuation || merged_is
                            || coprocessor_stream_start)
                        else $fatal(1,
                            "raw bus: S address lacks legal burst history");
                    assert (SIZE != 2'(SIZE_BYTE))
                        else $fatal(1, "raw bus: byte burst is forbidden");
                end

                if (phase_valid_q && phase_dmore_q) begin
                    assert (TRANS == 2'(TRANS_S)
                            && PROT[PROT_BIT_DATA]
                            && SIZE == 2'(SIZE_WORD)
                            && controls_match
                            && ADDR == (phase_addr_q + 32'd4))
                        else $fatal(1,
                            "raw bus: DMORE promise lacked +4 S follower");
                end

                phase_valid_q <= 1'b1;
                phase_addr_q  <= ADDR;
                phase_write_q <= WRITE;
                phase_size_q  <= SIZE;
                phase_prot_q  <= PROT;
                phase_lock_q  <= LOCK;
                phase_trans_q <= TRANS;
                phase_dmore_q <= DMORE;
                phase_cpni_q  <= CPnI;
            end
        end
    end

    // Once a LOW CLKEN has been sampled on a rising edge, hold every
    // outgoing bus/prediction signal on further stopped cycles. Appendix B
    // permits outputs to change in the cycle in which CLKEN is first taken
    // LOW, so capture on the following falling edge. Reset release can also
    // alter the idle pins while stopped; checking begins only after the
    // first enabled post-reset bus edge.
    always_ff @(negedge CLK) begin
        if (!nRESET || CLKEN || !enabled_since_reset_q
            || !stopped_edge_q) begin
            stall_seen_q <= 1'b0;
        end else if (!stall_seen_q) begin
            stall_seen_q <= 1'b1;
            stalled_bus_q <= {
                ADDR, WDATA, WRITE, SIZE, PROT, LOCK, TRANS, DMORE
            };
        end else begin
            assert ({ADDR, WDATA, WRITE, SIZE, PROT, LOCK, TRANS, DMORE}
                    == stalled_bus_q)
                else $fatal(1, "raw bus: output changed while CLKEN=0");
        end
    end

endmodule
