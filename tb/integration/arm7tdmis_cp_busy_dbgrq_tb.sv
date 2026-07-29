// CP-006 regression: DBGRQ terminates an indefinitely busy coprocessor
// instruction before halt-mode debug entry.
//
// TRM §5.3.3 says this case enters debug immediately, like IRQ/FIQ.
// CPnI must rise while the coprocessor still advertises low/high, no CP
// completion or younger instruction may occur, and the halted external
// boundary must advertise internal cycles without ghost retirements.

`timescale 1ns/1ps

module arm7tdmis_cp_busy_dbgrq_tb
    import arm7tdmis_bus_pkg::*;
;

    localparam int CYCLE_LIMIT = 260;

    logic CLK;
    initial begin
        CLK = 1'b0;
        forever #5 CLK = ~CLK;
    end

    logic nRESET;
    logic DBGnTRST;
    initial begin
        nRESET   = 1'b0;
        DBGnTRST = 1'b0;
        repeat (4) @(posedge CLK);
        DBGnTRST = 1'b1;
        nRESET   = 1'b1;
    end

    logic DBGRQ;
    initial DBGRQ = 1'b0;

    logic [31:0] ADDR;
    logic        WRITE;
    logic [1:0]  SIZE;
    logic [1:0]  PROT;
    logic        LOCK;
    logic [1:0]  TRANS;
    logic [31:0] WDATA, RDATA;
    logic        ABORT;

    logic CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI;
    logic CPA, CPB;
    logic DBGACK, DBGnEXEC, DBGINSTRVALID;
    logic [1:0] DBGRNG;
    logic DBGCOMMTX, DBGCOMMRX, DBGTDO, DBGnTDOEN, DMORE;

    arm7tdmis_top u_dut (
        .CLK,
        .CLKEN             (1'b1),
        .nRESET,
        .CFGBIGEND         (1'b0),
        .nIRQ              (1'b1),
        .nFIQ              (1'b1),
        .ABORT,
        .ADDR, .WRITE, .SIZE, .PROT, .LOCK, .TRANS, .WDATA, .RDATA,
        .CPnMREQ, .CPSEQ, .CPnTRANS, .CPnOPC, .CPTBIT, .CPnI, .CPA, .CPB,
        .DBGEN             (1'b1),
        .DBGRQ,
        .DBGBREAK          (1'b0),
        .DBGACK,
        .DBGnEXEC,
        .DBGINSTRVALID,
        .DBGEXT            (2'b00),
        .DBGRNG,
        .DBGCOMMTX,
        .DBGCOMMRX,
        .DBGTCKEN          (1'b0),
        .DBGTMS            (1'b0),
        .DBGTDI            (1'b0),
        .DBGTDO,
        .DBGnTRST,
        .DBGnTDOEN,
        .DMORE
    );

    arm7tdmis_memory #(
        .WORDS    (128),
        .INIT_HEX ("../tb/programs/cp_busy_dbgrq_test.hex")
    ) u_mem (
        .CLK,
        .CLKEN       (1'b1),
        .nRESET,
        .CFGBIGEND   (1'b0),
        .ADDR,
        .WRITE,
        .SIZE,
        .PROT,
        .LOCK,
        .TRANS,
        .WDATA,
        .RDATA,
        .ABORT,
        .inject_abort(1'b0)
    );

    // Keep CP4 busy until CPnI advertises cancellation. On that first
    // high cycle, the old abandoned_q value deliberately keeps low/high
    // visible so the cancellation handshake itself is checked.
    logic request_seen_q;
    logic abandoned_q;
    always_comb begin
        CPA = 1'b1;
        CPB = 1'b1;
        if ((!request_seen_q && !CPnI)
            || (request_seen_q && !abandoned_q)) begin
            CPA = 1'b0;
            CPB = 1'b1;
        end
    end

    int unsigned busy_samples_q;
    int unsigned abandon_samples_q;
    int unsigned completion_states_q;
    int unsigned protocol_errors_q;
    int unsigned halted_samples_q;

    always_ff @(posedge CLK) begin
        if (!nRESET) begin
            request_seen_q      <= 1'b0;
            abandoned_q         <= 1'b0;
            busy_samples_q      <= 0;
            abandon_samples_q   <= 0;
            completion_states_q <= 0;
        end else begin
            if (!request_seen_q && !CPnI)
                request_seen_q <= 1'b1;

            if (request_seen_q && !abandoned_q) begin
                if (!CPnI) begin
                    busy_samples_q <= busy_samples_q + 1;
                end else begin
                    abandoned_q       <= 1'b1;
                    abandon_samples_q <= abandon_samples_q + 1;
                end
            end

            if (u_dut.u_core.state_q inside {5'd13, 5'd14, 5'd15})
                completion_states_q <= completion_states_q + 1;
        end
    end

    // Apply the level-sensitive request after three completed busy
    // samples. Keep it asserted: halt mode remains entered until RESTART,
    // not until DBGRQ is released.
    initial begin
        wait (nRESET);
        wait (u_dut.u_core.state_q == 5'd12 && !CPnI);
        wait (busy_samples_q >= 3);
        @(negedge CLK);
        DBGRQ = 1'b1;
    end

    // Sample the post-edge halted boundary at falling edges.
    always @(negedge CLK) begin
        if (!nRESET) begin
            protocol_errors_q <= 0;
            halted_samples_q  <= 0;
        end else if (DBGACK) begin
            halted_samples_q <= halted_samples_q + 1;
            protocol_errors_q <= protocol_errors_q
                               + (!CPnI)
                               + (TRANS !== 2'(TRANS_I))
                               + LOCK
                               + DBGINSTRVALID
                               + (!DBGnEXEC)
                               + (u_dut.u_core.state_q != 5'd0);

            if (!CPnI || TRANS !== 2'(TRANS_I) || LOCK
                || DBGINSTRVALID || !DBGnEXEC
                || u_dut.u_core.state_q != 5'd0) begin
                $display("[cp_busy_dbgrq] FAIL halted CPnI/T/L/IV/nEX/state=%b/%02b/%b/%b/%b/%0d",
                         CPnI, TRANS, LOCK, DBGINSTRVALID, DBGnEXEC,
                         u_dut.u_core.state_q);
            end
        end
    end

    int unsigned errors;

    initial begin
        $dumpfile("cp_busy_dbgrq.fst");
        $dumpvars(0, arm7tdmis_cp_busy_dbgrq_tb);
        errors = 0;

        wait (DBGACK);
        repeat (8) @(posedge CLK);
        #1;

        errors = protocol_errors_q;
        if (!request_seen_q || !abandoned_q
            || busy_samples_q < 3 || abandon_samples_q != 1) begin
            $display("[cp_busy_dbgrq] FAIL request/abandon/busy/count=%b/%b/%0d/%0d",
                     request_seen_q, abandoned_q, busy_samples_q,
                     abandon_samples_q);
            errors = errors + 1;
        end
        if (completion_states_q != 0 || halted_samples_q < 4) begin
            $display("[cp_busy_dbgrq] FAIL completion/halted samples=%0d/%0d",
                     completion_states_q, halted_samples_q);
            errors = errors + 1;
        end
        if (u_dut.u_core.u_regfile.regs[0] !== 32'h0) begin
            $display("[cp_busy_dbgrq] FAIL younger instruction executed r0=%08x",
                     u_dut.u_core.u_regfile.regs[0]);
            errors = errors + 1;
        end

        if (errors != 0)
            $fatal(1, "[cp_busy_dbgrq] FAIL (%0d errors)", errors);
        $display("[cp_busy_dbgrq] PASS");
        $finish;
    end

    initial begin
        repeat (CYCLE_LIMIT) @(posedge CLK);
        $fatal(1, "[cp_busy_dbgrq] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, ADDR, WRITE, SIZE, PROT, WDATA, CPnMREQ,
        CPSEQ, CPnTRANS, CPnOPC, CPTBIT, DBGRNG, DBGCOMMTX, DBGCOMMRX,
        DBGTDO, DBGnTDOEN, DMORE};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
