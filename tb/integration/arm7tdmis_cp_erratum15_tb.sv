// CP-011 / erratum [15] corrected-default regression.
//
// FR002-PRDC-002719 §6.2 records that real r4p3 can mishandle the second
// and later sequential MRC when opcode1 is x1x and CPA/CPB are asserted
// early. The FPGA release policy is architecturally corrected behavior:
// all four consecutive x1x forms execute and receive their own data.

`timescale 1ns/1ps

module arm7tdmis_cp_erratum15_tb
    import arm7tdmis_bus_pkg::*;
;

    localparam int CYCLE_LIMIT = 420;
    localparam logic [31:0] MRC0 = 32'hEE51_4412; // opcode1=010
    localparam logic [31:0] MRC1 = 32'hEE73_5434; // opcode1=011
    localparam logic [31:0] MRC2 = 32'hEED5_6456; // opcode1=110
    localparam logic [31:0] MRC3 = 32'hEEF7_7478; // opcode1=111
    localparam logic [31:0] DATA0 = 32'h1500_0002;
    localparam logic [31:0] DATA1 = 32'h1500_0003;
    localparam logic [31:0] DATA2 = 32'h1500_0006;
    localparam logic [31:0] DATA3 = 32'h1500_0007;

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
    logic        WRITE;
    logic [1:0]  SIZE;
    logic [1:0]  PROT;
    logic        LOCK;
    logic [1:0]  TRANS;
    logic [31:0] WDATA, RDATA, mem_rdata;
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

    arm7tdmis_memory #(
        .WORDS    (128),
        .INIT_HEX ("../tb/programs/cp_erratum15_test.hex")
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
        .RDATA       (mem_rdata),
        .ABORT,
        .inject_abort(1'b0)
    );

    function automatic logic is_test_mrc(input logic [31:0] instr);
        return instr inside {MRC0, MRC1, MRC2, MRC3};
    endfunction

    function automatic logic [31:0] response_data(input logic [1:0] idx);
        unique case (idx)
            2'd0: response_data = DATA0;
            2'd1: response_data = DATA1;
            2'd2: response_data = DATA2;
            default: response_data = DATA3;
        endcase
    endfunction

    // Minimal public-pin fetch follower. Seeing MRC0 in its fetch slot
    // opens an early-claim window before the core asserts CPnI.
    wire arm_opcode_cycle = !CPnMREQ && !CPnOPC && !CPTBIT;
    logic previous_arm_opcode_q;
    logic [31:0] follower_fetch_q;
    logic follower_fetch_valid_q;
    logic claim_window_q;

    always_ff @(posedge CLK) begin
        if (!nRESET) begin
            previous_arm_opcode_q  <= 1'b0;
            follower_fetch_q       <= 32'h0;
            follower_fetch_valid_q <= 1'b0;
            claim_window_q         <= 1'b0;
        end else begin
            previous_arm_opcode_q <= arm_opcode_cycle;
            if (previous_arm_opcode_q) begin
                follower_fetch_q       <= RDATA;
                follower_fetch_valid_q <= 1'b1;
            end
            if (follower_fetch_valid_q && follower_fetch_q == MRC0)
                claim_window_q <= 1'b1;
            if (accepted_count_q == 4 && CPnI)
                claim_window_q <= 1'b0;
        end
    end

    wire first_mrc_visible = follower_fetch_valid_q
                           && follower_fetch_q == MRC0;
    wire early_claim = claim_window_q || first_mrc_visible;

    always_comb begin
        CPA = !early_claim;
        CPB = !early_claim;
    end

    logic mrc_drive_q;
    logic [1:0] response_index_q;
    assign RDATA = mrc_drive_q ? response_data(response_index_q)
                               : mem_rdata;

    logic request_accepted_q;
    logic early_seen_q;
    logic data_pending_q;
    logic wb_pending_q;
    int unsigned protocol_errors_q;
    int unsigned accepted_count_q;
    int unsigned early_qualified_q;
    int unsigned data_phase_count_q;
    int unsigned wb_phase_count_q;

    always_ff @(posedge CLK) begin
        if (!nRESET) begin
            mrc_drive_q       <= 1'b0;
            response_index_q  <= 2'h0;
            request_accepted_q <= 1'b0;
            early_seen_q      <= 1'b0;
            data_pending_q    <= 1'b0;
            wb_pending_q      <= 1'b0;
            protocol_errors_q <= 0;
            accepted_count_q  <= 0;
            early_qualified_q <= 0;
            data_phase_count_q <= 0;
            wb_phase_count_q  <= 0;
        end else begin
            mrc_drive_q <= 1'b0;

            if (CPnI && !CPA && !CPB)
                early_seen_q <= 1'b1;
            if (CPnI)
                request_accepted_q <= 1'b0;

            if (!CPnI && !CPA && !CPB && !request_accepted_q) begin
                request_accepted_q <= 1'b1;
                accepted_count_q   <= accepted_count_q + 1;
                response_index_q   <= accepted_count_q[1:0];
                mrc_drive_q        <= 1'b1;
                data_pending_q     <= 1'b1;

                if (early_seen_q)
                    early_qualified_q <= early_qualified_q + 1;
                early_seen_q <= 1'b0;

                if (!is_test_mrc(u_dut.u_core.de_q.instr)
                    || u_dut.u_core.de_q.instr[23:22] inside {2'b00, 2'b10}
                    || u_dut.u_core.de_q.pc
                       !== (32'h20 + 32'(accepted_count_q * 4))
                    || TRANS !== 2'(TRANS_C)) begin
                    $display("[cp_erratum15] FAIL accept idx=%0d PC/I/T=%08x/%08x/%02b early=%b",
                             accepted_count_q, u_dut.u_core.de_q.pc,
                             u_dut.u_core.de_q.instr, TRANS, early_seen_q);
                    protocol_errors_q <= protocol_errors_q + 1;
                end
            end

            if (data_pending_q) begin
                data_pending_q <= 1'b0;
                wb_pending_q   <= 1'b1;
                data_phase_count_q <= data_phase_count_q + 1;
                if (TRANS !== 2'(TRANS_I) || WRITE || !PROT[0]) begin
                    $display("[cp_erratum15] FAIL data phase T/W/P=%02b/%b/%b",
                             TRANS, WRITE, PROT[0]);
                    protocol_errors_q <= protocol_errors_q + 1;
                end
            end

            if (wb_pending_q) begin
                wb_pending_q <= 1'b0;
                wb_phase_count_q <= wb_phase_count_q + 1;
                if (TRANS !== 2'(TRANS_S)) begin
                    $display("[cp_erratum15] FAIL writeback TRANS=%02b",
                             TRANS);
                    protocol_errors_q <= protocol_errors_q + 1;
                end
            end
        end
    end

    int unsigned errors;

    initial begin
        $dumpfile("cp_erratum15.fst");
        $dumpvars(0, arm7tdmis_cp_erratum15_tb);
        errors = 0;

        wait (nRESET);
        repeat (340) @(posedge CLK);
        #1;

        errors = protocol_errors_q;
        if (accepted_count_q != 4 || early_qualified_q != 4
            || data_phase_count_q != 4 || wb_phase_count_q != 4) begin
            $display("[cp_erratum15] FAIL accepted/early/data/wb=%0d/%0d/%0d/%0d",
                     accepted_count_q, early_qualified_q,
                     data_phase_count_q, wb_phase_count_q);
            errors = errors + 1;
        end
        if (u_dut.u_core.u_regfile.regs[4] !== DATA0
            || u_dut.u_core.u_regfile.regs[5] !== DATA1
            || u_dut.u_core.u_regfile.regs[6] !== DATA2
            || u_dut.u_core.u_regfile.regs[7] !== DATA3) begin
            $display("[cp_erratum15] FAIL MRC data=%08x/%08x/%08x/%08x",
                     u_dut.u_core.u_regfile.regs[4],
                     u_dut.u_core.u_regfile.regs[5],
                     u_dut.u_core.u_regfile.regs[6],
                     u_dut.u_core.u_regfile.regs[7]);
            errors = errors + 1;
        end
        if (u_dut.u_core.u_regfile.regs[8] !== 32'h88
            || u_dut.u_core.u_regfile.regs[10] !== 32'h0) begin
            $display("[cp_erratum15] FAIL completion/undef=%08x/%08x",
                     u_dut.u_core.u_regfile.regs[8],
                     u_dut.u_core.u_regfile.regs[10]);
            errors = errors + 1;
        end

        if (errors != 0)
            $fatal(1, "[cp_erratum15] FAIL (%0d errors)", errors);
        $display("[cp_erratum15] PASS");
        $finish;
    end

    initial begin
        repeat (CYCLE_LIMIT) @(posedge CLK);
        $fatal(1, "[cp_erratum15] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, ADDR, SIZE, LOCK, WDATA, CPSEQ, CPnTRANS,
        DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG, DBGCOMMTX, DBGCOMMRX,
        DBGTDO, DBGnTDOEN, DMORE};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
