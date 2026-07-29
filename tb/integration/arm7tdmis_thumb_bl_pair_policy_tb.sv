// ISA-016 orphan Thumb BL-prefix policy regression.
//
// ARMv4T requires a Format-19 BL prefix to be followed by its BL suffix.
// Executing any other instruction next is UNPREDICTABLE. This implementation
// deterministically retains the prefix result in User LR and executes the
// ordinary successor normally. The existing thumb_bl_boundary regression
// freezes the complementary orphan-suffix policy.

`timescale 1ns/1ps

module arm7tdmis_thumb_bl_pair_policy_tb
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_instr_pkg::*;
    import arm7tdmis_types_pkg::*;
;

    localparam logic [31:0] PREFIX_PC = 32'h0000_0080;
    localparam logic [31:0] PREFIX_LR = 32'h0000_1084;

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

    task automatic fail(input string reason);
        $fatal(1, "[thumb_bl_pair_policy] FAIL: %s", reason);
    endtask

    task automatic setup_program;
        for (int word = 0; word < 128; word++)
            u_mem.mem[word] = 32'hEAFF_FFFE;

        u_mem.mem[0]  = 32'hEA00_0006; // reset: B 0x20
        u_mem.mem[8]  = 32'hE321_F01F; // MSR CPSR_c,#System
        u_mem.mem[9]  = 32'hE59F_0024; // LDR r0,[pc,#0x24] -> 0x50
        u_mem.mem[10] = 32'hE321_F010; // MSR CPSR_c,#User
        u_mem.mem[11] = 32'hE1A0_0000; // mode-change separation
        u_mem.mem[12] = 32'hE1A0_0000;
        u_mem.mem[13] = 32'hE12F_FF10; // BX r0
        u_mem.mem[14] = 32'hE3A0_70EE; // flushed ARM successor
        u_mem.mem[20] = PREFIX_PC | 32'h1;

        // F001: LR = visible-PC 0x84 + 0x1000 = 0x1084.
        // MOVS r5,#0x5a is deliberately not the required BL suffix.
        u_mem.mem[PREFIX_PC >> 2] = {16'h255A, 16'hF001};
        u_mem.mem[(PREFIX_PC >> 2) + 1] = {16'hE7FE, 16'h266B};
    endtask

    initial begin
        logic saw_prefix;
        logic saw_successor;
        logic saw_completion;
        int prefix_writes;

        repeat (4) @(posedge CLK);
        setup_program();
        @(negedge CLK);
        nRESET = 1'b1;

        saw_prefix    = 1'b0;
        saw_successor = 1'b0;
        saw_completion = 1'b0;
        prefix_writes = 0;

        for (int step = 0; step < 160; step++) begin
            @(negedge CLK);

            if (u_dut.u_core.state_q == 5'd0
                && u_dut.u_core.de_q.valid
                && u_dut.u_core.de_q.thumb
                && u_dut.u_core.de_q.pc == PREFIX_PC) begin
                saw_prefix = 1'b1;
                if (u_dut.u_core.de_q.dec.instr_class != INSTR_DP
                    || u_dut.u_core.rf_write_addr !== 4'd14
                    || u_dut.u_core.rf_write_data !== PREFIX_LR
                    || !u_dut.u_core.rf_write_en)
                    fail("orphan prefix did not commit 0x1084 to User LR");
                if (u_dut.u_core.flush)
                    fail("orphan prefix unexpectedly redirected execution");
                prefix_writes++;
            end

            if (u_dut.u_core.state_q == 5'd0
                && u_dut.u_core.de_q.valid
                && u_dut.u_core.de_q.thumb
                && u_dut.u_core.de_q.pc == (PREFIX_PC + 32'd2)) begin
                saw_successor = 1'b1;
                if (u_dut.u_core.de_q.dec.instr_class != INSTR_DP)
                    fail("ordinary successor did not decode as Thumb DP");
            end

            if (u_dut.u_core.u_regfile.regs[6] == 32'h0000_006B) begin
                saw_completion = 1'b1;
                break;
            end
        end

        if (!saw_prefix || prefix_writes != 1)
            fail("orphan prefix did not execute exactly once");
        if (!saw_successor)
            fail("non-suffix successor never reached Execute");
        if (!saw_completion
            || u_dut.u_core.u_regfile.regs[5] !== 32'h0000_005A)
            fail("ordinary successor sequence did not retire");
        if (u_dut.u_core.u_regfile.regs[14] !== PREFIX_LR)
            fail("orphan prefix LR result was not retained");
        if (u_dut.u_core.u_regfile.regs[7] !== 32'h0000_0000)
            fail("flushed ARM setup successor executed");
        if (u_dut.u_core.cpsr.m !== 5'(MODE_USER)
            || !u_dut.u_core.cpsr.t)
            fail("final mode/state was not User Thumb");

        $display("[thumb_bl_pair_policy] PASS (orphan-prefix policy)");
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "[thumb_bl_pair_policy] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, ADDR, WRITE, SIZE, PROT, LOCK, TRANS,
        WDATA, RDATA, CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT,
        CPnI, DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG, DBGCOMMTX,
        DBGCOMMRX, DBGTDO, DBGnTDOEN, DMORE};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
