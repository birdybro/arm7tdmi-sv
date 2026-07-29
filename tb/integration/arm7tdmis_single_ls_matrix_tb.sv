// ISA-010 ARM Addressing Mode 2 matrix.
//
// Executes every P/U/B/W/L combination twice: once with an immediate
// offset and once with a scaled-register offset.  The register rows cycle
// through LSL, LSR, ASR, and the encoded RRX form, so every row still
// resolves to the same 0x20 index and can use one independent scoreboard.

`timescale 1ns/1ps

module arm7tdmis_single_ls_matrix_tb
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_types_pkg::*;
;

    localparam int CASE_COUNT = 64;
    localparam logic [31:0] BASE_ADDR  = 32'h0000_0180;
    localparam logic [31:0] OFFSET     = 32'h0000_0020;
    localparam logic [31:0] LOAD_WORD  = 32'h8877_6644;
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
        $fatal(1, "[single_ls_matrix] FAIL case %0d: %s", case_id, label);
    endtask

    function automatic string shift_name(input logic [1:0] shift_type);
        case (shift_type)
            2'b00: return "LSL #1";
            2'b01: return "LSR #1";
            2'b10: return "ASR #1";
            2'b11: return "RRX";
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
        input logic        register_offset,
        output logic [31:0] expected_address,
        output logic [31:0] expected_base,
        output string       label
    );
        logic       pre_index;
        logic       up;
        logic       byte_access;
        logic       writeback;
        logic       load;
        logic [1:0] shift_type;
        logic [4:0] shift_amount;
        logic [7:0] rm_value;
        logic [31:0] adjusted_address;
        logic [31:0] opcode;

        pre_index   = combo[4];
        up          = combo[3];
        byte_access = combo[2];
        writeback   = combo[1];
        load        = combo[0];
        shift_type  = combo[1:0];

        case (shift_type)
            2'b00: begin shift_amount = 5'd1; rm_value = 8'h10; end
            2'b01: begin shift_amount = 5'd1; rm_value = 8'h40; end
            2'b10: begin shift_amount = 5'd1; rm_value = 8'h40; end
            2'b11: begin shift_amount = 5'd0; rm_value = 8'h40; end
        endcase

        for (int word = 0; word < 128; word++)
            u_mem.mem[word] = 32'hEAFF_FFFE;
        for (int word = 80; word <= 112; word++)
            u_mem.mem[word] = LOAD_WORD;

        u_mem.mem[0]  = 32'hEA00_0006; // B 0x20
        u_mem.mem[8]  = 32'hE59F_0038; // LDR r0,[pc,#0x38] -> 0x60
        u_mem.mem[9]  = 32'hE59F_1038; // LDR r1,[pc,#0x38] -> 0x64
        u_mem.mem[10] = 32'hE3A0_2000 | 32'(rm_value); // MOV r2,#value

        // cond 01 I P U B W L Rn=r0 Rd=r1 offset.
        opcode     = 32'hE400_1000;
        opcode[25] = register_offset;
        opcode[24] = pre_index;
        opcode[23] = up;
        opcode[22] = byte_access;
        opcode[21] = writeback;
        opcode[20] = load;
        if (register_offset) begin
            opcode[11:7] = shift_amount;
            opcode[6:5]  = shift_type;
            opcode[4]    = 1'b0;
            opcode[3:0]  = 4'd2;
        end else begin
            opcode[11:0] = OFFSET[11:0];
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
        label = $sformatf("%s%s P=%0b U=%0b W=%0b %s offset",
                          load ? "LDR" : "STR",
                          byte_access ? "B" : "",
                          pre_index, up, writeback,
                          register_offset ? shift_name(shift_type)
                                          : "immediate");
    endtask

    task automatic run_case(
        input int         case_id,
        input logic [4:0] combo,
        input logic       register_offset
    );
        string label;
        logic pre_index;
        logic byte_access;
        logic writeback;
        logic load;
        logic [31:0] expected_address;
        logic [31:0] expected_base;
        logic [31:0] expected_register;
        logic [31:0] expected_memory;
        logic [1:0] expected_size;
        logic expected_privileged;
        int unsigned data_cycles;

        hold_reset();
        setup_case(case_id, combo, register_offset, expected_address,
                   expected_base, label);
        @(negedge CLK);
        nRESET = 1'b1;

        pre_index   = combo[4];
        byte_access = combo[2];
        writeback   = combo[1];
        load        = combo[0];
        expected_size = byte_access ? 2'(SIZE_BYTE) : 2'(SIZE_WORD);
        expected_privileged = !(!pre_index && writeback);
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
                if (PROT[PROT_BIT_PRIV] !== expected_privileged)
                    fail(case_id, $sformatf(
                        "%s privilege expected %0b got %0b",
                        label, expected_privileged,
                        PROT[PROT_BIT_PRIV]));
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

        expected_register = load
                          ? (byte_access ? {24'h0, LOAD_WORD[7:0]}
                                         : LOAD_WORD)
                          : STORE_WORD;
        expected_memory = load ? LOAD_WORD
                        : byte_access ? {LOAD_WORD[31:8],
                                         STORE_WORD[7:0]}
                                      : STORE_WORD;
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

        $display("[single_ls_matrix] PASS (%0d reset-per-case rows)",
                 CASE_COUNT);
        $finish;
    end

    initial begin
        #650000;
        $fatal(1, "[single_ls_matrix] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, WDATA, RDATA,
        CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI,
        DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG,
        DBGCOMMTX, DBGCOMMRX, DBGTDO, DBGnTDOEN, DMORE};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
