// Prefetch-abort integration test. Program at tb/programs/pabt_test.hex:
//
//   0x00: B 0x20
//   0x0C: B 0x40                 ; PABT vector
//   ...
//   0x20: MOV r0, #1
//   0x24: B 0x100                ; fetch receives ABORT
//   ...
//   0x40: MOV r7, #0xAB          ; handler marker
//   0x44: B 0x44                 ; self-loop
//
// The injection predicate uses the memory model's latched response phase,
// not the core's current address phase. This is both the externally visible
// ABORT timing and necessary to keep exception redirection from feeding back
// into its own input combinationally.

`timescale 1ns/1ps

module arm7tdmis_pabt_tb
    import arm7tdmis_bus_pkg::*;
;

    localparam int    CLK_HALF_PERIOD = 5;
    localparam int    RESET_CYCLES    = 4;
    localparam int    CYCLE_LIMIT     = 256;
    localparam string INIT_HEX        = "../tb/programs/pabt_test.hex";

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
            $display("[pabt] FAIL %s (r%0d): expected %08x got %08x",
                     name, idx, expected, u_dut.u_core.u_regfile.regs[idx]);
            errors = errors + 1;
        end
    endtask

    // Inject ABORT on opcode read responses at or above 0x100. Sequential
    // fetches in 0x00-0xFC and all data responses are unaffected.
    always_comb begin
        mem_inject_abort = u_mem.is_active_q
                         && !u_mem.write_q
                         && (u_mem.prot_q[PROT_BIT_DATA] == 1'b0)
                         && (u_mem.addr_q >= 32'h100);
    end

    initial begin
        $dumpfile("pabt.fst");
        $display("[pabt] starting; CYCLE_LIMIT=%0d", CYCLE_LIMIT);
        wait (nRESET);
        repeat (CYCLE_LIMIT) @(posedge CLK);

        // Program flow:
        //   0x20  MOV r0, #1         (r0=1, ran)
        //   0x24  B 0x100            (branch to aborting address)
        //         → fetch from 0x100 returns with ABORT asserted
        //         → fd_q.pabort = 1 for that instruction
        //         → instr reaches E, pabt_fires
        //         → mode := ABT, vector := 0x0C
        //         → B 0x40 (PABT handler at the vector)
        //   0x40  MOV r7, #0xAB      (handler marker)
        //   0x44  self-loop
        check_reg(0, 32'h00000001, "r0 = MOV r0,#1 ran");
        check_reg(7, 32'h000000AB, "r7 = PABT handler marker");

        if (u_dut.u_core.cpsr.m !== 5'b10111) begin
            $display("[pabt] FAIL cpsr.m: expected ABORT (10111), got %05b",
                     u_dut.u_core.cpsr.m);
            errors = errors + 1;
        end

        if (u_dut.u_core.pc_q !== 32'h00000044) begin
            $display("[pabt] FAIL pc_q: expected 0x44 (PABT handler self-loop), got %08x",
                     u_dut.u_core.pc_q);
            errors = errors + 1;
        end

        if (errors != 0)
            $fatal(1, "[pabt] FAIL (%0d errors)", errors);
        $display("[pabt] PASS");
        $finish;
    end

    initial begin
        repeat (CYCLE_LIMIT + 32) @(posedge CLK);
        $fatal(1, "[pabt] TIMEOUT after %0d cycles", CYCLE_LIMIT + 32);
    end

endmodule
