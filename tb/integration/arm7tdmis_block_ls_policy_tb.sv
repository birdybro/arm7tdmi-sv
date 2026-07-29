// ISA-011 / ISA-016 block-transfer banking and operand-policy matrix.
//
// Cases 1-8 and 13 cover defined behavior plus the implementation's
// deterministic base-in-list policies, privileged User-bank transfers, and
// both writeback forms of LDM^ with PC/CPSR restore. Cases 9-12 and 14-21
// require a precise Undefined trap for the remaining statically or
// dynamically detectable ARMv4T UNPREDICTABLE operand classes.

`timescale 1ns/1ps

module arm7tdmis_block_ls_policy_tb
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_types_pkg::*;
;

    localparam int CASE_COUNT      = 21;
    localparam logic [31:0] TEST_PC = 32'h0000_0060;
    localparam logic [31:0] DATA_BASE = 32'h0000_0200;

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

    task automatic fail(input int case_id, input string label);
        $fatal(1, "[block_ls_policy] FAIL case %0d: %s", case_id, label);
    endtask

    function automatic logic [31:0] block_opcode(
        input logic        s_bit,
        input logic        writeback,
        input logic        load,
        input logic [3:0]  rn,
        input logic [15:0] reg_list
    );
        logic [31:0] opcode;
        opcode = 32'hE880_0000; // AL, LDM/STM IA
        opcode[22] = s_bit;
        opcode[21] = writeback;
        opcode[20] = load;
        opcode[19:16] = rn;
        opcode[15:0] = reg_list;
        return opcode;
    endfunction

    function automatic logic is_trap_case(input int case_id);
        return ((case_id >= 9) && (case_id <= 12))
            || (case_id >= 14);
    endfunction

    task automatic setup_case(
        input  int          case_id,
        output string       label,
        output int          expected_data_cycles,
        output logic [31:0] expected_spsr
    );
        logic [31:0] opcode;

        for (int word = 0; word < 256; word++)
            u_mem.mem[word] = 32'hEAFF_FFFE;

        // Reset and Undefined vectors.
        u_mem.mem[0]  = 32'hEA00_0006; // B 0x20
        u_mem.mem[1]  = 32'hEA00_003D; // B 0x100
        u_mem.mem[64] = 32'hE3A0_6000 | 32'(case_id);
        u_mem.mem[65] = 32'hEAFF_FFFE;

        // Common setup at 0x20. Literals are at 0xc0..0xc8, leaving
        // 0x2c..0x5c available for mode/bank-specific preparation.
        u_mem.mem[8]  = 32'hE59F_4098; // r4 <- [0xc0] = base
        u_mem.mem[9]  = 32'hE59F_5098; // r5 <- [0xc4] = 0x55
        u_mem.mem[10] = 32'hE59F_3098; // r3 <- [0xc8] = 0x33
        for (int word = 11; word < 24; word++)
            u_mem.mem[word] = 32'hE1A0_0000; // NOP

        u_mem.mem[25] = 32'hE3A0_7000 | 32'(case_id);
        u_mem.mem[26] = 32'hEAFF_FFFE;
        u_mem.mem[48] = DATA_BASE;
        u_mem.mem[49] = 32'h0000_0055;
        u_mem.mem[50] = 32'h0000_0033;
        u_mem.mem[96] = 32'hEAFF_FFFE; // target loop at 0x180

        u_mem.mem[128] = 32'hC001_C0DE;
        u_mem.mem[129] = 32'hC001_C0DE;
        opcode = 32'hE7F0_00F0;
        expected_data_cycles = is_trap_case(case_id) ? 0 : 2;
        expected_spsr = 32'h0000_00D3;

        unique case (case_id)
            1: begin
                label = "defined STM writeback base is lowest";
                opcode = block_opcode(
                    1'b0, 1'b1, 1'b0, 4'd4, 16'h0030);
            end
            2: begin
                label = "policy STM writeback base is not lowest";
                opcode = block_opcode(
                    1'b0, 1'b1, 1'b0, 4'd4, 16'h0018);
            end
            3: begin
                label = "defined LDM base in list without writeback";
                opcode = block_opcode(
                    1'b0, 1'b0, 1'b1, 4'd4, 16'h0030);
                u_mem.mem[128] = 32'h1111_1111;
                u_mem.mem[129] = 32'h2222_2222;
            end
            4, 5, 8: begin
                label = (case_id == 4)
                      ? "defined privileged STM user bank"
                      : (case_id == 5)
                      ? "defined privileged LDM user bank"
                      : "defined privileged STM user bank with PC";
                // Seed the current SVC and User/System r13/r14 banks.
                u_mem.mem[11] = 32'hE3A0_D0AA; // r13_svc = 0xaa
                u_mem.mem[12] = 32'hE3A0_E0BB; // r14_svc = 0xbb
                u_mem.mem[13] = 32'hE321_F0DF; // System mode
                u_mem.mem[14] = 32'hE3A0_D055; // r13_usr = 0x55
                u_mem.mem[15] = 32'hE3A0_E066; // r14_usr = 0x66
                u_mem.mem[16] = 32'hE321_F0D3; // Supervisor mode
                if (case_id == 4)
                    opcode = block_opcode(
                        1'b1, 1'b0, 1'b0, 4'd4, 16'h6000);
                else if (case_id == 5) begin
                    opcode = block_opcode(
                        1'b1, 1'b0, 1'b1, 4'd4, 16'h6000);
                    u_mem.mem[128] = 32'hD00D_0013;
                    u_mem.mem[129] = 32'hD00D_0014;
                end else begin
                    opcode = block_opcode(
                        1'b1, 1'b0, 1'b0, 4'd4, 16'hA000);
                end
            end
            6, 7: begin
                label = (case_id == 6)
                      ? "defined LDM PC restore without writeback"
                      : "defined LDM PC restore with writeback";
                u_mem.mem[11] = 32'hE3A0_10DF; // desired SPSR: System
                u_mem.mem[12] = 32'hE161_F001; // MSR SPSR_c,r1
                opcode = block_opcode(
                    1'b1, 1'(case_id == 7), 1'b1,
                    4'd4, 16'h8001);
                u_mem.mem[128] = 32'h1234_5678;
                u_mem.mem[129] = 32'h0000_0180;
            end
            9: begin
                label = "policy trap empty STM list";
                opcode = block_opcode(
                    1'b0, 1'b0, 1'b0, 4'd4, 16'h0000);
            end
            10: begin
                label = "policy trap empty LDM list";
                opcode = block_opcode(
                    1'b0, 1'b0, 1'b1, 4'd4, 16'h0000);
            end
            11: begin
                label = "policy trap STM Rn=pc";
                opcode = block_opcode(
                    1'b0, 1'b0, 1'b0, 4'd15, 16'h0001);
            end
            12: begin
                label = "policy trap LDM Rn=pc";
                opcode = block_opcode(
                    1'b0, 1'b0, 1'b1, 4'd15, 16'h0001);
            end
            13: begin
                // ARM leaves the final base value UNPREDICTABLE. Preserve
                // the r4p3-compatible Base Updated result, which also
                // permits the dedicated per-beat abort regression.
                label = "policy LDM writeback base in list";
                opcode = block_opcode(
                    1'b0, 1'b1, 1'b1, 4'd4, 16'h0030);
                u_mem.mem[128] = 32'h1111_1111;
                u_mem.mem[129] = 32'h2222_2222;
            end
            14: begin
                label = "policy trap LDM user bank with writeback";
                opcode = block_opcode(
                    1'b1, 1'b1, 1'b1, 4'd4, 16'h6000);
            end
            15: begin
                label = "policy trap STM user bank with writeback";
                opcode = block_opcode(
                    1'b1, 1'b1, 1'b0, 4'd4, 16'h6000);
            end
            16, 17, 18, 19, 20, 21: begin
                logic user_mode;
                logic load;
                logic pc_in_list;
                user_mode = case_id inside {16, 17, 20};
                load = case_id inside {16, 18, 20, 21};
                pc_in_list = case_id inside {20, 21};
                label = $sformatf(
                    "policy trap %s%s in %s mode",
                    load ? "LDM" : "STM",
                    pc_in_list ? " PC restore" : " user bank",
                    user_mode ? "User" : "System");
                u_mem.mem[11] = user_mode
                              ? 32'hE321_F0D0 : 32'hE321_F0DF;
                expected_spsr = user_mode
                              ? 32'h0000_00D0 : 32'h0000_00DF;
                opcode = block_opcode(
                    1'b1, 1'b0, load, 4'd4,
                    pc_in_list ? 16'h8001 : 16'h6000);
            end
            default: label = "invalid case";
        endcase

        u_mem.mem[24] = opcode;
    endtask

    task automatic run_case(input int case_id);
        string label;
        int expected_data_cycles;
        logic [31:0] expected_spsr;
        int data_cycles;
        int pc_internal_cycles;
        int merged_internal_cycles;
        logic test_seen;

        @(negedge CLK);
        nRESET = 1'b0;
        repeat (4) @(posedge CLK);
        setup_case(
            case_id, label, expected_data_cycles, expected_spsr);
        @(negedge CLK);
        nRESET = 1'b1;

        data_cycles = 0;
        pc_internal_cycles = 0;
        merged_internal_cycles = 0;
        test_seen = 1'b0;
        repeat (130) begin
            @(negedge CLK);
            if ((u_dut.u_core.state_q == 5'd0)
                && (u_dut.u_core.de_q.pc == TEST_PC))
                test_seen = 1'b1;
            if (test_seen && u_dut.u_core.block_pc_internal_phase) begin
                pc_internal_cycles++;
                if (!(case_id inside {6, 7})
                    || ADDR !== 32'h0000_0180
                    || WRITE !== WRITE_READ
                    || SIZE !== 2'(SIZE_WORD)
                    || PROT !== 2'(PROT_OPC_PRIV)
                    || LOCK !== LOCK_FREE
                    || TRANS !== 2'(TRANS_N))
                    fail(case_id, {label,
                        " emitted a malformed LDM target phase"});
            end
            if (test_seen
                && (TRANS inside {TRANS_N, TRANS_S})
                && PROT[PROT_BIT_DATA]) begin
                if (ADDR >= DATA_BASE
                    && ADDR < (DATA_BASE + 32'd8)) begin
                    data_cycles++;
                    if (SIZE !== 2'(SIZE_WORD))
                        fail(case_id, {label, " issued a non-word beat"});
                    if (LOCK)
                        fail(case_id, {label, " asserted LOCK"});
                end else begin
                    // Table 7-13 retains data-class controls while an
                    // ordinary LDM's final internal writeback merges with
                    // the pc+12/S prefetch.
                    merged_internal_cycles++;
                    if (!(case_id inside {3, 5, 13})
                        || ADDR !== (TEST_PC + 32'd12)
                        || WRITE !== WRITE_READ
                        || SIZE !== 2'(SIZE_WORD)
                        || PROT !== 2'(PROT_DAT_PRIV)
                        || LOCK !== LOCK_FREE
                        || TRANS !== 2'(TRANS_S))
                        fail(case_id, {label,
                            " emitted an unexpected merged LDM phase"});
                end
            end
        end

        if (!test_seen)
            fail(case_id, {label, " never reached the test instruction"});
        if (data_cycles != expected_data_cycles)
            fail(case_id, $sformatf(
                "%s data-cycle count expected %0d got %0d",
                label, expected_data_cycles, data_cycles));
        if (pc_internal_cycles != ((case_id inside {6, 7}) ? 1 : 0))
            fail(case_id, $sformatf(
                "%s target phase count expected %0d got %0d",
                label, (case_id inside {6, 7}) ? 1 : 0,
                pc_internal_cycles));
        if (merged_internal_cycles
            != ((case_id inside {3, 5, 13}) ? 1 : 0))
            fail(case_id, $sformatf(
                "%s merged phase count expected %0d got %0d",
                label, (case_id inside {3, 5, 13}) ? 1 : 0,
                merged_internal_cycles));

        if (is_trap_case(case_id)) begin
            if (u_dut.u_core.cpsr.m !== 5'(MODE_UNDEFINED)
                || u_dut.u_core.cpsr.t || !u_dut.u_core.cpsr.i)
                fail(case_id, {label, " did not enter ARM Undefined mode"});
            if (u_dut.u_core.u_regfile.regs[30] !== 32'h0000_0064)
                fail(case_id, $sformatf(
                    "%s LR_und expected 00000064 got %08x",
                    label, u_dut.u_core.u_regfile.regs[30]));
            if (u_dut.u_core.u_psr.spsr_q[4] !== expected_spsr)
                fail(case_id, $sformatf(
                    "%s SPSR_und expected %08x got %08x",
                    label, expected_spsr,
                    u_dut.u_core.u_psr.spsr_q[4]));
            if (u_dut.u_core.u_regfile.regs[6] !== 32'(case_id))
                fail(case_id, {label, " handler marker missing"});
            if (u_dut.u_core.u_regfile.regs[7] !== 32'h0)
                fail(case_id, {label, " executed the flushed successor"});
            if ((u_mem.mem[128] !== 32'hC001_C0DE)
                || (u_mem.mem[129] !== 32'hC001_C0DE)
                || (u_mem.mem[26] !== 32'hEAFF_FFFE))
                fail(case_id, {label, " modified memory before the trap"});
        end else begin
            if (case_id inside {6, 7}) begin
                if (u_dut.u_core.cpsr.m !== 5'(MODE_SYSTEM)
                    || u_dut.u_core.cpsr.t
                    || u_dut.u_core.pc_q !== 32'h0000_0180)
                    fail(case_id, {label, " restored wrong CPSR/PC"});
                if (u_dut.u_core.u_regfile.regs[0]
                    !== 32'h1234_5678)
                    fail(case_id, {label, " loaded wrong r0"});
                if (u_dut.u_core.u_regfile.regs[4]
                    !== ((case_id == 7)
                        ? 32'h0000_0208 : DATA_BASE))
                    fail(case_id, {label, " produced wrong base result"});
                if (u_dut.u_core.u_regfile.regs[7] !== 32'h0)
                    fail(case_id, {label, " failed to flush successor"});
            end else begin
                if (u_dut.u_core.cpsr.m !== 5'(MODE_SUPERVISOR))
                    fail(case_id, {label, " changed processor mode"});
                if (u_dut.u_core.u_regfile.regs[7] !== 32'(case_id))
                    fail(case_id, {label, " completion marker missing"});
            end

            unique case (case_id)
                1: begin
                    if ((u_mem.mem[128] !== DATA_BASE)
                        || (u_mem.mem[129] !== 32'h0000_0055)
                        || (u_dut.u_core.u_regfile.regs[4]
                            !== 32'h0000_0208))
                        fail(case_id, {label, " base-lowest rule mismatch"});
                end
                2: begin
                    if ((u_mem.mem[128] !== 32'h0000_0033)
                        || (u_mem.mem[129] !== 32'h0000_0208)
                        || (u_dut.u_core.u_regfile.regs[4]
                            !== 32'h0000_0208))
                        fail(case_id, {label,
                            " deterministic updated-base policy mismatch"});
                end
                3: begin
                    if ((u_dut.u_core.u_regfile.regs[4]
                         !== 32'h1111_1111)
                        || (u_dut.u_core.u_regfile.regs[5]
                            !== 32'h2222_2222))
                        fail(case_id, {label, " loaded wrong registers"});
                end
                4: begin
                    if ((u_mem.mem[128] !== 32'h0000_0055)
                        || (u_mem.mem[129] !== 32'h0000_0066)
                        || (u_dut.u_core.u_regfile.regs[25]
                            !== 32'h0000_00AA)
                        || (u_dut.u_core.u_regfile.regs[26]
                            !== 32'h0000_00BB))
                        fail(case_id, {label, " selected wrong bank"});
                end
                5: begin
                    if ((u_dut.u_core.u_regfile.regs[13]
                         !== 32'hD00D_0013)
                        || (u_dut.u_core.u_regfile.regs[14]
                            !== 32'hD00D_0014)
                        || (u_dut.u_core.u_regfile.regs[25]
                            !== 32'h0000_00AA)
                        || (u_dut.u_core.u_regfile.regs[26]
                            !== 32'h0000_00BB))
                        fail(case_id, {label, " selected wrong bank"});
                end
                8: begin
                    if ((u_mem.mem[128] !== 32'h0000_0055)
                        || (u_mem.mem[129] !== 32'h0000_006C))
                        fail(case_id, $sformatf(
                            "%s stored wrong user/PC data: %08x/%08x",
                            label, u_mem.mem[128], u_mem.mem[129]));
                end
                13: begin
                    if ((u_dut.u_core.u_regfile.regs[4]
                         !== 32'h0000_0208)
                        || (u_dut.u_core.u_regfile.regs[5]
                            !== 32'h2222_2222))
                        fail(case_id, {label,
                            " deterministic Base Updated result mismatch"});
                end
                default: ;
            endcase
        end
    endtask

    initial begin
        for (int case_id = 1; case_id <= CASE_COUNT; case_id++)
            run_case(case_id);

        $display("[block_ls_policy] PASS (%0d reset-per-case rows)",
                 CASE_COUNT);
        $finish;
    end

    initial begin
        #400000;
        $fatal(1, "[block_ls_policy] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, ADDR, WRITE, WDATA, RDATA, DMORE,
        CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI,
        DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG,
        DBGCOMMTX, DBGCOMMRX, DBGTDO, DBGnTDOEN};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
