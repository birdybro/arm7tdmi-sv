// ISA-003 architectural multiply matrix.
//
// Every row runs after a fresh reset and executes through the public pin-level
// memory interface.  The matrix covers:
//   * MUL, MLA, UMULL, UMLAL, SMULL, and SMLAL;
//   * S=0 flag preservation and S=1 N/Z updates with C/V preservation;
//   * final-zero long-accumulate flags (not the pre-accumulate product);
//   * legal ARMv4 source/destination overlap (Rd=Rs, Rd=Rn, and long
//     destinations overlapping Rm/Rs);
//   * INT32_MIN and INT32_MAX signed products; and
//   * architectural m=1/2/3/4 early-termination timing.
//
// ARMv4 described short Rd=Rm as UNPREDICTABLE. The r4p3-compatible project
// policy reads every operand before writeback and therefore returns the
// ordinary mathematical result; two rows freeze that policy without calling
// it an architectural guarantee. Long RdLo=RdHi and any r15
// operand/destination use the separate precise-Undefined project policy.

`timescale 1ns/1ps

module arm7tdmis_multiply_matrix_tb
    import arm7tdmis_bus_pkg::*;
;

    localparam int CYCLE_LIMIT = 5000;
    localparam logic [31:0] MULTIPLY_PC = 32'h0000_0040;
    localparam logic [31:0] MRS_PC      = 32'h0000_0044;
    localparam logic [31:0] LOOP_PC     = 32'h0000_0048;

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
        .WORDS(256)
    ) u_mem (
        .CLK(CLK), .CLKEN(1'b1), .nRESET(nRESET),
        .CFGBIGEND(1'b0),
        .ADDR(ADDR), .WRITE(WRITE), .SIZE(SIZE), .PROT(PROT),
        .LOCK(LOCK), .TRANS(TRANS), .WDATA(WDATA), .RDATA(RDATA),
        .ABORT(ABORT), .inject_abort(1'b0)
    );

    function automatic logic [31:0] mul_opcode(
        input logic       accumulate,
        input logic       set_flags,
        input logic [3:0] rd,
        input logic [3:0] rn,
        input logic [3:0] rs,
        input logic [3:0] rm
    );
        return {4'hE, 6'b000000, accumulate, set_flags,
                rd, rn, rs, 4'b1001, rm};
    endfunction

    function automatic logic [31:0] mull_opcode(
        input logic       unsigned_form,
        input logic       accumulate,
        input logic       set_flags,
        input logic [3:0] rd_lo,
        input logic [3:0] rd_hi,
        input logic [3:0] rs,
        input logic [3:0] rm
    );
        return {4'hE, 5'b00001, unsigned_form, accumulate, set_flags,
                rd_hi, rd_lo, rs, 4'b1001, rm};
    endfunction

    int unsigned errors;
    int unsigned cases_run;

    task automatic run_case(
        input string       label,
        input logic [31:0] opcode,
        input logic [31:0] seed_r0,
        input logic [31:0] seed_r1,
        input logic [31:0] seed_r2,
        input logic [31:0] seed_r3,
        input logic [31:0] seed_r4,
        input logic [31:0] seed_r5,
        input int unsigned result_lo_reg,
        input logic [31:0] expected_lo,
        input logic        has_hi,
        input int unsigned result_hi_reg,
        input logic [31:0] expected_hi,
        input logic [3:0]  expected_nzcv,
        input int unsigned expected_cycles
    );
        logic seen_multiply;
        logic reached_next;
        logic reached_loop;
        int unsigned measured_cycles;

        @(negedge CLK);
        nRESET = 1'b0;
        repeat (4) @(posedge CLK);

        // Reset vector and exception-vector traps.
        u_mem.mem[0] = 32'hEA00_0006; // B 0x20
        for (int word = 1; word < 8; word++)
            u_mem.mem[word] = 32'hE7FF_FFFE;

        // Seven literal loads use the same +0x58 PC-relative displacement:
        // r0-r6 data live at 0x80-0x98. r6 seeds CPSR.NZCV=0101.
        for (int reg_idx = 0; reg_idx <= 6; reg_idx++)
            u_mem.mem[8 + reg_idx] = 32'hE59F_0058
                                   | (32'(reg_idx) << 12);
        u_mem.mem[15] = 32'hE128_F006; // MSR CPSR_f,r6
        u_mem.mem[16] = opcode;
        u_mem.mem[17] = 32'hE10F_7000; // MRS r7,CPSR
        u_mem.mem[18] = 32'hEAFF_FFFE; // B 0x48

        u_mem.mem[32] = seed_r0;
        u_mem.mem[33] = seed_r1;
        u_mem.mem[34] = seed_r2;
        u_mem.mem[35] = seed_r3;
        u_mem.mem[36] = seed_r4;
        u_mem.mem[37] = seed_r5;
        u_mem.mem[38] = 32'h5000_0000;

        @(negedge CLK);
        nRESET = 1'b1;

        seen_multiply   = 1'b0;
        reached_next    = 1'b0;
        reached_loop    = 1'b0;
        measured_cycles = 0;

        // Sample on falling edges so state/de_q have settled after each
        // active clock edge. Count S_EXEC plus every multiply substate,
        // stopping when the following MRS reaches S_EXEC.
        for (int step = 0; step < 160; step++) begin
            @(negedge CLK);
            if (!seen_multiply
                && u_dut.u_core.state_q == 5'd0
                && u_dut.u_core.de_q.valid
                && u_dut.u_core.de_q.pc == MULTIPLY_PC) begin
                seen_multiply   = 1'b1;
                measured_cycles = 1;
            end else if (seen_multiply && !reached_next) begin
                if (u_dut.u_core.state_q == 5'd0
                    && u_dut.u_core.de_q.valid
                    && u_dut.u_core.de_q.pc == MRS_PC) begin
                    reached_next = 1'b1;
                end else begin
                    measured_cycles = measured_cycles + 1;
                end
            end

            if (reached_next
                && u_dut.u_core.state_q == 5'd0
                && u_dut.u_core.de_q.valid
                && u_dut.u_core.de_q.pc == LOOP_PC) begin
                reached_loop = 1'b1;
                break;
            end
        end

        cases_run = cases_run + 1;
        if (!seen_multiply || !reached_next || !reached_loop) begin
            $display("[multiply_matrix] FAIL %s: execution did not reach multiply/MRS/loop (%0b/%0b/%0b)",
                     label, seen_multiply, reached_next, reached_loop);
            errors = errors + 1;
        end
        if (measured_cycles != expected_cycles) begin
            $display("[multiply_matrix] FAIL %s: expected %0d E cycles, got %0d",
                     label, expected_cycles, measured_cycles);
            errors = errors + 1;
        end
        if (u_dut.u_core.u_regfile.regs[result_lo_reg] !== expected_lo) begin
            $display("[multiply_matrix] FAIL %s: r%0d expected %08x got %08x",
                     label, result_lo_reg, expected_lo,
                     u_dut.u_core.u_regfile.regs[result_lo_reg]);
            errors = errors + 1;
        end
        if (has_hi
            && u_dut.u_core.u_regfile.regs[result_hi_reg] !== expected_hi) begin
            $display("[multiply_matrix] FAIL %s: r%0d expected %08x got %08x",
                     label, result_hi_reg, expected_hi,
                     u_dut.u_core.u_regfile.regs[result_hi_reg]);
            errors = errors + 1;
        end
        if (u_dut.u_core.u_regfile.regs[7][31:28] !== expected_nzcv) begin
            $display("[multiply_matrix] FAIL %s: NZCV expected %04b got %04b",
                     label, expected_nzcv,
                     u_dut.u_core.u_regfile.regs[7][31:28]);
            errors = errors + 1;
        end
    endtask

    initial begin
        errors    = 0;
        cases_run = 0;

        // All non-S rows must preserve the seeded NZCV=0101.
        run_case("MUL", mul_opcode(0, 0, 2, 0, 1, 0),
                 3, 7, 0, 0, 0, 0, 2, 21, 0, 0, 0, 4'b0101, 2);
        run_case("MULS", mul_opcode(0, 1, 2, 0, 1, 0),
                 32'hFFFF_FFFF, 3, 0, 0, 0, 0,
                 2, 32'hFFFF_FFFD, 0, 0, 0, 4'b1001, 2);
        run_case("MLA", mul_opcode(1, 0, 3, 2, 1, 0),
                 3, 7, 5, 0, 0, 0, 3, 26, 0, 0, 0, 4'b0101, 3);
        run_case("MLAS", mul_opcode(1, 1, 3, 2, 1, 0),
                 32'h8000_0000, 1, 0, 0, 0, 0,
                 3, 32'h8000_0000, 0, 0, 0, 4'b1001, 3);

        run_case("UMULL", mull_opcode(1, 0, 0, 2, 3, 1, 0),
                 32'hFFFF_FFFF, 2, 0, 0, 0, 0,
                 2, 32'hFFFF_FFFE, 1, 3, 1, 4'b0101, 3);
        run_case("UMULLS", mull_opcode(1, 0, 1, 2, 3, 1, 0),
                 32'hFFFF_FFFF, 32'hFFFF_FFFF, 0, 0, 0, 0,
                 2, 1, 1, 3, 32'hFFFF_FFFE, 4'b1001, 3);
        run_case("UMLAL", mull_opcode(1, 1, 0, 2, 3, 1, 0),
                 3, 7, 5, 0, 0, 0, 2, 26, 1, 3, 0, 4'b0101, 4);
        run_case("UMLALS final zero", mull_opcode(1, 1, 1, 2, 3, 1, 0),
                 32'hFFFF_FFFF, 1, 1, 32'hFFFF_FFFF, 0, 0,
                 2, 0, 1, 3, 0, 4'b0101, 4);

        run_case("SMULL INT32_MAX", mull_opcode(0, 0, 0, 2, 3, 1, 0),
                 32'h7FFF_FFFF, 32'h7FFF_FFFF, 0, 0, 0, 0,
                 2, 32'h0000_0001, 1, 3, 32'h3FFF_FFFF, 4'b0101, 6);
        run_case("SMULLS INT32_MIN*-1", mull_opcode(0, 0, 1, 2, 3, 1, 0),
                 32'h8000_0000, 32'hFFFF_FFFF, 0, 0, 0, 0,
                 2, 32'h8000_0000, 1, 3, 0, 4'b0001, 3);
        run_case("SMLAL", mull_opcode(0, 1, 0, 2, 3, 1, 0),
                 32'hFFFF_FFFF, 2, 5, 0, 0, 0,
                 2, 3, 1, 3, 0, 4'b0101, 4);
        run_case("SMLALS final zero", mull_opcode(0, 1, 1, 2, 3, 1, 0),
                 32'hFFFF_FFFF, 1, 1, 0, 0, 0,
                 2, 0, 1, 3, 0, 4'b0101, 4);

        // Defined overlap rows.
        run_case("MUL Rd=Rs", mul_opcode(0, 0, 1, 0, 1, 0),
                 3, 7, 0, 0, 0, 0, 1, 21, 0, 0, 0, 4'b0101, 2);
        run_case("MLA Rd=Rn", mul_opcode(1, 0, 2, 2, 1, 0),
                 3, 7, 5, 0, 0, 0, 2, 26, 0, 0, 0, 4'b0101, 3);
        run_case("UMULL RdLo=Rm RdHi=Rs",
                 mull_opcode(1, 0, 0, 0, 1, 1, 0),
                 3, 7, 0, 0, 0, 0, 0, 21, 1, 1, 0, 4'b0101, 3);
        run_case("UMLAL RdLo=Rm RdHi=Rs",
                 mull_opcode(1, 1, 0, 0, 1, 1, 0),
                 3, 7, 0, 0, 0, 0, 0, 24, 1, 1, 7, 4'b0101, 4);

        // ARMv4 UNPREDICTABLE policy: short Rd=Rm uses the original
        // multiplicand and returns the ordinary result, matching r4p3.
        run_case("MUL Rd=Rm policy", mul_opcode(0, 0, 2, 0, 1, 2),
                 0, 7, 3, 0, 0, 0, 2, 21, 0, 0, 0, 4'b0101, 2);
        run_case("MLA Rd=Rm policy", mul_opcode(1, 0, 3, 2, 1, 3),
                 0, 7, 5, 3, 0, 0, 3, 26, 0, 0, 0, 4'b0101, 3);

        // m=1 is exercised above. These rows close m=2/3/4 at core level.
        run_case("MUL m=2", mul_opcode(0, 0, 2, 0, 1, 0),
                 1, 32'h0000_FF00, 0, 0, 0, 0,
                 2, 32'h0000_FF00, 0, 0, 0, 4'b0101, 3);
        run_case("MUL m=3", mul_opcode(0, 0, 2, 0, 1, 0),
                 1, 32'h00FF_0000, 0, 0, 0, 0,
                 2, 32'h00FF_0000, 0, 0, 0, 4'b0101, 4);
        run_case("MUL m=4", mul_opcode(0, 0, 2, 0, 1, 0),
                 1, 32'h1000_0000, 0, 0, 0, 0,
                 2, 32'h1000_0000, 0, 0, 0, 4'b0101, 5);

        if (errors != 0)
            $fatal(1, "[multiply_matrix] FAIL (%0d errors, %0d cases)",
                   errors, cases_run);
        if (cases_run != 21)
            $fatal(1, "[multiply_matrix] FAIL expected 21 cases, ran %0d",
                   cases_run);
        $display("[multiply_matrix] PASS (%0d cases)", cases_run);
        $finish;
    end

    initial begin
        repeat (CYCLE_LIMIT) @(posedge CLK);
        $fatal(1, "[multiply_matrix] TIMEOUT after %0d cycles", CYCLE_LIMIT);
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused_outputs = &{1'b0,
        CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI,
        DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG,
        DBGCOMMTX, DBGCOMMRX, DBGTDO, DBGnTDOEN, DMORE
    };
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
