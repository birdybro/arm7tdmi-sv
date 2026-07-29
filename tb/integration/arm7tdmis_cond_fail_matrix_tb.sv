// ISA-013 exhaustive ARM condition-failure matrix.
//
// Every genuinely conditional ARM condition (EQ through LE) is forced false
// for a representative of every decode class and every distinct side-effect
// path in both Supervisor and User state.  An unexecuted instruction must
// take exactly the single S opcode cycle in TRM r4p3 Table 7-23:
//
//   incoming data/address phase: PC+8 opcode, word read, S, Prot0=0
//   outgoing address phase:      PC+12 opcode, word read, S, Prot0=0
//
// The row also freezes all physical registers, CPSR, every SPSR, memory, and
// CP14 state, and forbids data, LOCK, DMORE, coprocessor, or exception
// activity.  AL cannot fail and cond=1111 has the project's precise-Undefined
// policy, so neither belongs in this matrix.

`timescale 1ns/1ps

module arm7tdmis_cond_fail_matrix_tb
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_instr_pkg::*;
    import arm7tdmis_types_pkg::*;
;

    localparam int MODE_COUNT = 2;
    localparam int COND_COUNT = 14;
    localparam int OP_COUNT   = 39;
    localparam logic [31:0] TEST_PC = 32'h0000_0048;

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

    // A ready external coprocessor is the strongest suppression case: any
    // accidental CPnI request would otherwise be accepted immediately.
    logic CPA = 1'b0;
    logic CPB = 1'b0;

    arm7tdmis_top u_dut (
        .CLK(CLK), .CLKEN(1'b1), .nRESET(nRESET),
        .CFGBIGEND(1'b0), .nIRQ(1'b1), .nFIQ(1'b1), .ABORT(ABORT),
        .ADDR(ADDR), .WRITE(WRITE), .SIZE(SIZE), .PROT(PROT),
        .LOCK(LOCK), .TRANS(TRANS), .WDATA(WDATA), .RDATA(RDATA),
        .CPnMREQ(CPnMREQ), .CPSEQ(CPSEQ), .CPnTRANS(CPnTRANS),
        .CPnOPC(CPnOPC), .CPTBIT(CPTBIT), .CPnI(CPnI),
        .CPA(CPA), .CPB(CPB),
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
    logic [31:0] cpsr_before;
    logic [31:0] dcc_tx_data_before;
    logic [31:0] dcc_rx_data_before;
    logic        dcc_tx_full_before;
    logic        dcc_rx_full_before;
    logic        dbg_abt_before;
    int unsigned rows_completed = 0;
    int          current_mode_idx = 0;

    function automatic logic [3:0] false_nzcv(input int cond_idx);
        unique case (cond_idx)
            0:  return 4'b0000; // EQ: Z=0
            1:  return 4'b0100; // NE: Z=1
            2:  return 4'b0000; // CS: C=0
            3:  return 4'b0010; // CC: C=1
            4:  return 4'b0000; // MI: N=0
            5:  return 4'b1000; // PL: N=1
            6:  return 4'b0000; // VS: V=0
            7:  return 4'b0001; // VC: V=1
            8:  return 4'b0110; // HI: Z=1
            9:  return 4'b0010; // LS: C=1,Z=0
            10: return 4'b1000; // GE: N!=V
            11: return 4'b0000; // LT: N=V
            12: return 4'b0100; // GT: Z=1
            13: return 4'b0000; // LE: Z=0,N=V
            default: return 4'bxxxx;
        endcase
    endfunction

    function automatic string cond_name(input int cond_idx);
        unique case (cond_idx)
            0: return "EQ";  1: return "NE";
            2: return "CS";  3: return "CC";
            4: return "MI";  5: return "PL";
            6: return "VS";  7: return "VC";
            8: return "HI";  9: return "LS";
           10: return "GE"; 11: return "LT";
           12: return "GT"; 13: return "LE";
            default: return "invalid";
        endcase
    endfunction

    function automatic string mode_name(input int mode_idx);
        return mode_idx == 0 ? "Supervisor" : "User";
    endfunction

    function automatic logic [31:0] op_opcode(input int op_idx);
        unique case (op_idx)
             0: return 32'hE090_4001; // ADDS r4,r0,r1
             1: return 32'hE1B0_4110; // MOVS r4,r0,LSL r1
             2: return 32'hE1B0_F00E; // MOVS pc,lr
             3: return 32'hE10F_4000; // MRS r4,CPSR
             4: return 32'hE14F_4000; // MRS r4,SPSR
             5: return 32'hE12F_F000; // MSR CPSR_fsxc,r0
             6: return 32'hE16F_F000; // MSR SPSR_fsxc,r0
             7: return 32'hE014_0190; // MULS r4,r0,r1
             8: return 32'hE034_3190; // MLAS r4,r0,r1,r3
             9: return 32'hE095_4190; // UMULLS r4,r5,r0,r1
            10: return 32'hE0B5_4190; // UMLALS r4,r5,r0,r1
            11: return 32'hEB00_000E; // BL 0x80
            12: return 32'hE12F_FF10; // BX r0
            13: return 32'hE5B2_4004; // LDR r4,[r2,#4]!
            14: return 32'hE482_0004; // STR r0,[r2],#4
            15: return 32'hE5F2_4004; // LDRB r4,[r2,#4]!
            16: return 32'hE4C2_0004; // STRB r0,[r2],#4
            17: return 32'hE1F2_40B4; // LDRH r4,[r2,#4]!
            18: return 32'hE0C2_00B4; // STRH r0,[r2],#4
            19: return 32'hE1F2_40D4; // LDRSB r4,[r2,#4]!
            20: return 32'hE1F2_40F4; // LDRSH r4,[r2,#4]!
            21: return 32'hE8B2_0030; // LDMIA r2!,{r4,r5}
            22: return 32'hE8A2_0003; // STMIA r2!,{r0,r1}
            23: return 32'hE102_4090; // SWP r4,r0,[r2]
            24: return 32'hE142_4090; // SWPB r4,r0,[r2]
            25: return 32'hE7F0_00F0; // allocated Undefined encoding
            26: return 32'hE5B2_2004; // policy Undef: LDR W with Rn=Rd
            27: return 32'hE8B2_0000; // policy Undef: empty LDM list
            28: return 32'hE102_4092; // policy Undef: SWP Rn=Rm
            29: return 32'hEF12_3456; // SWI
            30: return 32'hEE00_0400; // CDP p4
            31: return 32'hEE01_0412; // MCR p4
            32: return 32'hEE11_4412; // MRC p4 -> r4
            33: return 32'hEDB2_3401; // LDC p4,c3,[r2,#4]!
            34: return 32'hECA2_5403; // STC p4,c5,[r2],#12
            35: return 32'hEE01_0E10; // MCR p14,0,r0,c1,c0,0
            36: return 32'hEE11_4E10; // MRC p14,0,r4,c1,c0,0
            37: return 32'hEE02_0E10; // MCR p14,0,r0,c2,c0,0
            38: return 32'hEE10_FE10; // MRC p14,0,r15,c0,c0,0
            default: return 32'hExxx_xxxx;
        endcase
    endfunction

    function automatic instr_class_e expected_class(input int op_idx);
        unique case (op_idx)
             0, 1, 2:       return INSTR_DP;
             3, 4:          return INSTR_MRS;
             5, 6:          return INSTR_MSR;
             7, 8:          return INSTR_MUL;
             9, 10:         return INSTR_MULL;
            11:             return INSTR_BRANCH;
            12:             return INSTR_BX;
            13, 14, 15, 16: return INSTR_LDR_STR;
            17, 18, 19, 20: return INSTR_LDRH_STRH;
            21, 22, 27:     return INSTR_LDM_STM;
            23, 24, 28:     return INSTR_SWP;
            25, 26:         return INSTR_UNDEF;
            29:             return INSTR_SWI;
            30:             return INSTR_CDP;
            31, 32, 35, 36,
            37, 38:         return INSTR_MCR_MRC;
            33, 34:         return INSTR_LDC_STC;
            default:        return INSTR_UNDEF;
        endcase
    endfunction

    function automatic string op_name(input int op_idx);
        unique case (op_idx)
             0: return "ADDS";
             1: return "MOVS register shift";
             2: return "MOVS pc,lr";
             3: return "MRS CPSR";
             4: return "MRS SPSR";
             5: return "MSR CPSR";
             6: return "MSR SPSR";
             7: return "MULS";
             8: return "MLAS";
             9: return "UMULLS";
            10: return "UMLALS";
            11: return "BL";
            12: return "BX";
            13: return "LDR writeback";
            14: return "STR post-index";
            15: return "LDRB writeback";
            16: return "STRB post-index";
            17: return "LDRH writeback";
            18: return "STRH post-index";
            19: return "LDRSB writeback";
            20: return "LDRSH writeback";
            21: return "LDMIA writeback";
            22: return "STMIA writeback";
            23: return "SWP";
            24: return "SWPB";
            25: return "Undefined encoding";
            26: return "single-transfer policy Undef";
            27: return "block-transfer policy Undef";
            28: return "swap policy Undef";
            29: return "SWI";
            30: return "CDP";
            31: return "external MCR";
            32: return "external MRC";
            33: return "LDC";
            34: return "STC";
            35: return "CP14 DCC write";
            36: return "CP14 DCC read";
            37: return "CP14 debug-abort write";
            38: return "CP14 MRC r15 flags";
            default: return "invalid";
        endcase
    endfunction

    task automatic fail(
        input int cond_idx,
        input int op_idx,
        input string reason
    );
        $fatal(1, "[cond_fail_matrix] FAIL %s %s-failed %s: %s",
               mode_name(current_mode_idx), cond_name(cond_idx),
               op_name(op_idx), reason);
    endtask

    task automatic setup_row(
        input int mode_idx,
        input int cond_idx,
        input int op_idx
    );
        logic [31:0] opcode;

        for (int word = 0; word < 256; word++)
            u_mem.mem[word] = 32'hEAFF_FFFE;

        // Reset vector and a steady, sequential setup stream.  The three
        // words after the test are deliberately valid opcode fetch data for
        // the two pipeline addresses named by Table 7-23.
        u_mem.mem[0]  = 32'hEA00_0006; // B 0x20
        u_mem.mem[8]  = 32'hE59F_0058; // LDR r0,[pc,#0x58] -> 0x80
        u_mem.mem[9]  = 32'hE128_F000; // MSR CPSR_f,r0
        u_mem.mem[10] = 32'hE3A0_0011; // MOV r0,#0x11
        u_mem.mem[11] = 32'hE3A0_1022; // MOV r1,#0x22
        u_mem.mem[12] = 32'hE3A0_2C01; // MOV r2,#0x100
        u_mem.mem[13] = 32'hE59F_3048; // LDR r3,[pc,#0x48] -> 0x84
        u_mem.mem[14] = 32'hE16F_F003; // MSR SPSR_fsxc,r3
        u_mem.mem[15] = (mode_idx == 0)
                      ? 32'hE321_F0D3  // MSR CPSR_c,#Supervisor
                      : 32'hE321_F0D0; // MSR CPSR_c,#User
        // Drain the mode-changing MSR from Execute before the target's
        // PC+8/PC+12 fetch addresses are issued.  PROT[1] is sampled when
        // each address is issued, not retroactively when its opcode executes.
        u_mem.mem[16] = 32'hE1A0_0000;
        u_mem.mem[17] = 32'hE1A0_0000;

        opcode = op_opcode(op_idx);
        opcode[31:28] = 4'(cond_idx);
        u_mem.mem[18] = opcode;       // test at 0x48
        u_mem.mem[19] = 32'hE1A0_0000; // NOP at 0x4c
        u_mem.mem[20] = 32'hE1A0_0000; // PC+8 returned opcode
        u_mem.mem[21] = 32'hE1A0_0000; // PC+12 outgoing fetch
        u_mem.mem[22] = 32'hEAFF_FFFE;

        u_mem.mem[32] = {false_nzcv(cond_idx), 28'h0};
        u_mem.mem[33] = 32'hA000_00D3;
        u_mem.mem[64] = 32'h89AB_CDEF;
        u_mem.mem[65] = 32'h7654_3210;
    endtask

    task automatic snapshot_state;
        for (int reg_idx = 0; reg_idx < 31; reg_idx++)
            regs_before[reg_idx] =
                u_dut.u_core.u_regfile.regs[reg_idx];
        cpsr_before = 32'(u_dut.u_core.cpsr);
        for (int spsr_idx = 0; spsr_idx < 5; spsr_idx++)
            spsrs_before[spsr_idx] =
                32'(u_dut.u_core.u_psr.spsr_q[spsr_idx]);
        for (int word = 0; word < 256; word++)
            memory_before[word] = u_mem.mem[word];

        dcc_tx_data_before = u_dut.u_ice.dcc_tx_data_q;
        dcc_rx_data_before = u_dut.u_ice.dcc_rx_data_q;
        dcc_tx_full_before = u_dut.u_ice.dcc_tx_full_q;
        dcc_rx_full_before = u_dut.u_ice.dcc_rx_full_q;
        dbg_abt_before     = u_dut.u_ice.dbg_abt_q;
    endtask

    task automatic compare_state(input int cond_idx, input int op_idx);
        for (int reg_idx = 0; reg_idx < 31; reg_idx++) begin
            if (u_dut.u_core.u_regfile.regs[reg_idx]
                !== regs_before[reg_idx])
                fail(cond_idx, op_idx, $sformatf(
                    "physical GPR %0d changed %08x -> %08x",
                    reg_idx, regs_before[reg_idx],
                    u_dut.u_core.u_regfile.regs[reg_idx]));
        end

        if (32'(u_dut.u_core.cpsr) !== cpsr_before)
            fail(cond_idx, op_idx, $sformatf(
                "CPSR changed %08x -> %08x",
                cpsr_before, 32'(u_dut.u_core.cpsr)));

        for (int spsr_idx = 0; spsr_idx < 5; spsr_idx++) begin
            if (32'(u_dut.u_core.u_psr.spsr_q[spsr_idx])
                !== spsrs_before[spsr_idx])
                fail(cond_idx, op_idx, $sformatf(
                    "SPSR %0d changed %08x -> %08x",
                    spsr_idx, spsrs_before[spsr_idx],
                    32'(u_dut.u_core.u_psr.spsr_q[spsr_idx])));
        end

        for (int word = 0; word < 256; word++) begin
            if (u_mem.mem[word] !== memory_before[word])
                fail(cond_idx, op_idx, $sformatf(
                    "memory word %0d changed %08x -> %08x",
                    word, memory_before[word], u_mem.mem[word]));
        end

        if (u_dut.u_ice.dcc_tx_data_q !== dcc_tx_data_before
            || u_dut.u_ice.dcc_rx_data_q !== dcc_rx_data_before
            || u_dut.u_ice.dcc_tx_full_q !== dcc_tx_full_before
            || u_dut.u_ice.dcc_rx_full_q !== dcc_rx_full_before
            || u_dut.u_ice.dbg_abt_q !== dbg_abt_before)
            fail(cond_idx, op_idx, "CP14 DCC/debug-abort state changed");
    endtask

    task automatic check_table_7_23_cycle(
        input int cond_idx,
        input int op_idx
    );
        logic [1:0] expected_prot;
        logic       expected_cp_ntrans;

        expected_prot = current_mode_idx == 0
                      ? 2'(PROT_OPC_PRIV) : 2'(PROT_OPC_USR);
        expected_cp_ntrans = current_mode_idx == 0;

        if (u_dut.u_core.cpsr.m
            !== (current_mode_idx == 0
                ? 5'(MODE_SUPERVISOR) : 5'(MODE_USER)))
            fail(cond_idx, op_idx, $sformatf(
                "setup entered wrong mode %05b", u_dut.u_core.cpsr.m));
        if (u_dut.u_core.de_q.dec.instr_class
            !== expected_class(op_idx))
            fail(cond_idx, op_idx, $sformatf(
                "opcode decoded as class %0d, expected %0d",
                u_dut.u_core.de_q.dec.instr_class,
                expected_class(op_idx)));
        if (u_dut.u_core.condition_pass !== 1'b0)
            fail(cond_idx, op_idx, "condition unexpectedly passed");

        // Incoming PC+2i (ARM i=4) address/data half of the S cycle.
        if (!u_dut.u_core.bus_history_valid_q
            || u_dut.u_core.bus_history_addr_q !== (TEST_PC + 32'd8)
            || u_dut.u_core.bus_history_write_q !== WRITE_READ
            || u_dut.u_core.bus_history_size_q !== 2'(SIZE_WORD)
            || u_dut.u_core.bus_history_prot_q !== expected_prot
            || u_dut.u_core.bus_history_lock_q !== LOCK_FREE
            || u_dut.u_core.bus_history_trans_q !== 2'(TRANS_S))
            fail(cond_idx, op_idx, $sformatf(
                "incoming PC+8 tuple A/W/S/P/L/T=%08x/%0b/%02b/%02b/%0b/%02b",
                u_dut.u_core.bus_history_addr_q,
                u_dut.u_core.bus_history_write_q,
                u_dut.u_core.bus_history_size_q,
                u_dut.u_core.bus_history_prot_q,
                u_dut.u_core.bus_history_lock_q,
                u_dut.u_core.bus_history_trans_q));
        if (u_mem.addr_q !== (TEST_PC + 32'd8)
            || u_mem.write_q !== WRITE_READ
            || u_mem.size_q !== 2'(SIZE_WORD)
            || u_mem.trans_q !== 2'(TRANS_S)
            || RDATA !== u_mem.mem[(TEST_PC + 32'd8) >> 2])
            fail(cond_idx, op_idx, $sformatf(
                "returned PC+8 opcode tuple A/W/S/T/D=%08x/%0b/%02b/%02b/%08x",
                u_mem.addr_q, u_mem.write_q, u_mem.size_q,
                u_mem.trans_q, RDATA));

        // Outgoing pc+3i address half of the same S cycle.
        if (ADDR !== (TEST_PC + 32'd12)
            || WRITE !== WRITE_READ
            || SIZE !== 2'(SIZE_WORD)
            || PROT !== expected_prot
            || LOCK !== LOCK_FREE
            || TRANS !== 2'(TRANS_S))
            fail(cond_idx, op_idx, $sformatf(
                "outgoing PC+12 tuple A/W/S/P/L/T=%08x/%0b/%02b/%02b/%0b/%02b",
                ADDR, WRITE, SIZE, PROT, LOCK, TRANS));

        if (DMORE !== 1'b0)
            fail(cond_idx, op_idx, "DMORE asserted");
        if (CPnI !== 1'b1)
            fail(cond_idx, op_idx, "CPnI asserted a coprocessor request");
        if (CPnMREQ !== 1'b0 || CPSEQ !== 1'b1
            || CPnTRANS !== expected_cp_ntrans || CPnOPC !== 1'b0
            || CPTBIT !== 1'b0)
            fail(cond_idx, op_idx, $sformatf(
                "CP pipeline tuple MREQ/SEQ/TRANS/OPC/T=%0b/%0b/%0b/%0b/%0b",
                CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT));
        if (u_dut.u_core.core_dcc_we
            || u_dut.u_core.core_dcc_re
            || u_dut.u_core.core_dbgabt_we)
            fail(cond_idx, op_idx, "internal CP14 strobe asserted");
        if (DBGINSTRVALID !== 1'b1 || DBGnEXEC !== 1'b1)
            fail(cond_idx, op_idx, $sformatf(
                "debug execute tuple VALID/nEXEC=%0b/%0b",
                DBGINSTRVALID, DBGnEXEC));
    endtask

    task automatic run_row(
        input int mode_idx,
        input int cond_idx,
        input int op_idx
    );
        int wait_cycles;

        current_mode_idx = mode_idx;
        @(negedge CLK);
        nRESET = 1'b0;
        repeat (4) @(posedge CLK);
        setup_row(mode_idx, cond_idx, op_idx);
        @(negedge CLK);
        nRESET = 1'b1;

        wait_cycles = 0;
        while (!((u_dut.u_core.state_q == 5'd0)
                 && u_dut.u_core.de_q.valid
                 && (u_dut.u_core.de_q.pc == TEST_PC))) begin
            @(negedge CLK);
            wait_cycles++;
            if (wait_cycles > 80)
                fail(cond_idx, op_idx, "test instruction never reached Execute");
        end

        check_table_7_23_cycle(cond_idx, op_idx);
        snapshot_state();

        // A failed multicycle instruction must not enter any substate.  One
        // enabled edge later, its sequential successor must occupy Execute.
        @(negedge CLK);
        if (u_dut.u_core.state_q !== 5'd0
            || !u_dut.u_core.de_q.valid
            || u_dut.u_core.de_q.pc !== (TEST_PC + 32'd4))
            fail(cond_idx, op_idx, $sformatf(
                "not exactly one cycle; next state/valid/pc=%0d/%0b/%08x",
                u_dut.u_core.state_q, u_dut.u_core.de_q.valid,
                u_dut.u_core.de_q.pc));

        compare_state(cond_idx, op_idx);
        if (LOCK !== LOCK_FREE || DMORE !== 1'b0 || !CPnI)
            fail(cond_idx, op_idx, "side-effect signal persisted after retire");
    endtask

    initial begin
        for (int mode_idx = 0; mode_idx < MODE_COUNT; mode_idx++) begin
            for (int cond_idx = 0; cond_idx < COND_COUNT; cond_idx++) begin
                for (int op_idx = 0; op_idx < OP_COUNT; op_idx++) begin
                    run_row(mode_idx, cond_idx, op_idx);
                    rows_completed = rows_completed + 1;
                end
            end
        end

        if (rows_completed != (MODE_COUNT * COND_COUNT * OP_COUNT))
            $fatal(1, "[cond_fail_matrix] FAIL completed %0d/%0d rows",
                   rows_completed, MODE_COUNT * COND_COUNT * OP_COUNT);
        $display("[cond_fail_matrix] PASS (%0d modes x %0d conditions x %0d paths = %0d rows)",
                 MODE_COUNT, COND_COUNT, OP_COUNT, rows_completed);
        $finish;
    end

    initial begin
        #5000000;
        $fatal(1, "[cond_fail_matrix] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, WDATA, DBGACK, DBGRNG,
        DBGCOMMTX, DBGCOMMRX, DBGTDO, DBGnTDOEN};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
