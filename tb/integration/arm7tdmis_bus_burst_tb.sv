// BUS-005/BUS-011 regression: validate every S-cycle in a mixed ARM/Thumb
// workload against the immediately preceding address-class phase. An S-cycle
// is legal only as an incrementing continuation of an active word/halfword
// burst, as the committing half of a merged I-S cycle at the same address,
// at the same address. Redirect and exception-vector discontinuities open
// with N; their following target+i accesses are ordinary S continuations.

module arm7tdmis_bus_burst_tb
    import arm7tdmis_bus_pkg::*;
;

    logic CLK;
    logic nRESET;

    arm7tdmis_test_fixture #(
        .CYCLE_LIMIT (400),
        .INIT_HEX    ("../tb/programs/smoke.hex"),
        .TEST_NAME   ("bus_burst"),
        .FST_FILE    ("bus_burst.fst")
    ) u_fixture (
        .CFGBIGEND   (1'b0),
        .CLKEN       (1'b1),
        .nIRQ        (1'b1),
        .nFIQ        (1'b1),
        .inject_abort(1'b0),
        .CLK         (CLK),
        .nRESET      (nRESET)
    );

    logic        prev_valid;
    logic [31:0] prev_addr;
    logic        prev_write;
    logic [1:0]  prev_size;
    logic [1:0]  prev_prot;
    logic        prev_lock;
    logic [1:0]  prev_trans;

    logic seen_first;
    logic seen_first_n;
    logic seen_active_s;
    logic seen_merged_is;
    logic seen_data_to_code_n;
    logic seen_thumb_s;
    logic seen_illegal_s;
    logic seen_redirect_n;
    logic seen_bad_redirect;

    wire active_now = u_fixture.TRANS inside {TRANS_N, TRANS_S};
    wire active_prev = prev_trans inside {TRANS_N, TRANS_S};
    wire controls_match = (u_fixture.WRITE == prev_write)
                       && (u_fixture.SIZE  == prev_size)
                       && (u_fixture.PROT  == prev_prot)
                       && (u_fixture.LOCK  == prev_lock);
    wire [31:0] burst_step = (u_fixture.SIZE == SIZE_WORD) ? 32'd4
                             : (u_fixture.SIZE == SIZE_HALFWORD) ? 32'd2
                                                                : 32'd1;
    wire active_continuation = prev_valid
                            && active_prev
                            && controls_match
                            && (u_fixture.SIZE inside {SIZE_HALFWORD, SIZE_WORD})
                            && (u_fixture.ADDR == (prev_addr + burst_step));
    wire merged_is = prev_valid
                  && (prev_trans == TRANS_I)
                  && controls_match
                  && (u_fixture.SIZE inside {SIZE_HALFWORD, SIZE_WORD})
                  && (u_fixture.ADDR == prev_addr);
    wire redirect_target =
        u_fixture.u_dut.u_core.early_flush_fetch
        && (u_fixture.ADDR
            == u_fixture.u_dut.u_core.flush_target_pc)
        && (u_fixture.WRITE == WRITE_READ)
        && (u_fixture.SIZE
            == (u_fixture.u_dut.u_core.early_flush_t
                ? SIZE_HALFWORD : SIZE_WORD))
        && (u_fixture.PROT
            == {u_fixture.u_dut.u_core.early_flush_priv, 1'b0})
        && (u_fixture.LOCK == LOCK_FREE);

    always_ff @(posedge CLK or negedge nRESET) begin
        if (!nRESET) begin
            prev_valid         <= 1'b0;
            prev_addr          <= 32'h0;
            prev_write         <= WRITE_READ;
            prev_size          <= SIZE_WORD;
            prev_prot          <= PROT_OPC_PRIV;
            prev_lock          <= LOCK_FREE;
            prev_trans         <= TRANS_I;
            seen_first         <= 1'b0;
            seen_first_n       <= 1'b0;
            seen_active_s      <= 1'b0;
            seen_merged_is     <= 1'b0;
            seen_data_to_code_n <= 1'b0;
            seen_thumb_s       <= 1'b0;
            seen_illegal_s     <= 1'b0;
            seen_redirect_n    <= 1'b0;
            seen_bad_redirect  <= 1'b0;
        end else if (!u_fixture.u_dut.core_nreset) begin
            // Do not let reset I-cycles qualify the first post-reset access
            // as a merged I-S cycle.
            prev_valid           <= 1'b0;
        end else begin
            if (active_now) begin
                if (!seen_first) begin
                    seen_first   <= 1'b1;
                    seen_first_n <= (u_fixture.TRANS == TRANS_N);
                end

                if (u_fixture.TRANS == TRANS_S) begin
                    if (active_continuation)
                        seen_active_s <= 1'b1;
                    if (merged_is)
                        seen_merged_is <= 1'b1;
                    if (!(active_continuation || merged_is)) begin
                        seen_illegal_s <= 1'b1;
                        $display("[bus_burst] illegal S: prev T/A/W/S/P/L=%b/%08x/%b/%b/%b/%b current=%b/%08x/%b/%b/%b/%b",
                                 prev_trans, prev_addr, prev_write, prev_size,
                                 prev_prot, prev_lock, u_fixture.TRANS,
                                 u_fixture.ADDR, u_fixture.WRITE,
                                 u_fixture.SIZE, u_fixture.PROT,
                                 u_fixture.LOCK);
                    end
                end

                if (redirect_target) begin
                    if (u_fixture.TRANS == TRANS_N)
                        seen_redirect_n <= 1'b1;
                    else
                        seen_bad_redirect <= 1'b1;
                end

                if (prev_valid && active_prev
                    && prev_prot[0] && !u_fixture.PROT[0]
                    && u_fixture.TRANS == TRANS_N)
                    seen_data_to_code_n <= 1'b1;

                if (!u_fixture.PROT[0]
                    && u_fixture.SIZE == SIZE_HALFWORD
                    && u_fixture.TRANS == TRANS_S)
                    seen_thumb_s <= 1'b1;
            end

            prev_valid <= 1'b1;
            prev_addr  <= u_fixture.ADDR;
            prev_write <= u_fixture.WRITE;
            prev_size  <= u_fixture.SIZE;
            prev_prot  <= u_fixture.PROT;
            prev_lock  <= u_fixture.LOCK;
            prev_trans <= u_fixture.TRANS;
        end
    end

    int unsigned errors = 0;

    initial begin
        wait (nRESET);
        repeat (240) @(posedge CLK);

        if (!seen_first || !seen_first_n) begin
            $display("[bus_burst] FAIL first active access was not N");
            errors = errors + 1;
        end
        if (seen_illegal_s) begin
            $display("[bus_burst] FAIL one or more S-cycles lacked legal history");
            errors = errors + 1;
        end
        if (!seen_active_s) begin
            $display("[bus_burst] FAIL no active burst continuation observed");
            errors = errors + 1;
        end
        if (!seen_merged_is) begin
            $display("[bus_burst] FAIL no merged I-S cycle observed");
            errors = errors + 1;
        end
        if (!seen_data_to_code_n) begin
            $display("[bus_burst] FAIL no N data-to-code burst break observed");
            errors = errors + 1;
        end
        if (!seen_thumb_s) begin
            $display("[bus_burst] FAIL no sequential Thumb fetch observed");
            errors = errors + 1;
        end
        if (!seen_redirect_n || seen_bad_redirect) begin
            $display("[bus_burst] FAIL redirect target was not an N cycle");
            errors = errors + 1;
        end

        if (errors != 0)
            $fatal(1, "[bus_burst] FAIL (%0d errors)", errors);
        $display("[bus_burst] PASS");
        $finish;
    end

endmodule
