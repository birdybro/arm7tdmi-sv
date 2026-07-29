// ISA-010 / ISA-016 single-transfer register and PC policy matrix.
//
// Cases 1-12 execute architecturally defined aliases and r15 uses.
// Cases 13-26 freeze a precise Undefined trap for statically detectable
// ARMv4T UNPREDICTABLE operand combinations.  The trap rows must not issue
// the would-be data access or execute their successor.

`timescale 1ns/1ps

module arm7tdmis_single_ls_policy_tb
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_types_pkg::*;
;

    localparam int CASE_COUNT = 26;
    localparam int FIRST_TRAP_CASE = 13;
    localparam logic [31:0] DATA_WORD  = 32'h8877_8084;
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
        .WORDS(256)
    ) u_mem (
        .CLK(CLK), .CLKEN(1'b1), .nRESET(nRESET),
        .CFGBIGEND(1'b0),
        .ADDR(ADDR), .WRITE(WRITE), .SIZE(SIZE), .PROT(PROT),
        .LOCK(LOCK), .TRANS(TRANS), .WDATA(WDATA), .RDATA(RDATA),
        .ABORT(ABORT), .inject_abort(1'b0)
    );

    task automatic fail(input int case_id, input string label);
        $fatal(1, "[single_ls_policy] FAIL case %0d: %s", case_id, label);
    endtask

    task automatic setup_case(
        input  int          case_id,
        output string       label,
        output logic [31:0] expected_address
    );
        logic [31:0] opcode;

        for (int word = 0; word < 256; word++)
            u_mem.mem[word] = 32'hEAFF_FFFE;

        // Reset and Undefined vectors.
        u_mem.mem[0]  = 32'hEA00_0006; // B 0x20
        u_mem.mem[1]  = 32'hEA00_001D; // B 0x80
        u_mem.mem[32] = 32'hE3A0_6000 | 32'(case_id);
        u_mem.mem[33] = 32'hEAFF_FFFE;

        // Common setup. Test opcode is at 0x2c.
        u_mem.mem[8]  = 32'hE59F_0038; // r0 <- [0x60]
        u_mem.mem[9]  = 32'hE59F_1038; // r1 <- [0x64]
        u_mem.mem[10] = 32'hE59F_2038; // r2 <- [0x68]
        u_mem.mem[12] = 32'hE3A0_7000 | 32'(case_id);
        u_mem.mem[13] = 32'hEAFF_FFFE;
        u_mem.mem[24] = 32'h0000_0100;
        u_mem.mem[25] = STORE_WORD;
        u_mem.mem[26] = 32'h0000_0020;

        u_mem.mem[64]  = DATA_WORD; // 0x100
        u_mem.mem[72]  = DATA_WORD; // 0x120
        u_mem.mem[96]  = DATA_WORD; // 0x180
        u_mem.mem[128] = DATA_WORD; // 0x200

        opcode = 32'hE7F0_00F0;
        expected_address = 32'h0000_0120;
        unique case (case_id)
            1: begin
                label = "defined LDR Rn=Rd without writeback";
                opcode = 32'hE590_0020;
            end
            2: begin
                label = "defined STR Rn=Rd without writeback";
                opcode = 32'hE580_0020;
            end
            3: begin
                label = "defined LDR register offset Rn=Rm";
                opcode = 32'hE790_1000;
                expected_address = 32'h0000_0200;
            end
            4: begin
                label = "defined LDR register offset Rd=Rm";
                opcode = 32'hE790_2002;
            end
            5: begin
                label = "defined LDR immediate offset Rn=pc";
                opcode = 32'hE59F_10CC;
                expected_address = 32'h0000_0100;
            end
            6: begin
                label = "defined LDR register offset Rn=pc";
                opcode = 32'hE79F_1002;
                u_mem.mem[26] = 32'h0000_00CC;
                expected_address = 32'h0000_0100;
            end
            7: begin
                label = "implementation-defined STR pc value";
                opcode = 32'hE580_F000;
                expected_address = 32'h0000_0100;
            end
            8: begin
                label = "defined LDR pc";
                opcode = 32'hE590_F000;
                u_mem.mem[64] = 32'h0000_0180;
                u_mem.mem[96] = 32'hE3A0_7000 | 32'(case_id);
                u_mem.mem[97] = 32'hEAFF_FFFE;
                expected_address = 32'h0000_0100;
            end
            9: begin
                label = "defined LDRH Rn=Rd without writeback";
                opcode = 32'hE1D0_02B0;
            end
            10: begin
                label = "defined STRH Rn=Rd without writeback";
                opcode = 32'hE1C0_02B0;
            end
            11: begin
                label = "defined LDRH register offset Rn=Rm";
                opcode = 32'hE190_10B0;
                expected_address = 32'h0000_0200;
            end
            12: begin
                label = "defined LDRSH register offset Rd=Rm";
                opcode = 32'hE190_20F2;
            end
            13: begin
                label = "policy trap LDR writeback Rn=Rd";
                opcode = 32'hE5B0_0020;
            end
            14: begin
                label = "policy trap STR post-index Rn=Rd";
                opcode = 32'hE480_0020;
                expected_address = 32'h0000_0100;
            end
            15: begin
                label = "policy trap pre-index register Rn=Rm";
                opcode = 32'hE7B0_1000;
                expected_address = 32'h0000_0200;
            end
            16: begin
                label = "policy trap post-index register Rn=Rm";
                opcode = 32'hE690_1000;
                expected_address = 32'h0000_0100;
            end
            17: begin
                label = "policy trap mode-2 Rm=pc";
                opcode = 32'hE790_100F;
            end
            18: begin
                label = "policy trap mode-2 writeback Rn=pc";
                opcode = 32'hE5BF_1020;
            end
            19: begin
                label = "policy trap LDRB Rd=pc";
                opcode = 32'hE5D0_F000;
                expected_address = 32'h0000_0100;
            end
            20: begin
                label = "policy trap STRB Rd=pc";
                opcode = 32'hE5C0_F000;
                expected_address = 32'h0000_0100;
            end
            21: begin
                label = "policy trap LDRH writeback Rn=Rd";
                opcode = 32'hE1F0_02B0;
            end
            22: begin
                label = "policy trap STRH Rd=pc";
                opcode = 32'hE1C0_F0B0;
                expected_address = 32'h0000_0100;
            end
            23: begin
                label = "policy trap mode-3 Rm=pc";
                opcode = 32'hE190_10FF;
            end
            24: begin
                label = "policy trap mode-3 indexed Rn=Rm";
                opcode = 32'hE1B0_10B0;
                expected_address = 32'h0000_0200;
            end
            25: begin
                label = "policy trap mode-3 writeback Rn=pc";
                opcode = 32'hE0DF_12B0;
            end
            default: begin
                label = "policy trap LDRH Rd=pc";
                opcode = 32'hE1D0_F0B0;
                expected_address = 32'h0000_0100;
            end
        endcase

        u_mem.mem[11] = opcode;
    endtask

    task automatic run_case(input int case_id);
        string label;
        logic [31:0] expected_address;
        int unsigned target_data_cycles;

        @(negedge CLK);
        nRESET = 1'b0;
        repeat (4) @(posedge CLK);
        setup_case(case_id, label, expected_address);
        @(negedge CLK);
        nRESET = 1'b1;

        target_data_cycles = 0;
        repeat (120) begin
            @(negedge CLK);
            if ((TRANS inside {TRANS_N, TRANS_S})
                && PROT[PROT_BIT_DATA]
                && (ADDR >= 32'h0000_0100))
                target_data_cycles++;
        end

        if (case_id >= FIRST_TRAP_CASE) begin
            if (target_data_cycles != 0)
                fail(case_id, $sformatf(
                    "%s issued %0d forbidden data cycle(s)",
                    label, target_data_cycles));
            if (u_dut.u_core.cpsr.m !== 5'(MODE_UNDEFINED)
                || u_dut.u_core.cpsr.t || !u_dut.u_core.cpsr.i)
                fail(case_id, $sformatf(
                    "%s did not enter ARM Undefined mode", label));
            if (u_dut.u_core.u_regfile.regs[30] !== 32'h0000_0030)
                fail(case_id, $sformatf(
                    "%s LR_und expected 00000030 got %08x",
                    label, u_dut.u_core.u_regfile.regs[30]));
            if (u_dut.u_core.u_psr.spsr_q[4] !== 32'h0000_00D3)
                fail(case_id, $sformatf(
                    "%s SPSR_und expected 000000D3 got %08x",
                    label, u_dut.u_core.u_psr.spsr_q[4]));
            if (u_dut.u_core.u_regfile.regs[6] !== 32'(case_id))
                fail(case_id, {label, " handler marker missing"});
            if (u_dut.u_core.u_regfile.regs[7] !== 32'h0)
                fail(case_id, {label, " executed flushed successor"});
            if ((u_mem.mem[64] !== DATA_WORD)
                || (u_mem.mem[72] !== DATA_WORD)
                || (u_mem.mem[128] !== DATA_WORD))
                fail(case_id, {label, " changed memory before trap"});
        end else begin
            if (target_data_cycles != 1)
                fail(case_id, $sformatf(
                    "%s data-cycle count expected 1 got %0d",
                    label, target_data_cycles));
            if (u_dut.u_core.cpsr.m !== 5'(MODE_SUPERVISOR))
                fail(case_id, {label, " changed processor mode"});
            if (u_dut.u_core.u_regfile.regs[7] !== 32'(case_id))
                fail(case_id, {label, " completion marker missing"});

            unique case (case_id)
                1: if (u_dut.u_core.u_regfile.regs[0] !== DATA_WORD)
                    fail(case_id, {label, " loaded wrong value"});
                2: begin
                    if (u_dut.u_core.u_regfile.regs[0] !== 32'h0000_0100)
                        fail(case_id, {label, " changed base"});
                    if (u_mem.mem[72] !== 32'h0000_0100)
                        fail(case_id, {label, " stored wrong base value"});
                end
                3, 5, 6:
                    if (u_dut.u_core.u_regfile.regs[1] !== DATA_WORD)
                        fail(case_id, {label, " loaded wrong value"});
                4:
                    if (u_dut.u_core.u_regfile.regs[2] !== DATA_WORD)
                        fail(case_id, {label, " loaded wrong value"});
                7:
                    if (u_mem.mem[64] !== 32'h0000_0038)
                        fail(case_id, $sformatf(
                            "%s expected PC+12 store 00000038 got %08x",
                            label, u_mem.mem[64]));
                8: ; // target marker and Supervisor-mode checks above.
                9:
                    if (u_dut.u_core.u_regfile.regs[0]
                        !== 32'h0000_8084)
                        fail(case_id, {label, " loaded wrong halfword"});
                10:
                    if (u_mem.mem[72] !== 32'h8877_0100)
                        fail(case_id, {label, " stored wrong halfword"});
                11:
                    if (u_dut.u_core.u_regfile.regs[1]
                        !== 32'h0000_8084)
                        fail(case_id, {label, " loaded wrong halfword"});
                12:
                    if (u_dut.u_core.u_regfile.regs[2]
                        !== 32'hFFFF_8084)
                        fail(case_id, {label,
                                       " loaded wrong signed halfword"});
                default: ;
            endcase
        end

        // Keep the expected address live in the test and ensure defined
        // rows reached the intended operation, not merely any data cycle.
        if ((case_id < FIRST_TRAP_CASE) && (case_id != 8)
            && (u_dut.u_core.ls_data_addr_q !== expected_address))
            fail(case_id, $sformatf(
                "%s latched address expected %08x got %08x",
                label, expected_address, u_dut.u_core.ls_data_addr_q));
    endtask

    initial begin
        for (int case_id = 1; case_id <= CASE_COUNT; case_id++)
            run_case(case_id);

        $display("[single_ls_policy] PASS (%0d reset-per-case rows)",
                 CASE_COUNT);
        $finish;
    end

    initial begin
        #380000;
        $fatal(1, "[single_ls_policy] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, SIZE, WRITE, LOCK, WDATA, RDATA,
        CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI,
        DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG,
        DBGCOMMTX, DBGCOMMRX, DBGTDO, DBGnTDOEN, DMORE};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
