// CP-011 / erratum [14] corrected-default regression.
//
// FR002-PRDC-002719 §6.1 records that real r4p3 fails to decode
// unindexed (P=0,U=1,W=0) LDC/LDCL/STC/STCL. The FPGA release policy is
// architecturally corrected behavior: options[7:0] are ignored by ARM,
// the first address is Rn, and Rn is not written back.

`timescale 1ns/1ps

module arm7tdmis_cp_erratum14_tb
    import arm7tdmis_bus_pkg::*;
;

    localparam int CYCLE_LIMIT = 420;
    localparam logic [31:0] BASE0 = 32'h0000_0100;
    localparam logic [31:0] BASE1 = 32'h0000_0110;
    localparam logic [31:0] BASE2 = 32'h0000_0120;
    localparam logic [31:0] BASE3 = 32'h0000_0130;
    localparam logic [31:0] LDC0_DATA = 32'h145A_0001;
    localparam logic [31:0] LDC1_DATA = 32'h14A5_0002;
    localparam logic [31:0] STC0_DATA = 32'h143C_0003;
    localparam logic [31:0] STC1_DATA = 32'h14C3_0004;

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
    logic [31:0] WDATA, RDATA;
    logic [31:0] mem_wdata;
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
        .INIT_HEX ("../tb/programs/cp_erratum14_test.hex")
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
        .WDATA       (mem_wdata),
        .RDATA,
        .ABORT,
        .inject_abort(1'b0)
    );

    initial begin
        wait (nRESET);
        u_mem.mem[64] = LDC0_DATA;
        u_mem.mem[68] = LDC1_DATA;
        u_mem.mem[72] = 32'h0;
        u_mem.mem[76] = 32'h0;
    end

    logic request_accepted_q;
    logic transfer_active_q;
    logic transfer_is_stc_q;
    logic [1:0] transfer_index_q;
    logic response_pending_q;
    logic response_is_stc_q;
    logic [1:0] response_index_q;

    wire cp_data_cycle = transfer_active_q && CPnI && PROT[0]
                       && (TRANS inside {TRANS_N, TRANS_S});

    // Every operation is accepted immediately and requests exactly one
    // word: low/low in the execute handshake, then high/high in its data
    // phase marks that word final.
    always_comb begin
        CPA = 1'b1;
        CPB = 1'b1;
        if (!CPnI) begin
            CPA = 1'b0;
            CPB = 1'b0;
        end
    end

    always_comb begin
        mem_wdata = WDATA;
        if (response_pending_q && response_is_stc_q)
            mem_wdata = response_index_q == 2'd2
                      ? STC0_DATA : STC1_DATA;
    end

    function automatic logic [31:0] expected_base(input logic [1:0] idx);
        unique case (idx)
            2'd0: expected_base = BASE0;
            2'd1: expected_base = BASE1;
            2'd2: expected_base = BASE2;
            default: expected_base = BASE3;
        endcase
    endfunction

    int unsigned protocol_errors_q;
    int unsigned accepted_count_q;
    int unsigned data_count_q;
    int unsigned long_count_q;
    logic [31:0] ldc_data_q [0:1];

    always_ff @(posedge CLK) begin
        if (!nRESET) begin
            request_accepted_q <= 1'b0;
            transfer_active_q  <= 1'b0;
            transfer_is_stc_q  <= 1'b0;
            transfer_index_q   <= 2'h0;
            response_pending_q <= 1'b0;
            response_is_stc_q  <= 1'b0;
            response_index_q   <= 2'h0;
            protocol_errors_q  <= 0;
            accepted_count_q   <= 0;
            data_count_q       <= 0;
            long_count_q       <= 0;
            ldc_data_q[0]      <= 32'h0;
            ldc_data_q[1]      <= 32'h0;
        end else begin
            response_pending_q <= 1'b0;

            if (response_pending_q && !response_is_stc_q
                && response_index_q < 2) begin
                ldc_data_q[response_index_q[0]] <= RDATA;
            end

            if (CPnI)
                request_accepted_q <= 1'b0;

            if (!CPnI && !CPA && !CPB && !request_accepted_q) begin
                request_accepted_q <= 1'b1;
                transfer_active_q  <= 1'b1;
                transfer_is_stc_q  <= !u_dut.u_core.de_q.instr[20];
                transfer_index_q   <= accepted_count_q[1:0];
                accepted_count_q   <= accepted_count_q + 1;
                if (u_dut.u_core.de_q.instr[22])
                    long_count_q <= long_count_q + 1;
                if (TRANS !== 2'(TRANS_N)) begin
                    $display("[cp_erratum14] FAIL accept TRANS=%02b",
                             TRANS);
                    protocol_errors_q <= protocol_errors_q + 1;
                end
            end

            if (cp_data_cycle) begin
                transfer_active_q  <= 1'b0;
                response_pending_q <= 1'b1;
                response_is_stc_q  <= transfer_is_stc_q;
                response_index_q   <= transfer_index_q;
                data_count_q       <= data_count_q + 1;

                if (ADDR !== expected_base(transfer_index_q)
                    || WRITE !== transfer_is_stc_q
                    || SIZE !== 2'(SIZE_WORD)
                    || TRANS !== 2'(TRANS_N)) begin
                    $display("[cp_erratum14] FAIL data idx=%0d A/W/S/T=%08x/%b/%02b/%02b",
                             transfer_index_q, ADDR, WRITE, SIZE, TRANS);
                    protocol_errors_q <= protocol_errors_q + 1;
                end
            end
        end
    end

    int unsigned errors;

    initial begin
        $dumpfile("cp_erratum14.fst");
        $dumpvars(0, arm7tdmis_cp_erratum14_tb);
        errors = 0;

        wait (nRESET);
        repeat (340) @(posedge CLK);
        #1;

        errors = protocol_errors_q;
        if (accepted_count_q != 4 || data_count_q != 4
            || long_count_q != 2) begin
            $display("[cp_erratum14] FAIL accepted/data/long=%0d/%0d/%0d",
                     accepted_count_q, data_count_q, long_count_q);
            errors = errors + 1;
        end
        if (ldc_data_q[0] !== LDC0_DATA
            || ldc_data_q[1] !== LDC1_DATA
            || u_mem.mem[72] !== STC0_DATA
            || u_mem.mem[76] !== STC1_DATA) begin
            $display("[cp_erratum14] FAIL data LDC=%08x/%08x STC=%08x/%08x",
                     ldc_data_q[0], ldc_data_q[1],
                     u_mem.mem[72], u_mem.mem[76]);
            errors = errors + 1;
        end
        if (u_dut.u_core.u_regfile.regs[0] !== BASE0
            || u_dut.u_core.u_regfile.regs[1] !== BASE1
            || u_dut.u_core.u_regfile.regs[2] !== BASE2
            || u_dut.u_core.u_regfile.regs[3] !== BASE3) begin
            $display("[cp_erratum14] FAIL bases=%08x/%08x/%08x/%08x",
                     u_dut.u_core.u_regfile.regs[0],
                     u_dut.u_core.u_regfile.regs[1],
                     u_dut.u_core.u_regfile.regs[2],
                     u_dut.u_core.u_regfile.regs[3]);
            errors = errors + 1;
        end
        if (u_dut.u_core.u_regfile.regs[7] !== 32'h77
            || u_dut.u_core.u_regfile.regs[10] !== 32'h0) begin
            $display("[cp_erratum14] FAIL completion/undef=%08x/%08x",
                     u_dut.u_core.u_regfile.regs[7],
                     u_dut.u_core.u_regfile.regs[10]);
            errors = errors + 1;
        end

        if (errors != 0)
            $fatal(1, "[cp_erratum14] FAIL (%0d errors)", errors);
        $display("[cp_erratum14] PASS");
        $finish;
    end

    initial begin
        repeat (CYCLE_LIMIT) @(posedge CLK);
        $fatal(1, "[cp_erratum14] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT,
        DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG, DBGCOMMTX, DBGCOMMRX,
        DBGTDO, DBGnTDOEN, DMORE, LOCK};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
