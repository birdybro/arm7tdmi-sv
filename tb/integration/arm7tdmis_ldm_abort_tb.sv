// IRQ integration test: validates the §9d 2-cycle commit path
// end-to-end inside the pipelined core. Program at tb/programs/ldm_abort_test.hex:
//
//   0x00: B 0x20
//   ...
//   0x20: MOV r0, #0x10000000   ; 2^28
//   0x24: MOV r1, #0x10         ; 16
//   0x28: IRQ-test r2, r3, r0, r1  ; r2:r3 = r0 * r1 = 2^32
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

module arm7tdmis_ldm_abort_tb
    import arm7tdmis_bus_pkg::*;
;

    localparam int    CLK_HALF_PERIOD = 5;
    localparam int    RESET_CYCLES    = 4;
    localparam int    CYCLE_LIMIT     = 256;
    localparam string INIT_HEX        = "../tb/programs/ldm_abort_test.hex";

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
            $display("[ldm_abort] FAIL %s (r%0d): expected %08x got %08x",
                     name, idx, expected, u_dut.u_core.u_regfile.regs[idx]);
            errors = errors + 1;
        end
    endtask

    // Inject ABORT whenever the bus is reading from address ≥ 0x100 —
    // i.e., outside the loaded program region. Causes the memory to
    // assert ABORT on any access targeting that range. Sequential
    // fetches in 0x00-0xFC are unaffected.
    always_comb begin
        mem_inject_abort = (ADDR >= 32'h100);
    end

    initial begin
        $dumpfile("ldm_abort.fst");
        $display("[ldm_abort] starting; CYCLE_LIMIT=%0d", CYCLE_LIMIT);
        wait (nRESET);
        repeat (CYCLE_LIMIT) @(posedge CLK);

        // Program flow:
        //   0x20  MOV r5, #0x100      (r5 = aborting base addr)
        //   0x24  LDMIA r5!, {r0-r3}  (load 4 regs; ALL beats abort)
        //         → block_writes_ldm suppressed by data_abort_now
        //         → S_BLOCK_WB hit; block_does_writeback gated by
        //           !data_abort_q → Rn writeback suppressed
        //         → dabt_fires at S_BLOCK_WB → S_EXEC transition
        //         → mode := ABT, vector := 0x10, B 0x40 (handler)
        //   0x40  MOV r9, #0xEE       (handler marker)
        //   0x44  self-loop
        //
        // Verify the §17 LDM-DABT restart semantics:
        //   r0..r3 unchanged at 0 (load writebacks suppressed)
        //   r5     unchanged at 0x100 (writeback suppressed — restart-safe!)
        //   r8     = 0 (post-LDM MOV r8,#0xDD never ran)
        //   r9     = 0xEE (handler ran)
        //   cpsr.m = ABT (10111)
        //   pc_q   = 0x44 (handler self-loop)
        check_reg(0, 32'h00000000, "r0 unchanged (load writeback suppressed)");
        check_reg(1, 32'h00000000, "r1 unchanged (load writeback suppressed)");
        check_reg(2, 32'h00000000, "r2 unchanged (load writeback suppressed)");
        check_reg(3, 32'h00000000, "r3 unchanged (load writeback suppressed)");
        check_reg(5, 32'h00000100, "r5 = 0x100 (Rn writeback suppressed — RESTART-SAFE)");
        check_reg(8, 32'h00000000, "r8 = 0 (MOV after LDM never ran)");
        check_reg(9, 32'h000000EE, "r9 = DABT handler marker");

        if (u_dut.u_core.cpsr.m !== 5'b10111) begin
            $display("[ldm_abort] FAIL cpsr.m: expected ABORT (10111), got %05b",
                     u_dut.u_core.cpsr.m);
            errors = errors + 1;
        end

        if (u_dut.u_core.pc_q !== 32'h00000044) begin
            $display("[ldm_abort] FAIL pc_q: expected 0x44 (DABT handler self-loop), got %08x",
                     u_dut.u_core.pc_q);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("[ldm_abort] PASS");
        else
            $display("[ldm_abort] FAIL (%0d errors)", errors);
        $finish;
    end

endmodule
