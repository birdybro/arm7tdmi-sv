// ISA-017 pin-level User-bank block-transfer matrix.
//
// Ten reset-per-case rows execute STM^ and LDM^ from each mode that owns an
// SPSR: FIQ, IRQ, Supervisor, Abort, and Undefined. Every row seeds User and
// current banks through instructions, checks seven exact bus beats, compares
// all 31 flat storage slots, and proves mode/SPSR preservation. User/System
// S-form traps are covered by arm7tdmis_block_ls_policy_tb because ARMv4T
// labels those combinations UNPREDICTABLE.

`timescale 1ns/1ps

module arm7tdmis_register_banking_matrix_tb
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_types_pkg::*;
;

    localparam int CASE_COUNT = 10;
    localparam int MODE_COUNT = 5;
    localparam logic [31:0] TEST_PC = 32'h0000_004C;
    localparam logic [31:0] USER_SEED_BASE = 32'h0000_0200;
    localparam logic [31:0] CURRENT_SEED_BASE = 32'h0000_0240;
    localparam logic [31:0] TRANSFER_BASE = 32'h0000_0280;

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

    int unsigned errors;
    logic [31:0] expected_regs [0:30];

    function automatic logic [4:0] target_mode(input int mode_idx);
        unique case (mode_idx)
            0: return 5'(MODE_FIQ);
            1: return 5'(MODE_IRQ);
            2: return 5'(MODE_SUPERVISOR);
            3: return 5'(MODE_ABORT);
            default: return 5'(MODE_UNDEFINED);
        endcase
    endfunction

    function automatic string mode_name(input logic [4:0] selected_mode);
        unique case (selected_mode)
            MODE_FIQ:        return "FIQ";
            MODE_IRQ:        return "IRQ";
            MODE_SUPERVISOR: return "Supervisor";
            MODE_ABORT:      return "Abort";
            MODE_UNDEFINED:  return "Undefined";
            default:         return "invalid";
        endcase
    endfunction

    function automatic int banked_r13_index(
        input logic [4:0] selected_mode
    );
        unique case (selected_mode)
            MODE_FIQ:        return 21;
            MODE_IRQ:        return 23;
            MODE_SUPERVISOR: return 25;
            MODE_ABORT:      return 27;
            default:         return 29;
        endcase
    endfunction

    function automatic logic [31:0] user_value(
        input int case_id,
        input int reg_offset
    );
        return 32'h1100_0000
             | (32'(case_id) << 12)
             | 32'(8 + reg_offset);
    endfunction

    function automatic logic [31:0] current_value(
        input int case_id,
        input int reg_offset
    );
        return 32'h2200_0000
             | (32'(case_id) << 12)
             | 32'(8 + reg_offset);
    endfunction

    function automatic logic [31:0] transfer_value(
        input int case_id,
        input int reg_offset
    );
        return 32'h3300_0000
             | (32'(case_id) << 12)
             | 32'(8 + reg_offset);
    endfunction

    task automatic fail(
        input int    case_id,
        input string message
    );
        $display("[register_banking_matrix] FAIL case %0d: %s",
                 case_id, message);
        errors++;
    endtask

    task automatic setup_case(
        input  int          case_id,
        output logic [4:0]  selected_mode,
        output logic        load,
        output string       label
    );
        int mode_idx;
        logic [15:0] current_list;

        mode_idx = (case_id - 1) % MODE_COUNT;
        selected_mode = target_mode(mode_idx);
        load = case_id > MODE_COUNT;
        current_list = selected_mode == MODE_FIQ
                     ? 16'h7F00 : 16'h6000;
        label = $sformatf("%s %s user bank",
                          mode_name(selected_mode),
                          load ? "LDM^" : "STM^");

        for (int word = 0; word < 256; word++)
            u_mem.mem[word] = 32'hEAFF_FFFE;

        u_mem.mem[0]  = 32'hEA00_0006; // reset: B 0x20
        u_mem.mem[8]  = 32'hE321_F0DF; // System mode (User GPR bank)
        u_mem.mem[9]  = 32'hE1A0_0000; // mode-change separation
        u_mem.mem[10] = 32'hE1A0_0000;
        u_mem.mem[11] = 32'hE59F_00CC; // r0 <- 0x200 literal at 0x100
        u_mem.mem[12] = 32'hE890_7F00; // seed User r8-r14
        u_mem.mem[13] = 32'hE321_F0C0 | 32'(selected_mode);
        u_mem.mem[14] = 32'hE1A0_0000; // mode-change separation
        u_mem.mem[15] = 32'hE1A0_0000;
        u_mem.mem[16] = 32'hE59F_00BC; // r0 <- 0x240 literal at 0x104
        u_mem.mem[17] = 32'hE890_0000 | 32'(current_list);
        u_mem.mem[18] = 32'hE59F_00B8; // r0 <- 0x280 literal at 0x108
        u_mem.mem[19] = load ? 32'hE8D0_7F00  // LDMIA r0,{r8-r14}^
                             : 32'hE8C0_7F00; // STMIA r0,{r8-r14}^
        u_mem.mem[20] = 32'hE3A0_7000 | 32'(case_id);
        u_mem.mem[21] = 32'hEAFF_FFFE;

        u_mem.mem[64] = USER_SEED_BASE;
        u_mem.mem[65] = CURRENT_SEED_BASE;
        u_mem.mem[66] = TRANSFER_BASE;

        for (int offset = 0; offset < 7; offset++) begin
            u_mem.mem[(USER_SEED_BASE >> 2) + offset] =
                user_value(case_id, offset);
            u_mem.mem[(CURRENT_SEED_BASE >> 2) + offset] =
                current_value(case_id, offset);
            u_mem.mem[(TRANSFER_BASE >> 2) + offset] =
                load ? transfer_value(case_id, offset)
                     : 32'hC001_C0DE;
        end
    endtask

    task automatic build_expected(
        input int         case_id,
        input logic [4:0] selected_mode,
        input logic       load
    );
        int current_r13;

        for (int slot = 0; slot < 31; slot++)
            expected_regs[slot] = 32'h0;
        expected_regs[0] = TRANSFER_BASE;
        expected_regs[7] = 32'(case_id);

        for (int offset = 0; offset < 7; offset++)
            expected_regs[8 + offset] =
                load ? transfer_value(case_id, offset)
                     : user_value(case_id, offset);

        if (selected_mode == MODE_FIQ) begin
            for (int offset = 0; offset < 7; offset++)
                expected_regs[16 + offset] =
                    current_value(case_id, offset);
        end else begin
            current_r13 = banked_r13_index(selected_mode);
            expected_regs[current_r13] =
                current_value(case_id, 0);
            expected_regs[current_r13 + 1] =
                current_value(case_id, 1);
        end
    endtask

    task automatic run_case(input int case_id);
        logic [4:0] selected_mode;
        logic load;
        string label;
        logic test_seen;
        int data_cycles;
        int response_cycles;

        @(negedge CLK);
        nRESET = 1'b0;
        repeat (4) @(posedge CLK);
        setup_case(case_id, selected_mode, load, label);
        @(negedge CLK);
        nRESET = 1'b1;

        test_seen = 1'b0;
        data_cycles = 0;
        response_cycles = 0;
        repeat (180) begin
            @(negedge CLK);
            if (u_dut.u_core.state_q == 5'd0
                && u_dut.u_core.de_q.valid
                && u_dut.u_core.de_q.pc == TEST_PC)
                test_seen = 1'b1;

            if (test_seen
                && (TRANS inside {TRANS_N, TRANS_S})
                && PROT[PROT_BIT_DATA]) begin
                if (ADDR !== (TRANSFER_BASE + 32'(4 * data_cycles)))
                    fail(case_id, $sformatf(
                        "%s beat %0d address expected %08x got %08x",
                        label, data_cycles,
                        TRANSFER_BASE + 32'(4 * data_cycles), ADDR));
                if (SIZE !== 2'(SIZE_WORD) || WRITE !== !load
                    || !PROT[PROT_BIT_PRIV] || LOCK)
                    fail(case_id, $sformatf(
                        "%s beat %0d bus tuple is wrong", label,
                        data_cycles));
                if (TRANS !== (data_cycles == 0 ? TRANS_N : TRANS_S))
                    fail(case_id, $sformatf(
                        "%s beat %0d TRANS expected %02b got %02b",
                        label, data_cycles,
                        data_cycles == 0 ? TRANS_N : TRANS_S, TRANS));
                data_cycles++;
            end

            // Data is one cycle behind its address-class phase. Check it
            // against the memory model's latched response address.
            if (test_seen && u_mem.is_active_q
                && (u_mem.addr_q >= TRANSFER_BASE)
                && (u_mem.addr_q < (TRANSFER_BASE + 32'd28))) begin
                if (u_mem.addr_q
                    !== (TRANSFER_BASE + 32'(4 * response_cycles))
                    || u_mem.write_q !== !load)
                    fail(case_id, $sformatf(
                        "%s response %0d address/direction is wrong",
                        label, response_cycles));
                if (!load
                    && WDATA !== user_value(case_id, response_cycles))
                    fail(case_id, $sformatf(
                        "%s response %0d WDATA expected %08x got %08x",
                        label, response_cycles,
                        user_value(case_id, response_cycles), WDATA));
                if (load
                    && RDATA !== transfer_value(case_id, response_cycles))
                    fail(case_id, $sformatf(
                        "%s response %0d RDATA expected %08x got %08x",
                        label, response_cycles,
                        transfer_value(case_id, response_cycles), RDATA));
                response_cycles++;
            end
        end

        if (!test_seen)
            fail(case_id, {label, " never reached Execute"});
        if (data_cycles != 7)
            fail(case_id, $sformatf(
                "%s expected 7 data beats got %0d", label, data_cycles));
        if (response_cycles != 7)
            fail(case_id, $sformatf(
                "%s expected 7 data responses got %0d",
                label, response_cycles));
        if (u_dut.u_core.cpsr.m !== selected_mode
            || !u_dut.u_core.cpsr.i || !u_dut.u_core.cpsr.f
            || u_dut.u_core.cpsr.t)
            fail(case_id, $sformatf(
                "%s final CPSR/mode is wrong: %08x",
                label, 32'(u_dut.u_core.cpsr)));

        build_expected(case_id, selected_mode, load);
        for (int slot = 0; slot < 31; slot++) begin
            if (u_dut.u_core.u_regfile.regs[slot]
                !== expected_regs[slot])
                fail(case_id, $sformatf(
                    "%s slot %0d expected %08x got %08x",
                    label, slot, expected_regs[slot],
                    u_dut.u_core.u_regfile.regs[slot]));
        end

        for (int offset = 0; offset < 7; offset++) begin
            logic [31:0] expected_memory;
            expected_memory = load
                            ? transfer_value(case_id, offset)
                            : user_value(case_id, offset);
            if (u_mem.mem[(TRANSFER_BASE >> 2) + offset]
                !== expected_memory)
                fail(case_id, $sformatf(
                    "%s memory word %0d expected %08x got %08x",
                    label, offset, expected_memory,
                    u_mem.mem[(TRANSFER_BASE >> 2) + offset]));
        end

        for (int bank = 0; bank < 5; bank++) begin
            if (u_dut.u_core.u_psr.spsr_q[bank] !== 32'h0)
                fail(case_id, $sformatf(
                    "%s unexpectedly changed SPSR bank %0d to %08x",
                    label, bank,
                    u_dut.u_core.u_psr.spsr_q[bank]));
        end
        if (u_dut.u_core.u_regfile.regs[7] !== 32'(case_id))
            fail(case_id, {label, " completion marker did not retire"});
    endtask

    initial begin
        errors = 0;
        for (int case_id = 1; case_id <= CASE_COUNT; case_id++)
            run_case(case_id);

        if (errors != 0)
            $fatal(1, "[register_banking_matrix] FAIL (%0d errors)",
                   errors);
        $display("[register_banking_matrix] PASS (%0d reset-per-case rows)",
                 CASE_COUNT);
        $finish;
    end

    initial begin
        repeat (CASE_COUNT * 240) @(posedge CLK);
        $fatal(1, "[register_banking_matrix] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, ABORT, DMORE, CPnMREQ, CPSEQ,
        CPnTRANS, CPnOPC, CPTBIT, CPnI, DBGACK, DBGnEXEC,
        DBGINSTRVALID, DBGRNG, DBGCOMMTX, DBGCOMMRX, DBGTDO,
        DBGnTDOEN};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
