// ISA-016 Thumb BX-PC address-sensitive policy regression.
//
// BX pc at a word-aligned Thumb instruction is architecturally defined:
// visible pc+4 is word aligned and selects ARM state. At a halfword-only
// instruction address, visible pc+4 has bits[1:0]=2 and ARMv4T calls the
// result UNPREDICTABLE. This implementation deterministically clears both
// low bits and enters ARM state. The second row freezes only that project
// policy; it is not an ARM software guarantee.

`timescale 1ns/1ps

module arm7tdmis_thumb_bx_pc_policy_tb
    import arm7tdmis_bus_pkg::*;
;

    localparam int CASE_COUNT = 2;

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
        .WORDS(64)
    ) u_mem (
        .CLK(CLK), .CLKEN(1'b1), .nRESET(nRESET),
        .CFGBIGEND(1'b0),
        .ADDR(ADDR), .WRITE(WRITE), .SIZE(SIZE), .PROT(PROT),
        .LOCK(LOCK), .TRANS(TRANS), .WDATA(WDATA), .RDATA(RDATA),
        .ABORT(ABORT), .inject_abort(1'b0)
    );

    int unsigned errors;

    task automatic fail(input int case_id, input string message);
        $display("[thumb_bx_pc_policy] FAIL case %0d: %s",
                 case_id, message);
        errors++;
    endtask

    task automatic setup_case(input int case_id);
        for (int word = 0; word < 64; word++)
            u_mem.mem[word] = 32'hEAFF_FFFE;

        u_mem.mem[0] = 32'hEA00_0006; // reset: B 0x20
        u_mem.mem[8] = 32'hE59F_2014; // r2 <- Thumb entry at 0x3c
        u_mem.mem[9] = 32'hE12F_FF12; // BX r2
        u_mem.mem[10] = 32'hE3A0_50EE; // flushed successor
        u_mem.mem[16] = (case_id == 1)
                      ? 32'hE7FE_4778  // 0x40 BX pc (defined)
                      : 32'h4778_E7FE; // 0x42 BX pc (policy)
        u_mem.mem[17] = 32'hE3A0_7000 | 32'(case_id); // ARM 0x44
        u_mem.mem[18] = 32'hEAFF_FFFE;
        u_mem.mem[16 - 1] = (case_id == 1)
                          ? 32'h0000_0041 : 32'h0000_0043;
    endtask

    task automatic run_case(input int case_id);
        logic saw_bx_execute;
        logic saw_target_fetch;

        @(negedge CLK);
        nRESET = 1'b0;
        repeat (4) @(posedge CLK);
        setup_case(case_id);
        @(negedge CLK);
        nRESET = 1'b1;

        saw_bx_execute  = 1'b0;
        saw_target_fetch = 1'b0;
        repeat (100) begin
            @(negedge CLK);
            if (u_dut.u_core.de_q.valid
                && u_dut.u_core.de_q.thumb
                && (u_dut.u_core.de_q.pc
                    == (case_id == 1 ? 32'h0000_0040
                                     : 32'h0000_0042)))
                saw_bx_execute = 1'b1;
            if (saw_bx_execute
                && (TRANS inside {TRANS_N, TRANS_S})
                && !WRITE && !PROT[PROT_BIT_DATA]
                && ADDR == 32'h0000_0044) begin
                saw_target_fetch = 1'b1;
                if (SIZE !== 2'(SIZE_WORD))
                    fail(case_id, "ARM target fetch was not word-sized");
            end
        end

        if (!saw_bx_execute)
            fail(case_id, "BX pc never reached Thumb Execute");
        if (!saw_target_fetch)
            fail(case_id, "aligned ARM target fetch was not observed");
        if (u_dut.u_core.u_regfile.regs[7] !== 32'(case_id))
            fail(case_id, "ARM target marker did not retire");
        if (u_dut.u_core.u_regfile.regs[5] !== 32'h0000_0000)
            fail(case_id, "sequential ARM setup successor executed");
        if (u_dut.u_core.cpsr.t)
            fail(case_id, "BX pc did not enter ARM state");
        if (u_dut.u_core.pc_q !== 32'h0000_0048)
            fail(case_id, "final ARM loop PC mismatch");
    endtask

    initial begin
        errors = 0;
        for (int case_id = 1; case_id <= CASE_COUNT; case_id++)
            run_case(case_id);

        if (errors != 0)
            $fatal(1, "[thumb_bx_pc_policy] FAIL (%0d errors)", errors);
        $display("[thumb_bx_pc_policy] PASS (%0d reset-per-case rows)",
                 CASE_COUNT);
        $finish;
    end

    initial begin
        repeat (CASE_COUNT * 160) @(posedge CLK);
        $fatal(1, "[thumb_bx_pc_policy] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, LOCK, WDATA, ABORT, CPnMREQ, CPSEQ, CPnTRANS,
        CPnOPC, CPTBIT, CPnI, DBGACK, DBGnEXEC, DBGINSTRVALID,
        DBGRNG, DBGCOMMTX, DBGCOMMRX, DBGTDO, DBGnTDOEN, DMORE};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
