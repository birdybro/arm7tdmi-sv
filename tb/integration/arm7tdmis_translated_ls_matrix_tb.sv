// ISA-008 exhaustive translated single-transfer form matrix.
//
// Covers LDRT/STRT/LDRBT/STRBT across add/subtract and immediate/scaled
// register post-index offsets. Every row begins in Supervisor mode and
// requires a User-privilege data transfer while opcode fetches and the
// architectural processor mode remain privileged.

`timescale 1ns/1ps

module arm7tdmis_translated_ls_matrix_tb
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_types_pkg::*;
;

    localparam int CASE_COUNT = 16;
    localparam logic [31:0] BASE_ADDR = 32'h0000_0100;
    localparam logic [31:0] LOAD_WORD = 32'hA5A5_5A5A;
    localparam logic [31:0] STORE_SENTINEL = 32'hCAFE_BABE;

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

    int unsigned errors;

    task automatic fail(input int case_id, input string label);
        $display("[translated_ls_matrix] FAIL case %0d: %s",
                 case_id, label);
        errors++;
    endtask

    task automatic setup_case(
        input  int          case_id,
        output string       label,
        output logic        up,
        output logic        byte_access,
        output logic        load,
        output logic [31:0] offset_value
    );
        logic [2:0] combo;
        logic [31:0] opcode;
        logic [1:0] shift_type;
        logic [4:0] shift_amount;
        logic [7:0] rm_value;
        logic       use_register;

        combo        = 3'(case_id - 1);
        use_register = (case_id > 8);
        up           = combo[2];
        byte_access  = combo[1];
        load         = combo[0];
        offset_value = use_register ? 32'd12 : 32'd19;

        for (int word = 0; word < 128; word++)
            u_mem.mem[word] = 32'hEAFF_FFFE;

        // Reset vector to the test body.
        u_mem.mem[0] = 32'hEA00_0006; // B 0x20
        u_mem.mem[8] = 32'hE3A0_0C01; // MOV r0,#0x100
        u_mem.mem[9] = 32'hE3A0_105A; // MOV r1,#0x5a / load sentinel

        shift_type   = combo[1:0];
        shift_amount = (shift_type == 2'b00) ? 5'd2 : 5'd1;
        rm_value     = (shift_type == 2'b00) ? 8'd3 : 8'd24;
        u_mem.mem[10] = 32'hE3A0_2000 | 32'(rm_value); // MOV r2,#Rm value

        // cond 01 I P=0 U B W=1 L Rn=r0 Rd=r1 offset.
        opcode        = 32'hE400_1000;
        opcode[25]    = use_register;
        opcode[24]    = 1'b0;
        opcode[23]    = up;
        opcode[22]    = byte_access;
        opcode[21]    = 1'b1;
        opcode[20]    = load;
        if (use_register) begin
            opcode[11:7] = shift_amount;
            opcode[6:5]  = shift_type;
            opcode[4]    = 1'b0;
            opcode[3:0]  = 4'd2;
        end else begin
            opcode[11:0] = 12'd19;
        end

        u_mem.mem[11] = opcode;
        u_mem.mem[12] = 32'hE3A0_7000 | 32'(case_id); // completion marker
        u_mem.mem[13] = 32'hEAFF_FFFE;                 // B .
        u_mem.mem[64] = load ? LOAD_WORD : STORE_SENTINEL;

        label = $sformatf("%s%s %s %s offset",
                          load ? "LDR" : "STR",
                          byte_access ? "BT" : "T",
                          up ? "add" : "subtract",
                          use_register ? "scaled-register" : "immediate");
    endtask

    task automatic run_case(input int case_id);
        string       label;
        logic        up;
        logic        byte_access;
        logic        load;
        logic [31:0] offset_value;
        logic [31:0] expected_base;
        logic [31:0] expected_memory;
        logic [31:0] expected_load;
        int unsigned data_cycles;
        int unsigned privileged_fetches;

        @(negedge CLK);
        nRESET = 1'b0;
        repeat (4) @(posedge CLK);
        setup_case(case_id, label, up, byte_access, load, offset_value);
        @(negedge CLK);
        nRESET = 1'b1;

        data_cycles       = 0;
        privileged_fetches = 0;
        repeat (100) begin
            @(negedge CLK);
            if (TRANS inside {TRANS_N, TRANS_S}) begin
                if (PROT[PROT_BIT_DATA]) begin
                    data_cycles++;
                    if (ADDR !== BASE_ADDR)
                        fail(case_id, $sformatf(
                            "%s address expected %08x got %08x",
                            label, BASE_ADDR, ADDR));
                    if (PROT[PROT_BIT_PRIV] !== 1'b0)
                        fail(case_id, $sformatf(
                            "%s did not use User privilege", label));
                    if (SIZE !== (byte_access ? 2'(SIZE_BYTE)
                                             : 2'(SIZE_WORD)))
                        fail(case_id, $sformatf(
                            "%s SIZE expected %02b got %02b", label,
                            byte_access ? 2'(SIZE_BYTE) : 2'(SIZE_WORD),
                            SIZE));
                    if (WRITE !== !load)
                        fail(case_id, $sformatf(
                            "%s WRITE expected %0b got %0b",
                            label, !load, WRITE));
                end else if (PROT[PROT_BIT_PRIV]) begin
                    privileged_fetches++;
                end
            end
        end

        expected_base = up ? (BASE_ADDR + offset_value)
                           : (BASE_ADDR - offset_value);
        expected_memory = load ? LOAD_WORD
                        : byte_access ? 32'hCAFE_BA5A : 32'h0000_005A;
        expected_load = byte_access ? 32'h0000_005A : LOAD_WORD;

        if (data_cycles != 1)
            fail(case_id, $sformatf(
                "%s data-cycle count expected 1 got %0d",
                label, data_cycles));
        if (privileged_fetches == 0)
            fail(case_id, $sformatf(
                "%s never observed a privileged opcode fetch", label));
        if (u_dut.u_core.cpsr.m !== 5'(MODE_SUPERVISOR))
            fail(case_id, $sformatf(
                "%s changed processor mode to %05b",
                label, u_dut.u_core.cpsr.m));
        if (u_dut.u_core.u_regfile.regs[0] !== expected_base)
            fail(case_id, $sformatf(
                "%s base expected %08x got %08x", label, expected_base,
                u_dut.u_core.u_regfile.regs[0]));
        if (load && (u_dut.u_core.u_regfile.regs[1] !== expected_load))
            fail(case_id, $sformatf(
                "%s load expected %08x got %08x", label, expected_load,
                u_dut.u_core.u_regfile.regs[1]));
        if (u_mem.mem[64] !== expected_memory)
            fail(case_id, $sformatf(
                "%s memory expected %08x got %08x", label, expected_memory,
                u_mem.mem[64]));
        if (u_dut.u_core.u_regfile.regs[7] !== 32'(case_id))
            fail(case_id, $sformatf("%s completion marker missing", label));
    endtask

    initial begin
        errors = 0;
        for (int case_id = 1; case_id <= CASE_COUNT; case_id++)
            run_case(case_id);

        if (errors != 0)
            $fatal(1, "[translated_ls_matrix] FAIL (%0d errors)", errors);
        $display("[translated_ls_matrix] PASS (%0d reset-per-case rows)",
                 CASE_COUNT);
        $finish;
    end

    initial begin
        #250000;
        $fatal(1, "[translated_ls_matrix] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, ADDR, WRITE, SIZE, PROT, LOCK, TRANS, WDATA,
        CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI,
        DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG,
        DBGCOMMTX, DBGCOMMRX, DBGTDO, DBGnTDOEN, DMORE};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
