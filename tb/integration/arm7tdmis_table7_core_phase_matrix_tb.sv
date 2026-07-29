// BUS-002/BUS-003/BUS-005: raw Execute phases from TRM Tables 7-3--7-23.
//
// Section 7.1 is easy to misread: Data is the response in the numbered
// instruction cycle, while TRANS predicts the following bus cycle and the
// address-class outputs are already one bus cycle ahead.  Consequently the
// raw pins during an instruction's first Execute cycle contain the next
// row's address-class values and the current row's TRANS.  Examples:
//   * ordinary DP: pc+3i/S opcode
//   * shift(Rs):   pc+3i/I data (first half of a merged I-S)
//   * LDR/STR:     data-address/N data
//   * branch:      target/N opcode
// This reset-isolated matrix checks every raw phase of the base ARM
// instruction families without conflating them with the response that is
// simultaneously on RDATA. Every row runs in both endian configurations,
// first continuously and then with deterministic pseudorandom CLKEN holds
// inserted at every Execute phase.

`timescale 1ns/1ps

module arm7tdmis_table7_core_phase_matrix_tb
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_instr_pkg::*;
    import arm7tdmis_types_pkg::*;
;

    localparam int ROW_COUNT = 17;
    localparam int ENDIAN_COUNT = 2;
    localparam int STALL_PROFILE_COUNT = 2;
    localparam logic [31:0] TEST_PC = 32'h0000_0040;

    logic CLK;
    initial begin
        CLK = 1'b0;
        forever #5 CLK = ~CLK;
    end

    logic nRESET = 1'b0;
    logic CLKEN  = 1'b1;
    logic CFGBIGEND = 1'b0;
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
    int unsigned errors = 0;

    arm7tdmis_top u_dut (
        .CLK, .CLKEN, .nRESET, .CFGBIGEND(CFGBIGEND),
        .nIRQ(1'b1), .nFIQ(1'b1), .ABORT,
        .ADDR, .WRITE, .SIZE, .PROT, .LOCK, .TRANS, .WDATA, .RDATA,
        .CPnMREQ, .CPSEQ, .CPnTRANS, .CPnOPC, .CPTBIT, .CPnI,
        .CPA(1'b1), .CPB(1'b1),
        .DBGEN(1'b0), .DBGRQ(1'b0), .DBGBREAK(1'b0),
        .DBGACK, .DBGnEXEC, .DBGINSTRVALID, .DBGEXT(2'b00), .DBGRNG,
        .DBGCOMMTX, .DBGCOMMRX, .DBGTCKEN(1'b0), .DBGTMS(1'b0),
        .DBGTDI(1'b0), .DBGTDO, .DBGnTRST(1'b1), .DBGnTDOEN, .DMORE
    );

    arm7tdmis_memory #(
        .WORDS(256)
    ) u_mem (
        .CLK, .CLKEN, .nRESET, .CFGBIGEND(CFGBIGEND),
        .ADDR, .WRITE, .SIZE, .PROT, .LOCK, .TRANS, .WDATA, .RDATA,
        .ABORT, .inject_abort(1'b0)
    );

    function automatic logic [31:0] row_opcode(input int row);
        unique case (row)
            0:  return 32'hE1A0_3001; // MOV r3,r1
            1:  return 32'hE1A0_3211; // MOV r3,r1,LSL r2
            2:  return 32'hE003_0291; // MUL r3,r1,r2
            3:  return 32'hE023_4291; // MLA r3,r1,r2,r4
            4:  return 32'hE084_3291; // UMULL r3,r4,r1,r2
            5:  return 32'hE590_3000; // LDR r3,[r0]
            6:  return 32'hE580_3000; // STR r3,[r0]
            7:  return 32'hE1D0_30B0; // LDRH r3,[r0]
            8:  return 32'hE1C0_30B0; // STRH r3,[r0]
            9:  return 32'hE8B0_0006; // LDMIA r0!,{r1,r2}
            10: return 32'hE8A0_0006; // STMIA r0!,{r1,r2}
            11: return 32'hE100_3091; // SWP r3,r1,[r0]
            12: return 32'hEA00_0002; // B 0x50
            13: return 32'hEF00_0000; // SWI 0
            14: return 32'hE7F0_00F0; // reserved Undefined
            15: return 32'h0590_3000; // LDREQ r3,[r0], Z=0
            16: return 32'hE10F_3000; // MRS r3,CPSR
            default: return 32'hExxx_xxxx;
        endcase
    endfunction

    function automatic int expected_phase_count(input int row);
        unique case (row)
            0, 15, 16: return 1;
            1, 2, 6, 8: return 2;
            3, 4, 5, 7, 10, 12, 13: return 3;
            9, 11, 14: return 4;
            default: return 0;
        endcase
    endfunction

    function automatic logic [31:0] expected_addr(
        input int row,
        input int phase
    );
        unique case (row)
            3: return phase == 0 ? TEST_PC + 32'd8
                                : TEST_PC + 32'd12;
            5, 7: return phase == 0 ? 32'h0000_0100
                                    : TEST_PC + 32'd12;
            6, 8: return phase == 0 ? 32'h0000_0100
                                    : TEST_PC + 32'd12;
            9, 10: begin
                if (phase == 0) return 32'h0000_0100;
                if (phase == 1) return 32'h0000_0104;
                return TEST_PC + 32'd12;
            end
            11: return phase < 2 ? 32'h0000_0100
                                : TEST_PC + 32'd12;
            12: return 32'h0000_0050 + 32'(phase * 4);
            13: return 32'h0000_0008 + 32'(phase * 4);
            14: return phase == 0 ? TEST_PC + 32'd8
                                  : 32'h0000_0004 + 32'((phase - 1) * 4);
            default: return TEST_PC + 32'd12;
        endcase
    endfunction

    function automatic logic [1:0] expected_trans(
        input int row,
        input int phase
    );
        unique case (row)
            0, 15, 16: return 2'(TRANS_S);
            1, 2: return phase == 0 ? 2'(TRANS_I) : 2'(TRANS_S);
            3, 4: return phase < expected_phase_count(row) - 1
                              ? 2'(TRANS_I) : 2'(TRANS_S);
            5, 7: begin
                if (phase == 0) return 2'(TRANS_N);
                return phase == 1 ? 2'(TRANS_I) : 2'(TRANS_S);
            end
            6, 8: return 2'(TRANS_N);
            9: begin
                if (phase == 0) return 2'(TRANS_N);
                if (phase == 1) return 2'(TRANS_S);
                return phase == 2 ? 2'(TRANS_I) : 2'(TRANS_S);
            end
            10: return phase == 0 ? 2'(TRANS_N)
                                  : phase == 1 ? 2'(TRANS_S)
                                               : 2'(TRANS_N);
            11: begin
                if (phase < 2) return 2'(TRANS_N);
                return phase == 2 ? 2'(TRANS_I) : 2'(TRANS_S);
            end
            12, 13: return phase == 0 ? 2'(TRANS_N) : 2'(TRANS_S);
            14: begin
                if (phase == 0) return 2'(TRANS_I);
                return phase == 1 ? 2'(TRANS_N) : 2'(TRANS_S);
            end
            default: return 2'(TRANS_I);
        endcase
    endfunction

    function automatic logic [1:0] expected_prot(
        input int row,
        input int phase
    );
        unique case (row)
            0, 12, 13, 14, 15, 16: return 2'(PROT_OPC_PRIV);
            6, 8, 10: return phase == expected_phase_count(row) - 1
                                  ? 2'(PROT_OPC_PRIV)
                                  : 2'(PROT_DAT_PRIV);
            default: return 2'(PROT_DAT_PRIV);
        endcase
    endfunction

    function automatic logic [1:0] expected_size(
        input int row,
        input int phase
    );
        return (row inside {7, 8}) && phase == 0
             ? 2'(SIZE_HALFWORD) : 2'(SIZE_WORD);
    endfunction

    function automatic logic expected_lock(input int row, input int phase);
        return row == 11 && phase < 2 ? LOCK_LOCKED : LOCK_FREE;
    endfunction

    function automatic logic expected_write(input int row, input int phase);
        unique case (row)
            6, 8: return phase == 0 ? WRITE_WRITE : WRITE_READ;
            10: return phase < 2 ? WRITE_WRITE : WRITE_READ;
            11: return phase == 1 ? WRITE_WRITE : WRITE_READ;
            default: return WRITE_READ;
        endcase
    endfunction

    function automatic logic [31:0] expected_wdata(
        input int row,
        input int phase
    );
        unique case (row)
            6: return phase == 1 ? 32'h0000_0005 : 32'h0000_0000;
            // Byte/halfword stores replicate their value across lanes;
            // address plus SIZE selects the lane sampled by the target.
            8: return phase == 1 ? 32'h0005_0005 : 32'h0000_0000;
            10: begin
                if (phase == 1) return 32'h0000_0003;
                if (phase == 2) return 32'h0000_0004;
                return 32'h0000_0000;
            end
            11: return phase == 2 ? 32'h0000_0003 : 32'h0000_0000;
            default: return 32'h0000_0000;
        endcase
    endfunction

    function automatic logic expected_dmore(input int row, input int phase);
        return (row inside {9, 10}) && phase == 0;
    endfunction

    function automatic logic [4:0] expected_state(
        input int row,
        input int phase
    );
        if (phase == 0)
            return 5'd0;  // S_EXEC
        unique case (row)
            1:  return 5'd9;   // S_DP_SHIFT
            2, 3: return 5'd6; // S_MUL_BUSY
            4:  return phase == 1 ? 5'd6 : 5'd5; // BUSY, MULL_HI
            5, 7: return phase == 1 ? 5'd1 : 5'd10; // DDATA, LOAD_WB
            6, 8: return 5'd1; // S_DDATA
            9:  return phase < 3 ? 5'd2 : 5'd8; // BLOCK_DATA, BLOCK_WB
            10: return 5'd2;   // S_BLOCK_DATA
            11: begin
                if (phase == 1) return 5'd3;  // S_SWP_RDATA
                if (phase == 2) return 5'd4;  // S_SWP_WDATA
                return 5'd11;                 // S_SWP_WB
            end
            14: return phase == 1 ? 5'd16 : 5'd0; // UNDEF_WAIT, refill
            default: return 5'd0;
        endcase
    endfunction

    function automatic logic [31:0] expected_cpsr(
        input int row,
        input int phase
    );
        // Reset/setup leave NZCV clear with I/F set in Supervisor mode.
        // Undefined switches only the mode field after its recognition I
        // cycle; SWI is already executing in Supervisor mode.
        return (row == 14 && phase >= 2) ? 32'h0000_00DB
                                         : 32'h0000_00D3;
    endfunction

    function automatic logic [31:0] expected_rdata();
        logic       halfword_high;
        logic [1:0] byte_lane;
        logic [31:0] word;

        if (!u_mem.is_active_q || u_mem.write_q)
            return 32'h0000_0000;

        word = u_mem.mem[u_mem.index_q];
        unique case (u_mem.size_q)
            2'(SIZE_WORD): return word;
            2'(SIZE_HALFWORD): begin
                halfword_high = CFGBIGEND ? ~u_mem.addr_q[1]
                                          : u_mem.addr_q[1];
                return halfword_high ? {word[31:16], 16'h0000}
                                     : {16'h0000, word[15:0]};
            end
            2'(SIZE_BYTE): begin
                byte_lane = CFGBIGEND ? ~u_mem.addr_q[1:0]
                                      : u_mem.addr_q[1:0];
                unique case (byte_lane)
                    2'd0: return {24'h0, word[7:0]};
                    2'd1: return {16'h0, word[15:8], 8'h0};
                    2'd2: return {8'h0, word[23:16], 16'h0};
                    default: return {word[31:24], 24'h0};
                endcase
            end
            default: return 32'h0000_0000;
        endcase
    endfunction

    function automatic instr_class_e expected_class(input int row);
        unique case (row)
            0, 1: return INSTR_DP;
            2, 3: return INSTR_MUL;
            4: return INSTR_MULL;
            5, 6, 15: return INSTR_LDR_STR;
            7, 8: return INSTR_LDRH_STRH;
            9, 10: return INSTR_LDM_STM;
            11: return INSTR_SWP;
            12: return INSTR_BRANCH;
            13: return INSTR_SWI;
            14: return INSTR_UNDEF;
            16: return INSTR_MRS;
            default: return INSTR_UNDEF;
        endcase
    endfunction

    function automatic string row_name(input int row);
        unique case (row)
            0:  return "DP";
            1:  return "DP shift(Rs)";
            2:  return "MUL";
            3:  return "MLA";
            4:  return "UMULL";
            5:  return "LDR";
            6:  return "STR";
            7:  return "LDRH";
            8:  return "STRH";
            9:  return "LDM";
            10: return "STM";
            11: return "SWP";
            12: return "B";
            13: return "SWI";
            14: return "Undefined";
            15: return "failed LDR";
            16: return "MRS";
            default: return "invalid";
        endcase
    endfunction

    function automatic int stall_cycles(
        input int row,
        input int phase,
        input int endian
    );
        // Deterministic 1..4-cycle distribution, stable across simulators.
        return 1 + ((row ^ (phase << 1) ^ (endian << 2)) & 3);
    endfunction

    task automatic fail(input int row, input string reason);
        $display("[table7_core_phase_matrix] FAIL row %0d %s: %s",
                 row, row_name(row), reason);
        errors++;
    endtask

    task automatic setup_row(input int row);
        for (int word = 0; word < 256; word++)
            u_mem.mem[word] = 32'hEAFF_FFFE;

        u_mem.mem[0] = 32'hEA00_0006; // reset: B 0x20
        u_mem.mem[8] = 32'hE3A0_0C01; // r0 = 0x100
        u_mem.mem[9] = 32'hE3A0_1003; // r1 = 3
        u_mem.mem[10] = 32'hE3A0_2004; // r2 = 4
        u_mem.mem[11] = 32'hE3A0_3005; // r3 = 5
        u_mem.mem[12] = 32'hE3A0_4006; // r4 = 6
        u_mem.mem[13] = 32'hE1A0_0000;
        u_mem.mem[14] = 32'hE1A0_0000;
        u_mem.mem[15] = 32'hE1A0_0000;
        u_mem.mem[16] = row_opcode(row);
        u_mem.mem[17] = 32'hE1A0_0000;
        u_mem.mem[18] = 32'hEAFF_FFFE;
        u_mem.mem[DATA_ADDRESS_WORD] = 32'h1122_3344;
    endtask

    localparam int DATA_ADDRESS_WORD = 32'h0000_0100 >> 2;

    task automatic check_stalled_phase(
        input int row,
        input int phase,
        input int endian
    );
        logic [114:0] original_outputs;
        logic [114:0] held_outputs;
        logic [4:0]  frozen_state;
        logic [31:0] frozen_cpsr;
        logic        frozen_de_valid;
        logic [31:0] frozen_de_pc;
        logic [31:0] frozen_de_instr;
        logic [31:0] frozen_pc;
        int          cycles;

        original_outputs = {
            ADDR, WDATA, RDATA, WRITE, SIZE, PROT, LOCK, TRANS,
            ABORT, DMORE, CPnMREQ, CPSEQ, CPnTRANS, CPnOPC,
            CPTBIT, CPnI, DBGACK, DBGnEXEC, DBGINSTRVALID
        };
        frozen_state = u_dut.u_core.state_q;
        frozen_cpsr = u_dut.u_core.cpsr;
        frozen_de_valid = u_dut.u_core.de_q.valid;
        frozen_de_pc = u_dut.u_core.de_q.pc;
        frozen_de_instr = u_dut.u_core.de_q.instr;
        frozen_pc = u_dut.u_core.pc_q;

        CLKEN = 1'b0;
        cycles = stall_cycles(row, phase, endian);
        // Appendix B allows outputs to settle once when CLKEN is first
        // sampled LOW. Architectural state must already be frozen, and the
        // settled outputs must then hold for every further stopped edge.
        @(posedge CLK);
        #1;
        held_outputs = {
            ADDR, WDATA, RDATA, WRITE, SIZE, PROT, LOCK, TRANS,
            ABORT, DMORE, CPnMREQ, CPSEQ, CPnTRANS, CPnOPC,
            CPTBIT, CPnI, DBGACK, DBGnEXEC, DBGINSTRVALID
        };
        if (u_dut.u_core.state_q !== frozen_state
            || u_dut.u_core.cpsr !== frozen_cpsr
            || u_dut.u_core.de_q.valid !== frozen_de_valid
            || u_dut.u_core.de_q.pc !== frozen_de_pc
            || u_dut.u_core.de_q.instr !== frozen_de_instr
            || u_dut.u_core.pc_q !== frozen_pc)
            fail(row, $sformatf(
                "endian %0d phase %0d advanced on first stopped edge",
                endian, phase + 1));

        repeat (cycles - 1) begin
            @(posedge CLK);
            #1;
            if ({
                    ADDR, WDATA, RDATA, WRITE, SIZE, PROT, LOCK, TRANS,
                    ABORT, DMORE, CPnMREQ, CPSEQ, CPnTRANS, CPnOPC,
                    CPTBIT, CPnI, DBGACK, DBGnEXEC, DBGINSTRVALID
                } !== held_outputs)
                fail(row, $sformatf(
                    "endian %0d phase %0d outputs changed during %0d-cycle stall",
                    endian, phase + 1, cycles));
            if (u_dut.u_core.state_q !== frozen_state
                || u_dut.u_core.cpsr !== frozen_cpsr
                || u_dut.u_core.de_q.valid !== frozen_de_valid
                || u_dut.u_core.de_q.pc !== frozen_de_pc
                || u_dut.u_core.de_q.instr !== frozen_de_instr
                || u_dut.u_core.pc_q !== frozen_pc)
                fail(row, $sformatf(
                    "endian %0d phase %0d internal state changed during %0d-cycle stall",
                    endian, phase + 1, cycles));
        end
        @(negedge CLK);
        CLKEN = 1'b1;
        #1;
        if ({
                ADDR, WDATA, RDATA, WRITE, SIZE, PROT, LOCK, TRANS,
                ABORT, DMORE, CPnMREQ, CPSEQ, CPnTRANS, CPnOPC,
                CPTBIT, CPnI, DBGACK, DBGnEXEC, DBGINSTRVALID
            } !== original_outputs)
            fail(row, $sformatf(
                "endian %0d phase %0d did not restore after stall",
                endian, phase + 1));
    endtask

    task automatic run_row(
        input int row,
        input int endian,
        input int stall_profile
    );
        int unsigned wait_cycles;

        @(negedge CLK);
        nRESET = 1'b0;
        CLKEN = 1'b1;
        CFGBIGEND = 1'(endian);
        repeat (4) @(posedge CLK);
        setup_row(row);
        @(negedge CLK);
        nRESET = 1'b1;

        wait_cycles = 0;
        while (!(u_dut.u_core.state_q == 5'd0
                 && u_dut.u_core.de_q.valid
                 && u_dut.u_core.de_q.pc == TEST_PC)) begin
            @(negedge CLK);
            wait_cycles++;
            if (wait_cycles > 100)
                fail(row, "instruction never reached Execute");
        end

        if (u_dut.u_core.de_q.instr !== row_opcode(row)
            || u_dut.u_core.de_q.dec.instr_class !== expected_class(row))
            fail(row, "opcode did not reach the expected decode class");
        if (row == 15 && u_dut.u_core.condition_pass)
            fail(row, "condition-failed control row unexpectedly passed");
        if (row != 15 && !u_dut.u_core.condition_pass)
            fail(row, "executed row unexpectedly failed its condition");

        for (int phase = 0; phase < expected_phase_count(row); phase++) begin
            if (ADDR !== expected_addr(row, phase)
                || WRITE !== expected_write(row, phase)
                || SIZE !== expected_size(row, phase)
                || PROT !== expected_prot(row, phase)
                || LOCK !== expected_lock(row, phase)
                || TRANS !== expected_trans(row, phase)
                || WDATA !== expected_wdata(row, phase)
                || DMORE !== expected_dmore(row, phase))
                fail(row, $sformatf(
                    "phase %0d A/W/S/P/L/T/WD/M=%08x/%0b/%02b/%02b/%0b/%02b/%08x/%0b expected %08x/%0b/%02b/%02b/%0b/%02b/%08x/%0b",
                    phase + 1, ADDR, WRITE, SIZE, PROT, LOCK, TRANS,
                    WDATA, DMORE,
                    expected_addr(row, phase),
                    expected_write(row, phase), expected_size(row, phase),
                    expected_prot(row, phase), expected_lock(row, phase),
                    expected_trans(row, phase), expected_wdata(row, phase),
                    expected_dmore(row, phase)));

            if (RDATA !== expected_rdata() || ABORT !== 1'b0)
                fail(row, $sformatf(
                    "phase %0d response RDATA/ABORT=%08x/%0b expected %08x/0",
                    phase + 1, RDATA, ABORT, expected_rdata()));

            if (!CLKEN
                || CPnMREQ !== !(TRANS inside {TRANS_N, TRANS_S})
                || CPSEQ !== TRANS[0]
                || CPnTRANS !== 1'b1
                || CPnOPC !== PROT[PROT_BIT_DATA]
                || CPTBIT !== 1'b0
                || CPnI !== 1'b1)
                fail(row, $sformatf(
                    "phase %0d CLKEN/CP MREQ/SEQ/TRANS/OPC/T/I=%0b/%0b/%0b/%0b/%0b/%0b/%0b",
                    phase + 1, CLKEN, CPnMREQ, CPSEQ, CPnTRANS,
                    CPnOPC, CPTBIT, CPnI));

            if (u_dut.u_core.state_q !== expected_state(row, phase)
                || u_dut.u_core.cpsr !== expected_cpsr(row, phase)
                || (phase == 0
                    && (!u_dut.u_core.de_q.valid
                        || u_dut.u_core.de_q.pc !== TEST_PC
                        || u_dut.u_core.de_q.instr !== row_opcode(row)))
                || (phase != 0 && u_dut.u_core.pc_q !== TEST_PC))
                fail(row, $sformatf(
                    "phase %0d state/CPSR/de-valid/de-PC/de-instr/last-PC=%0d/%08x/%0b/%08x/%08x/%08x expected %0d/%08x/%0b/%08x/%08x/%08x",
                    phase + 1, u_dut.u_core.state_q, u_dut.u_core.cpsr,
                    u_dut.u_core.de_q.valid, u_dut.u_core.de_q.pc,
                    u_dut.u_core.de_q.instr, u_dut.u_core.pc_q,
                    expected_state(row, phase), expected_cpsr(row, phase),
                    phase == 0, TEST_PC, row_opcode(row), TEST_PC));

            if (DBGINSTRVALID !== (phase == 0)
                || DBGnEXEC !== !((phase == 0) && (row != 15))
                || DBGACK !== 1'b0
                || u_dut.u_core.any_exc_fires
                   !== ((row == 13 && phase == 0)
                        || (row == 14 && phase == 1)))
                fail(row, $sformatf(
                    "phase %0d debug/exception IV/nEX/ACK/EXC=%0b/%0b/%0b/%0b",
                    phase + 1, DBGINSTRVALID, DBGnEXEC, DBGACK,
                    u_dut.u_core.any_exc_fires));

            if (stall_profile != 0)
                check_stalled_phase(row, phase, endian);
            if (phase + 1 < expected_phase_count(row))
                @(negedge CLK);
        end
    endtask

    initial begin
        for (int endian = 0; endian < ENDIAN_COUNT; endian++) begin
            for (int stall_profile = 0;
                 stall_profile < STALL_PROFILE_COUNT;
                 stall_profile++) begin
                for (int row = 0; row < ROW_COUNT; row++)
                    run_row(row, endian, stall_profile);
            end
        end
        if (errors != 0)
            $fatal(1, "[table7_core_phase_matrix] FAIL (%0d errors)",
                   errors);
        $display(
            "[table7_core_phase_matrix] PASS (%0d endian x %0d stall profiles x %0d rows = %0d reset-isolated cases)",
            ENDIAN_COUNT, STALL_PROFILE_COUNT, ROW_COUNT,
            ENDIAN_COUNT * STALL_PROFILE_COUNT * ROW_COUNT);
        $finish;
    end

    initial begin
        #150000;
        $fatal(1, "[table7_core_phase_matrix] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, DBGRNG, DBGCOMMTX, DBGCOMMRX, DBGTDO,
        DBGnTDOEN};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
