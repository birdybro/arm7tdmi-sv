// ISA-016 Thumb unaligned word-transfer policy matrix.
//
// Before ARMv6, Thumb word loads and stores whose effective address is not
// word aligned are UNPREDICTABLE. This implementation applies its shared
// ARM7 data path deterministically: loads rotate the aligned word right by
// 8*address[1:0], while stores replace the aligned word. The raw calculated
// address remains visible on ADDR. The 48 rows cover register-offset,
// immediate-offset, and SP-relative LDR/STR, all address suffixes, and both
// endian configurations. Rows with suffix zero are architectural controls;
// the other 36 rows freeze project policy, not an ARM software guarantee.

`timescale 1ns/1ps

module arm7tdmis_thumb_word_unaligned_policy_tb
    import arm7tdmis_bus_pkg::*;
;

    localparam int OP_COUNT   = 6;
    localparam int CASE_COUNT = 2 * 4 * OP_COUNT;
    localparam logic [31:0] DATA_WORD  = 32'h80F1_7E25;
    localparam logic [31:0] STORE_WORD = 32'hA1B2_C3D4;

    localparam int OP_LDR_REG = 0;
    localparam int OP_STR_REG = 1;
    localparam int OP_LDR_IMM = 2;
    localparam int OP_STR_IMM = 3;
    localparam int OP_LDR_SP  = 4;
    localparam int OP_STR_SP  = 5;

    logic CLK;
    initial begin
        CLK = 1'b0;
        forever #5 CLK = ~CLK;
    end

    logic nRESET = 1'b0;
    logic cfg_bigend = 1'b0;
    logic [31:0] ADDR;
    logic        WRITE;
    logic [1:0]  SIZE;
    logic [1:0]  PROT;
    logic        LOCK;
    logic [1:0]  TRANS;
    logic [31:0] WDATA;
    logic [31:0] RDATA;
    logic        ABORT;

    logic CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI;
    logic DBGACK, DBGnEXEC, DBGINSTRVALID;
    logic [1:0] DBGRNG;
    logic DBGCOMMTX, DBGCOMMRX, DBGTDO, DBGnTDOEN, DMORE;

    arm7tdmis_top u_dut (
        .CLK, .CLKEN(1'b1), .nRESET, .CFGBIGEND(cfg_bigend),
        .nIRQ(1'b1), .nFIQ(1'b1), .ABORT,
        .ADDR, .WRITE, .SIZE, .PROT, .LOCK, .TRANS, .WDATA, .RDATA,
        .CPnMREQ, .CPSEQ, .CPnTRANS, .CPnOPC, .CPTBIT, .CPnI,
        .CPA(1'b1), .CPB(1'b1),
        .DBGEN(1'b0), .DBGRQ(1'b0), .DBGBREAK(1'b0),
        .DBGACK, .DBGnEXEC, .DBGINSTRVALID, .DBGEXT(2'b00), .DBGRNG,
        .DBGCOMMTX, .DBGCOMMRX, .DBGTCKEN(1'b0), .DBGTMS(1'b0),
        .DBGTDI(1'b0), .DBGTDO, .DBGnTRST(1'b1), .DBGnTDOEN, .DMORE
    );

    arm7tdmis_memory #(
        .WORDS(128)
    ) u_mem (
        .CLK, .CLKEN(1'b1), .nRESET, .CFGBIGEND(cfg_bigend),
        .ADDR, .WRITE, .SIZE, .PROT, .LOCK, .TRANS, .WDATA, .RDATA,
        .ABORT, .inject_abort(1'b0)
    );

    int unsigned errors;

    function automatic logic is_store(input int op_idx);
        return op_idx inside {OP_STR_REG, OP_STR_IMM, OP_STR_SP};
    endfunction

    function automatic string op_name(input int op_idx);
        unique case (op_idx)
            OP_LDR_REG: return "LDR register";
            OP_STR_REG: return "STR register";
            OP_LDR_IMM: return "LDR immediate";
            OP_STR_IMM: return "STR immediate";
            OP_LDR_SP:  return "LDR SP-relative";
            default:    return "STR SP-relative";
        endcase
    endfunction

    function automatic logic [31:0] rotate_word(
        input logic [31:0] word,
        input logic [1:0]  low
    );
        unique case (low)
            2'd0: return word;
            2'd1: return {word[7:0], word[31:8]};
            2'd2: return {word[15:0], word[31:16]};
            default: return {word[23:0], word[31:24]};
        endcase
    endfunction

    task automatic fail(
        input int    case_id,
        input string label,
        input string message
    );
        $display("[thumb_word_unaligned_policy] FAIL case %0d %s: %s",
                 case_id, label, message);
        errors++;
    endtask

    task automatic setup_case(
        input  int          case_id,
        output int          op_idx,
        output logic [1:0]  low,
        output logic [31:0] data_address,
        output string       label
    );
        logic [15:0] opcode;

        op_idx = (case_id - 1) % OP_COUNT;
        low = 2'(((case_id - 1) / OP_COUNT) % 4);
        cfg_bigend = ((case_id - 1) / (4 * OP_COUNT)) != 0;
        data_address = 32'h0000_0100 | 32'(low);
        label = $sformatf("%s %s low=%02b",
                          cfg_bigend ? "BE" : "LE",
                          op_name(op_idx), low);

        unique case (op_idx)
            OP_LDR_REG: opcode = 16'h58C4; // LDR r4,[r0,r3]
            OP_STR_REG: opcode = 16'h50C1; // STR r1,[r0,r3]
            OP_LDR_IMM: opcode = 16'h6804; // LDR r4,[r0,#0]
            OP_STR_IMM: opcode = 16'h6001; // STR r1,[r0,#0]
            OP_LDR_SP:  opcode = 16'h9C00; // LDR r4,[sp,#0]
            default:    opcode = 16'h9100; // STR r1,[sp,#0]
        endcase

        for (int word = 0; word < 128; word++)
            u_mem.mem[word] = 32'hEAFF_FFFE;

        u_mem.mem[0]  = 32'hEA00_0006; // reset: B 0x20
        u_mem.mem[8]  = 32'hE59F_0058; // r0 <- data address
        u_mem.mem[9]  = 32'hE59F_1058; // r1 <- store word
        u_mem.mem[10] = 32'hE59F_2058; // r2 <- Thumb target 0x41
        u_mem.mem[11] = 32'hE59F_D058; // sp <- data address
        u_mem.mem[12] = 32'hE3A0_3000; // r3 <- register offset zero
        u_mem.mem[13] = 32'hE12F_FF12; // BX r2

        u_mem.mem[16] = {
            (16'h2700 | 16'(case_id)), opcode
        };
        u_mem.mem[17] = 32'hE7FE_E7FE;

        u_mem.mem[32] = data_address;
        u_mem.mem[33] = STORE_WORD;
        u_mem.mem[34] = 32'h0000_0041;
        u_mem.mem[35] = data_address;
        u_mem.mem[64] = DATA_WORD;
    endtask

    task automatic run_case(input int case_id);
        int op_idx;
        logic [1:0] low;
        logic [31:0] data_address;
        string label;
        int unsigned data_cycles;

        @(negedge CLK);
        nRESET = 1'b0;
        repeat (4) @(posedge CLK);
        setup_case(case_id, op_idx, low, data_address, label);
        @(negedge CLK);
        nRESET = 1'b1;

        data_cycles = 0;
        repeat (120) begin
            @(negedge CLK);
            if ((TRANS inside {TRANS_N, TRANS_S})
                && PROT[PROT_BIT_DATA]
                && ADDR == data_address) begin
                data_cycles++;
                if (SIZE !== 2'(SIZE_WORD))
                    fail(case_id, label, "transfer was not word-sized");
                if (WRITE !== is_store(op_idx))
                    fail(case_id, label, "transfer direction mismatch");
            end
        end

        if (data_cycles != 1)
            fail(case_id, label, $sformatf(
                "expected one raw-address data cycle, got %0d",
                data_cycles));
        if (is_store(op_idx)) begin
            if (u_mem.mem[64] !== STORE_WORD)
                fail(case_id, label, $sformatf(
                    "stored word expected %08x got %08x",
                    STORE_WORD, u_mem.mem[64]));
        end else begin
            if (u_dut.u_core.u_regfile.regs[4]
                !== rotate_word(DATA_WORD, low))
                fail(case_id, label, $sformatf(
                    "loaded word expected %08x got %08x",
                    rotate_word(DATA_WORD, low),
                    u_dut.u_core.u_regfile.regs[4]));
            if (u_mem.mem[64] !== DATA_WORD)
                fail(case_id, label, "load changed memory");
        end
        if (u_dut.u_core.u_regfile.regs[7] !== 32'(case_id))
            fail(case_id, label, "completion marker did not retire");
        if (!u_dut.u_core.cpsr.t)
            fail(case_id, label, "execution left Thumb state");
    endtask

    initial begin
        errors = 0;
        for (int case_id = 1; case_id <= CASE_COUNT; case_id++)
            run_case(case_id);

        if (errors != 0)
            $fatal(1, "[thumb_word_unaligned_policy] FAIL (%0d errors)",
                   errors);
        $display("[thumb_word_unaligned_policy] PASS (%0d reset-per-case rows)",
                 CASE_COUNT);
        $finish;
    end

    initial begin
        repeat (CASE_COUNT * 160) @(posedge CLK);
        $fatal(1, "[thumb_word_unaligned_policy] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, LOCK, WDATA, ABORT, CPnMREQ, CPSEQ,
        CPnTRANS, CPnOPC, CPTBIT, CPnI, DBGACK, DBGnEXEC,
        DBGINSTRVALID, DBGRNG, DBGCOMMTX, DBGCOMMRX, DBGTDO,
        DBGnTDOEN, DMORE};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
