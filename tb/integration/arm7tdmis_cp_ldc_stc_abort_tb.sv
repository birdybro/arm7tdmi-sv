// CP-006 Data Abort regression for external LDC/STC.
//
// ARM7TDMI-S uses the Base Updated abort model selected by this project:
// every requested coprocessor word is presented, requested base writeback
// remains visible, the failed store does not reach memory, and Data Abort is
// taken after the variable-length transfer terminates. Six independent cores
// inject ABORT on every one of three LDC and STC words.

`timescale 1ns/1ps

/* verilator lint_off DECLFILENAME */
module arm7tdmis_cp_ldc_stc_abort_scenario #(
    parameter bit          IS_STC     = 1'b0,
    parameter logic [31:0] ABORT_ADDR = 32'h0000_0104,
    parameter string       FST_FILE   = "cp_ldc_stc_abort.fst"
) (
    output logic done,
    output logic failed
);
    import arm7tdmis_bus_pkg::*;

    localparam logic [31:0] LDC_OPCODE = 32'hEDB0_3401;
    localparam logic [31:0] STC_OPCODE = 32'hECA0_5403;
    localparam logic [31:0] FIRST_ADDR = IS_STC
                                               ? 32'h0000_0100
                                               : 32'h0000_0104;
    localparam logic [31:0] EXPECTED_BASE = IS_STC
                                               ? 32'h0000_010C
                                               : 32'h0000_0104;
    localparam logic [31:0] WORD0 = 32'h1020_3040;
    localparam logic [31:0] WORD1 = 32'h5060_7080;
    localparam logic [31:0] WORD2 = 32'h90A0_B0C0;
    localparam logic [31:0] ORIGINAL0 = 32'hAAAA_0000;
    localparam logic [31:0] ORIGINAL1 = 32'hBBBB_0001;
    localparam logic [31:0] ORIGINAL2 = 32'hCCCC_0002;

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
    logic        inject_abort;

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
        .INIT_HEX ("../tb/programs/cp_ldc_stc_abort_test.hex")
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
        .inject_abort
    );

    // Each instance runs either the LDC or STC form from the same image.
    // Source/destination words are initialized after readmemh at time zero.
    initial begin
        #1;
        u_mem.mem[9]  = IS_STC ? STC_OPCODE : LDC_OPCODE;
        u_mem.mem[64] = IS_STC ? ORIGINAL0 : 32'h0;
        u_mem.mem[65] = IS_STC ? ORIGINAL1 : WORD0;
        u_mem.mem[66] = IS_STC ? ORIGINAL2 : WORD1;
        u_mem.mem[67] = IS_STC ? 32'h0      : WORD2;
    end

    assign inject_abort = u_mem.is_active_q
                        && (u_mem.write_q == IS_STC)
                        && (u_mem.addr_q == ABORT_ADDR);

    // The external coprocessor accepts immediately. Low/low requests a
    // continuation word; high/high terminates the third data transfer.
    logic       transfer_active_q;
    logic [1:0] words_remaining_q;
    logic       request_seen_q;

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

    // STC write data belongs to the address captured one cycle earlier.
    always_comb begin
        mem_wdata = WDATA;
        if (IS_STC && u_mem.is_active_q && u_mem.write_q) begin
            unique case (u_mem.addr_q)
                32'h0000_0100: mem_wdata = WORD0;
                32'h0000_0104: mem_wdata = WORD1;
                default:       mem_wdata = WORD2;
            endcase
        end
    end

    wire cp_data_cycle = transfer_active_q && CPnI && PROT[0]
                       && (TRANS inside {TRANS_N, TRANS_S});

    logic [2:0] seen_beats_q;
    logic       seen_abort_q;
    int unsigned protocol_errors_q;

    always_ff @(posedge CLK) begin
        if (!nRESET) begin
            transfer_active_q <= 1'b0;
            words_remaining_q <= 2'd0;
            request_seen_q    <= 1'b0;
            seen_beats_q      <= 3'b000;
            seen_abort_q      <= 1'b0;
            protocol_errors_q <= 0;
        end else begin
            if (!CPnI && !request_seen_q) begin
                request_seen_q    <= 1'b1;
                transfer_active_q <= 1'b1;
                words_remaining_q <= 2'd3;
                if (TRANS !== 2'(TRANS_N)) begin
                    $display("[cp_ldc_stc_abort/%s/%08x] FAIL request TRANS=%02b",
                             IS_STC ? "STC" : "LDC", ABORT_ADDR, TRANS);
                    protocol_errors_q <= protocol_errors_q + 1;
                end
            end

            if (cp_data_cycle) begin
                logic [31:0] expected_addr;
                expected_addr = FIRST_ADDR
                              + ((32'd3 - 32'(words_remaining_q)) << 2);
                if (ADDR !== expected_addr
                    || WRITE !== IS_STC
                    || SIZE !== 2'(SIZE_WORD)
                    || CPSEQ !== TRANS[0]) begin
                    $display("[cp_ldc_stc_abort/%s/%08x] FAIL data A/W/S/T/SEQ=%08x/%b/%02b/%02b/%b",
                             IS_STC ? "STC" : "LDC", ABORT_ADDR,
                             ADDR, WRITE, SIZE, TRANS, CPSEQ);
                    protocol_errors_q <= protocol_errors_q + 1;
                end
                if ((words_remaining_q > 1 && TRANS !== 2'(TRANS_S))
                    || (words_remaining_q == 1
                        && TRANS !== 2'(TRANS_N))) begin
                    $display("[cp_ldc_stc_abort/%s/%08x] FAIL termination rem=%0d T=%02b",
                             IS_STC ? "STC" : "LDC", ABORT_ADDR,
                             words_remaining_q, TRANS);
                    protocol_errors_q <= protocol_errors_q + 1;
                end

                unique case (ADDR)
                    FIRST_ADDR:          seen_beats_q[0] <= 1'b1;
                    FIRST_ADDR + 32'd4:  seen_beats_q[1] <= 1'b1;
                    FIRST_ADDR + 32'd8:  seen_beats_q[2] <= 1'b1;
                    default: begin
                        $display("[cp_ldc_stc_abort/%s/%08x] FAIL unexpected address %08x",
                                 IS_STC ? "STC" : "LDC", ABORT_ADDR, ADDR);
                        protocol_errors_q <= protocol_errors_q + 1;
                    end
                endcase

                if (words_remaining_q == 1) begin
                    transfer_active_q <= 1'b0;
                    words_remaining_q <= 2'd0;
                end else begin
                    words_remaining_q <= words_remaining_q - 1'b1;
                end
            end

            if (ABORT)
                seen_abort_q <= 1'b1;
        end
    end

    int unsigned errors;

    task automatic check_stc_word(
        input int unsigned beat,
        input logic [31:0] stored,
        input logic [31:0] original
    );
        logic [31:0] beat_addr;
        logic [31:0] expected;
        beat_addr = FIRST_ADDR + (32'(beat) << 2);
        expected = (ABORT_ADDR == beat_addr) ? original : stored;
        if (u_mem.mem[64 + beat] !== expected) begin
            $display("[cp_ldc_stc_abort/STC/%08x] FAIL mem[%0d] expected %08x got %08x",
                     ABORT_ADDR, beat, expected, u_mem.mem[64 + beat]);
            errors = errors + 1;
        end
    endtask

    initial begin
        $dumpfile(FST_FILE);
        $dumpvars(0, arm7tdmis_cp_ldc_stc_abort_scenario);
        done   = 1'b0;
        failed = 1'b0;
        errors = 0;

        wait (nRESET);
        repeat (180) @(posedge CLK);
        #1;

        errors = errors + protocol_errors_q;
        if (!request_seen_q || !seen_abort_q || seen_beats_q !== 3'b111) begin
            $display("[cp_ldc_stc_abort/%s/%08x] FAIL request/abort/beats=%b/%b/%03b",
                     IS_STC ? "STC" : "LDC", ABORT_ADDR,
                     request_seen_q, seen_abort_q, seen_beats_q);
            errors = errors + 1;
        end
        if (u_dut.u_core.u_regfile.regs[0] !== EXPECTED_BASE) begin
            $display("[cp_ldc_stc_abort/%s/%08x] FAIL base expected %08x got %08x",
                     IS_STC ? "STC" : "LDC", ABORT_ADDR, EXPECTED_BASE,
                     u_dut.u_core.u_regfile.regs[0]);
            errors = errors + 1;
        end
        if (u_dut.u_core.u_regfile.regs[8] !== 32'h0
            || u_dut.u_core.u_regfile.regs[9] !== 32'h0000_00EE) begin
            $display("[cp_ldc_stc_abort/%s/%08x] FAIL flow r8/r9=%08x/%08x",
                     IS_STC ? "STC" : "LDC", ABORT_ADDR,
                     u_dut.u_core.u_regfile.regs[8],
                     u_dut.u_core.u_regfile.regs[9]);
            errors = errors + 1;
        end
        if (u_dut.u_core.u_regfile.regs[28] !== 32'h0000_002C
            || u_dut.u_core.cpsr.m !== 5'b10111) begin
            $display("[cp_ldc_stc_abort/%s/%08x] FAIL LR/mode=%08x/%05b",
                     IS_STC ? "STC" : "LDC", ABORT_ADDR,
                     u_dut.u_core.u_regfile.regs[28],
                     u_dut.u_core.cpsr.m);
            errors = errors + 1;
        end

        if (IS_STC) begin
            check_stc_word(0, WORD0, ORIGINAL0);
            check_stc_word(1, WORD1, ORIGINAL1);
            check_stc_word(2, WORD2, ORIGINAL2);
        end

        failed = (errors != 0);
        done   = 1'b1;
    end

    initial begin
        repeat (260) @(posedge CLK);
        $fatal(1, "[cp_ldc_stc_abort/%s/%08x] TIMEOUT",
               IS_STC ? "STC" : "LDC", ABORT_ADDR);
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, CPnMREQ, CPnTRANS, CPnOPC, CPTBIT, DBGACK,
                     DBGnEXEC, DBGINSTRVALID, DBGRNG, DBGCOMMTX, DBGCOMMRX,
                     DBGTDO, DBGnTDOEN, DMORE};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
/* verilator lint_on DECLFILENAME */

module arm7tdmis_cp_ldc_stc_abort_tb;
    logic [5:0] done;
    logic [5:0] failed;

    arm7tdmis_cp_ldc_stc_abort_scenario #(
        .IS_STC(1'b0), .ABORT_ADDR(32'h0000_0104),
        .FST_FILE("cp_ldc_abort_beat0.fst")
    ) u_ldc0 (.done(done[0]), .failed(failed[0]));

    arm7tdmis_cp_ldc_stc_abort_scenario #(
        .IS_STC(1'b0), .ABORT_ADDR(32'h0000_0108),
        .FST_FILE("cp_ldc_abort_beat1.fst")
    ) u_ldc1 (.done(done[1]), .failed(failed[1]));

    arm7tdmis_cp_ldc_stc_abort_scenario #(
        .IS_STC(1'b0), .ABORT_ADDR(32'h0000_010C),
        .FST_FILE("cp_ldc_abort_beat2.fst")
    ) u_ldc2 (.done(done[2]), .failed(failed[2]));

    arm7tdmis_cp_ldc_stc_abort_scenario #(
        .IS_STC(1'b1), .ABORT_ADDR(32'h0000_0100),
        .FST_FILE("cp_stc_abort_beat0.fst")
    ) u_stc0 (.done(done[3]), .failed(failed[3]));

    arm7tdmis_cp_ldc_stc_abort_scenario #(
        .IS_STC(1'b1), .ABORT_ADDR(32'h0000_0104),
        .FST_FILE("cp_stc_abort_beat1.fst")
    ) u_stc1 (.done(done[4]), .failed(failed[4]));

    arm7tdmis_cp_ldc_stc_abort_scenario #(
        .IS_STC(1'b1), .ABORT_ADDR(32'h0000_0108),
        .FST_FILE("cp_stc_abort_beat2.fst")
    ) u_stc2 (.done(done[5]), .failed(failed[5]));

    initial begin
        wait (&done);
        if (|failed)
            $fatal(1, "[cp_ldc_stc_abort] FAIL");
        $display("[cp_ldc_stc_abort] PASS (all LDC/STC abort beats)");
        $finish;
    end
endmodule
