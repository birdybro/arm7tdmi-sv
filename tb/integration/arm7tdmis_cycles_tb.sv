// Cycle-accuracy verification harness (§18 / TRM §7).
//
// Measures per-instruction cycle counts in E and compares to expected
// values derived from TRM Tables 7-3 through 7-23. "Cycles in E for
// instruction X" = number of CLK ticks during which de_q.pc == X_pc
// (with state_q == S_EXEC the first cycle, possibly in substates for
// later cycles).
//
// Test program at tb/programs/cycles_test.hex exercises one
// representative of each cycle-count category. Expected values are
// hardcoded below per TRM.

`timescale 1ns/1ps

module arm7tdmis_cycles_tb
    import arm7tdmis_bus_pkg::*;
;

    localparam int    CLK_HALF_PERIOD = 5;
    localparam int    RESET_CYCLES    = 4;
    localparam int    CYCLE_LIMIT     = 1024;
    localparam string INIT_HEX        = "../tb/programs/cycles_test.hex";

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

    // ---- Per-instruction cycle counter ----
    // last_pc tracks the most recently observed de_q.pc value during an
    // S_EXEC cycle (= first cycle of a new instruction in E). cycle_count
    // increments every CLK tick that the same instruction is held in
    // de_q (through any substate). When de_q.pc changes, we log the
    // completed instruction's cycles and start counting the new one.
    logic [31:0] last_pc;
    logic [31:0] cycle_count;
    logic        first_seen;

    // Table of observed instructions: (pc, cycles, instr_class).
    // Use small fixed-size buffer; smoke tests should stay under 64 records.
    int          record_idx;
    logic [31:0] rec_pc    [0:127];
    logic [31:0] rec_cycles[0:127];
    logic [3:0]  rec_class [0:127];

    initial begin
        last_pc     = 32'hFFFFFFFF;
        cycle_count = 0;
        first_seen  = 1'b0;
        record_idx  = 0;
    end

    always_ff @(posedge CLK) begin
        if (nRESET && CLKEN) begin
            // Detect a new instruction entering E: state_q == S_EXEC AND
            // de_q.valid AND de_q.pc != last_pc.
            if (u_dut.u_core.state_q == 4'd0    // S_EXEC
              && u_dut.u_core.de_q.valid
              && u_dut.u_core.de_q.pc != last_pc) begin
                // Log the previous instruction if we have one.
                if (first_seen) begin
                    if (record_idx < 128) begin
                        rec_pc    [record_idx] <= last_pc;
                        rec_cycles[record_idx] <= cycle_count;
                        rec_class [record_idx] <= u_dut.u_core.de_q.dec.instr_class;
                        record_idx <= record_idx + 1;
                    end
                end
                last_pc     <= u_dut.u_core.de_q.pc;
                cycle_count <= 1;
                first_seen  <= 1'b1;
            end else if (first_seen) begin
                cycle_count <= cycle_count + 1;
            end
        end
    end

    int unsigned errors = 0;

    task automatic check_cycles(input logic [31:0] pc,
                                input int expected,
                                input string instr_desc);
        int found_idx;
        found_idx = -1;
        for (int i = 0; i < record_idx; i = i + 1) begin
            if (rec_pc[i] == pc) begin
                found_idx = i;
            end
        end
        if (found_idx == -1) begin
            $display("[cycles] FAIL %s @0x%08x: not observed", instr_desc, pc);
            errors = errors + 1;
        end else if (rec_cycles[found_idx] != expected) begin
            $display("[cycles] FAIL %s @0x%08x: expected %0d, got %0d",
                     instr_desc, pc, expected, rec_cycles[found_idx]);
            errors = errors + 1;
        end else begin
            $display("[cycles]   ok  %s @0x%08x: %0d cycles",
                     instr_desc, pc, expected);
        end
    endtask

    initial begin
        $dumpfile("cycles.fst");
        $display("[cycles] starting; CYCLE_LIMIT=%0d", CYCLE_LIMIT);
        wait (nRESET);
        repeat (CYCLE_LIMIT) @(posedge CLK);

        // Dump all observations first so we see what we got.
        $display("[cycles] === observed instructions ===");
        for (int i = 0; i < record_idx; i = i + 1) begin
            $display("[cycles]   pc=%08x class=%0d cycles=%0d",
                     rec_pc[i], rec_class[i], rec_cycles[i]);
        end

        $display("[cycles] === TRM compliance check ===");
        // Per-PC expected cycles, derived from TRM Tables 7-3..7-23.
        check_cycles(32'h00000020, 1, "MOV r0,#1 (DP imm)");
        check_cycles(32'h00000024, 1, "MOV r1,#2 (DP imm)");
        check_cycles(32'h00000028, 1, "MOV r2,r0,LSL #2 (DP shift-by-imm)");
        check_cycles(32'h0000002C, 2, "MOV r3,r0,LSL r1 (DP shift-by-reg)");
        check_cycles(32'h00000030, 1, "MOV r13,#0x100 (DP imm)");
        check_cycles(32'h00000034, 2, "STR r0,[r13] (TRM 1S+1N => 2 cyc E)");
        check_cycles(32'h00000038, 3, "LDR r2,[r13] (TRM 1S+1N+1I => 3 cyc E)");
        check_cycles(32'h0000003C, 1, "AND r2,r4,r5 (DP-reg)");
        check_cycles(32'h00000040, 1, "ADD r3,r5,r2 (DP-reg)");
        // UMLAL: 1 S_EXEC + 1 S_MULL_ACC + m S_MUL_BUSY + 1 S_MULL_HI.
        // For r0=1, r1=2: Rs[31:8]=0 so m=1. Total = 4 cycles.
        check_cycles(32'h00000044, 4, "UMLAL r2,r3,r0,r1 (1S+1+m+1, m=1 => 4)");
        // TRM Table 7-12 LDM: 1S+(n-1)S+1N+1I = n+2 cycles (1I for Rd writeback).
        check_cycles(32'h00000048, 4, "LDM r13!,{r2,r3} (TRM n+2 = 4 cyc)");
        // TRM Table 7-15 STM: 1S+(n-1)S+1N = n+1 cycles (no I cycle).
        check_cycles(32'h0000004C, 3, "STM r13!,{r2,r3} (TRM n+1 = 3 cyc)");
        check_cycles(32'h00000050, 3, "LDRB r2,[r13,#4] (1S+1N+1I = 3 cyc E)");
        check_cycles(32'h00000054, 2, "STRB r3,[r13,#4] (1S+1N = 2 cyc E)");
        // Halfword loads/stores share the same S_DDATA / S_LOAD_WB path
        // as LDR/STR (TRM Table 7-8/7-10: same 1S+1N+1I / 1S+1N).
        check_cycles(32'h00000058, 3, "LDRH r4,[r13,#4] (1S+1N+1I = 3 cyc E)");
        check_cycles(32'h0000005C, 2, "STRH r2,[r13,#4] (1S+1N = 2 cyc E)");
        // MUL r5,r0,r1 with r1=2: Rs[31:8]=0 so m=1.
        // TRM Table 7-19: 1S+mI → 1+1 = 2 cycles E.
        check_cycles(32'h00000060, 2, "MUL r5,r0,r1 (1S+mI, m=1 => 2 cyc E)");
        // UMULL r6,r7,r0,r1 with r1=2: m=1.
        // TRM Table 7-21: 1S+(m+1)I → 1+2 = 3 cycles E (1 S_EXEC + 1 S_MUL_BUSY + 1 S_MULL_HI).
        check_cycles(32'h00000064, 3, "UMULL r6,r7,r0,r1 (1S+(m+1)I, m=1 => 3 cyc E)");
        // MRS / MSR: single-cycle DP-class (TRM Table 7-3).
        check_cycles(32'h00000068, 1, "MRS r8,CPSR (1S = 1 cyc E)");
        check_cycles(32'h0000006C, 1, "MSR CPSR_f,r0 (1S = 1 cyc E)");
        // MLA r9,r0,r1,r5 with r1=2: m=1.
        // TRM Table 7-19: 1S+(m+1)I → 1+2 = 3 cycles E.
        check_cycles(32'h00000070, 3, "MLA r9,r0,r1,r5 (1S+(m+1)I, m=1 => 3 cyc E)");
        // SMULL r10,r11,r0,r1 with r1=2: m=1.
        // TRM Table 7-21: 1S+(m+1)I → 3 cycles E (same as UMULL).
        check_cycles(32'h00000074, 3, "SMULL r10,r11,r0,r1 (1S+(m+1)I, m=1 => 3 cyc E)");
        // SMLAL r10,r11,r0,r1 with r1=2: m=1.
        // TRM Table 7-23: 1S+(m+2)I → 4 cycles E (same as UMLAL).
        check_cycles(32'h00000078, 4, "SMLAL r10,r11,r0,r1 (1S+(m+2)I, m=1 => 4 cyc E)");
        // SWP r12,r0,[r13]: TRM Table 7-17 = 1S+2N+1I = 4 cycles.
        check_cycles(32'h0000007C, 4, "SWP r12,r0,[r13] (TRM 1S+2N+1I = 4 cyc)");
        // BL: TRM Table 7-5 = 2S+1N = 3 cycles total (same as B). With
        // the §18 early-flush fast path driving the target onto ADDR
        // same cycle, refill is 2 cycles; LR is written in S_EXEC.
        check_cycles(32'h00000080, 3, "BL 0x8C (TRM 2S+1N = 3 cyc)");

        if (errors == 0)
            $display("[cycles] PASS (%0d instructions verified)", record_idx);
        else
            $display("[cycles] FAIL (%0d errors)", errors);
        $finish;
    end

endmodule
