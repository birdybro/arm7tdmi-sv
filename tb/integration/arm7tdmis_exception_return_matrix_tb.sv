// ISA-014 exception-return cross-product.
//
// Every row starts from reset, selects one of the five modes with an SPSR,
// writes a distinct complete SPSR, and returns to User ARM or Thumb state.
// The six forms cover the architecturally recommended MOVS/SUBS idioms,
// both immediate return offsets, the separate register-controlled-shifter
// implementation path, and the conventional stack-based LDM ... {pc}^ form.
//
// In addition to the final PC/CPSR, each row checks the selected physical
// SPSR/LR/SP banks, the first redirected opcode bus tuple (including the
// restored privilege and instruction width), exact PC alignment, LDM data
// beats/writeback, all otherwise-unmodified physical registers and SPSRs,
// and suppression of the sequential instruction after the return.

`timescale 1ns/1ps

module arm7tdmis_exception_return_matrix_tb
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_instr_pkg::*;
    import arm7tdmis_types_pkg::*;
;

    localparam int MODE_COUNT  = 5;
    localparam int STATE_COUNT = 2;
    localparam int FORM_COUNT  = 6;
    localparam int ROW_COUNT   = MODE_COUNT * STATE_COUNT * FORM_COUNT;

    localparam logic [31:0] TEST_PC      = 32'h0000_0048;
    localparam logic [31:0] DATA_BASE    = 32'h0000_0200;
    localparam logic [31:0] ARM_TARGET   = 32'h0000_0300;
    localparam logic [31:0] THUMB_TARGET = 32'h0000_0342;

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

    logic [31:0] regs_before   [0:30];
    logic [31:0] spsrs_before  [0:4];
    logic [31:0] memory_before [0:255];
    int unsigned rows_completed = 0;

    function automatic logic [4:0] source_mode(input int mode_idx);
        unique case (mode_idx)
            0: return 5'(MODE_FIQ);
            1: return 5'(MODE_IRQ);
            2: return 5'(MODE_SUPERVISOR);
            3: return 5'(MODE_ABORT);
            4: return 5'(MODE_UNDEFINED);
            default: return 5'bxxxxx;
        endcase
    endfunction

    function automatic int spsr_index(input int mode_idx);
        return mode_idx;
    endfunction

    function automatic int sp_index(input int mode_idx);
        unique case (mode_idx)
            0: return 21;
            1: return 23;
            2: return 25;
            3: return 27;
            4: return 29;
            default: return -1;
        endcase
    endfunction

    function automatic int lr_index(input int mode_idx);
        return sp_index(mode_idx) + 1;
    endfunction

    function automatic string mode_name(input int mode_idx);
        unique case (mode_idx)
            0: return "FIQ";
            1: return "IRQ";
            2: return "Supervisor";
            3: return "Abort";
            4: return "Undefined";
            default: return "invalid";
        endcase
    endfunction

    function automatic string form_name(input int form_idx);
        unique case (form_idx)
            0: return "MOVS pc,lr";
            1: return "MOVS pc,r0,LSL r1";
            2: return "SUBS pc,lr,#4";
            3: return "SUBS pc,lr,#8";
            4: return "SUBS pc,lr,r0,LSL r1";
            5: return "LDMIA sp!,{r4,pc}^";
            default: return "invalid";
        endcase
    endfunction

    function automatic logic [31:0] return_opcode(input int form_idx);
        unique case (form_idx)
            0: return 32'hE1B0_F00E; // MOVS pc,lr
            1: return 32'hE1B0_F110; // MOVS pc,r0,LSL r1
            2: return 32'hE25E_F004; // SUBS pc,lr,#4
            3: return 32'hE25E_F008; // SUBS pc,lr,#8
            4: return 32'hE05E_F110; // SUBS pc,lr,r0,LSL r1
            5: return 32'hE8FD_8010; // LDMIA sp!,{r4,pc}^
            default: return 32'hExxx_xxxx;
        endcase
    endfunction

    function automatic logic [31:0] target_pc(input int state_idx);
        return state_idx == 0 ? ARM_TARGET : THUMB_TARGET;
    endfunction

    function automatic logic [31:0] raw_target(input int state_idx);
        // Both discarded ARM bits and the discarded Thumb bit are set.
        return state_idx == 0 ? (ARM_TARGET | 32'h3)
                              : (THUMB_TARGET | 32'h1);
    endfunction

    function automatic logic [31:0] target_spsr(
        input int mode_idx,
        input int state_idx,
        input int form_idx
    );
        logic [3:0] flags;
        logic       irq_mask;
        logic       fiq_mask;
        logic       thumb;
        flags    = 4'(((mode_idx * FORM_COUNT) + form_idx + 1) & 15);
        irq_mask = form_idx[0];
        thumb    = state_idx != 0;
        fiq_mask = mode_idx[0] ^ thumb;
        return {flags, 20'h0, irq_mask, fiq_mask, thumb,
                5'(MODE_USER)};
    endfunction

    function automatic logic [31:0] expected_source_cpsr(
        input int mode_idx
    );
        return {24'h0, 3'b110, source_mode(mode_idx)};
    endfunction

    function automatic logic [31:0] expected_lr(
        input int mode_idx,
        input int state_idx,
        input int form_idx
    );
        logic [31:0] raw;
        raw = raw_target(state_idx);
        unique case (form_idx)
            0: return raw;
            2: return raw + 32'd4;
            3: return raw + 32'd8;
            4: return raw + 32'd4;
            default: return 32'hCA00_0000
                            | (32'(mode_idx) << 8)
                            | 32'(form_idx);
        endcase
    endfunction

    function automatic logic [31:0] expected_r0(
        input int state_idx,
        input int form_idx
    );
        unique case (form_idx)
            1: return raw_target(state_idx);
            4: return 32'd4;
            default: return 32'h1357_9BDF;
        endcase
    endfunction

    task automatic fail(
        input int mode_idx,
        input int state_idx,
        input int form_idx,
        input string reason
    );
        $fatal(1, "[exception_return_matrix] FAIL %s -> %s via %s: %s",
               mode_name(mode_idx), state_idx == 0 ? "ARM" : "Thumb",
               form_name(form_idx), reason);
    endtask

    task automatic setup_row(
        input int mode_idx,
        input int state_idx,
        input int form_idx
    );
        logic [7:0]  source_control;
        logic [31:0] loaded_pc;

        for (int word = 0; word < 256; word++)
            u_mem.mem[word] = 32'hEAFF_FFFE;

        source_control = {3'b110, source_mode(mode_idx)};
        loaded_pc = raw_target(state_idx);

        // Reset vector and setup. Two NOPs drain the mode-changing MSR
        // before the exception-mode SPSR/LR/SP accesses are fetched.
        u_mem.mem[0]  = 32'hEA00_0006; // B 0x20
        u_mem.mem[8]  = 32'hE59F_2058; // LDR r2,[pc,#0x58] -> 0x80
        u_mem.mem[9]  = 32'hE321_F000 | 32'(source_control);
        u_mem.mem[10] = 32'hE1A0_0000; // NOP
        u_mem.mem[11] = 32'hE1A0_0000; // NOP
        u_mem.mem[12] = 32'hE16F_F002; // MSR SPSR_fsxc,r2
        u_mem.mem[13] = 32'hE59F_E048; // LDR lr,[pc,#0x48] -> 0x84
        u_mem.mem[14] = 32'hE59F_0048; // LDR r0,[pc,#0x48] -> 0x88
        u_mem.mem[15] = 32'hE59F_D048; // LDR sp,[pc,#0x48] -> 0x8c
        u_mem.mem[16] = 32'hE3A0_1000; // MOV r1,#0
        u_mem.mem[17] = 32'hE3A0_4044; // MOV r4,#0x44
        u_mem.mem[18] = return_opcode(form_idx);
        u_mem.mem[19] = 32'hE3A0_6066; // must be flushed
        u_mem.mem[20] = 32'hEAFF_FFFE;

        u_mem.mem[32] = target_spsr(mode_idx, state_idx, form_idx);
        u_mem.mem[33] = expected_lr(mode_idx, state_idx, form_idx);
        u_mem.mem[34] = expected_r0(state_idx, form_idx);
        u_mem.mem[35] = DATA_BASE;

        u_mem.mem[DATA_BASE >> 2] =
            32'hA500_0000 | 32'((mode_idx * 16) + (state_idx * 8)
                                + form_idx);
        u_mem.mem[(DATA_BASE >> 2) + 1] = loaded_pc;

        u_mem.mem[ARM_TARGET >> 2] = 32'hE1A0_0000; // ARM NOP
        u_mem.mem[(ARM_TARGET >> 2) + 1] = 32'hEAFF_FFFE;

        // THUMB_TARGET is the upper halfword of its word. If a faulty
        // return clears bit 1 too, it executes the lower-halfword loop.
        u_mem.mem[THUMB_TARGET >> 2] = {16'h46C0, 16'hE7FE};
        u_mem.mem[(THUMB_TARGET >> 2) + 1] = 32'hE7FE_E7FE;
    endtask

    task automatic snapshot_state;
        for (int reg_idx = 0; reg_idx < 31; reg_idx++)
            regs_before[reg_idx] = u_dut.u_core.u_regfile.regs[reg_idx];
        for (int spsr_idx = 0; spsr_idx < 5; spsr_idx++)
            spsrs_before[spsr_idx] =
                32'(u_dut.u_core.u_psr.spsr_q[spsr_idx]);
        for (int word = 0; word < 256; word++)
            memory_before[word] = u_mem.mem[word];
    endtask

    task automatic check_target_bus(
        input int mode_idx,
        input int state_idx,
        input int form_idx
    );
        if (ADDR !== target_pc(state_idx)
            || WRITE !== WRITE_READ
            || SIZE !== (state_idx == 0 ? 2'(SIZE_WORD)
                                        : 2'(SIZE_HALFWORD))
            || PROT !== 2'(PROT_OPC_USR)
            || LOCK !== LOCK_FREE
            || TRANS !== 2'(TRANS_N))
            fail(mode_idx, state_idx, form_idx, $sformatf(
                "first target bus A/W/S/P/L/T=%08x/%0b/%02b/%02b/%0b/%02b",
                ADDR, WRITE, SIZE, PROT, LOCK, TRANS));
    endtask

    task automatic check_final_state(
        input int mode_idx,
        input int state_idx,
        input int form_idx
    );
        logic [31:0] expected;
        logic [31:0] desired_spsr;
        logic [31:0] ldm_r4;

        desired_spsr = target_spsr(mode_idx, state_idx, form_idx);
        ldm_r4 = 32'hA500_0000
               | 32'((mode_idx * 16) + (state_idx * 8) + form_idx);

        if (u_dut.u_core.de_q.pc !== target_pc(state_idx)
            || u_dut.u_core.de_q.thumb !== 1'(state_idx))
            fail(mode_idx, state_idx, form_idx, $sformatf(
                "Execute target/state expected %08x/%0b got %08x/%0b",
                target_pc(state_idx), state_idx,
                u_dut.u_core.de_q.pc, u_dut.u_core.de_q.thumb));

        if ((state_idx == 0
             && u_dut.u_core.de_q.instr !== 32'hE1A0_0000)
            || (state_idx == 1
                && u_dut.u_core.de_q.instr[31:16] !== 16'h46C0))
            fail(mode_idx, state_idx, form_idx, $sformatf(
                "wrong target opcode word %08x", u_dut.u_core.de_q.instr));

        if (32'(u_dut.u_core.cpsr) !== desired_spsr)
            fail(mode_idx, state_idx, form_idx, $sformatf(
                "CPSR restore expected %08x got %08x",
                desired_spsr, 32'(u_dut.u_core.cpsr)));

        for (int reg_idx = 0; reg_idx < 31; reg_idx++) begin
            expected = regs_before[reg_idx];
            if (form_idx == 5 && reg_idx == sp_index(mode_idx))
                expected = DATA_BASE + 32'd8;
            if (form_idx == 5 && reg_idx == 4)
                expected = ldm_r4;
            if (u_dut.u_core.u_regfile.regs[reg_idx] !== expected)
                fail(mode_idx, state_idx, form_idx, $sformatf(
                    "physical GPR %0d expected %08x got %08x",
                    reg_idx, expected,
                    u_dut.u_core.u_regfile.regs[reg_idx]));
        end

        for (int spsr_idx = 0; spsr_idx < 5; spsr_idx++) begin
            if (32'(u_dut.u_core.u_psr.spsr_q[spsr_idx])
                !== spsrs_before[spsr_idx])
                fail(mode_idx, state_idx, form_idx, $sformatf(
                    "SPSR %0d changed %08x -> %08x",
                    spsr_idx, spsrs_before[spsr_idx],
                    32'(u_dut.u_core.u_psr.spsr_q[spsr_idx])));
        end

        for (int word = 0; word < 256; word++) begin
            if (u_mem.mem[word] !== memory_before[word])
                fail(mode_idx, state_idx, form_idx, $sformatf(
                    "memory word %0d changed %08x -> %08x",
                    word, memory_before[word], u_mem.mem[word]));
        end
    endtask

    task automatic run_row(
        input int mode_idx,
        input int state_idx,
        input int form_idx
    );
        logic [31:0] desired_spsr;
        logic        redirect_seen;
        logic        await_target_fetch;
        logic        target_fetch_seen;
        logic        target_exec_seen;
        int          redirect_count;
        int          data_cycles;
        int          wait_cycles;

        @(negedge CLK);
        nRESET = 1'b0;
        repeat (4) @(posedge CLK);
        setup_row(mode_idx, state_idx, form_idx);
        @(negedge CLK);
        nRESET = 1'b1;

        wait_cycles = 0;
        while (!(u_dut.u_core.state_q == 4'd0
                 && u_dut.u_core.de_q.valid
                 && u_dut.u_core.de_q.pc == TEST_PC)) begin
            @(negedge CLK);
            wait_cycles++;
            if (wait_cycles > 100)
                fail(mode_idx, state_idx, form_idx,
                     "return instruction never reached Execute");
        end

        desired_spsr = target_spsr(mode_idx, state_idx, form_idx);
        if (32'(u_dut.u_core.cpsr) !== expected_source_cpsr(mode_idx))
            fail(mode_idx, state_idx, form_idx, $sformatf(
                "source CPSR expected %08x got %08x",
                expected_source_cpsr(mode_idx),
                32'(u_dut.u_core.cpsr)));
        if (!u_dut.u_core.spsr_valid
            || 32'(u_dut.u_core.spsr_value) !== desired_spsr
            || 32'(u_dut.u_core.u_psr.spsr_q[spsr_index(mode_idx)])
               !== desired_spsr)
            fail(mode_idx, state_idx, form_idx, $sformatf(
                "selected SPSR expected %08x got live/bank=%08x/%08x",
                desired_spsr, 32'(u_dut.u_core.spsr_value),
                32'(u_dut.u_core.u_psr.spsr_q[spsr_index(mode_idx)])));
        for (int bank = 0; bank < 5; bank++) begin
            if (bank != spsr_index(mode_idx)
                && u_dut.u_core.u_psr.spsr_q[bank] !== 32'h0)
                fail(mode_idx, state_idx, form_idx, $sformatf(
                    "setup wrote unselected SPSR bank %0d", bank));
        end
        if (u_dut.u_core.u_regfile.regs[lr_index(mode_idx)]
            !== expected_lr(mode_idx, state_idx, form_idx))
            fail(mode_idx, state_idx, form_idx,
                 "setup selected the wrong banked LR");
        if (u_dut.u_core.u_regfile.regs[sp_index(mode_idx)] !== DATA_BASE)
            fail(mode_idx, state_idx, form_idx,
                 "setup selected the wrong banked SP");
        if (u_dut.u_core.de_q.instr !== return_opcode(form_idx)
            || !u_dut.u_core.condition_pass
            || (form_idx == 5
                ? (u_dut.u_core.de_q.dec.instr_class !== INSTR_LDM_STM)
                : (u_dut.u_core.de_q.dec.instr_class !== INSTR_DP)))
            fail(mode_idx, state_idx, form_idx,
                 "return opcode did not decode as intended");

        snapshot_state();
        redirect_seen      = 1'b0;
        await_target_fetch = 1'b0;
        target_fetch_seen  = 1'b0;
        target_exec_seen   = 1'b0;
        redirect_count     = 0;
        data_cycles        = 0;

        for (int step = 0; step < 100; step++) begin
            if ((TRANS == 2'(TRANS_N) || TRANS == 2'(TRANS_S))
                && PROT[PROT_BIT_DATA]) begin
                if (form_idx != 5)
                    fail(mode_idx, state_idx, form_idx,
                         "data transfer issued by data-processing return");
                if (data_cycles == 0) begin
                    if (ADDR !== DATA_BASE || TRANS !== 2'(TRANS_N))
                        fail(mode_idx, state_idx, form_idx,
                             "wrong first LDM data address/cycle");
                end else if (data_cycles == 1) begin
                    if (ADDR !== (DATA_BASE + 32'd4)
                        || TRANS !== 2'(TRANS_S))
                        fail(mode_idx, state_idx, form_idx,
                             "wrong second LDM data address/cycle");
                end else begin
                    fail(mode_idx, state_idx, form_idx,
                         "too many LDM data address cycles");
                end
                if (WRITE !== WRITE_READ || SIZE !== 2'(SIZE_WORD)
                    || PROT !== 2'(PROT_DAT_PRIV) || LOCK !== LOCK_FREE)
                    fail(mode_idx, state_idx, form_idx,
                         "wrong LDM data bus controls");
                data_cycles++;
            end

            if (u_dut.u_core.flush) begin
                redirect_count++;
                if (redirect_count > 1)
                    fail(mode_idx, state_idx, form_idx,
                         "more than one redirect before target");
                redirect_seen = 1'b1;
                if (!u_dut.u_core.cpsr_restore_now)
                    fail(mode_idx, state_idx, form_idx,
                         "redirect did not request CPSR-from-SPSR restore");
                if (u_dut.u_core.flush_target_pc !== target_pc(state_idx))
                    fail(mode_idx, state_idx, form_idx, $sformatf(
                        "aligned redirect expected %08x got %08x",
                        target_pc(state_idx),
                        u_dut.u_core.flush_target_pc));
                if (u_dut.u_core.early_flush_fetch !== (form_idx != 5))
                    fail(mode_idx, state_idx, form_idx,
                         "wrong early-refill path for return form");
                if (form_idx == 5
                    && !u_dut.u_core.block_ldm_pc_restore)
                    fail(mode_idx, state_idx, form_idx,
                         "LDM PC beat did not select exception restore");

                if (u_dut.u_core.early_flush_fetch) begin
                    check_target_bus(mode_idx, state_idx, form_idx);
                    target_fetch_seen = 1'b1;
                end else begin
                    await_target_fetch = 1'b1;
                end
            end else if (await_target_fetch
                         && (TRANS == 2'(TRANS_N)
                             || TRANS == 2'(TRANS_S))
                         && !PROT[PROT_BIT_DATA]) begin
                check_target_bus(mode_idx, state_idx, form_idx);
                target_fetch_seen  = 1'b1;
                await_target_fetch = 1'b0;
            end

            if (u_dut.u_core.state_q == 4'd0
                && u_dut.u_core.de_q.valid
                && u_dut.u_core.de_q.pc == target_pc(state_idx)) begin
                if (!target_fetch_seen)
                    fail(mode_idx, state_idx, form_idx,
                         "target reached Execute before its checked fetch");
                check_final_state(mode_idx, state_idx, form_idx);
                target_exec_seen = 1'b1;
                break;
            end

            @(negedge CLK);
        end

        if (!redirect_seen)
            fail(mode_idx, state_idx, form_idx, "return never redirected");
        if (!target_fetch_seen)
            fail(mode_idx, state_idx, form_idx,
                 "first target opcode fetch was not observed");
        if (!target_exec_seen)
            fail(mode_idx, state_idx, form_idx,
                 "return target never reached Execute");
        if (data_cycles != (form_idx == 5 ? 2 : 0))
            fail(mode_idx, state_idx, form_idx, $sformatf(
                "data cycle count expected %0d got %0d",
                form_idx == 5 ? 2 : 0, data_cycles));
    endtask

    initial begin
        for (int mode_idx = 0; mode_idx < MODE_COUNT; mode_idx++) begin
            for (int state_idx = 0; state_idx < STATE_COUNT; state_idx++) begin
                for (int form_idx = 0; form_idx < FORM_COUNT; form_idx++) begin
                    run_row(mode_idx, state_idx, form_idx);
                    rows_completed++;
                end
            end
        end

        if (rows_completed != ROW_COUNT)
            $fatal(1, "[exception_return_matrix] FAIL completed %0d/%0d rows",
                   rows_completed, ROW_COUNT);
        $display("[exception_return_matrix] PASS (%0d modes x %0d states x %0d forms = %0d rows)",
                 MODE_COUNT, STATE_COUNT, FORM_COUNT, rows_completed);
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "[exception_return_matrix] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, WDATA, RDATA, ABORT,
        CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI,
        DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG,
        DBGCOMMTX, DBGCOMMRX, DBGTDO, DBGnTDOEN, DMORE};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
