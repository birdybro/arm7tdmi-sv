// CP-005/006 regression for external MCR/MRC handshaking and data cycles.
//
// A synthetic CP4 busy-waits the first request (MCR) for three cycles, then
// accepts it. The following MRC is accepted immediately. The responder checks
// the C cycles, captures ARM-to-CP WDATA, and drives CP-to-ARM RDATA.

`timescale 1ns/1ps

module arm7tdmis_cp_reg_transfer_tb
    import arm7tdmis_bus_pkg::*;
;

    localparam int CYCLE_LIMIT = 420;
    localparam logic [31:0] MCR_DATA = 32'h5A000000;
    localparam logic [31:0] MRC_DATA = 32'hC35AA53C;

    logic CLK;
    initial begin
        CLK = 1'b0;
        forever #5 CLK = ~CLK;
    end

    logic nRESET;
    initial begin
        nRESET = 1'b0;
        repeat (4) @(posedge CLK);
        nRESET = 1'b1;
    end

    logic [31:0] ADDR;
    logic WRITE;
    logic [1:0] SIZE;
    logic [1:0] PROT;
    logic LOCK;
    logic [1:0] TRANS;
    logic [31:0] WDATA;
    logic [31:0] RDATA;
    logic [31:0] mem_rdata;
    logic ABORT;

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
        .DBGEN             (1'b0),
        .DBGRQ             (1'b0),
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
        .DBGnTRST          (1'b1),
        .DBGnTDOEN,
        .DMORE
    );

    logic cp_transfer_phase_q;
    logic mrc_drive_q;
    wire mem_write = WRITE && !cp_transfer_phase_q;

    arm7tdmis_memory #(
        .WORDS    (256),
        .INIT_HEX ("../tb/programs/cp_reg_transfer_test.hex")
    ) u_mem (
        .CLK,
        .CLKEN       (1'b1),
        .nRESET,
        .CFGBIGEND   (1'b0),
        .ADDR,
        .WRITE       (mem_write),
        .SIZE,
        .PROT,
        .LOCK,
        .TRANS,
        .WDATA,
        .RDATA       (mem_rdata),
        .ABORT,
        .inject_abort(1'b0)
    );

    assign RDATA = mrc_drive_q ? MRC_DATA : mem_rdata;

    int unsigned errors;
    int unsigned protocol_errors;
    int unsigned accepted_count;
    int unsigned busy_cycles_seen;
    int unsigned c_cycles_seen;
    logic [2:0] busy_remaining_q;
    logic request_accepted_q;
    logic transfer_pending_q;
    logic transfer_is_mrc_q;
    logic mrc_wb_pending_q;
    logic [31:0] mcr_captured_q;

    // The synthetic coprocessor recognizes every CPnI-low request. It
    // presents legal absent/default levels outside a request.
    always_comb begin
        CPA = 1'b1;
        CPB = 1'b1;
        if (!CPnI) begin
            CPA = 1'b0;
            CPB = (busy_remaining_q != 3'd0);
        end
    end

    always_ff @(posedge CLK) begin
        if (!nRESET) begin
            accepted_count      <= 0;
            protocol_errors     <= 0;
            busy_cycles_seen    <= 0;
            c_cycles_seen       <= 0;
            busy_remaining_q    <= 3'd3;
            request_accepted_q  <= 1'b0;
            transfer_pending_q  <= 1'b0;
            transfer_is_mrc_q   <= 1'b0;
            mrc_wb_pending_q    <= 1'b0;
            cp_transfer_phase_q <= 1'b0;
            mrc_drive_q         <= 1'b0;
            mcr_captured_q      <= 32'h0;
        end else begin
            cp_transfer_phase_q <= 1'b0;
            mrc_drive_q         <= 1'b0;

            if (CPnI) begin
                request_accepted_q <= 1'b0;
                busy_remaining_q <= (accepted_count == 0) ? 3'd3 : 3'd0;
            end else if (CPB) begin
                busy_cycles_seen <= busy_cycles_seen + 1;
                if (busy_remaining_q != 0)
                    busy_remaining_q <= busy_remaining_q - 3'd1;
            end

            if (!CPnI && !CPA && !CPB && !request_accepted_q) begin
                request_accepted_q <= 1'b1;
                accepted_count     <= accepted_count + 1;
                transfer_pending_q <= 1'b1;
                transfer_is_mrc_q  <= (accepted_count == 1);
                cp_transfer_phase_q <= 1'b1;
                mrc_drive_q         <= (accepted_count == 1);

                if (TRANS !== 2'(TRANS_C)) begin
                    $display("[cp_reg_transfer] FAIL accepted request did not drive C: %02b",
                             TRANS);
                    protocol_errors <= protocol_errors + 1;
                end else begin
                    c_cycles_seen <= c_cycles_seen + 1;
                end
            end

            if (transfer_pending_q) begin
                transfer_pending_q <= 1'b0;
                if (!transfer_is_mrc_q) begin
                    mcr_captured_q <= WDATA;
                    if (TRANS !== 2'(TRANS_N) || !WRITE || !PROT[0]) begin
                        $display("[cp_reg_transfer] FAIL MCR data phase T/W/P=%02b/%b/%b",
                                 TRANS, WRITE, PROT[0]);
                        protocol_errors <= protocol_errors + 1;
                    end
                end else begin
                    mrc_wb_pending_q <= 1'b1;
                    if (TRANS !== 2'(TRANS_I) || WRITE || !PROT[0]) begin
                        $display("[cp_reg_transfer] FAIL MRC data phase T/W/P=%02b/%b/%b",
                                 TRANS, WRITE, PROT[0]);
                        protocol_errors <= protocol_errors + 1;
                    end
                end
            end

            if (mrc_wb_pending_q) begin
                mrc_wb_pending_q <= 1'b0;
                if (TRANS !== 2'(TRANS_S)) begin
                    $display("[cp_reg_transfer] FAIL MRC writeback expected S, got %02b",
                             TRANS);
                    protocol_errors <= protocol_errors + 1;
                end
            end
        end
    end

    initial begin
        $dumpfile("cp_reg_transfer.fst");
        $dumpvars(0, arm7tdmis_cp_reg_transfer_tb);
        errors = 0;

        wait (nRESET);
        repeat (340) @(posedge CLK);
        #1;
        errors = protocol_errors;

        if (accepted_count != 2) begin
            $display("[cp_reg_transfer] FAIL accepted_count expected 2 got %0d",
                     accepted_count);
            errors = errors + 1;
        end
        if (busy_cycles_seen != 3) begin
            $display("[cp_reg_transfer] FAIL busy cycles expected 3 got %0d",
                     busy_cycles_seen);
            errors = errors + 1;
        end
        if (c_cycles_seen != 2) begin
            $display("[cp_reg_transfer] FAIL C cycles expected 2 got %0d",
                     c_cycles_seen);
            errors = errors + 1;
        end
        if (mcr_captured_q !== MCR_DATA) begin
            $display("[cp_reg_transfer] FAIL MCR expected %08x got %08x",
                     MCR_DATA, mcr_captured_q);
            errors = errors + 1;
        end
        if (u_dut.u_core.u_regfile.regs[1] !== MRC_DATA) begin
            $display("[cp_reg_transfer] FAIL MRC r1 expected %08x got %08x",
                     MRC_DATA, u_dut.u_core.u_regfile.regs[1]);
            errors = errors + 1;
        end
        if (u_dut.u_core.u_regfile.regs[2] !== 32'h22) begin
            $display("[cp_reg_transfer] FAIL completion marker r2=%08x",
                     u_dut.u_core.u_regfile.regs[2]);
            errors = errors + 1;
        end
        if (u_dut.u_core.u_regfile.regs[10] !== 32'h0) begin
            $display("[cp_reg_transfer] FAIL unexpected Undefined handler r10=%08x",
                     u_dut.u_core.u_regfile.regs[10]);
            errors = errors + 1;
        end

        if (errors != 0)
            $fatal(1, "[cp_reg_transfer] FAIL (%0d errors)", errors);
        $display("[cp_reg_transfer] PASS");
        $finish;
    end

    initial begin
        repeat (CYCLE_LIMIT) @(posedge CLK);
        $fatal(1, "[cp_reg_transfer] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT,
        DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG, DBGCOMMTX, DBGCOMMRX,
        DBGTDO, DBGnTDOEN, DMORE, SIZE, LOCK};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
