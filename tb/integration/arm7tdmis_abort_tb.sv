// ABORT integration test: validates the §9d 2-cycle commit path
// end-to-end inside the pipelined core. Program at tb/programs/abort_test.hex:
//
//   0x00: B 0x20
//   ...
//   0x20: MOV r0, #0x10000000   ; 2^28
//   0x24: MOV r1, #0x10         ; 16
//   0x28: ABORT r2, r3, r0, r1  ; r2:r3 = r0 * r1 = 2^32
//   0x2C: MOV r15, #0x2C        ; self-loop
//
// Expected:
//   r0 = 0x10000000
//   r1 = 0x00000010
//   r2 = 0x00000000  (low half of 2^32)
//   r3 = 0x00000001  (high half of 2^32)
//
// The high half being non-zero specifically exercises the S_MULL_HI
// substate cycle and the latched RdHi/result_hi writeback.

`timescale 1ns/1ps

module arm7tdmis_abort_tb
    import arm7tdmis_bus_pkg::*;
;

    localparam int    CLK_HALF_PERIOD = 5;
    localparam int    RESET_CYCLES    = 4;
    localparam int    CYCLE_LIMIT     = 256;
    localparam string INIT_HEX        = "../tb/programs/abort_test.hex";

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
        // Deassert DBGnTRST so the ICE-RT macrocell's register bank
        // (ABORT register at 0x02) doesn't get cleared each
        // posedge by the async reset path.
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
            $display("[abort] FAIL %s (r%0d): expected %08x got %08x",
                     name, idx, expected, u_dut.u_core.u_regfile.regs[idx]);
            errors = errors + 1;
        end
    endtask

    // Drive inject_abort only when the core is in a data-cycle state.
    // The memory's gating logic doesn't distinguish opcode-fetch from
    // data accesses — both are "active" — so driving inject_abort high
    // unconditionally would PABT every instruction fetch. Gating on
    // the core's E-stage data substates (S_DDATA=1, S_BLOCK_DATA=2,
    // S_SWP_RDATA=3, S_SWP_WDATA=4) keeps the abort firing only on
    // LDR/STR/LDM/STM/SWP data cycles.
    always_comb begin
        mem_inject_abort = (u_dut.u_core.state_q == 4'd1)   // S_DDATA
                        || (u_dut.u_core.state_q == 4'd2)   // S_BLOCK_DATA
                        || (u_dut.u_core.state_q == 4'd3)   // S_SWP_RDATA
                        || (u_dut.u_core.state_q == 4'd4);  // S_SWP_WDATA
    end

    initial begin
        $dumpfile("abort.fst");
        $display("[abort] starting; CYCLE_LIMIT=%0d", CYCLE_LIMIT);
        wait (nRESET);
        repeat (CYCLE_LIMIT) @(posedge CLK);

        // After the data abort, the program should have flushed to the
        // DABT vector (0x10), branched to the handler at 0x40, and the
        // handler should have set r3 = 0xAB. CPSR.M should be ABT.
        //
        //   r0 = 0x100   (MOV at 0x20 ran)
        //   r1 = 0       (LDR aborted — writeback suppressed)
        //   r2 = 0       (MOV at 0x28 NEVER ran — DABT flushed first)
        //   r3 = 0xAB    (handler at 0x40 ran)
        //   cpsr.m = MODE_ABORT (5'b10111)
        check_reg(0, 32'h00000100, "r0 = MOV r0,#0x100 setup");
        check_reg(1, 32'h00000000, "r1 = LDR target (abort suppressed writeback)");
        check_reg(2, 32'h00000000, "r2 = MOV after LDR (skipped by DABT)");
        check_reg(3, 32'h000000AB, "r3 = DABT handler marker");

        if (u_dut.u_core.cpsr.m !== 5'b10111) begin
            $display("[abort] FAIL cpsr.m: expected ABORT (10111), got %05b",
                     u_dut.u_core.cpsr.m);
            errors = errors + 1;
        end

        // Verify the abort handler is the one looping (PC at the handler's
        // self-loop = 0x44).
        if (u_dut.u_core.pc_q !== 32'h00000044) begin
            $display("[abort] FAIL pc_q: expected 0x44 (DABT handler self-loop), got %08x",
                     u_dut.u_core.pc_q);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("[abort] PASS");
        else
            $display("[abort] FAIL (%0d errors)", errors);
        $finish;
    end

endmodule
