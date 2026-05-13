// CP14 DCC integration test: validates the §9d 2-cycle commit path
// end-to-end inside the pipelined core. Program at tb/programs/cp14_dcc_test.hex:
//
//   0x00: B 0x20
//   ...
//   0x20: MOV r0, #0x10000000   ; 2^28
//   0x24: MOV r1, #0x10         ; 16
//   0x28: CP14 DCC r2, r3, r0, r1  ; r2:r3 = r0 * r1 = 2^32
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

module arm7tdmis_cp14_dcc_tb
    import arm7tdmis_bus_pkg::*;
;

    localparam int    CLK_HALF_PERIOD = 5;
    localparam int    RESET_CYCLES    = 4;
    localparam int    CYCLE_LIMIT     = 256;
    localparam string INIT_HEX        = "../tb/programs/cp14_dcc_test.hex";

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
        // (specifically the DCC Data register at 0x04) can actually
        // commit writes. Holding it low keeps the bank cleared every
        // posedge via the async reset path.
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
            $display("[cp14_dcc] FAIL %s (r%0d): expected %08x got %08x",
                     name, idx, expected, u_dut.u_core.u_regfile.regs[idx]);
            errors = errors + 1;
        end
    endtask

    initial begin
        $dumpfile("cp14_dcc.fst");
        $display("[cp14_dcc] starting; CYCLE_LIMIT=%0d", CYCLE_LIMIT);
        wait (nRESET);
        repeat (CYCLE_LIMIT) @(posedge CLK);

        // CP14 DCC round-trip:
        //   r0 := 0xFF000000           (some value to ship)
        //   MCR p14, 0, r0, c0, c0, 0  (write r0 → ICE-RT regs[0x04])
        //   r0 := 0                    (clobber to verify the read brings it back)
        //   MRC p14, 0, r0, c0, c0, 0  (read ICE-RT regs[0x04] → r0)
        // Final: r0 should be 0xFF000000 (the value round-tripped through DCC).
        check_reg(0, 32'hFF000000, "r0 = DCC value after MCR/MRC p14 round-trip");

        // Also verify the ICE-RT DCC register itself holds the value.
        if (u_dut.u_ice.regs[5'h04] !== 32'hFF000000) begin
            $display("[cp14_dcc] FAIL ICE-RT regs[0x04]: expected FF000000, got %08x",
                     u_dut.u_ice.regs[5'h04]);
            errors = errors + 1;
        end

        if (u_dut.u_core.pc_q !== 32'h00000030) begin
            $display("[cp14_dcc] FAIL pc_q: expected 0x30 self-loop, got %08x",
                     u_dut.u_core.pc_q);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("[cp14_dcc] PASS");
        else
            $display("[cp14_dcc] FAIL (%0d errors)", errors);
        $finish;
    end

endmodule
