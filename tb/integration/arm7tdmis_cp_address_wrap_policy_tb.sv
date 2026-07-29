// ISA-016 external-coprocessor address-space rollover policy.
//
// ARMv4T makes an LDC/STC sequence that crosses the top of the 32-bit
// address space UNPREDICTABLE. This implementation deliberately continues
// with modulo-2^32 addresses. A synthetic CP4 requests two words from an
// LDC and then supplies two words to an STC, both starting at 0xffff_fffc.
// The checks below freeze that project policy; they are not a portable ARM
// software guarantee.

`timescale 1ns/1ps

module arm7tdmis_cp_address_wrap_policy_tb
    import arm7tdmis_bus_pkg::*;
;

    localparam int CYCLE_LIMIT = 360;
    localparam logic [31:0] RESET_OPCODE = 32'hEA00_0006;
    localparam logic [31:0] HIGH_WORD    = 32'h1122_3344;
    localparam logic [31:0] STC_WORD0    = 32'hC001_C0DE;
    localparam logic [31:0] STC_WORD1    = 32'h5A17_0001;

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
    logic [31:0] WDATA;
    logic [31:0] mem_wdata;
    logic [31:0] RDATA;
    logic        ABORT;

    logic CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI;
    logic CPA, CPB;
    logic DBGACK, DBGnEXEC, DBGINSTRVALID;
    logic [1:0] DBGRNG;
    logic DBGCOMMTX, DBGCOMMRX, DBGTDO, DBGnTDOEN, DMORE;

    arm7tdmis_top u_dut (
        .CLK, .CLKEN(1'b1), .nRESET,
        .CFGBIGEND(1'b0), .nIRQ(1'b1), .nFIQ(1'b1), .ABORT,
        .ADDR, .WRITE, .SIZE, .PROT, .LOCK, .TRANS, .WDATA, .RDATA,
        .CPnMREQ, .CPSEQ, .CPnTRANS, .CPnOPC, .CPTBIT, .CPnI, .CPA, .CPB,
        .DBGEN(1'b0), .DBGRQ(1'b0), .DBGBREAK(1'b0),
        .DBGACK, .DBGnEXEC, .DBGINSTRVALID, .DBGEXT(2'b00), .DBGRNG,
        .DBGCOMMTX, .DBGCOMMRX, .DBGTCKEN(1'b0), .DBGTMS(1'b0),
        .DBGTDI(1'b0), .DBGTDO, .DBGnTRST(1'b1), .DBGnTDOEN, .DMORE
    );

    // The memory model intentionally aliases the raw top-of-space word to
    // mem[255] and wrapped address zero to mem[0]. Raw ADDR is checked
    // independently on every coprocessor data address phase.
    arm7tdmis_memory #(
        .WORDS(256)
    ) u_mem (
        .CLK, .CLKEN(1'b1), .nRESET, .CFGBIGEND(1'b0),
        .ADDR, .WRITE, .SIZE, .PROT, .LOCK, .TRANS,
        .WDATA(mem_wdata), .RDATA, .ABORT, .inject_abort(1'b0)
    );

    initial begin
        #1;
        for (int word = 0; word < 256; word++)
            u_mem.mem[word] = 32'hEAFF_FFFE;

        u_mem.mem[0]  = RESET_OPCODE; // B 0x20; wrapped LDC word 1
        u_mem.mem[8]  = 32'hE59F_0058; // r0 <- 0xffff_fffc
        u_mem.mem[9]  = 32'hE59F_1058; // r1 <- 0xffff_fffc
        u_mem.mem[10] = 32'hECB0_3402; // LDC p4,c3,[r0],#8!
        u_mem.mem[11] = 32'hECA1_5402; // STC p4,c5,[r1],#8!
        u_mem.mem[12] = 32'hE3A0_2022; // completion marker
        u_mem.mem[13] = 32'hEAFF_FFFE;
        u_mem.mem[32] = 32'hFFFF_FFFC;
        u_mem.mem[33] = 32'hFFFF_FFFC;
        u_mem.mem[255] = HIGH_WORD;
    end

    int unsigned protocol_errors;
    int unsigned accepted_count;
    int unsigned data_cycle_count;
    int unsigned ldc_capture_count;
    int unsigned stc_address_count;

    logic request_accepted_q;
    logic transfer_active_q;
    logic transfer_is_stc_q;
    logic [1:0] words_remaining_q;
    logic ldc_response_pending_q;
    logic stc_response_pending_q;
    logic [31:0] ldc_captured [0:1];

    wire cp_data_cycle = transfer_active_q && CPnI && PROT[0]
                       && (TRANS inside {TRANS_N, TRANS_S});

    // Both instructions are accepted immediately. Low/low requests the
    // second word; high/high marks that second word as the final transfer.
    always_comb begin
        CPA = 1'b1;
        CPB = 1'b1;
        if (!CPnI) begin
            CPA = 1'b0;
            CPB = 1'b0;
        end else if (transfer_active_q && (words_remaining_q > 1)) begin
            CPA = 1'b0;
            CPB = 1'b0;
        end
    end

    // STC data follows its address by one cycle on the pipelined memory
    // contract, so the external coprocessor replaces core WDATA only in
    // the matching response phase.
    always_comb begin
        mem_wdata = WDATA;
        if (stc_response_pending_q)
            mem_wdata = (stc_address_count == 1) ? STC_WORD0 : STC_WORD1;
    end

    always_ff @(posedge CLK) begin
        if (!nRESET) begin
            protocol_errors        <= 0;
            accepted_count         <= 0;
            data_cycle_count       <= 0;
            ldc_capture_count      <= 0;
            stc_address_count      <= 0;
            request_accepted_q     <= 1'b0;
            transfer_active_q      <= 1'b0;
            transfer_is_stc_q      <= 1'b0;
            words_remaining_q      <= 2'd0;
            ldc_response_pending_q <= 1'b0;
            stc_response_pending_q <= 1'b0;
            ldc_captured[0]        <= 32'h0;
            ldc_captured[1]        <= 32'h0;
        end else begin
            ldc_response_pending_q <= 1'b0;
            stc_response_pending_q <= 1'b0;

            if (ldc_response_pending_q) begin
                if (ldc_capture_count < 2)
                    ldc_captured[ldc_capture_count] <= RDATA;
                ldc_capture_count <= ldc_capture_count + 1;
            end

            if (CPnI)
                request_accepted_q <= 1'b0;

            if (!CPnI && !CPA && !CPB && !request_accepted_q) begin
                request_accepted_q <= 1'b1;
                accepted_count     <= accepted_count + 1;
                transfer_active_q  <= 1'b1;
                transfer_is_stc_q  <= (accepted_count == 1);
                words_remaining_q  <= 2'd2;
                if (accepted_count == 1)
                    stc_address_count <= 0;

                if (TRANS !== 2'(TRANS_N)) begin
                    $display("[cp_address_wrap_policy] FAIL accepted T=%02b",
                             TRANS);
                    protocol_errors <= protocol_errors + 1;
                end
            end

            if (cp_data_cycle) begin
                logic [31:0] expected_addr;
                expected_addr = (words_remaining_q == 2)
                              ? 32'hFFFF_FFFC : 32'h0000_0000;

                data_cycle_count <= data_cycle_count + 1;
                if (ADDR !== expected_addr
                    || SIZE !== 2'(SIZE_WORD)
                    || WRITE !== transfer_is_stc_q
                    || CPSEQ !== TRANS[0]) begin
                    $display("[cp_address_wrap_policy] FAIL A/S/W/T/SEQ=%08x/%02b/%b/%02b/%b",
                             ADDR, SIZE, WRITE, TRANS, CPSEQ);
                    protocol_errors <= protocol_errors + 1;
                end
                if ((words_remaining_q == 2 && TRANS !== 2'(TRANS_S))
                    || (words_remaining_q == 1
                        && TRANS !== 2'(TRANS_N))) begin
                    $display("[cp_address_wrap_policy] FAIL rem/T=%0d/%02b",
                             words_remaining_q, TRANS);
                    protocol_errors <= protocol_errors + 1;
                end

                if (transfer_is_stc_q) begin
                    stc_response_pending_q <= 1'b1;
                    stc_address_count <= stc_address_count + 1;
                end else begin
                    ldc_response_pending_q <= 1'b1;
                end

                if (words_remaining_q == 1) begin
                    transfer_active_q <= 1'b0;
                    words_remaining_q <= 2'd0;
                end else begin
                    words_remaining_q <= words_remaining_q - 1'b1;
                end
            end
        end
    end

    initial begin
        int unsigned errors;

        $dumpfile("cp_address_wrap_policy.fst");
        $dumpvars(0, arm7tdmis_cp_address_wrap_policy_tb);

        wait (nRESET);
        repeat (260) @(posedge CLK);
        #1;

        errors = protocol_errors;
        if (accepted_count != 2 || data_cycle_count != 4) begin
            $display("[cp_address_wrap_policy] FAIL accepted/data=%0d/%0d",
                     accepted_count, data_cycle_count);
            errors++;
        end
        if (ldc_capture_count != 2
            || ldc_captured[0] !== HIGH_WORD
            || ldc_captured[1] !== RESET_OPCODE) begin
            $display("[cp_address_wrap_policy] FAIL LDC count/data=%0d/%08x/%08x",
                     ldc_capture_count, ldc_captured[0], ldc_captured[1]);
            errors++;
        end
        if (u_mem.mem[255] !== STC_WORD0
            || u_mem.mem[0] !== STC_WORD1) begin
            $display("[cp_address_wrap_policy] FAIL STC aliases=%08x/%08x",
                     u_mem.mem[255], u_mem.mem[0]);
            errors++;
        end
        if (u_dut.u_core.u_regfile.regs[0] !== 32'h0000_0004
            || u_dut.u_core.u_regfile.regs[1] !== 32'h0000_0004
            || u_dut.u_core.u_regfile.regs[2] !== 32'h0000_0022) begin
            $display("[cp_address_wrap_policy] FAIL r0/r1/r2=%08x/%08x/%08x",
                     u_dut.u_core.u_regfile.regs[0],
                     u_dut.u_core.u_regfile.regs[1],
                     u_dut.u_core.u_regfile.regs[2]);
            errors++;
        end

        if (errors != 0)
            $fatal(1, "[cp_address_wrap_policy] FAIL (%0d errors)", errors);
        $display("[cp_address_wrap_policy] PASS");
        $finish;
    end

    initial begin
        repeat (CYCLE_LIMIT) @(posedge CLK);
        $fatal(1, "[cp_address_wrap_policy] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, CPnMREQ, CPnTRANS, CPnOPC, CPTBIT,
        DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG, DBGCOMMTX, DBGCOMMRX,
        DBGTDO, DBGnTDOEN, DMORE, LOCK};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
