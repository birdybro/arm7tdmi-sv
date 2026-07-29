// ISA-015 Thumb BL boundary regression.
//
// ARMv4T defines the two BL halfwords in terms of architectural LR:
//   prefix: LR = prefix-visible-PC + sign_extend(imm11 << 12)
//   suffix: PC = LR + (imm11 << 1), LR = suffix-next-PC | 1
//
// Whether an implementation permits an exception between the halfwords is
// IMPLEMENTATION DEFINED. This core permits it. The IRQ and PABT rows prove
// that returning to the suffix works after the complete exception pipeline
// flush and uses the prefix value retained in User LR. The orphan row enters
// a suffix directly with a seeded LR. A standalone suffix is architecturally
// UNPREDICTABLE; its checked result is this project's deterministic policy,
// not a portable ARM software guarantee.

`timescale 1ns/1ps

module arm7tdmis_thumb_bl_boundary_tb
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_instr_pkg::*;
    import arm7tdmis_types_pkg::*;
;

    localparam int CASE_IRQ    = 0;
    localparam int CASE_PABT   = 1;
    localparam int CASE_ORPHAN = 2;
    localparam int CASE_COUNT  = 3;

    localparam logic [31:0] PREFIX_PC    = 32'h0000_0080;
    localparam logic [31:0] SUFFIX_PC    = 32'h0000_0082;
    localparam logic [31:0] PAIR_TARGET  = 32'h0000_00C0;
    localparam logic [31:0] ORPHAN_LR    = 32'h0000_00A4;
    localparam logic [31:0] ORPHAN_TARGET = 32'h0000_00E0;

    logic CLK;
    initial begin
        CLK = 1'b0;
        forever #5 CLK = ~CLK;
    end

    logic nRESET = 1'b0;
    logic nIRQ   = 1'b1;
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
        .CFGBIGEND(1'b0), .nIRQ(nIRQ), .nFIQ(1'b1), .ABORT(ABORT),
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

    logic inject_abort;
    arm7tdmis_memory #(
        .WORDS(256)
    ) u_mem (
        .CLK(CLK), .CLKEN(1'b1), .nRESET(nRESET),
        .CFGBIGEND(1'b0),
        .ADDR(ADDR), .WRITE(WRITE), .SIZE(SIZE), .PROT(PROT),
        .LOCK(LOCK), .TRANS(TRANS), .WDATA(WDATA), .RDATA(RDATA),
        .ABORT(ABORT), .inject_abort(inject_abort)
    );

    int   current_case = CASE_IRQ;
    logic abort_injected;
    int unsigned rows_completed = 0;

    // Abort exactly the first response for the suffix halfword. The retry
    // after SUBS pc,lr,#4 must complete normally.
    always_comb begin
        inject_abort = nRESET
                     && (current_case == CASE_PABT)
                     && !abort_injected
                     && u_mem.is_active_q
                     && !u_mem.write_q
                     && (u_mem.size_q == 2'(SIZE_HALFWORD))
                     && (u_mem.addr_q == SUFFIX_PC);
    end

    always_ff @(posedge CLK) begin
        if (!nRESET)
            abort_injected <= 1'b0;
        else if (ABORT)
            abort_injected <= 1'b1;
    end

    function automatic logic [31:0] arm_branch(
        input logic [31:0] from_pc,
        input logic [31:0] to_pc
    );
        logic signed [31:0] displacement;
        displacement = $signed(to_pc) - $signed(from_pc + 32'd8);
        return 32'hEA00_0000
             | (32'(displacement >>> 2) & 32'h00FF_FFFF);
    endfunction

    function automatic logic [7:0] target_marker(
        input logic [1:0] case_id
    );
        return 8'h41 + {6'h0, case_id};
    endfunction

    function automatic string case_name(input int case_id);
        unique case (case_id)
            CASE_IRQ:    return "IRQ between BL prefix/suffix";
            CASE_PABT:   return "PABT on BL suffix";
            CASE_ORPHAN: return "orphan BL suffix policy";
            default:     return "invalid";
        endcase
    endfunction

    task automatic fail(input int case_id, input string reason);
        $fatal(1, "[thumb_bl_boundary] FAIL %s: %s",
               case_name(case_id), reason);
    endtask

    task automatic setup_case(input int case_id);
        logic [31:0] entry;
        logic [15:0] marker;

        for (int word = 0; word < 256; word++)
            u_mem.mem[word] = 32'hEAFF_FFFE;

        entry  = case_id == CASE_ORPHAN
               ? (SUFFIX_PC | 32'h1) : (PREFIX_PC | 32'h1);
        marker = 16'h2500
               | 16'(target_marker(2'(case_id))); // MOVS r5,#id

        // Exception vectors.
        u_mem.mem[0] = arm_branch(32'h0000_0000, 32'h0000_0020);
        u_mem.mem[3] = arm_branch(32'h0000_000C, 32'h0000_0120);
        u_mem.mem[6] = arm_branch(32'h0000_0018, 32'h0000_0100);

        // Enter System to seed the shared User LR, load the Thumb entry,
        // then enter unmasked User mode. Two NOPs put the mode change
        // safely ahead of BX in the pipeline.
        u_mem.mem[8]  = 32'hE321_F01F; // MSR CPSR_c,#System
        u_mem.mem[9]  = 32'hE59F_E044; // LDR lr,[pc,#0x44] -> 0x70
        u_mem.mem[10] = 32'hE59F_0044; // LDR r0,[pc,#0x44] -> 0x74
        u_mem.mem[11] = 32'hE321_F010; // MSR CPSR_c,#User, IRQ/FIQ on
        u_mem.mem[12] = 32'hE1A0_0000; // NOP
        u_mem.mem[13] = 32'hE1A0_0000; // NOP
        u_mem.mem[14] = 32'hE12F_FF10; // BX r0
        u_mem.mem[15] = 32'hE3A0_70EE; // flushed successor
        u_mem.mem[28] = ORPHAN_LR;
        u_mem.mem[29] = entry;

        // Prefix imm11=0 gives LR=0x84. Suffix imm11=0x1e adds 0x3c,
        // producing target 0xc0 and final architectural LR=0x85.
        u_mem.mem[PREFIX_PC >> 2] = {16'hF81E, 16'hF000};
        u_mem.mem[(PREFIX_PC >> 2) + 1] = {16'hE7FE, 16'h27EE};

        // Normal-pair and orphan destinations.
        u_mem.mem[PAIR_TARGET >> 2] =
            {16'hE7FE, case_id == CASE_ORPHAN ? 16'h25EE : marker};
        u_mem.mem[ORPHAN_TARGET >> 2] =
            {16'hE7FE, case_id == CASE_ORPHAN ? marker : 16'h25EE};

        // IRQ and Abort handlers leave distinct shared-register evidence,
        // then retry the interrupted/faulted suffix.
        u_mem.mem[32'h100 >> 2] = 32'hE3A0_6061; // MOV r6,#0x61
        u_mem.mem[32'h104 >> 2] = 32'hE25E_F004; // SUBS pc,lr,#4
        u_mem.mem[32'h108 >> 2] = 32'hE3A0_70E1; // must flush
        u_mem.mem[32'h120 >> 2] = 32'hE3A0_6062; // MOV r6,#0x62
        u_mem.mem[32'h124 >> 2] = 32'hE25E_F004; // SUBS pc,lr,#4
        u_mem.mem[32'h128 >> 2] = 32'hE3A0_70E2; // must flush
    endtask

    task automatic run_case(input int case_id);
        logic completed;
        logic irq_asserted;
        logic irq_released;
        int prefix_count;
        int suffix_count;
        int exception_count;
        int suffix_branch_count;
        int return_count;
        int abort_count;
        logic [31:0] expected_target;

        @(negedge CLK);
        nRESET = 1'b0;
        nIRQ   = 1'b1;
        current_case = case_id;
        repeat (4) @(posedge CLK);
        setup_case(case_id);
        @(negedge CLK);
        nRESET = 1'b1;

        completed           = 1'b0;
        irq_asserted        = 1'b0;
        irq_released        = 1'b0;
        prefix_count        = 0;
        suffix_count        = 0;
        exception_count     = 0;
        suffix_branch_count = 0;
        return_count        = 0;
        abort_count         = 0;
        expected_target = case_id == CASE_ORPHAN
                        ? ORPHAN_TARGET : PAIR_TARGET;

        for (int step = 0; step < 240; step++) begin
            @(negedge CLK);

            if (ABORT) begin
                abort_count++;
                if (case_id != CASE_PABT
                    || u_mem.addr_q !== SUFFIX_PC)
                    fail(case_id, "abort occurred outside the suffix fetch");
            end

            if (u_dut.u_core.state_q == 5'd0
                && u_dut.u_core.de_q.valid
                && u_dut.u_core.de_q.pc == PREFIX_PC) begin
                prefix_count++;
                if (!u_dut.u_core.de_q.thumb
                    || u_dut.u_core.de_q.dec.instr_class != INSTR_DP
                    || u_dut.u_core.rf_write_addr !== 4'd14
                    || u_dut.u_core.rf_write_data !== 32'h0000_0084)
                    fail(case_id, "BL prefix did not commit 0x84 to User LR");
            end

            if (u_dut.u_core.state_q == 5'd0
                && u_dut.u_core.de_q.valid
                && u_dut.u_core.de_q.pc == SUFFIX_PC) begin
                suffix_count++;
                if (!u_dut.u_core.de_q.thumb
                    || u_dut.u_core.de_q.dec.instr_class != INSTR_BRANCH
                    || !u_dut.u_core.de_q.dec.branch_thumb_link
                    || u_dut.u_core.u_regfile.regs[14]
                       !== (case_id == CASE_ORPHAN
                           ? ORPHAN_LR : 32'h0000_0084))
                    fail(case_id, "suffix did not consume architectural User LR");

                // Assert IRQ only after the prefix has committed and the
                // suffix is at the architectural Execute boundary.
                if (case_id == CASE_IRQ && !irq_asserted) begin
                    irq_asserted = 1'b1;
                    nIRQ = 1'b0;
                    #1;
                    if (!u_dut.u_core.irq_fires
                        || u_dut.u_core.flush_target_pc
                           !== 32'h0000_0018)
                        fail(case_id, "IRQ was not selected at the suffix boundary");
                end
            end

            if (case_id == CASE_IRQ && irq_asserted && !irq_released
                && u_dut.u_core.cpsr.m == 5'(MODE_IRQ)) begin
                nIRQ = 1'b1;
                irq_released = 1'b1;
            end

            if (u_dut.u_core.any_exc_fires) begin
                exception_count++;
                if (u_dut.u_core.de_q.pc !== SUFFIX_PC
                    || u_dut.u_core.u_regfile.regs[14]
                       !== 32'h0000_0084
                    || u_dut.u_core.rf_write_addr !== 4'd14
                    || u_dut.u_core.rf_write_data !== 32'h0000_0086)
                    fail(case_id, "exception did not preserve User LR/save suffix+4");
                if ((case_id == CASE_IRQ && !u_dut.u_core.irq_fires)
                    || (case_id == CASE_PABT
                        && !u_dut.u_core.pabt_fires)
                    || case_id == CASE_ORPHAN)
                    fail(case_id, "wrong exception class selected");
            end

            if (u_dut.u_core.flush
                && !u_dut.u_core.any_exc_fires
                && u_dut.u_core.de_q.valid
                && u_dut.u_core.de_q.pc == SUFFIX_PC) begin
                suffix_branch_count++;
                if (u_dut.u_core.flush_target_pc !== expected_target
                    || u_dut.u_core.rf_write_addr !== 4'd14
                    || u_dut.u_core.rf_write_data !== 32'h0000_0085)
                    fail(case_id, "suffix branch/link result was incorrect");
            end

            if (u_dut.u_core.flush
                && u_dut.u_core.cpsr_restore_now
                && ((case_id == CASE_IRQ
                     && u_dut.u_core.de_q.pc == 32'h0000_0104)
                    || (case_id == CASE_PABT
                        && u_dut.u_core.de_q.pc == 32'h0000_0124))) begin
                return_count++;
                if (u_dut.u_core.flush_target_pc !== SUFFIX_PC)
                    fail(case_id, "exception return did not retry the suffix");
            end

            if (u_dut.u_core.u_regfile.regs[5]
                == 32'(target_marker(2'(case_id)))) begin
                completed = 1'b1;
                break;
            end
        end

        if (!completed)
            fail(case_id, "branch destination marker did not retire");
        if (prefix_count != (case_id == CASE_ORPHAN ? 0 : 1))
            fail(case_id, $sformatf("prefix count expected %0d got %0d",
                 case_id == CASE_ORPHAN ? 0 : 1, prefix_count));
        if (suffix_count != (case_id == CASE_ORPHAN ? 1 : 2))
            fail(case_id, $sformatf("suffix count expected %0d got %0d",
                 case_id == CASE_ORPHAN ? 1 : 2, suffix_count));
        if (exception_count != (case_id == CASE_ORPHAN ? 0 : 1))
            fail(case_id, $sformatf("exception count expected %0d got %0d",
                 case_id == CASE_ORPHAN ? 0 : 1, exception_count));
        if (suffix_branch_count != 1)
            fail(case_id, "suffix did not commit exactly one branch");
        if (return_count != (case_id == CASE_ORPHAN ? 0 : 1))
            fail(case_id, "wrong exception-return count");
        if (abort_count != (case_id == CASE_PABT ? 1 : 0)
            || abort_injected !== (case_id == CASE_PABT))
            fail(case_id, "wrong suffix-fetch abort count");

        if (u_dut.u_core.u_regfile.regs[14] !== 32'h0000_0085
            || u_dut.u_core.u_regfile.regs[7] !== 32'h0
            || u_dut.u_core.cpsr.m !== 5'(MODE_USER)
            || !u_dut.u_core.cpsr.t)
            fail(case_id, "final User Thumb state/LR/flush state is wrong");

        unique case (case_id)
            CASE_IRQ: begin
                if (!irq_asserted || !irq_released
                    || u_dut.u_core.u_regfile.regs[6] !== 32'h61
                    || u_dut.u_core.u_regfile.regs[24] !== 32'h86
                    || 32'(u_dut.u_core.u_psr.spsr_q[1]) !== 32'h30)
                    fail(case_id, "IRQ bank, SPSR, or handler evidence is wrong");
            end
            CASE_PABT: begin
                if (u_dut.u_core.u_regfile.regs[6] !== 32'h62
                    || u_dut.u_core.u_regfile.regs[28] !== 32'h86
                    || 32'(u_dut.u_core.u_psr.spsr_q[3]) !== 32'h30)
                    fail(case_id, "Abort bank, SPSR, or handler evidence is wrong");
            end
            CASE_ORPHAN: begin
                if (u_dut.u_core.u_regfile.regs[6] !== 32'h0)
                    fail(case_id, "orphan suffix unexpectedly entered a handler");
            end
            default: ;
        endcase
    endtask

    initial begin
        for (int case_id = 0; case_id < CASE_COUNT; case_id++) begin
            run_case(case_id);
            rows_completed++;
        end

        if (rows_completed != CASE_COUNT)
            $fatal(1, "[thumb_bl_boundary] FAIL completed %0d/%0d",
                   rows_completed, CASE_COUNT);
        $display("[thumb_bl_boundary] PASS (IRQ, PABT, orphan suffix)");
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "[thumb_bl_boundary] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, ADDR, WRITE, SIZE, PROT, LOCK, TRANS,
        WDATA, RDATA, CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT,
        CPnI, DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG, DBGCOMMTX,
        DBGCOMMRX, DBGTDO, DBGnTDOEN, DMORE};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
