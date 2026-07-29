// ETM-001: DBGINSTRVALID/DBGnEXEC architectural trace-status matrix.
//
// DBGINSTRVALID marks exactly one enabled cycle when an instruction is
// committed to the Execute stage. DBGnEXEC is the active-low condition-code
// result for that instruction; Undefined/trapping instructions with a passing
// condition are still executed instructions.

`timescale 1ns/1ps

module arm7tdmis_etm_trace_matrix_tb;
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_types_pkg::*;

    logic CLK = 1'b0;
    initial forever #5 CLK = ~CLK;

    logic nRESET = 1'b0;
    logic CLKEN = 1'b1;
    logic DBGRQ = 1'b0;

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
        .CLK,
        .CLKEN,
        .nRESET,
        .CFGBIGEND(1'b0),
        .nIRQ(1'b1),
        .nFIQ(1'b1),
        .ABORT,
        .ADDR,
        .WRITE,
        .SIZE,
        .PROT,
        .LOCK,
        .TRANS,
        .WDATA,
        .RDATA,
        .CPnMREQ,
        .CPSEQ,
        .CPnTRANS,
        .CPnOPC,
        .CPTBIT,
        .CPnI,
        .CPA(1'b1),
        .CPB(1'b1),
        .DBGEN(1'b1),
        .DBGRQ,
        .DBGBREAK(1'b0),
        .DBGACK,
        .DBGnEXEC,
        .DBGINSTRVALID,
        .DBGEXT(2'b00),
        .DBGRNG,
        .DBGCOMMTX,
        .DBGCOMMRX,
        .DBGTCKEN(1'b0),
        .DBGTMS(1'b0),
        .DBGTDI(1'b0),
        .DBGTDO,
        .DBGnTRST(1'b1),
        .DBGnTDOEN,
        .DMORE
    );

    arm7tdmis_memory #(
        .WORDS(256)
    ) u_mem (
        .CLK,
        .CLKEN,
        .nRESET,
        .CFGBIGEND(1'b0),
        .ADDR,
        .WRITE,
        .SIZE,
        .PROT,
        .LOCK,
        .TRANS,
        .WDATA,
        .RDATA,
        .ABORT,
        .inject_abort(1'b0)
    );

    localparam logic [31:0] PC_ARM_NORMAL = 32'h0000_0040;
    localparam logic [31:0] PC_ARM_FAIL   = 32'h0000_0044;
    localparam logic [31:0] PC_ARM_LDR    = 32'h0000_0048;
    localparam logic [31:0] PC_ARM_BRANCH = 32'h0000_004c;
    localparam logic [31:0] PC_DISCARDED  = 32'h0000_0050;
    localparam logic [31:0] PC_UNDEFINED  = 32'h0000_0060;
    localparam logic [31:0] PC_UNDEF_VEC  = 32'h0000_0004;
    localparam logic [31:0] PC_THUMB_NOP  = 32'h0000_00a0;
    localparam logic [31:0] PC_THUMB_FAIL = 32'h0000_00a2;
    localparam logic [31:0] PC_THUMB_MOV  = 32'h0000_00a4;

    int unsigned errors = 0;
    int unsigned arm_normal_pulses = 0;
    int unsigned arm_fail_pulses = 0;
    int unsigned arm_ldr_pulses = 0;
    int unsigned arm_branch_pulses = 0;
    int unsigned discarded_pulses = 0;
    int unsigned undefined_pulses = 0;
    int unsigned undef_vector_pulses = 0;
    int unsigned thumb_nop_pulses = 0;
    int unsigned thumb_fail_pulses = 0;
    int unsigned thumb_mov_pulses = 0;
    int unsigned ldr_busy_cycles = 0;
    int unsigned stopped_execute_cycles = 0;

    task automatic fail(input string reason);
        $display("[etm_trace_matrix] FAIL: %s", reason);
        errors++;
    endtask

    // Sample after testbench edge stimulus has settled. This is a
    // testbench monitor process, not clocked design logic.
    initial forever begin
        @(negedge CLK);
        #2;
        if (!u_dut.core_nreset) begin
            if (DBGINSTRVALID || !DBGnEXEC)
                fail("trace status active during core reset");
        end else begin
            if (!DBGINSTRVALID && !DBGnEXEC)
                fail("DBGnEXEC LOW without a valid Execute-stage instruction");

            if (DBGINSTRVALID) begin
                if (!CLKEN || DBGACK
                    || u_dut.u_core.state_q != 5'd0
                    || !u_dut.u_core.de_q.valid)
                    fail("DBGINSTRVALID outside an enabled Execute stage");
                if (DBGnEXEC !== !u_dut.u_core.condition_pass)
                    fail($sformatf(
                        "DBGnEXEC did not reflect condition result at PC=%08x",
                        u_dut.u_core.de_q.pc));

                unique case (u_dut.u_core.de_q.pc)
                    PC_ARM_NORMAL: arm_normal_pulses++;
                    PC_ARM_FAIL: begin
                        arm_fail_pulses++;
                        if (!DBGnEXEC)
                            fail("condition-failed ARM instruction executed");
                    end
                    PC_ARM_LDR: arm_ldr_pulses++;
                    PC_ARM_BRANCH: arm_branch_pulses++;
                    PC_DISCARDED: discarded_pulses++;
                    PC_UNDEFINED: begin
                        undefined_pulses++;
                        if (DBGnEXEC)
                            fail("passing Undefined instruction reported unexecuted");
                    end
                    PC_UNDEF_VEC: undef_vector_pulses++;
                    PC_THUMB_NOP: begin
                        thumb_nop_pulses++;
                        if (!CPTBIT)
                            fail("Thumb NOP trace pulse lacked CPTBIT");
                    end
                    PC_THUMB_FAIL: begin
                        thumb_fail_pulses++;
                        if (!DBGnEXEC || !CPTBIT)
                            fail("failed Thumb condition trace classification");
                    end
                    PC_THUMB_MOV: begin
                        thumb_mov_pulses++;
                        if (!CPTBIT)
                            fail("Thumb MOV trace pulse lacked CPTBIT");
                    end
                    default: ;
                endcase
            end

            if (u_dut.u_core.state_q inside {5'd1, 5'd10}) begin
                ldr_busy_cycles++;
                if (DBGINSTRVALID || !DBGnEXEC)
                    fail("multicycle LDR substate emitted an extra trace pulse");
            end

            if (!CLKEN && u_dut.u_core.state_q == 5'd0
                && u_dut.u_core.de_q.valid
                && u_dut.u_core.de_q.pc == PC_ARM_NORMAL) begin
                stopped_execute_cycles++;
                if (DBGINSTRVALID || !DBGnEXEC)
                    fail("stopped Execute stage emitted a trace pulse");
            end

            if (DBGACK && (DBGINSTRVALID || !DBGnEXEC))
                fail("debug halt emitted an Execute trace pulse");
        end
    end

    initial begin
        int unsigned wait_cycles;

        for (int word = 0; word < 256; word++)
            u_mem.mem[word] = 32'hEAFF_FFFE;

        // Reset and Undefined vectors.
        u_mem.mem[0]  = 32'hEA00_000A; // B 0x30
        u_mem.mem[1]  = 32'hEA00_001D; // 0x04: B 0x80

        // ARM setup and trace rows.
        u_mem.mem[12] = 32'hE3A0_2C01; // 0x30: MOV r2,#0x100
        u_mem.mem[13] = 32'hE350_0001; // 0x34: CMP r0,#1 => Z=0
        u_mem.mem[14] = 32'hE1A0_0000; // 0x38: NOP
        u_mem.mem[15] = 32'hE1A0_0000; // 0x3c: NOP
        u_mem.mem[16] = 32'hE1A0_0000; // 0x40: normal NOP
        u_mem.mem[17] = 32'h0280_0001; // 0x44: ADDEQ r0,r0,#1 (fails)
        u_mem.mem[18] = 32'hE592_1000; // 0x48: LDR r1,[r2]
        u_mem.mem[19] = 32'hEA00_0003; // 0x4c: B 0x60
        u_mem.mem[20] = 32'hE3A0_30EE; // 0x50: flushed, must not trace
        u_mem.mem[24] = 32'hE7F0_00F0; // 0x60: reserved Undefined

        // Undefined handler enters Thumb at 0xa0.
        u_mem.mem[32] = 32'hE3A0_40A1; // 0x80: MOV r4,#0xa1
        u_mem.mem[33] = 32'hE12F_FF14; // 0x84: BX r4
        u_mem.mem[40] = 32'hD000_46C0; // 0xa0: NOP; BEQ (fails)
        u_mem.mem[41] = 32'hE7FE_2001; // 0xa4: MOV r0,#1; B .
        u_mem.mem[32'h100 >> 2] = 32'h1122_3344;

        repeat (4) @(posedge CLK);
        @(negedge CLK);
        nRESET = 1'b1;

        // Stop the first named instruction while it is resident in Execute.
        wait_cycles = 0;
        while (!(u_dut.u_core.state_q == 5'd0
                 && u_dut.u_core.de_q.valid
                 && u_dut.u_core.de_q.pc == PC_ARM_NORMAL)) begin
            @(negedge CLK);
            wait_cycles++;
            if (wait_cycles > 100)
                $fatal(1, "[etm_trace_matrix] ARM normal row not reached");
        end
        CLKEN = 1'b0;
        repeat (3) @(posedge CLK);
        @(negedge CLK);
        CLKEN = 1'b1;

        wait_cycles = 0;
        while (thumb_mov_pulses == 0) begin
            @(negedge CLK);
            wait_cycles++;
            if (wait_cycles > 180)
                $fatal(1, "[etm_trace_matrix] Thumb rows not reached");
        end

        // A synchronous debug request must stop future trace pulses.
        DBGRQ = 1'b1;
        wait_cycles = 0;
        while (!DBGACK) begin
            @(negedge CLK);
            wait_cycles++;
            if (wait_cycles > 80)
                $fatal(1, "[etm_trace_matrix] debug halt not reached");
        end
        repeat (4) @(negedge CLK);
        #3;

        if (arm_normal_pulses != 1
            || arm_fail_pulses != 1
            || arm_ldr_pulses != 1
            || arm_branch_pulses != 1
            || discarded_pulses != 0
            || undefined_pulses != 1
            || undef_vector_pulses != 1
            || thumb_nop_pulses != 1
            || thumb_fail_pulses != 1
            || thumb_mov_pulses != 1)
            fail($sformatf(
                "target pulse counts ARM=%0d/%0d/%0d/%0d discard=%0d UDF=%0d/vector=%0d Thumb=%0d/%0d/%0d",
                arm_normal_pulses, arm_fail_pulses, arm_ldr_pulses,
                arm_branch_pulses, discarded_pulses, undefined_pulses,
                undef_vector_pulses, thumb_nop_pulses, thumb_fail_pulses,
                thumb_mov_pulses));
        if (stopped_execute_cycles < 2)
            fail("Execute-stage CLKEN stall was not observed");
        if (ldr_busy_cycles < 2)
            fail("multicycle LDR substates were not observed");

        if (errors != 0)
            $fatal(1, "[etm_trace_matrix] FAIL (%0d errors)", errors);
        $display("[etm_trace_matrix] PASS");
        $finish;
    end

    initial begin
        repeat (500) @(posedge CLK);
        $fatal(1, "[etm_trace_matrix] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, WRITE, SIZE, PROT, LOCK, TRANS, WDATA, ABORT,
        CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPnI, DBGRNG, DBGCOMMTX,
        DBGCOMMRX, DBGTDO, DBGnTDOEN, DMORE};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
