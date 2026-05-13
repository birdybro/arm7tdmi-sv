// SWI (software interrupt) integration test.
//
// Validates the SWI exception entry path through the pipelined core:
// SWI fires from S_EXEC, banks PC+4 into r14_svc, saves CPSR into
// SPSR_svc, sets CPSR.m = Supervisor (10011) + I=1, and branches to
// the SWI vector at 0x08. The vector redirects to the handler at
// 0x40 which sets r5 = 0x42 and halts.
//
// Program at tb/programs/swi_test.hex:
//   0x00: B 0x20                  ; reset → main
//   0x08: B 0x40                  ; SWI vector → handler
//   0x20: MOV r0, #0xAA
//   0x24: MOV r1, #0xBB
//   0x28: SWI #0x123              ; triggers exception
//   0x2C: MOV r2, #0xCC           ; never executes
//   0x30: B-self                  ; main loop (unreachable)
//   0x40: MOV r5, #0x42           ; handler marker
//   0x44: B-self                  ; handler loop

`timescale 1ns/1ps

module arm7tdmis_swi_tb
    import arm7tdmis_bus_pkg::*;
;

    localparam int    CLK_HALF_PERIOD = 5;
    localparam int    RESET_CYCLES    = 4;
    localparam int    CYCLE_LIMIT     = 256;
    localparam string INIT_HEX        = "../tb/programs/swi_test.hex";

    logic CLK;
    initial begin
        CLK = 1'b0;
        forever #(CLK_HALF_PERIOD) CLK = ~CLK;
    end

    logic nRESET;
    initial begin
        nRESET = 1'b0;
        repeat (RESET_CYCLES) @(posedge CLK);
        nRESET = 1'b1;
    end

    logic CFGBIGEND, CLKEN;
    initial begin
        CFGBIGEND = 1'b0;
        CLKEN     = 1'b1;
    end

    logic nIRQ, nFIQ, ABORT;
    initial begin
        nIRQ  = 1'b1;
        nFIQ  = 1'b1;
        ABORT = 1'b0;
    end

    logic       DBGEN, DBGRQ, DBGBREAK;
    logic [1:0] DBGEXT;
    logic       DBGTCKEN, DBGTMS, DBGTDI, DBGnTRST;
    initial begin
        DBGEN    = 1'b0;
        DBGRQ    = 1'b0;
        DBGBREAK = 1'b0;
        DBGEXT   = 2'b00;
        DBGTCKEN = 1'b0;
        DBGTMS   = 1'b0;
        DBGTDI   = 1'b0;
        DBGnTRST = 1'b1;
    end

    logic [31:0] ADDR;
    logic        WRITE;
    logic [1:0]  SIZE;
    logic [1:0]  PROT;
    logic        LOCK;
    logic [1:0]  TRANS;
    logic [31:0] WDATA, RDATA;

    logic CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI;
    logic CPA, CPB;
    assign CPA = 1'b1;
    assign CPB = 1'b1;

    logic       DBGACK, DBGnEXEC, DBGINSTRVALID;
    logic [1:0] DBGRNG;
    logic       DBGCOMMTX, DBGCOMMRX;
    logic       DBGTDO, DBGnTDOEN;
    logic       DMORE;

    arm7tdmis_top u_dut (
        .CLK            (CLK),
        .CLKEN          (CLKEN),
        .nRESET         (nRESET),
        .CFGBIGEND      (CFGBIGEND),
        .nIRQ           (nIRQ),
        .nFIQ           (nFIQ),
        .ABORT          (ABORT),
        .ADDR           (ADDR),
        .WRITE          (WRITE),
        .SIZE           (SIZE),
        .PROT           (PROT),
        .LOCK           (LOCK),
        .TRANS          (TRANS),
        .WDATA          (WDATA),
        .RDATA          (RDATA),
        .CPnMREQ        (CPnMREQ),
        .CPSEQ          (CPSEQ),
        .CPnTRANS       (CPnTRANS),
        .CPnOPC         (CPnOPC),
        .CPTBIT         (CPTBIT),
        .CPnI           (CPnI),
        .CPA            (CPA),
        .CPB            (CPB),
        .DBGEN          (DBGEN),
        .DBGRQ          (DBGRQ),
        .DBGBREAK       (DBGBREAK),
        .DBGACK         (DBGACK),
        .DBGnEXEC       (DBGnEXEC),
        .DBGINSTRVALID  (DBGINSTRVALID),
        .DBGEXT         (DBGEXT),
        .DBGRNG         (DBGRNG),
        .DBGCOMMTX      (DBGCOMMTX),
        .DBGCOMMRX      (DBGCOMMRX),
        .DBGTCKEN       (DBGTCKEN),
        .DBGTMS         (DBGTMS),
        .DBGTDI         (DBGTDI),
        .DBGTDO         (DBGTDO),
        .DBGnTRST       (DBGnTRST),
        .DBGnTDOEN      (DBGnTDOEN),
        .DMORE          (DMORE)
    );

    logic mem_inject_abort;
    initial mem_inject_abort = 1'b0;

    /* verilator lint_off SYNCASYNCNET */
    arm7tdmis_memory #(
        .WORDS    (4096),
        .INIT_HEX (INIT_HEX)
    ) u_mem (
        .CLK          (CLK),
        .CLKEN        (CLKEN),
        .nRESET       (nRESET),
        .CFGBIGEND    (CFGBIGEND),
        .ADDR         (ADDR),
        .WRITE        (WRITE),
        .SIZE         (SIZE),
        .PROT         (PROT),
        .LOCK         (LOCK),
        .TRANS        (TRANS),
        .WDATA        (WDATA),
        .RDATA        (RDATA),
        .ABORT        (ABORT),
        .inject_abort (mem_inject_abort)
    );
    /* verilator lint_on SYNCASYNCNET */

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0,
        CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI,
        DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG,
        DBGCOMMTX, DBGCOMMRX, DBGTDO, DBGnTDOEN, DMORE
    };
    /* verilator lint_on UNUSEDSIGNAL */

    int unsigned errors = 0;

    task automatic check_reg(input int idx, input logic [31:0] expected,
                             input string name);
        if (u_dut.u_core.u_regfile.regs[idx] !== expected) begin
            $display("[swi] FAIL %s (r%0d): expected %08x got %08x",
                     name, idx, expected, u_dut.u_core.u_regfile.regs[idx]);
            errors = errors + 1;
        end
    endtask

    initial begin
        $dumpfile("swi.fst");
        $display("[swi] starting; CYCLE_LIMIT=%0d", CYCLE_LIMIT);
        wait (nRESET);
        repeat (CYCLE_LIMIT) @(posedge CLK);

        // r0/r1 from main code (executed before SWI).
        check_reg(0, 32'h000000AA, "r0 from MOV r0,#0xAA");
        check_reg(1, 32'h000000BB, "r1 from MOV r1,#0xBB");

        // r2 must NOT have been set — SWI fires at 0x28 and flushes the
        // pipeline before 0x2C reaches E. (de_q for 0x2C was decoded but
        // gets flushed.)
        if (u_dut.u_core.u_regfile.regs[2] !== 32'h0) begin
            $display("[swi] FAIL r2: expected 0 (MOV r2 should have been flushed), got %08x",
                     u_dut.u_core.u_regfile.regs[2]);
            errors = errors + 1;
        end

        // Handler marker.
        check_reg(5, 32'h00000042, "r5 = SWI handler marker (MOV r5,#0x42)");

        // After SWI: CPSR.m = Supervisor (10011), I bit set, T cleared.
        if (u_dut.u_core.cpsr.m !== 5'b10011) begin
            $display("[swi] FAIL cpsr.m: expected SVC (10011), got %05b",
                     u_dut.u_core.cpsr.m);
            errors = errors + 1;
        end
        if (u_dut.u_core.cpsr.i !== 1'b1) begin
            $display("[swi] FAIL cpsr.i: expected 1 after SWI entry, got %0b",
                     u_dut.u_core.cpsr.i);
            errors = errors + 1;
        end

        // r14_svc = PC of SWI + 4 = 0x28 + 4 = 0x2C (per TRM exception
        // entry semantics: r14 holds the return address). Per the regfile
        // storage layout, r14_svc lives at regs[26].
        if (u_dut.u_core.u_regfile.regs[26] !== 32'h0000002C) begin
            $display("[swi] FAIL r14_svc (regs[26]): expected 0x2C, got %08x",
                     u_dut.u_core.u_regfile.regs[26]);
            errors = errors + 1;
        end

        // pc_q stops at the handler's self-loop (0x44).
        if (u_dut.u_core.pc_q !== 32'h00000044) begin
            $display("[swi] FAIL pc_q: expected 0x44 (handler self-loop), got %08x",
                     u_dut.u_core.pc_q);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("[swi] PASS");
        else
            $display("[swi] FAIL (%0d errors)", errors);
        $finish;
    end

endmodule
