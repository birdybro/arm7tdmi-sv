// ISA-009 / ISA-012 alignment-and-endian matrix.
//
// Defined ARMv4T behavior:
//   * LDR and the read half of SWP rotate the aligned word right by
//     8 * address[1:0].
//   * STR and the write half of SWP ignore address[1:0].
//   * byte accesses use every address bit and the configured endian lane.
//   * Defined BX targets select word/halfword-aligned instruction fetches.
//
// A BX target ending in binary 10 is itself UNPREDICTABLE in ARMv4T. The
// fetch rows freeze this implementation's clear-low-two-bits policy for that
// suffix while retaining architectural checks for the other three suffixes.
//
// ISA-016 implementation policy for architecturally UNPREDICTABLE odd
// halfword accesses:
//   Match the ARM7TDMI-S r4p3 pin-level behavior.  The core presents the
//   calculated byte address, the memory ignores ADDR[0] for SIZE=halfword,
//   and the r4p3 endian lane table uses ADDR[1] only.  Do not interpret
//   these deterministic odd-address checks as an architectural guarantee.

`timescale 1ns/1ps

module arm7tdmis_unaligned_access_matrix_tb
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_types_pkg::*;
;

    localparam int DATA_CLASS_COUNT = 8;
    localparam int DATA_CASE_COUNT  = 2 * 4 * DATA_CLASS_COUNT;
    localparam int FETCH_CASE_COUNT = 2 * 4;

    localparam int ACCESS_LDR   = 0;
    localparam int ACCESS_STR   = 1;
    localparam int ACCESS_LDRH  = 2;
    localparam int ACCESS_STRH  = 3;
    localparam int ACCESS_LDRSH = 4;
    localparam int ACCESS_LDRSB = 5;
    localparam int ACCESS_SWP   = 6;
    localparam int ACCESS_SWPB  = 7;

    localparam logic [31:0] BASE_ADDR   = 32'h0000_0100;
    localparam logic [31:0] DATA_WORD   = 32'h80F1_7E25;
    localparam logic [31:0] STORE_WORD  = 32'hA1B2_C3D4;
    localparam logic [15:0] THUMB_SPIN  = 16'hE7FE;

    logic CLK;
    initial begin
        CLK = 1'b0;
        forever #5 CLK = ~CLK;
    end

    logic nRESET = 1'b0;
    logic cfg_bigend = 1'b0;
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
        .CFGBIGEND(cfg_bigend), .nIRQ(1'b1), .nFIQ(1'b1), .ABORT(ABORT),
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
        .WORDS(128)
    ) u_mem (
        .CLK(CLK), .CLKEN(1'b1), .nRESET(nRESET),
        .CFGBIGEND(cfg_bigend),
        .ADDR(ADDR), .WRITE(WRITE), .SIZE(SIZE), .PROT(PROT),
        .LOCK(LOCK), .TRANS(TRANS), .WDATA(WDATA), .RDATA(RDATA),
        .ABORT(ABORT), .inject_abort(1'b0)
    );

    function automatic string access_name(input int access_class);
        case (access_class)
            ACCESS_LDR:   return "LDR";
            ACCESS_STR:   return "STR";
            ACCESS_LDRH:  return "LDRH";
            ACCESS_STRH:  return "STRH";
            ACCESS_LDRSH: return "LDRSH";
            ACCESS_LDRSB: return "LDRSB";
            ACCESS_SWP:   return "SWP";
            ACCESS_SWPB:  return "SWPB";
            default:      return "unknown";
        endcase
    endfunction

    function automatic logic [31:0] rotate_word(
        input logic [31:0] word,
        input logic [1:0]  low
    );
        case (low)
            2'd0: return word;
            2'd1: return {word[7:0], word[31:8]};
            2'd2: return {word[15:0], word[31:16]};
            2'd3: return {word[23:0], word[31:24]};
        endcase
    endfunction

    function automatic logic [15:0] addressed_halfword(
        input logic       big_endian,
        input logic       address_bit1
    );
        logic high_lane;
        high_lane = big_endian ? ~address_bit1 : address_bit1;
        return high_lane ? DATA_WORD[31:16] : DATA_WORD[15:0];
    endfunction

    function automatic logic [7:0] addressed_byte(
        input logic       big_endian,
        input logic [1:0] low
    );
        logic [1:0] lane;
        lane = big_endian ? ~low : low;
        case (lane)
            2'd0: return DATA_WORD[7:0];
            2'd1: return DATA_WORD[15:8];
            2'd2: return DATA_WORD[23:16];
            2'd3: return DATA_WORD[31:24];
        endcase
    endfunction

    function automatic logic [31:0] halfword_store_result(
        input logic       big_endian,
        input logic       address_bit1
    );
        logic high_lane;
        high_lane = big_endian ? ~address_bit1 : address_bit1;
        return high_lane ? {STORE_WORD[15:0], DATA_WORD[15:0]}
                         : {DATA_WORD[31:16], STORE_WORD[15:0]};
    endfunction

    function automatic logic [31:0] byte_store_result(
        input logic       big_endian,
        input logic [1:0] low
    );
        logic [31:0] result;
        logic [1:0] lane;
        result = DATA_WORD;
        lane = big_endian ? ~low : low;
        case (lane)
            2'd0: result[7:0]   = STORE_WORD[7:0];
            2'd1: result[15:8]  = STORE_WORD[7:0];
            2'd2: result[23:16] = STORE_WORD[7:0];
            2'd3: result[31:24] = STORE_WORD[7:0];
        endcase
        return result;
    endfunction

    task automatic fail(input int case_id, input string label);
        $fatal(1, "[unaligned_access_matrix] FAIL case %0d: %s",
               case_id, label);
    endtask

    task automatic clear_memory;
        for (int word = 0; word < 128; word++)
            u_mem.mem[word] = 32'hEAFF_FFFE;
    endtask

    task automatic hold_reset;
        @(negedge CLK);
        nRESET = 1'b0;
        repeat (4) @(posedge CLK);
    endtask

    task automatic release_reset;
        @(negedge CLK);
        nRESET = 1'b1;
    endtask

    task automatic setup_data_case(
        input int         case_id,
        input logic       big_endian,
        input logic [1:0] low,
        input int         access_class
    );
        logic [31:0] opcode;

        cfg_bigend = big_endian;
        clear_memory();

        u_mem.mem[0]  = 32'hEA00_0006; // B 0x20
        u_mem.mem[8]  = 32'hE3A0_0C01; // MOV r0,#0x100
        u_mem.mem[9]  = 32'hE280_0000 | 32'(low); // ADD r0,r0,#low
        u_mem.mem[10] = 32'hE59F_1030; // LDR r1,[pc,#0x30] -> 0x60
        u_mem.mem[11] = 32'hE59F_2030; // LDR r2,[pc,#0x30] -> 0x64

        case (access_class)
            ACCESS_LDR:   opcode = 32'hE590_1000;
            ACCESS_STR:   opcode = 32'hE580_1000;
            ACCESS_LDRH:  opcode = 32'hE1D0_10B0;
            ACCESS_STRH:  opcode = 32'hE1C0_10B0;
            ACCESS_LDRSH: opcode = 32'hE1D0_10F0;
            ACCESS_LDRSB: opcode = 32'hE1D0_10D0;
            ACCESS_SWP:   opcode = 32'hE100_1092;
            ACCESS_SWPB:  opcode = 32'hE140_1092;
            default:      opcode = 32'hE7F0_00F0;
        endcase

        u_mem.mem[12] = opcode;
        u_mem.mem[13] = 32'hE3A0_7000 | 32'(case_id); // completion
        u_mem.mem[14] = 32'hEAFF_FFFE;                 // B .
        u_mem.mem[24] = STORE_WORD;
        u_mem.mem[25] = STORE_WORD;
        u_mem.mem[64] = DATA_WORD;
    endtask

    task automatic run_data_case(
        input int         case_id,
        input logic       big_endian,
        input logic [1:0] low,
        input int         access_class
    );
        string label;
        logic is_load;
        logic is_store;
        logic is_swap;
        logic [1:0] expected_size;
        logic [31:0] expected_register;
        logic [31:0] expected_memory;
        logic [15:0] halfword;
        logic [7:0] byte_value;
        int unsigned read_cycles;
        int unsigned write_cycles;
        int unsigned locked_cycles;

        hold_reset();
        setup_data_case(case_id, big_endian, low, access_class);
        release_reset();

        label = $sformatf("%s %s address +%0d",
                          big_endian ? "BE" : "LE",
                          access_name(access_class), low);
        is_swap  = access_class inside {ACCESS_SWP, ACCESS_SWPB};
        is_load  = access_class inside {
            ACCESS_LDR, ACCESS_LDRH, ACCESS_LDRSH, ACCESS_LDRSB,
            ACCESS_SWP, ACCESS_SWPB
        };
        is_store = access_class inside {
            ACCESS_STR, ACCESS_STRH, ACCESS_SWP, ACCESS_SWPB
        };
        expected_size = (access_class inside {ACCESS_LDRH, ACCESS_STRH,
                                               ACCESS_LDRSH})
                      ? 2'(SIZE_HALFWORD)
                      : (access_class inside {ACCESS_LDRSB, ACCESS_SWPB})
                      ? 2'(SIZE_BYTE) : 2'(SIZE_WORD);

        read_cycles   = 0;
        write_cycles  = 0;
        locked_cycles = 0;
        repeat (90) begin
            @(negedge CLK);
            if ((TRANS inside {TRANS_N, TRANS_S})
                && PROT[PROT_BIT_DATA]
                && (ADDR[31:2] == BASE_ADDR[31:2])) begin
                if (ADDR !== (BASE_ADDR + 32'(low)))
                    fail(case_id, $sformatf(
                        "%s bus address expected %08x got %08x",
                        label, BASE_ADDR + 32'(low), ADDR));
                if (SIZE !== expected_size)
                    fail(case_id, $sformatf(
                        "%s SIZE expected %02b got %02b",
                        label, expected_size, SIZE));
                if (WRITE)
                    write_cycles++;
                else
                    read_cycles++;
                if (LOCK)
                    locked_cycles++;
            end
        end

        if (read_cycles != (is_load ? 1 : 0))
            fail(case_id, $sformatf(
                "%s read-cycle count expected %0d got %0d",
                label, is_load ? 1 : 0, read_cycles));
        if (write_cycles != (is_store ? 1 : 0))
            fail(case_id, $sformatf(
                "%s write-cycle count expected %0d got %0d",
                label, is_store ? 1 : 0, write_cycles));
        if (locked_cycles != (is_swap ? 2 : 0))
            fail(case_id, $sformatf(
                "%s locked-cycle count expected %0d got %0d",
                label, is_swap ? 2 : 0, locked_cycles));

        halfword = addressed_halfword(big_endian, low[1]);
        byte_value = addressed_byte(big_endian, low);
        case (access_class)
            ACCESS_LDR:
                expected_register = rotate_word(DATA_WORD, low);
            ACCESS_LDRH:
                expected_register = {16'h0, halfword};
            ACCESS_LDRSH:
                expected_register = {{16{halfword[15]}}, halfword};
            ACCESS_LDRSB:
                expected_register = {{24{byte_value[7]}}, byte_value};
            ACCESS_SWP:
                expected_register = rotate_word(DATA_WORD, low);
            ACCESS_SWPB:
                expected_register = {24'h0, byte_value};
            default:
                expected_register = STORE_WORD;
        endcase

        case (access_class)
            ACCESS_STR, ACCESS_SWP:
                expected_memory = STORE_WORD;
            ACCESS_STRH:
                expected_memory = halfword_store_result(big_endian, low[1]);
            ACCESS_SWPB:
                expected_memory = byte_store_result(big_endian, low);
            default:
                expected_memory = DATA_WORD;
        endcase

        if (u_dut.u_core.u_regfile.regs[1] !== expected_register)
            fail(case_id, $sformatf(
                "%s r1 expected %08x got %08x",
                label, expected_register,
                u_dut.u_core.u_regfile.regs[1]));
        if (u_mem.mem[64] !== expected_memory)
            fail(case_id, $sformatf(
                "%s memory expected %08x got %08x",
                label, expected_memory, u_mem.mem[64]));
        if (u_dut.u_core.u_regfile.regs[7] !== 32'(case_id))
            fail(case_id, $sformatf("%s completion marker missing", label));
    endtask

    task automatic write_thumb(
        input logic [8:1]  address,
        input logic [15:0] instruction,
        input logic        big_endian
    );
        logic [6:0] word_index;
        word_index = address[8:2];
        if (address[1] ^ big_endian)
            u_mem.mem[word_index][31:16] = instruction;
        else
            u_mem.mem[word_index][15:0] = instruction;
    endtask

    task automatic setup_fetch_case(
        input int         case_id,
        input logic       big_endian,
        input logic [1:0] low
    );
        logic [31:0] target;
        logic [8:1] effective_target;
        logic [31:0] marker_opcode;

        cfg_bigend = big_endian;
        clear_memory();

        target = BASE_ADDR + 32'(low);
        effective_target = low[0] ? target[8:1]
                                  : {target[8:2], 1'b0};

        u_mem.mem[0]  = 32'hEA00_0006; // B 0x20
        u_mem.mem[8]  = 32'hE59F_0038; // LDR r0,[pc,#0x38] -> 0x60
        u_mem.mem[9]  = 32'hE12F_FF10; // BX r0
        u_mem.mem[10] = 32'hEAFF_FFFE;
        u_mem.mem[24] = target;

        if (!low[0]) begin
            marker_opcode = 32'hE3A0_6000 | 32'(case_id);
            u_mem.mem[effective_target[8:2]] = marker_opcode;
            u_mem.mem[effective_target[8:2] + 1] = 32'hEAFF_FFFE;
        end else begin
            u_mem.mem[effective_target[8:2]] = {THUMB_SPIN, THUMB_SPIN};
            u_mem.mem[effective_target[8:2] + 1] = {THUMB_SPIN, THUMB_SPIN};
            write_thumb(effective_target, 16'h2600 | 16'(case_id),
                        big_endian);
        end
    endtask

    task automatic run_fetch_case(
        input int         case_id,
        input logic       big_endian,
        input logic [1:0] low
    );
        string label;
        logic [31:0] target;
        logic [31:0] effective_target;
        logic [1:0] expected_size;
        bit target_seen;

        hold_reset();
        setup_fetch_case(case_id, big_endian, low);
        release_reset();

        label = $sformatf("%s BX target low bits %02b",
                          big_endian ? "BE" : "LE", low);
        target = BASE_ADDR + 32'(low);
        effective_target = low[0] ? (target & 32'hFFFF_FFFE)
                                  : (target & 32'hFFFF_FFFC);
        expected_size = low[0] ? 2'(SIZE_HALFWORD) : 2'(SIZE_WORD);
        target_seen = 1'b0;

        repeat (90) begin
            @(negedge CLK);
            if ((TRANS inside {TRANS_N, TRANS_S})
                && !PROT[PROT_BIT_DATA]) begin
                if (((SIZE == 2'(SIZE_WORD)) && (ADDR[1:0] != 2'b00))
                    || ((SIZE == 2'(SIZE_HALFWORD)) && ADDR[0]))
                    fail(case_id, $sformatf(
                        "%s emitted misaligned fetch address %08x SIZE=%02b",
                        label, ADDR, SIZE));
                if (ADDR == effective_target) begin
                    target_seen = 1'b1;
                    if (SIZE !== expected_size)
                        fail(case_id, $sformatf(
                            "%s target SIZE expected %02b got %02b",
                            label, expected_size, SIZE));
                end
            end
        end

        if (!target_seen)
            fail(case_id, $sformatf(
                "%s effective target %08x was never fetched",
                label, effective_target));
        if (u_dut.u_core.u_regfile.regs[0] !== target)
            fail(case_id, $sformatf(
                "%s source target expected %08x got %08x",
                label, target, u_dut.u_core.u_regfile.regs[0]));
        if (u_dut.u_core.cpsr.t !== low[0])
            fail(case_id, $sformatf(
                "%s CPSR.T expected %0b got %0b",
                label, low[0], u_dut.u_core.cpsr.t));
        if (u_dut.u_core.u_regfile.regs[6] !== 32'(case_id))
            fail(case_id, $sformatf("%s completion marker missing", label));
    endtask

    initial begin
        int case_id;

        case_id = 0;
        for (int endian = 0; endian < 2; endian++) begin
            for (int low = 0; low < 4; low++) begin
                for (int access_class = 0;
                     access_class < DATA_CLASS_COUNT;
                     access_class++) begin
                    case_id++;
                    run_data_case(case_id, 1'(endian), 2'(low),
                                  access_class);
                end
            end
        end

        for (int endian = 0; endian < 2; endian++) begin
            for (int low = 0; low < 4; low++) begin
                case_id++;
                run_fetch_case(case_id, 1'(endian), 2'(low));
            end
        end

        $display("[unaligned_access_matrix] PASS (%0d data/SWP + %0d fetch reset-per-case rows)",
                 DATA_CASE_COUNT, FETCH_CASE_COUNT);
        $finish;
    end

    initial begin
        #900000;
        $fatal(1, "[unaligned_access_matrix] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, WDATA, RDATA,
        CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI,
        DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG,
        DBGCOMMTX, DBGCOMMRX, DBGTDO, DBGnTDOEN, DMORE};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
