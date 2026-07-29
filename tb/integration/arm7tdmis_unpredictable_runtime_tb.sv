// ISA-016 runtime UNPREDICTABLE-policy regression.
//
// These rows deliberately exercise behavior that ARMv4T software must not
// rely on.  Their expected results are implementation policy, not additional
// architectural guarantees:
//   * ARM7TDMI-S register-controlled data operations accept r15 in every
//     operand position. Rn/Rs use pc+8, Rm uses the r4p3 pc+12 value, and a
//     destination-PC result is aligned in the current state.
//   * address arithmetic wraps modulo 2^32.
//
// Every case starts from reset. A marker after a redirected instruction must
// remain untouched, so stale sequential execution cannot masquerade as a
// correct final state.

`timescale 1ns/1ps

module arm7tdmis_unpredictable_runtime_tb
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_types_pkg::*;
;

    localparam int CASE_COUNT = 5;

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

    // Upper address bits intentionally alias. Case 5 executes from
    // 0xfffffff8/0xfffffffc and checks the raw addresses separately.
    arm7tdmis_memory #(
        .WORDS(256)
    ) u_mem (
        .CLK(CLK), .CLKEN(1'b1), .nRESET(nRESET),
        .CFGBIGEND(1'b0),
        .ADDR(ADDR), .WRITE(WRITE), .SIZE(SIZE), .PROT(PROT),
        .LOCK(LOCK), .TRANS(TRANS), .WDATA(WDATA), .RDATA(RDATA),
        .ABORT(ABORT), .inject_abort(1'b0)
    );

    function automatic logic [31:0] dp_reg_shift(
        input logic [3:0] opcode,
        input logic       set_flags,
        input logic [3:0] rn,
        input logic [3:0] rd,
        input logic [3:0] rs,
        input logic [1:0] shift_type,
        input logic [3:0] rm
    );
        return {4'hE, 3'b000, opcode, set_flags, rn, rd,
                rs, 1'b0, shift_type, 1'b1, rm};
    endfunction

    task automatic fail(input int case_id, input string message);
        $fatal(1, "[unpredictable_runtime] FAIL case %0d: %s",
               case_id, message);
    endtask

    task automatic clear_memory;
        for (int word = 0; word < 256; word++)
            u_mem.mem[word] = 32'hEAFF_FFFE;
        u_mem.mem[0] = 32'hEA00_0006; // reset: B 0x20
        for (int word = 1; word < 8; word++)
            u_mem.mem[word] = 32'hE7FF_FFFE;
    endtask

    task automatic setup_case(input int case_id);
        clear_memory();

        if (case_id <= 4) begin
            u_mem.mem[8]  = 32'hE59F_0058; // 0x20 LDR r0,[pc,#0x58]
            u_mem.mem[9]  = 32'hE59F_1058; // 0x24 LDR r1,[pc,#0x58]
            u_mem.mem[10] = 32'hE1A0_0000; // test at 0x28
            u_mem.mem[11] = 32'hE3A0_7000 | 32'(case_id);
            u_mem.mem[12] = 32'hEAFF_FFFE;
            u_mem.mem[32] = 32'h0000_0001;
            u_mem.mem[33] = 32'h0000_0001;

            unique case (case_id)
                1: begin
                    // ADD r4,pc,r0,LSL r1: Rn sees 0x28+8.
                    u_mem.mem[10] = dp_reg_shift(
                        4'b0100, 1'b0, 4'd15, 4'd4,
                        4'd1, 2'b00, 4'd0);
                end
                2: begin
                    // MOV r4,pc,LSL r1: Rm sees 0x28+12.
                    u_mem.mem[10] = dp_reg_shift(
                        4'b1101, 1'b0, 4'd0, 4'd4,
                        4'd1, 2'b00, 4'd15);
                    u_mem.mem[33] = 32'h0000_0000;
                end
                3: begin
                    // MOV r4,r0,LSL pc: Rs sees 0x28+8; 0x30 > 32.
                    u_mem.mem[10] = dp_reg_shift(
                        4'b1101, 1'b0, 4'd0, 4'd4,
                        4'd15, 2'b00, 4'd0);
                end
                default: begin
                    // MOV pc,r0,LSL r1: current ARM-state alignment.
                    u_mem.mem[10] = dp_reg_shift(
                        4'b1101, 1'b0, 4'd0, 4'd15,
                        4'd1, 2'b00, 4'd0);
                    u_mem.mem[32] = 32'h0000_0102;
                    u_mem.mem[33] = 32'h0000_0000;
                    u_mem.mem[11] = 32'hE3A0_50EE; // flushed successor
                    u_mem.mem[64] = 32'hE3A0_7004; // target 0x100
                    u_mem.mem[65] = 32'hEAFF_FFFE;
                end
            endcase
        end else if (case_id == 5) begin
            u_mem.mem[8]   = 32'hE59F_0058; // r0 <- 0xfffffff8
            u_mem.mem[9]   = 32'hE1A0_F000; // MOV pc,r0
            u_mem.mem[10]  = 32'hE3A0_50EE; // flushed successor
            u_mem.mem[16]  = 32'hE3A0_7005; // wrapped target 0x40
            u_mem.mem[17]  = 32'hEAFF_FFFE;
            u_mem.mem[32]  = 32'hFFFF_FFF8;
            // At 0xfffffff8, visible PC wraps to zero. Offset +0x40.
            u_mem.mem[254] = 32'hEA00_0010;
            u_mem.mem[255] = 32'hE1A0_0000;
        end
    endtask

    task automatic run_case(input int case_id);
        logic saw_high_fetch;
        logic saw_wrapped_target;

        @(negedge CLK);
        nRESET = 1'b0;
        repeat (4) @(posedge CLK);
        setup_case(case_id);
        @(negedge CLK);
        nRESET = 1'b1;

        saw_high_fetch    = 1'b0;
        saw_wrapped_target = 1'b0;
        repeat (150) begin
            @(negedge CLK);
            if ((TRANS inside {TRANS_N, TRANS_S})
                && !PROT[PROT_BIT_DATA]
                && (ADDR == 32'hFFFF_FFF8))
                saw_high_fetch = 1'b1;
            if (saw_high_fetch
                && (TRANS inside {TRANS_N, TRANS_S})
                && !PROT[PROT_BIT_DATA]
                && (ADDR == 32'h0000_0040))
                saw_wrapped_target = 1'b1;
        end

        if (u_dut.u_core.u_regfile.regs[7] !== 32'(case_id))
            fail(case_id, $sformatf(
                "completion marker expected %08x got %08x",
                32'(case_id), u_dut.u_core.u_regfile.regs[7]));
        if (u_dut.u_core.u_regfile.regs[5] !== 32'h0000_0000)
            fail(case_id, "flushed successor executed");

        unique case (case_id)
            1: if (u_dut.u_core.u_regfile.regs[4] !== 32'h0000_0032)
                fail(case_id, "Rn=pc did not use pc+8");
            2: if (u_dut.u_core.u_regfile.regs[4] !== 32'h0000_0034)
                fail(case_id, "Rm=pc did not use r4p3 pc+12");
            3: if (u_dut.u_core.u_regfile.regs[4] !== 32'h0000_0000)
                fail(case_id, "Rs=pc did not use pc+8 shift amount");
            4: if (u_dut.u_core.pc_q !== 32'h0000_0104)
                fail(case_id, "Rd=pc result was not ARM-aligned/refilled");
            5: begin
                if (!saw_high_fetch || !saw_wrapped_target)
                    fail(case_id, "did not observe high fetch and wrapped target");
            end
            default: ;
        endcase
    endtask

    initial begin
        for (int case_id = 1; case_id <= CASE_COUNT; case_id++)
            run_case(case_id);

        $display("[unpredictable_runtime] PASS (%0d reset-per-case policies)",
                 CASE_COUNT);
        $finish;
    end

    initial begin
        repeat (CASE_COUNT * 220) @(posedge CLK);
        $fatal(1, "[unpredictable_runtime] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused_outputs = &{1'b0,
        WRITE, SIZE, LOCK, WDATA, ABORT,
        CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI,
        DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG,
        DBGCOMMTX, DBGCOMMRX, DBGTDO, DBGnTDOEN, DMORE
    };
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
