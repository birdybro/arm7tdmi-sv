// CP-005/006 regression for variable-length external LDC/STC transfers.
//
// A synthetic CP4 busy-waits LDC for two cycles, then transfers three
// memory words into the coprocessor. A ready STC transfers three words
// back to memory. This checks Table 7-18/7-19 N/S termination, address
// generation, base writeback, CPSEQ, data direction, and forward progress.

`timescale 1ns/1ps

module arm7tdmis_cp_ldc_stc_tb
    import arm7tdmis_bus_pkg::*;
;

    localparam int CYCLE_LIMIT = 520;
    localparam logic [31:0] LDC_BASE = 32'h0000_0104;
    localparam logic [31:0] STC_BASE = 32'h0000_0120;
    localparam logic [31:0] LDC_WORD0 = 32'h1122_3344;
    localparam logic [31:0] LDC_WORD1 = 32'h5566_7788;
    localparam logic [31:0] LDC_WORD2 = 32'h99AA_BBCC;
    localparam logic [31:0] STC_WORD0 = 32'hC001_C0DE;
    localparam logic [31:0] STC_WORD1 = 32'h5A17_0001;
    localparam logic [31:0] STC_WORD2 = 32'hDEAD_BEEF;

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
    logic [31:0] mem_wdata;
    logic [31:0] RDATA;
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

    arm7tdmis_memory #(
        .WORDS    (256),
        .INIT_HEX ("../tb/programs/cp_ldc_stc_test.hex")
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

    // Seed the coprocessor-load source and the store destinations after
    // readmemh has initialized the program image at time zero.
    initial begin
        #1;
        u_mem.mem[65] = LDC_WORD0; // 0x104
        u_mem.mem[66] = LDC_WORD1; // 0x108
        u_mem.mem[67] = LDC_WORD2; // 0x10c
        u_mem.mem[72] = 32'h0;     // 0x120
        u_mem.mem[73] = 32'h0;     // 0x124
        u_mem.mem[74] = 32'h0;     // 0x128
    end

    int unsigned errors;
    int unsigned protocol_errors;
    int unsigned accepted_count;
    int unsigned busy_cycles_seen;
    int unsigned ldc_data_cycles;
    int unsigned stc_data_cycles;
    int unsigned ldc_capture_count;

    logic [1:0] busy_remaining_q;
    logic request_accepted_q;
    logic transfer_active_q;
    logic transfer_is_stc_q;
    logic [2:0] words_remaining_q;
    logic ldc_response_pending_q;
    logic stc_response_pending_q;
    logic [2:0] stc_address_count_q;
    logic [31:0] ldc_captured [0:2];

    wire cp_data_cycle = transfer_active_q && CPnI && PROT[0]
                       && (TRANS inside {TRANS_N, TRANS_S});

    // During CPnI-low the first instruction busy-waits and the second is
    // accepted immediately. Once active, low/low requests another word;
    // high/high marks the current transfer as the final word.
    always_comb begin
        CPA = 1'b1;
        CPB = 1'b1;
        if (!CPnI) begin
            CPA = 1'b0;
            CPB = (busy_remaining_q != 0);
        end else if (transfer_active_q) begin
            if (words_remaining_q > 1) begin
                CPA = 1'b0;
                CPB = 1'b0;
            end
        end
    end

    // STC data is supplied by the external coprocessor directly to the
    // system write-data mux. It trails the corresponding address phase by
    // one cycle, exactly like core WDATA on the pipelined memory contract.
    always_comb begin
        mem_wdata = WDATA;
        if (stc_response_pending_q) begin
            unique case (stc_address_count_q)
                3'd1: mem_wdata = STC_WORD0;
                3'd2: mem_wdata = STC_WORD1;
                default: mem_wdata = STC_WORD2;
            endcase
        end
    end

    always_ff @(posedge CLK) begin
        if (!nRESET) begin
            protocol_errors       <= 0;
            accepted_count        <= 0;
            busy_cycles_seen      <= 0;
            ldc_data_cycles       <= 0;
            stc_data_cycles       <= 0;
            ldc_capture_count     <= 0;
            busy_remaining_q      <= 2'd2;
            request_accepted_q    <= 1'b0;
            transfer_active_q     <= 1'b0;
            transfer_is_stc_q     <= 1'b0;
            words_remaining_q     <= 3'd0;
            ldc_response_pending_q <= 1'b0;
            stc_response_pending_q <= 1'b0;
            stc_address_count_q   <= 3'd0;
            ldc_captured[0]       <= 32'h0;
            ldc_captured[1]       <= 32'h0;
            ldc_captured[2]       <= 32'h0;
        end else begin
            ldc_response_pending_q <= 1'b0;
            stc_response_pending_q <= 1'b0;

            if (ldc_response_pending_q) begin
                if (ldc_capture_count < 3)
                    ldc_captured[ldc_capture_count] <= RDATA;
                ldc_capture_count <= ldc_capture_count + 1;
            end

            if (CPnI)
                request_accepted_q <= 1'b0;

            if (!CPnI && CPB) begin
                busy_cycles_seen <= busy_cycles_seen + 1;
                if (busy_remaining_q != 0)
                    busy_remaining_q <= busy_remaining_q - 1'b1;
                if (TRANS !== 2'(TRANS_I)) begin
                    $display("[cp_ldc_stc] FAIL busy phase T=%02b", TRANS);
                    protocol_errors <= protocol_errors + 1;
                end
            end

            if (!CPnI && !CPA && !CPB && !request_accepted_q) begin
                request_accepted_q <= 1'b1;
                accepted_count     <= accepted_count + 1;
                transfer_active_q  <= 1'b1;
                transfer_is_stc_q  <= (accepted_count == 1);
                words_remaining_q  <= 3'd3;
                if (accepted_count == 1)
                    stc_address_count_q <= 3'd0;

                if (TRANS !== 2'(TRANS_N)) begin
                    $display("[cp_ldc_stc] FAIL accepted phase T=%02b", TRANS);
                    protocol_errors <= protocol_errors + 1;
                end
            end

            if (cp_data_cycle) begin
                logic [31:0] expected_addr;
                expected_addr = (transfer_is_stc_q ? STC_BASE : LDC_BASE)
                              + ((32'd3 - 32'(words_remaining_q)) * 32'd4);

                if (ADDR !== expected_addr
                    || SIZE !== 2'(SIZE_WORD)
                    || WRITE !== transfer_is_stc_q
                    || CPSEQ !== TRANS[0]) begin
                    $display("[cp_ldc_stc] FAIL data A/S/W/T/SEQ=%08x/%02b/%b/%02b/%b",
                             ADDR, SIZE, WRITE, TRANS, CPSEQ);
                    protocol_errors <= protocol_errors + 1;
                end
                if ((words_remaining_q > 1 && TRANS !== 2'(TRANS_S))
                    || (words_remaining_q == 1 && TRANS !== 2'(TRANS_N))) begin
                    $display("[cp_ldc_stc] FAIL continuation rem=%0d T=%02b",
                             words_remaining_q, TRANS);
                    protocol_errors <= protocol_errors + 1;
                end

                if (transfer_is_stc_q) begin
                    stc_data_cycles <= stc_data_cycles + 1;
                    stc_response_pending_q <= 1'b1;
                    stc_address_count_q <= stc_address_count_q + 1'b1;
                end else begin
                    ldc_data_cycles <= ldc_data_cycles + 1;
                    ldc_response_pending_q <= 1'b1;
                end

                if (words_remaining_q == 1) begin
                    transfer_active_q <= 1'b0;
                    words_remaining_q <= 3'd0;
                end else begin
                    words_remaining_q <= words_remaining_q - 1'b1;
                end
            end
        end
    end

    initial begin
        $dumpfile("cp_ldc_stc.fst");
        $dumpvars(0, arm7tdmis_cp_ldc_stc_tb);
        errors = 0;

        wait (nRESET);
        repeat (420) @(posedge CLK);
        #1;
        errors = protocol_errors;

        if (accepted_count != 2 || busy_cycles_seen != 2) begin
            $display("[cp_ldc_stc] FAIL accepted/busy=%0d/%0d",
                     accepted_count, busy_cycles_seen);
            errors = errors + 1;
        end
        if (ldc_data_cycles != 3 || stc_data_cycles != 3) begin
            $display("[cp_ldc_stc] FAIL LDC/STC cycles=%0d/%0d",
                     ldc_data_cycles, stc_data_cycles);
            errors = errors + 1;
        end
        if (ldc_capture_count != 3
            || ldc_captured[0] !== LDC_WORD0
            || ldc_captured[1] !== LDC_WORD1
            || ldc_captured[2] !== LDC_WORD2) begin
            $display("[cp_ldc_stc] FAIL LDC data count/words=%0d %08x/%08x/%08x",
                     ldc_capture_count, ldc_captured[0],
                     ldc_captured[1], ldc_captured[2]);
            errors = errors + 1;
        end
        if (u_mem.mem[72] !== STC_WORD0
            || u_mem.mem[73] !== STC_WORD1
            || u_mem.mem[74] !== STC_WORD2) begin
            $display("[cp_ldc_stc] FAIL STC memory=%08x/%08x/%08x",
                     u_mem.mem[72], u_mem.mem[73], u_mem.mem[74]);
            errors = errors + 1;
        end
        if (u_dut.u_core.u_regfile.regs[0] !== 32'h0000_0104
            || u_dut.u_core.u_regfile.regs[1] !== 32'h0000_012C) begin
            $display("[cp_ldc_stc] FAIL writeback r0/r1=%08x/%08x",
                     u_dut.u_core.u_regfile.regs[0],
                     u_dut.u_core.u_regfile.regs[1]);
            errors = errors + 1;
        end
        if (u_dut.u_core.u_regfile.regs[2] !== 32'h22
            || u_dut.u_core.u_regfile.regs[10] !== 32'h0) begin
            $display("[cp_ldc_stc] FAIL completion/undef r2/r10=%08x/%08x",
                     u_dut.u_core.u_regfile.regs[2],
                     u_dut.u_core.u_regfile.regs[10]);
            errors = errors + 1;
        end

        if (errors != 0)
            $fatal(1, "[cp_ldc_stc] FAIL (%0d errors)", errors);
        $display("[cp_ldc_stc] PASS");
        $finish;
    end

    initial begin
        repeat (CYCLE_LIMIT) @(posedge CLK);
        $fatal(1, "[cp_ldc_stc] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, CPnMREQ, CPnTRANS, CPnOPC, CPTBIT,
        DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG, DBGCOMMTX, DBGCOMMRX,
        DBGTDO, DBGnTDOEN, DMORE, LOCK};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
