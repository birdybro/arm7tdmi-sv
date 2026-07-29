// ISA-011 ARM Addressing Mode 4 matrix.
//
// The 256 one-hot rows execute every P/U/W/L combination with each of the
// sixteen register-list bits independently.  Sixteen eight-register rows
// then prove ascending register/address order and sequential bus addressing
// for every IA/IB/DA/DB, W, and L combination.  S-bit banking and
// UNPREDICTABLE operand policy are intentionally left to the paired policy
// matrix so every row here is architecturally defined.

`timescale 1ns/1ps

module arm7tdmis_block_ls_matrix_tb
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_types_pkg::*;
;

    localparam int ONE_HOT_CASES = 256;
    localparam int MULTI_CASES   = 16;
    localparam int CASE_COUNT    = ONE_HOT_CASES + MULTI_CASES;

    localparam logic [31:0] ONE_BASE   = 32'h0000_0300;
    localparam logic [31:0] MULTI_BASE = 32'h0000_0380;
    localparam logic [15:0] MULTI_LIST = 16'h6AA5; // r0,r2,r5,r7,r9,r11,r13,r14
    localparam int MULTI_COUNT = 8;

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
        .WORDS(512)
    ) u_mem (
        .CLK(CLK), .CLKEN(1'b1), .nRESET(nRESET),
        .CFGBIGEND(1'b0),
        .ADDR(ADDR), .WRITE(WRITE), .SIZE(SIZE), .PROT(PROT),
        .LOCK(LOCK), .TRANS(TRANS), .WDATA(WDATA), .RDATA(RDATA),
        .ABORT(ABORT), .inject_abort(1'b0)
    );

    task automatic fail(input int case_id, input string label);
        $fatal(1, "[block_ls_matrix] FAIL case %0d: %s", case_id, label);
    endtask

    task automatic hold_reset;
        @(negedge CLK);
        nRESET = 1'b0;
        repeat (4) @(posedge CLK);
    endtask

    function automatic int physical_svc_index(input int reg_index);
        if (reg_index == 13)
            return 25;
        if (reg_index == 14)
            return 26;
        return reg_index;
    endfunction

    function automatic logic [31:0] start_address(
        input logic [31:0] base,
        input logic        pre_index,
        input logic        up,
        input int          count
    );
        logic [31:0] count_bytes;
        count_bytes = 32'(count * 4);
        unique case ({pre_index, up})
            2'b01: return base;
            2'b11: return base + 32'd4;
            2'b00: return base - count_bytes + 32'd4;
            default: return base - count_bytes;
        endcase
    endfunction

    function automatic logic [31:0] final_base(
        input logic [31:0] base,
        input logic        up,
        input logic        writeback,
        input int          count
    );
        if (!writeback)
            return base;
        return up ? (base + 32'(count * 4))
                  : (base - 32'(count * 4));
    endfunction

    function automatic string mode_name(
        input logic pre_index,
        input logic up
    );
        unique case ({pre_index, up})
            2'b01: return "IA";
            2'b11: return "IB";
            2'b00: return "DA";
            default: return "DB";
        endcase
    endfunction

    task automatic clear_memory;
        for (int word = 0; word < 512; word++)
            u_mem.mem[word] = 32'hEAFF_FFFE;
        u_mem.mem[0] = 32'hEA00_0006; // B 0x20
    endtask

    task automatic observe_data_addresses(
        input int          case_id,
        input string       label,
        input logic [31:0] expected_start,
        input int          expected_count,
        input logic        load,
        input int          cycles
    );
        int seen;
        seen = 0;
        repeat (cycles) begin
            @(negedge CLK);
            if ((TRANS inside {TRANS_N, TRANS_S})
                && PROT[PROT_BIT_DATA]
                && (ADDR >= 32'h0000_02C0)
                && (ADDR < 32'h0000_0400)) begin
                if (seen >= expected_count)
                    fail(case_id, {label, " issued an extra data cycle"});
                if (ADDR !== (expected_start + 32'(seen * 4)))
                    fail(case_id, $sformatf(
                        "%s beat %0d address expected %08x got %08x",
                        label, seen, expected_start + 32'(seen * 4), ADDR));
                if (SIZE !== 2'(SIZE_WORD))
                    fail(case_id, {label, " issued a non-word beat"});
                if (WRITE !== !load)
                    fail(case_id, {label, " issued wrong transfer direction"});
                if (!PROT[PROT_BIT_PRIV])
                    fail(case_id, {label, " issued an unprivileged beat"});
                if (LOCK)
                    fail(case_id, {label, " asserted LOCK"});
                if ((seen == 0) && (TRANS !== 2'(TRANS_N)))
                    fail(case_id, {label, " first beat was not N"});
                if ((seen != 0) && (TRANS !== 2'(TRANS_S)))
                    fail(case_id, {label, " continuation beat was not S"});
                seen++;
            end
        end
        if (seen != expected_count)
            fail(case_id, $sformatf(
                "%s data-cycle count expected %0d got %0d",
                label, expected_count, seen));
    endtask

    task automatic run_one_hot(
        input int   case_id,
        input logic pre_index,
        input logic up,
        input logic writeback,
        input logic load,
        input int   reg_index
    );
        logic [3:0]  base_reg;
        logic [15:0] reg_list;
        logic [31:0] opcode;
        logic [31:0] expected_address;
        logic [31:0] transfer_value;
        logic [31:0] expected_pc;
        string label;

        hold_reset();
        clear_memory();

        // Keep Rn distinct from the one-hot destination/source so every
        // row in this functional matrix is architecturally defined.
        base_reg = (reg_index == 10) ? 4'd11 : 4'd10;
        reg_list = 16'h0001 << reg_index;
        expected_address = start_address(
            ONE_BASE, pre_index, up, 1);
        transfer_value = load ? (32'hA500_0000 | 32'(reg_index))
                              : (32'h5A00_0000 | 32'(reg_index));
        expected_pc = (load && (reg_index == 15))
                    ? 32'h0000_0080 : 32'h0000_002C;
        label = $sformatf("%s%s W=%0b one-hot r%0d",
                          load ? "LDM" : "STM",
                          mode_name(pre_index, up),
                          writeback, reg_index);

        // 0x20: load Rn; 0x24: seed the STM source; 0x28: transfer.
        u_mem.mem[8] = 32'hE59F_0038 | (32'(base_reg) << 12);
        u_mem.mem[9] = (reg_index == 15)
                     ? 32'hE1A0_0000
                     : (32'hE59F_0038 | (32'(reg_index) << 12));
        opcode = 32'hE800_0000;
        opcode[24] = pre_index;
        opcode[23] = up;
        opcode[22] = 1'b0;
        opcode[21] = writeback;
        opcode[20] = load;
        opcode[19:16] = base_reg;
        opcode[15:0] = reg_list;
        u_mem.mem[10] = opcode;
        u_mem.mem[11] = 32'hEAFF_FFFE; // B 0x2c
        u_mem.mem[24] = ONE_BASE;
        u_mem.mem[25] = transfer_value;
        u_mem.mem[32] = 32'hEAFF_FFFE; // B 0x80

        if (load && (reg_index == 15))
            u_mem.mem[expected_address[10:2]] = 32'h0000_0080;
        else
            u_mem.mem[expected_address[10:2]] = load
                                               ? transfer_value
                                               : 32'hC001_C0DE;

        @(negedge CLK);
        nRESET = 1'b1;
        observe_data_addresses(
            case_id, label, expected_address, 1, load, 70);

        if (u_dut.u_core.u_regfile.regs[5'(base_reg)]
            !== final_base(ONE_BASE, up, writeback, 1))
            fail(case_id, $sformatf(
                "%s base expected %08x got %08x",
                label, final_base(ONE_BASE, up, writeback, 1),
                u_dut.u_core.u_regfile.regs[5'(base_reg)]));
        if (load && (reg_index != 15)) begin
            if (u_dut.u_core.u_regfile.regs[
                    physical_svc_index(reg_index)] !== transfer_value)
                fail(case_id, $sformatf(
                    "%s destination expected %08x got %08x",
                    label, transfer_value,
                    u_dut.u_core.u_regfile.regs[
                        physical_svc_index(reg_index)]));
        end else if (!load) begin
            logic [31:0] expected_store;
            expected_store = (reg_index == 15)
                           ? 32'h0000_0034 : transfer_value;
            if (u_mem.mem[expected_address[10:2]] !== expected_store)
                fail(case_id, $sformatf(
                    "%s memory expected %08x got %08x",
                    label, expected_store,
                    u_mem.mem[expected_address[10:2]]));
        end
        if (u_dut.u_core.pc_q !== expected_pc)
            fail(case_id, $sformatf(
                "%s final PC expected %08x got %08x",
                label, expected_pc, u_dut.u_core.pc_q));
        if (u_dut.u_core.cpsr.m !== 5'(MODE_SUPERVISOR)
            || u_dut.u_core.cpsr.t)
            fail(case_id, {label, " changed mode/state"});
    endtask

    task automatic run_multi(
        input int   case_id,
        input logic pre_index,
        input logic up,
        input logic writeback,
        input logic load
    );
        logic [31:0] opcode;
        logic [31:0] expected_start;
        string label;
        int program_word;
        int beat;

        hold_reset();
        clear_memory();

        expected_start = start_address(
            MULTI_BASE, pre_index, up, MULTI_COUNT);
        label = $sformatf("%s%s W=%0b multi-list",
                          load ? "LDM" : "STM",
                          mode_name(pre_index, up), writeback);

        program_word = 8;
        for (int reg_index = 0; reg_index < 15; reg_index++) begin
            if (MULTI_LIST[reg_index]) begin
                u_mem.mem[program_word] = 32'hE3A0_0000
                                        | (32'(reg_index) << 12)
                                        | 32'(8'h40 + reg_index);
                program_word++;
            end
        end
        // Eight MOVs occupy 0x20..0x3c. Load r12 at 0x40.
        u_mem.mem[16] = 32'hE59F_C028; // [pc,#0x28] -> 0x70
        opcode = 32'hE800_0000;
        opcode[24] = pre_index;
        opcode[23] = up;
        opcode[22] = 1'b0;
        opcode[21] = writeback;
        opcode[20] = load;
        opcode[19:16] = 4'd12;
        opcode[15:0] = MULTI_LIST;
        u_mem.mem[17] = opcode;
        u_mem.mem[18] = 32'hEAFF_FFFE; // B 0x48
        u_mem.mem[28] = MULTI_BASE;

        beat = 0;
        for (int reg_index = 0; reg_index < 15; reg_index++) begin
            if (MULTI_LIST[reg_index]) begin
                u_mem.mem[(expected_start >> 2) + beat] =
                    load ? (32'hB600_0000 | 32'(reg_index))
                         : 32'hC001_C0DE;
                beat++;
            end
        end

        @(negedge CLK);
        nRESET = 1'b1;
        observe_data_addresses(
            case_id, label, expected_start, MULTI_COUNT, load, 90);

        if (u_dut.u_core.u_regfile.regs[12]
            !== final_base(MULTI_BASE, up, writeback, MULTI_COUNT))
            fail(case_id, $sformatf(
                "%s base expected %08x got %08x",
                label,
                final_base(MULTI_BASE, up, writeback, MULTI_COUNT),
                u_dut.u_core.u_regfile.regs[12]));

        beat = 0;
        for (int reg_index = 0; reg_index < 15; reg_index++) begin
            if (MULTI_LIST[reg_index]) begin
                logic [31:0] expected_value;
                expected_value = load
                               ? (32'hB600_0000 | 32'(reg_index))
                               : (32'h0000_0040 | 32'(reg_index));
                if (load) begin
                    if (u_dut.u_core.u_regfile.regs[
                            physical_svc_index(reg_index)]
                        !== expected_value)
                        fail(case_id, $sformatf(
                            "%s r%0d expected %08x got %08x",
                            label, reg_index, expected_value,
                            u_dut.u_core.u_regfile.regs[
                                physical_svc_index(reg_index)]));
                end else if (u_mem.mem[(expected_start >> 2) + beat]
                             !== expected_value) begin
                    fail(case_id, $sformatf(
                        "%s beat %0d/r%0d expected %08x got %08x",
                        label, beat, reg_index, expected_value,
                        u_mem.mem[(expected_start >> 2) + beat]));
                end
                beat++;
            end
        end
        if (u_dut.u_core.pc_q !== 32'h0000_0048)
            fail(case_id, {label, " did not reach completion loop"});
        if (u_dut.u_core.cpsr.m !== 5'(MODE_SUPERVISOR))
            fail(case_id, {label, " changed processor mode"});
    endtask

    initial begin
        int case_id;
        case_id = 0;

        for (int pre = 0; pre < 2; pre++) begin
            for (int up = 0; up < 2; up++) begin
                for (int wb = 0; wb < 2; wb++) begin
                    for (int load = 0; load < 2; load++) begin
                        for (int reg_index = 0;
                             reg_index < 16; reg_index++) begin
                            case_id++;
                            run_one_hot(
                                case_id, 1'(pre), 1'(up), 1'(wb),
                                1'(load), reg_index);
                        end
                    end
                end
            end
        end

        for (int pre = 0; pre < 2; pre++) begin
            for (int up = 0; up < 2; up++) begin
                for (int wb = 0; wb < 2; wb++) begin
                    for (int load = 0; load < 2; load++) begin
                        case_id++;
                        run_multi(
                            case_id, 1'(pre), 1'(up), 1'(wb), 1'(load));
                    end
                end
            end
        end

        $display("[block_ls_matrix] PASS (%0d one-hot + %0d multi rows)",
                 ONE_HOT_CASES, MULTI_CASES);
        $finish;
    end

    initial begin
        #3000000;
        $fatal(1, "[block_ls_matrix] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, WDATA, RDATA, DMORE,
        CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI,
        DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG,
        DBGCOMMTX, DBGCOMMRX, DBGTDO, DBGnTDOEN};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
