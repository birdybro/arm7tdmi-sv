// ISA-010 ARM Addressing Mode 3 matrix.
//
// Covers STRH, LDRH, LDRSB, and LDRSH across every P/U/W combination
// with both immediate and register offsets.  P=0,W=1 is architecturally
// UNPREDICTABLE for this mode (there is no translated extra-transfer
// form); those rows explicitly freeze the implementation policy as an
// ordinary privileged post-indexed transfer with deterministic writeback.

`timescale 1ns/1ps

module arm7tdmis_extra_ls_matrix_tb
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_types_pkg::*;
;

    localparam int CASE_COUNT = 64;
    localparam logic [1:0] ACCESS_STRH  = 2'd0;
    localparam logic [1:0] ACCESS_LDRH  = 2'd1;
    localparam logic [1:0] ACCESS_LDRSB = 2'd2;
    localparam logic [1:0] ACCESS_LDRSH = 2'd3;

    localparam logic [31:0] BASE_ADDR  = 32'h0000_0180;
    localparam logic [31:0] OFFSET     = 32'h0000_0020;
    localparam logic [31:0] LOAD_WORD  = 32'h7766_8084;
    localparam logic [31:0] STORE_WORD = 32'hA1B2_C3D5;

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
        .WORDS(128)
    ) u_mem (
        .CLK(CLK), .CLKEN(1'b1), .nRESET(nRESET),
        .CFGBIGEND(1'b0),
        .ADDR(ADDR), .WRITE(WRITE), .SIZE(SIZE), .PROT(PROT),
        .LOCK(LOCK), .TRANS(TRANS), .WDATA(WDATA), .RDATA(RDATA),
        .ABORT(ABORT), .inject_abort(1'b0)
    );

    task automatic fail(input int case_id, input string label);
        $fatal(1, "[extra_ls_matrix] FAIL case %0d: %s", case_id, label);
    endtask

    function automatic string access_name(input logic [1:0] access_type);
        case (access_type)
            ACCESS_STRH:  return "STRH";
            ACCESS_LDRH:  return "LDRH";
            ACCESS_LDRSB: return "LDRSB";
            ACCESS_LDRSH: return "LDRSH";
        endcase
    endfunction

    task automatic hold_reset;
        @(negedge CLK);
        nRESET = 1'b0;
        repeat (4) @(posedge CLK);
    endtask

    task automatic setup_case(
        input int          case_id,
        input logic [4:0]  combo,
        input logic        immediate_offset,
        output logic [31:0] expected_address,
        output logic [31:0] expected_base,
        output string       label
    );
        logic       pre_index;
        logic       up;
        logic       writeback;
        logic [1:0] access_type;
        logic       load;
        logic [1:0] sh_bits;
        logic [31:0] adjusted_address;
        logic [31:0] opcode;

        pre_index  = combo[4];
        up         = combo[3];
        writeback  = combo[2];
        access_type = combo[1:0];
        load       = access_type != ACCESS_STRH;
        case (access_type)
            ACCESS_STRH, ACCESS_LDRH: sh_bits = 2'b01;
            ACCESS_LDRSB:             sh_bits = 2'b10;
            ACCESS_LDRSH:             sh_bits = 2'b11;
        endcase

        for (int word = 0; word < 128; word++)
            u_mem.mem[word] = 32'hEAFF_FFFE;
        for (int word = 80; word <= 112; word++)
            u_mem.mem[word] = LOAD_WORD;

        u_mem.mem[0]  = 32'hEA00_0006; // B 0x20
        u_mem.mem[8]  = 32'hE59F_0038; // LDR r0,[pc,#0x38] -> 0x60
        u_mem.mem[9]  = 32'hE59F_1038; // LDR r1,[pc,#0x38] -> 0x64
        u_mem.mem[10] = 32'hE3A0_2020; // MOV r2,#0x20

        // cond 000 P U I W L Rn=r0 Rd=r1 offset 1 S H 1 offset.
        opcode       = 32'hE000_1090;
        opcode[24]   = pre_index;
        opcode[23]   = up;
        opcode[22]   = immediate_offset;
        opcode[21]   = writeback;
        opcode[20]   = load;
        opcode[6:5]  = sh_bits;
        if (immediate_offset) begin
            opcode[11:8] = OFFSET[7:4];
            opcode[3:0]  = OFFSET[3:0];
        end else begin
            opcode[11:8] = 4'h0;
            opcode[3:0]  = 4'd2;
        end

        u_mem.mem[11] = opcode;
        u_mem.mem[12] = 32'hE3A0_7000 | 32'(case_id);
        u_mem.mem[13] = 32'hEAFF_FFFE;
        u_mem.mem[24] = BASE_ADDR;
        u_mem.mem[25] = STORE_WORD;

        adjusted_address = up ? (BASE_ADDR + OFFSET)
                              : (BASE_ADDR - OFFSET);
        expected_address = pre_index ? adjusted_address : BASE_ADDR;
        expected_base = (pre_index && !writeback)
                      ? BASE_ADDR : adjusted_address;
        label = $sformatf("%s P=%0b U=%0b W=%0b %s offset%s",
                          access_name(access_type), pre_index, up,
                          writeback,
                          immediate_offset ? "immediate" : "register",
                          (!pre_index && writeback)
                            ? " (UNPREDICTABLE policy)" : "");
    endtask

    task automatic run_case(
        input int         case_id,
        input logic [4:0] combo,
        input logic       immediate_offset
    );
        string label;
        logic [1:0] access_type;
        logic load;
        logic [31:0] expected_address;
        logic [31:0] expected_base;
        logic [31:0] expected_register;
        logic [31:0] expected_memory;
        logic [1:0] expected_size;
        int unsigned data_cycles;

        hold_reset();
        setup_case(case_id, combo, immediate_offset, expected_address,
                   expected_base, label);
        @(negedge CLK);
        nRESET = 1'b1;

        access_type = combo[1:0];
        load = access_type != ACCESS_STRH;
        expected_size = (access_type == ACCESS_LDRSB)
                      ? 2'(SIZE_BYTE) : 2'(SIZE_HALFWORD);
        data_cycles = 0;

        repeat (90) begin
            @(negedge CLK);
            if ((TRANS inside {TRANS_N, TRANS_S})
                && PROT[PROT_BIT_DATA]
                && (ADDR >= 32'h0000_0100)) begin
                data_cycles++;
                if (ADDR !== expected_address)
                    fail(case_id, $sformatf(
                        "%s address expected %08x got %08x",
                        label, expected_address, ADDR));
                if (SIZE !== expected_size)
                    fail(case_id, $sformatf(
                        "%s SIZE expected %02b got %02b",
                        label, expected_size, SIZE));
                if (WRITE !== !load)
                    fail(case_id, $sformatf(
                        "%s WRITE expected %0b got %0b",
                        label, !load, WRITE));
                if (!PROT[PROT_BIT_PRIV])
                    fail(case_id, $sformatf(
                        "%s incorrectly requested User privilege", label));
                if (LOCK)
                    fail(case_id, $sformatf("%s asserted LOCK", label));
            end
        end

        if (data_cycles != 1)
            fail(case_id, $sformatf(
                "%s data-cycle count expected 1 got %0d",
                label, data_cycles));
        if (u_dut.u_core.u_regfile.regs[0] !== expected_base)
            fail(case_id, $sformatf(
                "%s base expected %08x got %08x",
                label, expected_base,
                u_dut.u_core.u_regfile.regs[0]));

        case (access_type)
            ACCESS_STRH:  expected_register = STORE_WORD;
            ACCESS_LDRH:  expected_register = 32'h0000_8084;
            ACCESS_LDRSB: expected_register = 32'hFFFF_FF84;
            ACCESS_LDRSH: expected_register = 32'hFFFF_8084;
        endcase
        expected_memory = (access_type == ACCESS_STRH)
                        ? {LOAD_WORD[31:16], STORE_WORD[15:0]}
                        : LOAD_WORD;

        if (u_dut.u_core.u_regfile.regs[1] !== expected_register)
            fail(case_id, $sformatf(
                "%s r1 expected %08x got %08x",
                label, expected_register,
                u_dut.u_core.u_regfile.regs[1]));
        if (u_mem.mem[expected_address[8:2]] !== expected_memory)
            fail(case_id, $sformatf(
                "%s memory expected %08x got %08x",
                label, expected_memory,
                u_mem.mem[expected_address[8:2]]));
        if (u_dut.u_core.u_regfile.regs[7] !== 32'(case_id))
            fail(case_id, $sformatf("%s completion marker missing", label));
        if (u_dut.u_core.cpsr.m !== 5'(MODE_SUPERVISOR))
            fail(case_id, $sformatf("%s changed processor mode", label));
    endtask

    initial begin
        int case_id;
        case_id = 0;
        for (int form = 0; form < 2; form++) begin
            for (int combo = 0; combo < 32; combo++) begin
                case_id++;
                run_case(case_id, 5'(combo), 1'(form));
            end
        end

        $display("[extra_ls_matrix] PASS (%0d reset-per-case rows)",
                 CASE_COUNT);
        $finish;
    end

    initial begin
        #650000;
        $fatal(1, "[extra_ls_matrix] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, WDATA, RDATA,
        CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI,
        DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG,
        DBGCOMMTX, DBGCOMMRX, DBGTDO, DBGnTDOEN, DMORE};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
