// ISA-016 pin-level precise-trap regression for statically detectable
// ARMv4T UNPREDICTABLE encodings.
//
// INSTR_UNDEF is this core's safety policy, not an ARM architectural
// guarantee. The exhaustive field enumeration lives in the decoder unit
// test; these representatives prove the policy reaches precise Undefined
// entry without register, memory, successor, or coprocessor side effects.

`timescale 1ns/1ps

module arm7tdmis_unpredictable_trap_tb
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_types_pkg::*;
;

    localparam int CASE_COUNT = 24;
    localparam logic [31:0] DATA_SENTINEL = 32'hCAFE_BABE;

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

    function automatic logic [31:0] mul_word(
        input logic       accumulate,
        input logic [3:0] rd,
        input logic [3:0] rn,
        input logic [3:0] rs,
        input logic [3:0] rm
    );
        return {4'hE, 6'b000000, accumulate, 1'b0,
                rd, rn, rs, 4'b1001, rm};
    endfunction

    function automatic logic [31:0] mull_word(
        input logic [3:0] rd_hi,
        input logic [3:0] rd_lo,
        input logic [3:0] rs,
        input logic [3:0] rm
    );
        return {4'hE, 5'b00001, 3'b100,
                rd_hi, rd_lo, rs, 4'b1001, rm};
    endfunction

    int unsigned errors;

    task automatic fail(input int case_id, input string label);
        $display("[unpredictable_trap] FAIL case %0d: %s", case_id, label);
        errors++;
    endtask

    task automatic setup_case(
        input  int          case_id,
        output string       label,
        output logic [31:0] expected_lr,
        output logic [31:0] expected_spsr
    );
        logic [31:0] arm_opcode;
        logic [15:0] thumb_opcode;
        logic        thumb_case;

        for (int word = 0; word < 128; word++)
            u_mem.mem[word] = 32'hEAFF_FFFE;

        u_mem.mem[0]  = 32'hEA00_0006; // reset: B 0x20
        u_mem.mem[1]  = 32'hEA00_001D; // Undef: B 0x80
        u_mem.mem[32] = 32'hE3A0_7000 | 32'(case_id);
        u_mem.mem[33] = 32'hEAFF_FFFE;
        u_mem.mem[64] = DATA_SENTINEL;

        thumb_case    = (case_id >= 19);
        expected_lr   = thumb_case ? 32'h0000_0042 : 32'h0000_0030;
        expected_spsr = thumb_case ? 32'h0000_00F3 : 32'h0000_00D3;
        arm_opcode    = 32'hE7F0_00F0;
        thumb_opcode  = 16'h4408;

        unique case (case_id)
            1: begin
                label = "ARM test-op nonzero Rd/SBZ";
                arm_opcode = 32'hE110_2001;
            end
            2: begin
                label = "ARM MOV nonzero Rn/SBZ";
                arm_opcode = 32'hE1A1_2003;
            end
            3: begin
                label = "ARM MUL nonzero accumulator/SBZ";
                arm_opcode = mul_word(1'b0, 4'd1, 4'd2, 4'd3, 4'd4);
            end
            4: begin
                label = "ARM MUL r15 destination";
                arm_opcode = mul_word(1'b0, 4'd15, 4'd0, 4'd3, 4'd4);
            end
            5: begin
                label = "ARM MLA r15 accumulator";
                arm_opcode = mul_word(1'b1, 4'd1, 4'd15, 4'd3, 4'd4);
            end
            6: begin
                label = "ARM MULL identical destinations";
                arm_opcode = mull_word(4'd2, 4'd2, 4'd3, 4'd4);
            end
            7: begin
                label = "ARM MULL r15 source";
                arm_opcode = mull_word(4'd1, 4'd2, 4'd3, 4'd15);
            end
            8: begin
                label = "ARM MRS destination pc";
                arm_opcode = 32'hE10F_F000;
            end
            9: begin
                label = "ARM MSR zero field mask";
                arm_opcode = 32'hE120_F001;
            end
            10: begin
                label = "ARM MSR source pc";
                arm_opcode = 32'hE128_F00F;
            end
            11: begin
                label = "ARM LDC indexed pc base";
                arm_opcode = 32'hEDBF_1104;
            end
            12: begin
                label = "ARM STC indexed pc base";
                arm_opcode = 32'hECAF_1104;
            end
            13: begin
                label = "ARM MRS nonzero SBZ";
                arm_opcode = 32'hE10F_1001;
            end
            14: begin
                label = "ARM MSR register nonzero SBZ";
                arm_opcode = 32'hE128_F801;
            end
            15: begin
                label = "ARM MSR immediate invalid SBO";
                arm_opcode = 32'hE328_E001;
            end
            16: begin
                label = "ARM BX invalid SBO";
                arm_opcode = 32'hE12F_FE11;
            end
            17: begin
                label = "ARM SWP nonzero SBZ";
                arm_opcode = 32'hE101_2193;
            end
            18: begin
                label = "ARM LDRH register nonzero SBZ";
                arm_opcode = 32'hE191_21B3;
            end
            19: begin
                label = "Thumb high-ADD low/low operands";
                thumb_opcode = 16'h4408;
            end
            20: begin
                label = "Thumb high-CMP low/low operands";
                thumb_opcode = 16'h4508;
            end
            21: begin
                label = "Thumb high-MOV low/low operands";
                thumb_opcode = 16'h4608;
            end
            22: begin
                label = "Thumb high-CMP Rn=pc";
                thumb_opcode = 16'h4587;
            end
            23: begin
                label = "Thumb pre-v5 BLX-register spelling";
                thumb_opcode = 16'h4780;
            end
            default: begin
                label = "Thumb BX nonzero SBZ";
                thumb_opcode = 16'h4701;
            end
        endcase

        if (!thumb_case) begin
            u_mem.mem[8]  = 32'hE3A0_005A; // preserved r0
            u_mem.mem[9]  = 32'hE3A0_20A5;
            u_mem.mem[10] = 32'hE3A0_3C01;
            u_mem.mem[11] = arm_opcode;    // policy word at 0x2c
            u_mem.mem[12] = 32'hE3A0_10A5; // flushed successor
            u_mem.mem[13] = 32'hEAFF_FFFE;
        end else begin
            u_mem.mem[8]  = 32'hE3A0_005A;
            u_mem.mem[9]  = 32'hE59F_200C;
            u_mem.mem[10] = 32'hE12F_FF12; // BX r2 -> Thumb 0x40
            u_mem.mem[14] = 32'h0000_0041;
            u_mem.mem[16] = {16'h21A5, thumb_opcode};
            u_mem.mem[17] = 32'hE7FE_E7FE;
        end
    endtask

    task automatic run_case(input int case_id);
        string       label;
        logic [31:0] expected_lr;
        logic [31:0] expected_spsr;
        logic        cp_request_seen;
        int unsigned data_cycles;

        @(negedge CLK);
        nRESET = 1'b0;
        repeat (4) @(posedge CLK);
        setup_case(case_id, label, expected_lr, expected_spsr);
        @(negedge CLK);
        nRESET = 1'b1;

        cp_request_seen = 1'b0;
        data_cycles = 0;
        repeat (120) begin
            @(negedge CLK);
            if (!CPnI)
                cp_request_seen = 1'b1;
            if ((TRANS inside {TRANS_N, TRANS_S})
                && PROT[PROT_BIT_DATA])
                data_cycles++;
        end

        if (u_dut.u_core.cpsr.m !== 5'(MODE_UNDEFINED)
         || u_dut.u_core.cpsr.t !== 1'b0
         || u_dut.u_core.cpsr.i !== 1'b1)
            fail(case_id, $sformatf(
                "%s did not finish in ARM Undefined mode", label));
        if (u_dut.u_core.u_regfile.regs[30] !== expected_lr)
            fail(case_id, $sformatf(
                "%s LR_und expected %08x got %08x", label, expected_lr,
                u_dut.u_core.u_regfile.regs[30]));
        if (u_dut.u_core.u_psr.spsr_q[4] !== expected_spsr)
            fail(case_id, $sformatf(
                "%s SPSR_und expected %08x got %08x", label, expected_spsr,
                u_dut.u_core.u_psr.spsr_q[4]));
        if (u_dut.u_core.u_regfile.regs[0] !== 32'h0000_005A)
            fail(case_id, $sformatf("%s changed pre-instruction r0", label));
        if (u_dut.u_core.u_regfile.regs[1] !== 32'h0000_0000)
            fail(case_id, $sformatf("%s executed flushed successor", label));
        if (u_dut.u_core.u_regfile.regs[7] !== 32'(case_id))
            fail(case_id, $sformatf("%s handler marker missing", label));
        if (u_mem.mem[64] !== DATA_SENTINEL)
            fail(case_id, $sformatf("%s changed memory", label));
        // Thumb setup executes one LDR. Its Table 7-11 sequence exposes
        // the data address/N plus the merged pc+3i/S data-class phase.
        if (data_cycles != (case_id >= 19 ? 2 : 0))
            fail(case_id, $sformatf(
                "%s issued unexpected data cycles (%0d)", label, data_cycles));
        if (cp_request_seen)
            fail(case_id, $sformatf(
                "%s leaked into the coprocessor interface", label));
    endtask

    initial begin
        errors = 0;
        for (int case_id = 1; case_id <= CASE_COUNT; case_id++)
            run_case(case_id);

        if (errors != 0)
            $fatal(1, "[unpredictable_trap] FAIL (%0d errors)", errors);
        $display("[unpredictable_trap] PASS (%0d reset-per-case policies)",
                 CASE_COUNT);
        $finish;
    end

    initial begin
        repeat (CASE_COUNT * 180) @(posedge CLK);
        $fatal(1, "[unpredictable_trap] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, ADDR, WRITE, SIZE, LOCK, WDATA, ABORT,
        CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT,
        DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG,
        DBGCOMMTX, DBGCOMMRX, DBGTDO, DBGnTDOEN, DMORE};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
