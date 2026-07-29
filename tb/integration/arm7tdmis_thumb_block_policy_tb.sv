// ISA-016 Thumb multiple-transfer policy and base-overlap regression.
//
// LDMIA with Rb in the list is architecturally defined in Thumb state: the
// loaded value, not writeback, is the final Rb. STMIA stores the original
// base when Rb is lowest; a non-lowest Rb store is UNPREDICTABLE and this
// project deterministically stores the already-updated base. Empty LDMIA,
// STMIA, PUSH, and POP use the project-wide precise Undefined policy.

`timescale 1ns/1ps

module arm7tdmis_thumb_block_policy_tb
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_types_pkg::*;
;

    localparam int CASE_COUNT = 7;

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
        .WORDS(128)
    ) u_mem (
        .CLK(CLK), .CLKEN(1'b1), .nRESET(nRESET),
        .CFGBIGEND(1'b0),
        .ADDR(ADDR), .WRITE(WRITE), .SIZE(SIZE), .PROT(PROT),
        .LOCK(LOCK), .TRANS(TRANS), .WDATA(WDATA), .RDATA(RDATA),
        .ABORT(ABORT), .inject_abort(1'b0)
    );

    int unsigned errors;

    task automatic fail(input int case_id, input string message);
        $display("[thumb_block_policy] FAIL case %0d: %s",
                 case_id, message);
        errors++;
    endtask

    task automatic setup_case(input int case_id);
        logic [15:0] opcode;

        for (int word = 0; word < 128; word++)
            u_mem.mem[word] = 32'hEAFF_FFFE;

        u_mem.mem[0]  = 32'hEA00_0006; // reset: B 0x20
        u_mem.mem[1]  = 32'hEA00_001D; // Undef: B 0x80
        u_mem.mem[32] = 32'hE3A0_6000 | 32'(case_id);
        u_mem.mem[33] = 32'hEAFF_FFFE;

        // Four setup loads, then BX r3 to the test at Thumb address 0x40.
        u_mem.mem[8]  = 32'hE59F_1038; // r1 <- 0x100
        u_mem.mem[9]  = 32'hE59F_0038; // r0 <- 0x11111111
        u_mem.mem[10] = 32'hE59F_2038; // r2 <- 0x22222222
        u_mem.mem[11] = 32'hE59F_3038; // r3 <- 0x41
        u_mem.mem[12] = 32'hE12F_FF13; // BX r3
        u_mem.mem[24] = 32'h0000_0100;
        u_mem.mem[25] = 32'h1111_1111;
        u_mem.mem[26] = 32'h2222_2222;
        u_mem.mem[27] = 32'h0000_0041;

        opcode = 16'hC907; // LDMIA r1!,{r0-r2}
        unique case (case_id)
            1: opcode = 16'hC907; // defined loaded-base-wins rule
            2: opcode = 16'hC106; // STMIA r1!,{r1,r2}, base lowest
            3: opcode = 16'hC107; // STMIA r1!,{r0-r2}, base non-lowest
            4: opcode = 16'hC900; // LDMIA r1!,{}
            5: opcode = 16'hC100; // STMIA r1!,{}
            6: opcode = 16'hB400; // PUSH {}
            default: opcode = 16'hBC00; // POP {}
        endcase

        u_mem.mem[16] = {16'h2700 | 16'(case_id), opcode};
        u_mem.mem[17] = 32'hE7FE_E7FE;

        u_mem.mem[64] = (case_id == 1)
                      ? 32'hAAAA_0000 : 32'hDEAD_0000;
        u_mem.mem[65] = (case_id == 1)
                      ? 32'hA1A2_A3A4 : 32'hDEAD_0001;
        u_mem.mem[66] = (case_id == 1)
                      ? 32'hBBBB_2222 : 32'hDEAD_0002;
    endtask

    task automatic run_case(input int case_id);
        int unsigned target_cycles;
        int unsigned expected_cycles;

        @(negedge CLK);
        nRESET = 1'b0;
        repeat (4) @(posedge CLK);
        setup_case(case_id);
        @(negedge CLK);
        nRESET = 1'b1;

        target_cycles = 0;
        repeat (140) begin
            @(negedge CLK);
            if ((TRANS inside {TRANS_N, TRANS_S})
                && PROT[PROT_BIT_DATA]
                && (ADDR inside {[32'h0000_0100:32'h0000_0108]}))
                target_cycles++;
        end

        expected_cycles = (case_id == 1) ? 3
                        : ((case_id == 2) ? 2
                        : ((case_id == 3) ? 3 : 0));
        if (target_cycles != expected_cycles)
            fail(case_id, $sformatf(
                "target data cycles expected %0d got %0d",
                expected_cycles, target_cycles));

        if (case_id <= 3) begin
            if ((u_dut.u_core.cpsr.m !== 5'(MODE_SUPERVISOR))
             || !u_dut.u_core.cpsr.t)
                fail(case_id, "defined transfer left Thumb Supervisor state");
            if (u_dut.u_core.u_regfile.regs[7] !== 32'(case_id))
                fail(case_id, "defined transfer did not execute successor");
        end else begin
            if ((u_dut.u_core.cpsr.m !== 5'(MODE_UNDEFINED))
             || u_dut.u_core.cpsr.t)
                fail(case_id, "empty-list policy did not enter ARM Undef");
            if (u_dut.u_core.u_regfile.regs[30] !== 32'h0000_0042)
                fail(case_id, "empty-list LR_und is not Thumb pc+2");
            if (u_dut.u_core.u_psr.spsr_q[4] !== 32'h0000_00F3)
                fail(case_id, "empty-list SPSR_und is not Thumb SVC state");
            if (u_dut.u_core.u_regfile.regs[6] !== 32'(case_id))
                fail(case_id, "empty-list handler marker missing");
            if (u_dut.u_core.u_regfile.regs[7] !== 32'h0000_0000)
                fail(case_id, "empty-list successor executed");
        end

        unique case (case_id)
            1: begin
                if (u_dut.u_core.u_regfile.regs[0] !== 32'hAAAA_0000)
                    fail(case_id, "LDM r0 value mismatch");
                if (u_dut.u_core.u_regfile.regs[1] !== 32'hA1A2_A3A4)
                    fail(case_id, "Thumb LDM base load lost to writeback");
                if (u_dut.u_core.u_regfile.regs[2] !== 32'hBBBB_2222)
                    fail(case_id, "LDM r2 value mismatch");
            end
            2: begin
                if (u_mem.mem[64] !== 32'h0000_0100)
                    fail(case_id, "base-lowest STM did not store original base");
                if (u_mem.mem[65] !== 32'h2222_2222)
                    fail(case_id, "base-lowest STM r2 mismatch");
                if (u_dut.u_core.u_regfile.regs[1] !== 32'h0000_0108)
                    fail(case_id, "base-lowest STM writeback mismatch");
            end
            3: begin
                if (u_mem.mem[64] !== 32'h1111_1111)
                    fail(case_id, "base-nonlowest STM r0 mismatch");
                if (u_mem.mem[65] !== 32'h0000_010C)
                    fail(case_id, "base-nonlowest policy is not updated base");
                if (u_mem.mem[66] !== 32'h2222_2222)
                    fail(case_id, "base-nonlowest STM r2 mismatch");
                if (u_dut.u_core.u_regfile.regs[1] !== 32'h0000_010C)
                    fail(case_id, "base-nonlowest STM writeback mismatch");
            end
            default: begin
                if ((u_mem.mem[64] !== 32'hDEAD_0000)
                 || (u_mem.mem[65] !== 32'hDEAD_0001)
                 || (u_mem.mem[66] !== 32'hDEAD_0002))
                    fail(case_id, "empty-list policy changed memory");
            end
        endcase
    endtask

    initial begin
        errors = 0;
        for (int case_id = 1; case_id <= CASE_COUNT; case_id++)
            run_case(case_id);

        if (errors != 0)
            $fatal(1, "[thumb_block_policy] FAIL (%0d errors)", errors);
        $display("[thumb_block_policy] PASS (%0d reset-per-case rows)",
                 CASE_COUNT);
        $finish;
    end

    initial begin
        repeat (CASE_COUNT * 200) @(posedge CLK);
        $fatal(1, "[thumb_block_policy] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, WRITE, SIZE, LOCK, WDATA, ABORT,
        CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI,
        DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG,
        DBGCOMMTX, DBGCOMMRX, DBGTDO, DBGnTDOEN, DMORE};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
