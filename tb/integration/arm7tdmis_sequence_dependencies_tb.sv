// ISA-015 sequence and dependency regression.
//
// Isolated opcode tests cannot expose a stale decode-stage operand, a
// writeback that lands one cycle too late, or a redirect that leaks across
// the next PC-writing instruction. These reset-per-row programs exercise
// immediately adjacent producer/consumer pairs, coherent self-modification
// followed by an explicit pipeline flush, adjacent PC changes through both
// fast and memory paths, interworking redirects, and immediate bank use after
// mode changes.

`timescale 1ns/1ps

module arm7tdmis_sequence_dependencies_tb
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_types_pkg::*;
;

    localparam int CASE_COUNT = 16;
    localparam logic [31:0] DATA_BASE = 32'h0000_0200;

    logic CLK;
    initial begin
        CLK = 1'b0;
        forever #5 CLK = ~CLK;
    end

    logic nRESET = 1'b0;
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
        .CFGBIGEND(1'b0), .nIRQ(1'b1), .nFIQ(1'b1), .ABORT(ABORT),
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
        .WORDS(256)
    ) u_mem (
        .CLK(CLK), .CLKEN(1'b1), .nRESET(nRESET),
        .CFGBIGEND(1'b0),
        .ADDR(ADDR), .WRITE(WRITE), .SIZE(SIZE), .PROT(PROT),
        .LOCK(LOCK), .TRANS(TRANS), .WDATA(WDATA), .RDATA(RDATA),
        .ABORT(ABORT), .inject_abort(1'b0)
    );

    int unsigned rows_completed = 0;

    function automatic logic [31:0] arm_branch(
        input logic [31:0] from_pc,
        input logic [31:0] to_pc
    );
        logic signed [31:0] displacement;
        displacement = $signed(to_pc) - $signed(from_pc + 32'd8);
        return 32'hEA00_0000
             | (32'(displacement >>> 2) & 32'h00FF_FFFF);
    endfunction

    function automatic logic [31:0] ldr_literal(
        input logic [3:0]  rd,
        input logic [31:0] from_pc,
        input logic [31:0] literal_pc
    );
        logic [31:0] offset;
        offset = literal_pc - (from_pc + 32'd8);
        return 32'hE59F_0000 | (32'(rd) << 12)
             | (offset & 32'h0000_0FFF);
    endfunction

    function automatic logic [31:0] mov_imm(
        input logic [3:0] rd,
        input logic [7:0] imm
    );
        return 32'hE3A0_0000 | (32'(rd) << 12) | 32'(imm);
    endfunction

    function automatic string case_name(input int case_id);
        unique case (case_id)
             1: return "DP result to Rn";
             2: return "DP result to shifted Rm";
             3: return "DP result to register-shift Rs";
             4: return "flags to immediate condition";
             5: return "LDR result to DP";
             6: return "post-index base to next LDR";
             7: return "MUL result to DP";
             8: return "UMULL halves to DP";
             9: return "LDM results to DP";
            10: return "DP result to store data";
            11: return "mode changes to banked SP";
            12: return "self-modifying store plus refill";
            13: return "branch to MOV-pc to branch";
            14: return "branch to LDR-pc to branch";
            15: return "ARM/Thumb/ARM adjacent BX chain";
            16: return "back-to-back UMULL result independence";
            default: return "invalid";
        endcase
    endfunction

    function automatic int expected_flush_count(input int case_id);
        unique case (case_id)
            12: return 1;
            13, 14, 15: return 3;
            default: return 0;
        endcase
    endfunction

    function automatic logic [31:0] expected_flush_target(
        input int case_id,
        input int flush_idx
    );
        unique case (case_id)
            12: return 32'h0000_0034;
            13, 14, 15: begin
                unique case (flush_idx)
                    0: return 32'h0000_0040;
                    1: return 32'h0000_0060;
                    default: return 32'h0000_0080;
                endcase
            end
            default: return 32'hxxxx_xxxx;
        endcase
    endfunction

    task automatic fail(input int case_id, input string reason);
        $fatal(1, "[sequence_dependencies] FAIL case %0d (%s): %s",
               case_id, case_name(case_id), reason);
    endtask

    task automatic install_marker(
        input logic [31:0] marker_pc,
        input logic [7:0]  case_id
    );
        u_mem.mem[marker_pc >> 2] = mov_imm(4'd7, case_id);
        u_mem.mem[(marker_pc >> 2) + 1] =
            arm_branch(marker_pc + 32'd4, marker_pc + 32'd4);
    endtask

    task automatic setup_case(input int case_id);
        for (int word = 0; word < 256; word++)
            u_mem.mem[word] = 32'hEAFF_FFFE;

        u_mem.mem[0] = arm_branch(32'h0000_0000, 32'h0000_0020);

        unique case (case_id)
            1: begin
                u_mem.mem[8]  = mov_imm(4'd0, 8'd5);
                u_mem.mem[9]  = 32'hE280_1003; // ADD r1,r0,#3
                install_marker(32'h0000_0028, 8'(case_id));
            end
            2: begin
                u_mem.mem[8]  = mov_imm(4'd0, 8'd3);
                u_mem.mem[9]  = 32'hE082_1100; // ADD r1,r2,r0,LSL #2
                install_marker(32'h0000_0028, 8'(case_id));
            end
            3: begin
                u_mem.mem[8]  = mov_imm(4'd2, 8'd2);
                u_mem.mem[9]  = mov_imm(4'd1, 8'd3);
                u_mem.mem[10] = 32'hE1A0_4112; // MOV r4,r2,LSL r1
                install_marker(32'h0000_002C, 8'(case_id));
            end
            4: begin
                u_mem.mem[8]  = mov_imm(4'd0, 8'd5);
                u_mem.mem[9]  = 32'hE350_0005; // CMP r0,#5
                u_mem.mem[10] = 32'h0285_5001; // ADDEQ r5,r5,#1
                u_mem.mem[11] = 32'h1285_5008; // ADDNE r5,r5,#8
                install_marker(32'h0000_0030, 8'(case_id));
            end
            5: begin
                u_mem.mem[8] = ldr_literal(
                    4'd0, 32'h0000_0020, 32'h0000_0100);
                u_mem.mem[9] = 32'hE280_1001; // ADD r1,r0,#1
                install_marker(32'h0000_0028, 8'(case_id));
                u_mem.mem[64] = 32'h1234_5678;
            end
            6: begin
                u_mem.mem[8] = ldr_literal(
                    4'd0, 32'h0000_0020, 32'h0000_0100);
                u_mem.mem[9]  = 32'hE490_1004; // LDR r1,[r0],#4
                u_mem.mem[10] = 32'hE590_2000; // LDR r2,[r0]
                install_marker(32'h0000_002C, 8'(case_id));
                u_mem.mem[64] = DATA_BASE;
                u_mem.mem[128] = 32'h1111_1111;
                u_mem.mem[129] = 32'h2222_2222;
            end
            7: begin
                u_mem.mem[8]  = mov_imm(4'd0, 8'd3);
                u_mem.mem[9]  = mov_imm(4'd1, 8'd7);
                u_mem.mem[10] = 32'hE002_0190; // MUL r2,r0,r1
                u_mem.mem[11] = 32'hE282_3001; // ADD r3,r2,#1
                install_marker(32'h0000_0030, 8'(case_id));
            end
            8: begin
                u_mem.mem[8]  = 32'hE3A0_0201; // MOV r0,#0x10000000
                u_mem.mem[9]  = mov_imm(4'd1, 8'h10);
                u_mem.mem[10] = 32'hE083_2190; // UMULL r2,r3,r0,r1
                u_mem.mem[11] = 32'hE083_4002; // ADD r4,r3,r2
                install_marker(32'h0000_0030, 8'(case_id));
            end
            9: begin
                u_mem.mem[8] = ldr_literal(
                    4'd4, 32'h0000_0020, 32'h0000_0100);
                u_mem.mem[9]  = 32'hE8B4_0003; // LDMIA r4!,{r0,r1}
                u_mem.mem[10] = 32'hE080_2001; // ADD r2,r0,r1
                install_marker(32'h0000_002C, 8'(case_id));
                u_mem.mem[64] = DATA_BASE;
                u_mem.mem[128] = 32'h0102_0304;
                u_mem.mem[129] = 32'h1010_2020;
            end
            10: begin
                u_mem.mem[8] = ldr_literal(
                    4'd0, 32'h0000_0020, 32'h0000_0100);
                u_mem.mem[9]  = mov_imm(4'd1, 8'h5A);
                u_mem.mem[10] = 32'hE580_1000; // STR r1,[r0]
                u_mem.mem[11] = 32'hE590_2000; // LDR r2,[r0]
                install_marker(32'h0000_0030, 8'(case_id));
                u_mem.mem[64]  = DATA_BASE;
                u_mem.mem[128] = 32'hDEAD_BEEF;
            end
            11: begin
                u_mem.mem[8]  = 32'hE321_F01F; // System
                u_mem.mem[9]  = mov_imm(4'd13, 8'h11);
                u_mem.mem[10] = 32'hE321_F011; // FIQ
                u_mem.mem[11] = mov_imm(4'd13, 8'h22);
                u_mem.mem[12] = 32'hE321_F013; // Supervisor
                u_mem.mem[13] = mov_imm(4'd13, 8'h33);
                u_mem.mem[14] = 32'hE321_F011; // FIQ
                u_mem.mem[15] = 32'hE28D_0001; // ADD r0,sp,#1
                u_mem.mem[16] = 32'hE321_F01F; // System
                u_mem.mem[17] = 32'hE28D_1001; // ADD r1,sp,#1
                u_mem.mem[18] = 32'hE321_F013; // Supervisor
                u_mem.mem[19] = 32'hE28D_2001; // ADD r2,sp,#1
                install_marker(32'h0000_0050, 8'(case_id));
            end
            12: begin
                u_mem.mem[8] = ldr_literal(
                    4'd0, 32'h0000_0020, 32'h0000_0100);
                u_mem.mem[9] = ldr_literal(
                    4'd1, 32'h0000_0024, 32'h0000_0104);
                u_mem.mem[10] = 32'hE580_1000; // STR patched opcode,[r0]
                u_mem.mem[11] = arm_branch(
                    32'h0000_002C, 32'h0000_0034);
                u_mem.mem[12] = mov_imm(4'd6, 8'hEE); // must flush
                u_mem.mem[13] = mov_imm(4'd7, 8'hEE); // stale opcode
                u_mem.mem[14] = arm_branch(
                    32'h0000_0038, 32'h0000_0038);
                u_mem.mem[64] = 32'h0000_0034;
                u_mem.mem[65] = mov_imm(4'd7, 8'(case_id));
            end
            13: begin
                u_mem.mem[8] = ldr_literal(
                    4'd0, 32'h0000_0020, 32'h0000_0100);
                u_mem.mem[9] = arm_branch(
                    32'h0000_0024, 32'h0000_0040);
                u_mem.mem[10] = mov_imm(4'd3, 8'hEE);
                u_mem.mem[16] = 32'hE1A0_F000; // MOV pc,r0
                u_mem.mem[17] = mov_imm(4'd4, 8'hEE);
                u_mem.mem[24] = arm_branch(
                    32'h0000_0060, 32'h0000_0080);
                u_mem.mem[25] = mov_imm(4'd5, 8'hEE);
                install_marker(32'h0000_0080, 8'(case_id));
                u_mem.mem[64] = 32'h0000_0060;
            end
            14: begin
                u_mem.mem[8] = ldr_literal(
                    4'd0, 32'h0000_0020, 32'h0000_0100);
                u_mem.mem[9] = arm_branch(
                    32'h0000_0024, 32'h0000_0040);
                u_mem.mem[16] = 32'hE590_F000; // LDR pc,[r0]
                u_mem.mem[17] = mov_imm(4'd4, 8'hEE);
                u_mem.mem[24] = arm_branch(
                    32'h0000_0060, 32'h0000_0080);
                u_mem.mem[25] = mov_imm(4'd5, 8'hEE);
                install_marker(32'h0000_0080, 8'(case_id));
                u_mem.mem[64]  = DATA_BASE;
                u_mem.mem[128] = 32'h0000_0060;
            end
            15: begin
                u_mem.mem[8] = ldr_literal(
                    4'd0, 32'h0000_0020, 32'h0000_0100);
                u_mem.mem[9] = ldr_literal(
                    4'd1, 32'h0000_0024, 32'h0000_0104);
                u_mem.mem[10] = 32'hE12F_FF10; // BX r0
                u_mem.mem[11] = mov_imm(4'd3, 8'hEE);
                u_mem.mem[16] = {16'h25EE, 16'h4708}; // BX r1; bad MOVS
                u_mem.mem[24] = arm_branch(
                    32'h0000_0060, 32'h0000_0080);
                u_mem.mem[25] = mov_imm(4'd5, 8'hEE);
                install_marker(32'h0000_0080, 8'(case_id));
                u_mem.mem[64] = 32'h0000_0041;
                u_mem.mem[65] = 32'h0000_0060;
            end
            16: begin
                u_mem.mem[8]  = mov_imm(4'd0, 8'd4);
                u_mem.mem[9]  = mov_imm(4'd1, 8'd8);
                u_mem.mem[10] = 32'hE083_2190; // UMULL r2,r3,r0,r1
                u_mem.mem[11] = 32'hE3E0_0000; // MVN r0,#0
                u_mem.mem[12] = 32'hE3E0_1000; // MVN r1,#0
                u_mem.mem[13] = 32'hE083_2190; // UMULL r2,r3,r0,r1
                install_marker(32'h0000_0038, 8'(case_id));
            end
            default: ;
        endcase
    endtask

    task automatic check_case(input int case_id);
        unique case (case_id)
            1: if (u_dut.u_core.u_regfile.regs[1] !== 32'd8)
                   fail(case_id, "consumer did not see preceding DP result");
            2: if (u_dut.u_core.u_regfile.regs[1] !== 32'd12)
                   fail(case_id, "shifted Rm used a stale DP result");
            3: if (u_dut.u_core.u_regfile.regs[4] !== 32'd16)
                   fail(case_id, "register shift used a stale Rs");
            4: if (u_dut.u_core.u_regfile.regs[5] !== 32'd1)
                   fail(case_id, "condition did not see preceding flags");
            5: if (u_dut.u_core.u_regfile.regs[1] !== 32'h1234_5679)
                   fail(case_id, "consumer did not see LDR writeback");
            6: begin
                if (u_dut.u_core.u_regfile.regs[0]
                    !== DATA_BASE + 32'd4
                    || u_dut.u_core.u_regfile.regs[1] !== 32'h1111_1111
                    || u_dut.u_core.u_regfile.regs[2] !== 32'h2222_2222)
                    fail(case_id, "next LDR missed post-index base/result");
            end
            7: if (u_dut.u_core.u_regfile.regs[2] !== 32'd21
                  || u_dut.u_core.u_regfile.regs[3] !== 32'd22)
                   fail(case_id, "consumer did not see MUL result");
            8: begin
                if (u_dut.u_core.u_regfile.regs[2] !== 32'h0
                    || u_dut.u_core.u_regfile.regs[3] !== 32'h1
                    || u_dut.u_core.u_regfile.regs[4] !== 32'h1)
                    fail(case_id, "consumer missed UMULL low/high commit");
            end
            9: begin
                if (u_dut.u_core.u_regfile.regs[0] !== 32'h0102_0304
                    || u_dut.u_core.u_regfile.regs[1] !== 32'h1010_2020
                    || u_dut.u_core.u_regfile.regs[2] !== 32'h1112_2324
                    || u_dut.u_core.u_regfile.regs[4]
                       !== DATA_BASE + 32'd8)
                    fail(case_id, "consumer missed LDM result/writeback");
            end
            10: begin
                if (u_mem.mem[128] !== 32'h0000_005A
                    || u_dut.u_core.u_regfile.regs[2] !== 32'h0000_005A)
                    fail(case_id, "store/load missed adjacent DP data");
            end
            11: begin
                if (u_dut.u_core.u_regfile.regs[0] !== 32'h23
                    || u_dut.u_core.u_regfile.regs[1] !== 32'h12
                    || u_dut.u_core.u_regfile.regs[2] !== 32'h34
                    || u_dut.u_core.u_regfile.regs[13] !== 32'h11
                    || u_dut.u_core.u_regfile.regs[21] !== 32'h22
                    || u_dut.u_core.u_regfile.regs[25] !== 32'h33)
                    fail(case_id, "mode successor selected a stale bank");
            end
            12: begin
                if (u_mem.mem[13] !== mov_imm(4'd7, 8'(case_id))
                    || u_dut.u_core.u_regfile.regs[6] !== 32'h0)
                    fail(case_id, "patched code/refill contract violated");
            end
            13: begin
                if (u_dut.u_core.u_regfile.regs[3] !== 32'h0
                    || u_dut.u_core.u_regfile.regs[4] !== 32'h0
                    || u_dut.u_core.u_regfile.regs[5] !== 32'h0)
                    fail(case_id, "fast redirect leaked a successor");
            end
            14: begin
                if (u_dut.u_core.u_regfile.regs[4] !== 32'h0
                    || u_dut.u_core.u_regfile.regs[5] !== 32'h0)
                    fail(case_id, "load-to-PC chain leaked a successor");
            end
            15: begin
                if (u_dut.u_core.u_regfile.regs[3] !== 32'h0
                    || u_dut.u_core.u_regfile.regs[5] !== 32'h0
                    || u_dut.u_core.cpsr.t !== 1'b0)
                    fail(case_id, "interworking redirect chain failed");
            end
            16: begin
                if (u_dut.u_core.u_regfile.regs[2] !== 32'h0000_0001
                 || u_dut.u_core.u_regfile.regs[3] !== 32'hFFFF_FFFE)
                    fail(case_id, $sformatf(
                        "second UMULL reused stale operands/result: r2=%08x r3=%08x",
                        u_dut.u_core.u_regfile.regs[2],
                        u_dut.u_core.u_regfile.regs[3]));
            end
            default: ;
        endcase

        if (u_dut.u_core.cpsr.m !== 5'(MODE_SUPERVISOR))
            fail(case_id, "final mode is not Supervisor");
    endtask

    task automatic run_case(input int case_id);
        logic main_seen;
        logic completed;
        logic patched_execute_seen;
        logic stale_execute_seen;
        int   flush_count;

        @(negedge CLK);
        nRESET = 1'b0;
        repeat (4) @(posedge CLK);
        setup_case(case_id);
        @(negedge CLK);
        nRESET = 1'b1;

        main_seen           = 1'b0;
        completed           = 1'b0;
        patched_execute_seen = 1'b0;
        stale_execute_seen  = 1'b0;
        flush_count         = 0;

        for (int step = 0; step < 240; step++) begin
            @(negedge CLK);

            if (u_dut.u_core.state_q == 5'd0
                && u_dut.u_core.de_q.valid
                && u_dut.u_core.de_q.pc == 32'h0000_0020)
                main_seen = 1'b1;

            if (main_seen && u_dut.u_core.any_exc_fires)
                fail(case_id, "unexpected exception");

            // Stop before counting the marker's following self-loop as
            // part of the sequence under test.
            if (u_dut.u_core.u_regfile.regs[7] == 32'(case_id)) begin
                completed = 1'b1;
                break;
            end

            if (case_id == 12 && u_dut.u_core.state_q == 5'd0
                && u_dut.u_core.de_q.valid
                && u_dut.u_core.de_q.pc == 32'h0000_0034) begin
                if (u_dut.u_core.de_q.instr
                    == mov_imm(4'd7, 8'(case_id)))
                    patched_execute_seen = 1'b1;
                if (u_dut.u_core.de_q.instr == mov_imm(4'd7, 8'hEE))
                    stale_execute_seen = 1'b1;
            end

            if (main_seen && u_dut.u_core.flush) begin
                if (flush_count >= expected_flush_count(case_id))
                    fail(case_id, "unexpected extra PC redirect");
                if (u_dut.u_core.flush_target_pc
                    !== expected_flush_target(case_id, flush_count))
                    fail(case_id, $sformatf(
                        "redirect %0d expected %08x got %08x",
                        flush_count,
                        expected_flush_target(case_id, flush_count),
                        u_dut.u_core.flush_target_pc));
                flush_count++;
            end

        end

        if (!completed)
            fail(case_id, "completion marker did not retire");
        if (flush_count != expected_flush_count(case_id))
            fail(case_id, $sformatf(
                "redirect count expected %0d got %0d",
                expected_flush_count(case_id), flush_count));
        if (case_id == 12
            && (!patched_execute_seen || stale_execute_seen))
            fail(case_id, $sformatf(
                "patched/stale Execute observations=%0b/%0b",
                patched_execute_seen, stale_execute_seen));
        check_case(case_id);
    endtask

    initial begin
        for (int case_id = 1; case_id <= CASE_COUNT; case_id++) begin
            run_case(case_id);
            rows_completed++;
        end

        if (rows_completed != CASE_COUNT)
            $fatal(1, "[sequence_dependencies] FAIL completed %0d/%0d",
                   rows_completed, CASE_COUNT);
        $display("[sequence_dependencies] PASS (%0d reset-per-case sequences)",
                 rows_completed);
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "[sequence_dependencies] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, ADDR, WRITE, SIZE, PROT, LOCK, TRANS,
        WDATA, RDATA, ABORT, CPnMREQ, CPSEQ, CPnTRANS, CPnOPC,
        CPTBIT, CPnI, DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG,
        DBGCOMMTX, DBGCOMMRX, DBGTDO, DBGnTDOEN, DMORE};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
