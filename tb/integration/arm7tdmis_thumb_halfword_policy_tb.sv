// ISA-016 Thumb odd-halfword access policy matrix.
//
// ARMv4T makes odd-address LDRH, LDRSH, and STRH results UNPREDICTABLE.
// This implementation follows the r4p3 pin behavior: it presents the raw
// odd address, the memory ignores address bit 0 for a halfword transfer,
// and address bit 1 plus CFGBIGEND selects the lane. These 20 rows cover
// both Thumb LDRH/STRH encodings, LDRSH, both halfword lanes, and both
// endian configurations. They freeze project policy, not an ARM guarantee.

`timescale 1ns/1ps

module arm7tdmis_thumb_halfword_policy_tb
    import arm7tdmis_bus_pkg::*;
;

    localparam int OP_COUNT   = 5;
    localparam int CASE_COUNT = 2 * 2 * OP_COUNT;
    localparam logic [31:0] DATA_WORD  = 32'h80F1_7E25;
    localparam logic [31:0] STORE_WORD = 32'hA1B2_C3D4;

    localparam int OP_LDRH_REG = 0;
    localparam int OP_LDRH_IMM = 1;
    localparam int OP_STRH_REG = 2;
    localparam int OP_STRH_IMM = 3;
    localparam int OP_LDRSH    = 4;

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
        .CLK(CLK), .CLKEN(1'b1), .nRESET(nRESET),
        .CFGBIGEND(cfg_bigend), .nIRQ(1'b1), .nFIQ(1'b1),
        .ABORT(ABORT),
        .ADDR(ADDR), .WRITE(WRITE), .SIZE(SIZE), .PROT(PROT),
        .LOCK(LOCK), .TRANS(TRANS), .WDATA(WDATA), .RDATA(RDATA),
        .CPnMREQ(CPnMREQ), .CPSEQ(CPSEQ), .CPnTRANS(CPnTRANS),
        .CPnOPC(CPnOPC), .CPTBIT(CPTBIT), .CPnI(CPnI),
        .CPA(1'b1), .CPB(1'b1),
        .DBGEN(1'b0), .DBGRQ(1'b0), .DBGBREAK(1'b0),
        .DBGACK(DBGACK), .DBGnEXEC(DBGnEXEC),
        .DBGINSTRVALID(DBGINSTRVALID), .DBGEXT(2'b00),
        .DBGRNG(DBGRNG), .DBGCOMMTX(DBGCOMMTX),
        .DBGCOMMRX(DBGCOMMRX), .DBGTCKEN(1'b0),
        .DBGTMS(1'b0), .DBGTDI(1'b0), .DBGTDO(DBGTDO),
        .DBGnTRST(1'b1), .DBGnTDOEN(DBGnTDOEN), .DMORE(DMORE)
    );

    arm7tdmis_memory #(
        .WORDS(128)
    ) u_mem (
        .CLK(CLK), .CLKEN(1'b1), .nRESET(nRESET),
        .CFGBIGEND(cfg_bigend),
        .ADDR(ADDR), .WRITE(WRITE), .SIZE(SIZE), .PROT(PROT),
        .LOCK(LOCK), .TRANS(TRANS), .WDATA(WDATA), .RDATA(RDATA),
        .ABORT(ABORT), .inject_abort(1'b0)
    );

    int unsigned errors;

    function automatic string op_name(input int op_idx);
        unique case (op_idx)
            OP_LDRH_REG: return "LDRH register";
            OP_LDRH_IMM: return "LDRH immediate";
            OP_STRH_REG: return "STRH register";
            OP_STRH_IMM: return "STRH immediate";
            default: return "LDRSH register";
        endcase
    endfunction

    function automatic logic is_store(input int op_idx);
        return op_idx inside {OP_STRH_REG, OP_STRH_IMM};
    endfunction

    function automatic logic [15:0] selected_halfword(
        input logic big_endian,
        input logic address_bit1
    );
        logic high_lane;
        high_lane = big_endian ? ~address_bit1 : address_bit1;
        return high_lane ? DATA_WORD[31:16] : DATA_WORD[15:0];
    endfunction

    function automatic logic [31:0] expected_store_word(
        input logic big_endian,
        input logic address_bit1
    );
        logic high_lane;
        high_lane = big_endian ? ~address_bit1 : address_bit1;
        return high_lane ? {STORE_WORD[15:0], DATA_WORD[15:0]}
                         : {DATA_WORD[31:16], STORE_WORD[15:0]};
    endfunction

    task automatic fail(
        input int    case_id,
        input string label,
        input string message
    );
        $display("[thumb_halfword_policy] FAIL case %0d %s: %s",
                 case_id, label, message);
        errors++;
    endtask

    task automatic setup_case(
        input  int          case_id,
        output int          op_idx,
        output logic        address_bit1,
        output logic [31:0] data_address,
        output string       label
    );
        logic [15:0] opcode;

        op_idx = (case_id - 1) % OP_COUNT;
        address_bit1 = 1'(((case_id - 1) / OP_COUNT) % 2);
        cfg_bigend = ((case_id - 1) / (2 * OP_COUNT)) != 0;
        data_address = 32'h0000_0101
                     | (address_bit1 ? 32'h2 : 32'h0);
        label = $sformatf("%s %s lane=%0b", cfg_bigend ? "BE" : "LE",
                          op_name(op_idx), address_bit1);

        unique case (op_idx)
            OP_LDRH_REG: opcode = 16'h5AC4; // LDRH r4,[r0,r3]
            OP_LDRH_IMM: opcode = 16'h8804; // LDRH r4,[r0,#0]
            OP_STRH_REG: opcode = 16'h52C1; // STRH r1,[r0,r3]
            OP_STRH_IMM: opcode = 16'h8001; // STRH r1,[r0,#0]
            default: opcode = 16'h5EC4;     // LDRSH r4,[r0,r3]
        endcase

        for (int word = 0; word < 128; word++)
            u_mem.mem[word] = 32'hEAFF_FFFE;

        u_mem.mem[0]  = 32'hEA00_0006; // reset: B 0x20
        u_mem.mem[8]  = 32'hE59F_0058; // r0 <- odd data address
        u_mem.mem[9]  = 32'hE59F_1058; // r1 <- store data
        u_mem.mem[10] = 32'hE59F_2058; // r2 <- Thumb target 0x41
        u_mem.mem[11] = 32'hE3A0_3000; // r3 <- register offset 0
        u_mem.mem[12] = 32'hE12F_FF12; // BX r2
        u_mem.mem[13] = 32'hE3A0_50EE; // flushed successor

        u_mem.mem[16] = {
            (16'h2700 | 16'(case_id)), opcode
        };
        u_mem.mem[17] = 32'hE7FE_E7FE;

        u_mem.mem[32] = data_address;
        u_mem.mem[33] = STORE_WORD;
        u_mem.mem[34] = 32'h0000_0041;
        u_mem.mem[64] = DATA_WORD;
    endtask

    task automatic run_case(input int case_id);
        int op_idx;
        logic address_bit1;
        logic [31:0] data_address;
        logic [15:0] halfword;
        logic [31:0] expected_r4;
        logic [31:0] expected_memory;
        string label;
        int unsigned data_cycles;

        @(negedge CLK);
        nRESET = 1'b0;
        repeat (4) @(posedge CLK);
        setup_case(case_id, op_idx, address_bit1, data_address, label);
        @(negedge CLK);
        nRESET = 1'b1;

        data_cycles = 0;
        repeat (120) begin
            @(negedge CLK);
            if ((TRANS inside {TRANS_N, TRANS_S})
                && PROT[PROT_BIT_DATA]
                && ADDR == data_address) begin
                data_cycles++;
                if (SIZE !== 2'(SIZE_HALFWORD))
                    fail(case_id, label, "transfer was not halfword-sized");
                if (WRITE !== is_store(op_idx))
                    fail(case_id, label, "transfer direction mismatch");
            end
        end

        if (data_cycles != 1)
            fail(case_id, label, $sformatf(
                "expected one raw odd-address cycle, got %0d", data_cycles));

        halfword = selected_halfword(cfg_bigend, address_bit1);
        expected_r4 = (op_idx == OP_LDRSH)
                    ? {{16{halfword[15]}}, halfword}
                    : {16'h0, halfword};
        expected_memory = is_store(op_idx)
                        ? expected_store_word(cfg_bigend, address_bit1)
                        : DATA_WORD;

        if (!is_store(op_idx)
            && u_dut.u_core.u_regfile.regs[4] !== expected_r4)
            fail(case_id, label, $sformatf(
                "r4 expected %08x got %08x", expected_r4,
                u_dut.u_core.u_regfile.regs[4]));
        if (u_mem.mem[64] !== expected_memory)
            fail(case_id, label, $sformatf(
                "memory expected %08x got %08x",
                expected_memory, u_mem.mem[64]));
        if (u_dut.u_core.u_regfile.regs[7] !== 32'(case_id))
            fail(case_id, label, "completion marker did not retire");
        if (u_dut.u_core.u_regfile.regs[5] !== 32'h0000_0000)
            fail(case_id, label, "flushed ARM successor executed");
        if (!u_dut.u_core.cpsr.t)
            fail(case_id, label, "execution left Thumb state");
    endtask

    initial begin
        errors = 0;
        for (int case_id = 1; case_id <= CASE_COUNT; case_id++)
            run_case(case_id);

        if (errors != 0)
            $fatal(1, "[thumb_halfword_policy] FAIL (%0d errors)", errors);
        $display("[thumb_halfword_policy] PASS (%0d reset-per-case rows)",
                 CASE_COUNT);
        $finish;
    end

    initial begin
        repeat (CASE_COUNT * 160) @(posedge CLK);
        $fatal(1, "[thumb_halfword_policy] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, LOCK, WDATA, ABORT, CPnMREQ, CPSEQ,
        CPnTRANS, CPnOPC, CPTBIT, CPnI, DBGACK, DBGnEXEC,
        DBGINSTRVALID, DBGRNG, DBGCOMMTX, DBGCOMMRX, DBGTDO,
        DBGnTDOEN, DMORE};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
