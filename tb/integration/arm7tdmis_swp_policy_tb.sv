// ISA-012 / ISA-016 SWP/SWPB register-alias and operand-policy matrix.
//
// Defined rows cover distinct operands and the architectural Rd=Rm exchange
// in Supervisor and User modes.  Unsafe rows require the repository-wide
// precise Undefined policy before any locked data transfer for Rn=Rd,
// Rn=Rm, or any use of r15.

`timescale 1ns/1ps

module arm7tdmis_swp_policy_tb
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_types_pkg::*;
;

    localparam int CASE_COUNT = 18;
    localparam logic [31:0] TEST_PC = 32'h0000_0030;
    localparam logic [31:0] DATA_ADDR = 32'h0000_0200;
    localparam logic [31:0] OLD_WORD = 32'h1234_5678;
    localparam logic [31:0] STORE_WORD = 32'hA5A5_C3D4;

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

    function automatic logic [31:0] swp_opcode(
        input logic       byte_access,
        input logic [3:0] rn,
        input logic [3:0] rd,
        input logic [3:0] rm
    );
        logic [31:0] opcode;
        opcode = 32'hE100_0090;
        opcode[22] = byte_access;
        opcode[19:16] = rn;
        opcode[15:12] = rd;
        opcode[3:0] = rm;
        return opcode;
    endfunction

    function automatic logic is_trap_case(input int case_id);
        return case_id >= 7;
    endfunction

    task automatic fail(input int case_id, input string label);
        $fatal(1, "[swp_policy] FAIL case %0d: %s", case_id, label);
    endtask

    task automatic setup_case(
        input  int          case_id,
        output string       label,
        output logic        byte_access,
        output logic        user_mode,
        output logic [3:0]  rd
    );
        logic [3:0] rn;
        logic [3:0] rm;

        for (int word = 0; word < 256; word++)
            u_mem.mem[word] = 32'hEAFF_FFFE;

        // Reset and Undefined vectors.
        u_mem.mem[0]  = 32'hEA00_0006; // B 0x20
        u_mem.mem[1]  = 32'hEA00_003D; // B 0x100

        // Common setup.  The literal at 0xc0 supplies Rm's store value.
        u_mem.mem[8]  = 32'hE3A0_4C02; // MOV r4,#0x200
        u_mem.mem[9]  = 32'hE59F_2094; // LDR r2,[pc,#0x94] -> 0xc0
        u_mem.mem[10] = 32'hE3A0_1055; // MOV r1,#0x55
        u_mem.mem[11] = 32'hE1A0_0000; // NOP / optional mode change
        u_mem.mem[13] = 32'hE3A0_7000 | 32'(case_id);
        u_mem.mem[14] = 32'hEAFF_FFFE;
        u_mem.mem[48] = STORE_WORD;

        // Undefined handler and data word.
        u_mem.mem[64]  = 32'hE3A0_6000 | 32'(case_id);
        u_mem.mem[65]  = 32'hEAFF_FFFE;
        u_mem.mem[128] = OLD_WORD;

        byte_access = !(case_id inside {1, 3, 5, 7, 9, 11, 13, 15, 17});
        user_mode = case_id inside {5, 6};
        rn = 4'd4;
        rd = 4'd1;
        rm = 4'd2;

        unique case (case_id)
            1, 2: label = byte_access
                        ? "defined SWPB distinct operands"
                        : "defined SWP distinct operands";
            3, 4: begin
                label = byte_access
                      ? "defined SWPB Rd equals Rm"
                      : "defined SWP Rd equals Rm";
                rd = 4'd2;
            end
            5, 6: begin
                label = byte_access
                      ? "defined User SWPB distinct operands"
                      : "defined User SWP distinct operands";
                u_mem.mem[11] = 32'hE321_F0D0; // MSR CPSR_c,#User
            end
            7, 8: begin
                label = byte_access
                      ? "policy trap SWPB Rn equals Rm"
                      : "policy trap SWP Rn equals Rm";
                rm = 4'd4;
            end
            9, 10: begin
                label = byte_access
                      ? "policy trap SWPB Rn equals Rd"
                      : "policy trap SWP Rn equals Rd";
                rd = 4'd4;
            end
            11, 12: begin
                label = byte_access
                      ? "policy trap SWPB all operands equal"
                      : "policy trap SWP all operands equal";
                rd = 4'd4;
                rm = 4'd4;
            end
            13, 14: begin
                label = byte_access
                      ? "policy trap SWPB Rd is r15"
                      : "policy trap SWP Rd is r15";
                rd = 4'd15;
            end
            15: begin
                label = "policy trap SWP Rn is r15";
                rn = 4'd15;
            end
            16: begin
                label = "policy trap SWPB Rn is r15";
                rn = 4'd15;
            end
            17: begin
                label = "policy trap SWP Rm is r15";
                rm = 4'd15;
            end
            18: begin
                label = "policy trap SWPB Rm is r15";
                rm = 4'd15;
            end
            default: label = "invalid case";
        endcase

        u_mem.mem[12] = swp_opcode(byte_access, rn, rd, rm);
    endtask

    task automatic run_case(input int case_id);
        string label;
        logic byte_access;
        logic user_mode;
        logic [3:0] rd;
        logic test_seen;
        int data_cycles;
        int locked_cycles;
        int read_cycles;
        int write_cycles;

        @(negedge CLK);
        nRESET = 1'b0;
        repeat (4) @(posedge CLK);
        setup_case(case_id, label, byte_access, user_mode, rd);
        @(negedge CLK);
        nRESET = 1'b1;

        test_seen = 1'b0;
        data_cycles = 0;
        locked_cycles = 0;
        read_cycles = 0;
        write_cycles = 0;
        repeat (100) begin
            @(negedge CLK);
            if ((u_dut.u_core.state_q == 5'd0)
                && (u_dut.u_core.de_q.pc == TEST_PC))
                test_seen = 1'b1;
            if (test_seen
                && (TRANS inside {TRANS_N, TRANS_S})
                && PROT[PROT_BIT_DATA]) begin
                data_cycles++;
                if (LOCK)
                    locked_cycles++;
                if (WRITE)
                    write_cycles++;
                else
                    read_cycles++;
                if (SIZE !== (byte_access
                            ? 2'(SIZE_BYTE) : 2'(SIZE_WORD)))
                    fail(case_id, {label, " emitted wrong SIZE"});
            end
        end

        if (!test_seen)
            fail(case_id, {label, " never reached test instruction"});

        if (is_trap_case(case_id)) begin
            if (data_cycles != 0 || locked_cycles != 0)
                fail(case_id, $sformatf(
                    "%s issued data=%0d locked=%0d cycles before trap",
                    label, data_cycles, locked_cycles));
            if (u_dut.u_core.cpsr.m !== 5'(MODE_UNDEFINED)
                || u_dut.u_core.cpsr.t || !u_dut.u_core.cpsr.i)
                fail(case_id, {label, " did not enter ARM Undefined mode"});
            if (u_dut.u_core.u_regfile.regs[30] !== (TEST_PC + 32'd4))
                fail(case_id, {label, " saved wrong LR_und"});
            if (u_dut.u_core.u_psr.spsr_q[4] !== 32'h0000_00D3)
                fail(case_id, {label, " saved wrong SPSR_und"});
            if (u_dut.u_core.u_regfile.regs[6] !== 32'(case_id))
                fail(case_id, {label, " handler marker missing"});
            if (u_dut.u_core.u_regfile.regs[7] !== 32'h0)
                fail(case_id, {label, " executed flushed successor"});
            if (u_mem.mem[128] !== OLD_WORD)
                fail(case_id, {label, " changed memory before trap"});
        end else begin
            logic [31:0] expected_loaded;
            logic [31:0] expected_memory;

            expected_loaded = byte_access
                            ? {24'h0, OLD_WORD[7:0]} : OLD_WORD;
            expected_memory = byte_access
                            ? {OLD_WORD[31:8], STORE_WORD[7:0]}
                            : STORE_WORD;

            if (data_cycles != 2 || locked_cycles != 2
                || read_cycles != 1 || write_cycles != 1)
                fail(case_id, $sformatf(
                    "%s cycles data=%0d lock=%0d read=%0d write=%0d",
                    label, data_cycles, locked_cycles,
                    read_cycles, write_cycles));
            if (u_dut.u_core.u_regfile.regs[{1'b0, rd}]
                !== expected_loaded)
                fail(case_id, {label, " returned wrong loaded value"});
            if (u_mem.mem[128] !== expected_memory)
                fail(case_id, {label, " stored wrong source value"});
            if (u_dut.u_core.u_regfile.regs[7] !== 32'(case_id))
                fail(case_id, {label, " completion marker missing"});
            if (u_dut.u_core.cpsr.m
                !== (user_mode ? 5'(MODE_USER) : 5'(MODE_SUPERVISOR)))
                fail(case_id, {label, " finished in wrong mode"});
        end

        if (LOCK !== LOCK_FREE)
            fail(case_id, {label, " left LOCK asserted"});
    endtask

    initial begin
        for (int case_id = 1; case_id <= CASE_COUNT; case_id++)
            run_case(case_id);

        $display("[swp_policy] PASS (%0d reset-per-case rows)", CASE_COUNT);
        $finish;
    end

    initial begin
        #500000;
        $fatal(1, "[swp_policy] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, ADDR, WDATA, RDATA, DMORE,
        CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI,
        DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG,
        DBGCOMMTX, DBGCOMMRX, DBGTDO, DBGnTDOEN};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
