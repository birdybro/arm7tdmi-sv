// ISA-016 data-processing S+PC policy matrix for modes without an SPSR.
//
// ARMv4T makes every flag-setting data-processing write to r15
// UNPREDICTABLE in User and System modes because no SPSR exists to restore.
// This implementation commits the ordinary result, aligns it for the current
// ARM state, and leaves the complete CPSR unchanged. The 24 rows cover all
// twelve result-writing opcodes in both modes. This is project policy, not an
// architectural guarantee.

`timescale 1ns/1ps

module arm7tdmis_dp_pc_no_spsr_policy_tb
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_types_pkg::*;
;

    localparam int OPCODE_COUNT = 12;
    localparam int CASE_COUNT   = 2 * OPCODE_COUNT;
    localparam logic [31:0] RAW_TARGET = 32'h0000_0103;
    localparam logic [31:0] TARGET     = 32'h0000_0100;

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

    function automatic logic [3:0] result_opcode(input int op_idx);
        unique case (op_idx)
            0: return 4'h0; // AND
            1: return 4'h1; // EOR
            2: return 4'h2; // SUB
            3: return 4'h3; // RSB
            4: return 4'h4; // ADD
            5: return 4'h5; // ADC
            6: return 4'h6; // SBC
            7: return 4'h7; // RSC
            8: return 4'hC; // ORR
            9: return 4'hD; // MOV
            10: return 4'hE; // BIC
            default: return 4'hF; // MVN
        endcase
    endfunction

    function automatic string opcode_name(input int op_idx);
        unique case (op_idx)
            0: return "ANDS";
            1: return "EORS";
            2: return "SUBS";
            3: return "RSBS";
            4: return "ADDS";
            5: return "ADCS";
            6: return "SBCS";
            7: return "RSCS";
            8: return "ORRS";
            9: return "MOVS";
            10: return "BICS";
            default: return "MVNS";
        endcase
    endfunction

    task automatic operands_for(
        input  int          op_idx,
        output logic [31:0] rn_value,
        output logic [31:0] rm_value
    );
        unique case (op_idx)
            0: begin rn_value = RAW_TARGET; rm_value = 32'hFFFF_FFFF; end
            1: begin rn_value = RAW_TARGET; rm_value = 32'h0000_0000; end
            2: begin rn_value = 32'h0000_0124; rm_value = 32'h0000_0021; end
            3: begin rn_value = 32'h0000_0021; rm_value = 32'h0000_0124; end
            4: begin rn_value = 32'h0000_00E2; rm_value = 32'h0000_0021; end
            5: begin rn_value = 32'h0000_00E1; rm_value = 32'h0000_0021; end
            6: begin rn_value = 32'h0000_0124; rm_value = 32'h0000_0021; end
            7: begin rn_value = 32'h0000_0021; rm_value = 32'h0000_0124; end
            8: begin rn_value = 32'h0000_0102; rm_value = 32'h0000_0001; end
            9: begin rn_value = 32'h0000_0000; rm_value = RAW_TARGET; end
            10: begin rn_value = RAW_TARGET; rm_value = 32'h0000_0000; end
            default: begin
                rn_value = 32'h0000_0000;
                rm_value = ~RAW_TARGET;
            end
        endcase
    endtask

    task automatic fail(
        input int    case_id,
        input string label,
        input string message
    );
        $display("[dp_pc_no_spsr_policy] FAIL case %0d %s: %s",
                 case_id, label, message);
        errors++;
    endtask

    task automatic setup_case(
        input  int          case_id,
        output string       label,
        output logic [31:0] expected_cpsr
    );
        int op_idx;
        logic user_mode;
        logic [31:0] rn_value;
        logic [31:0] rm_value;
        logic [3:0] opcode;

        op_idx = (case_id - 1) % OPCODE_COUNT;
        user_mode = case_id <= OPCODE_COUNT;
        opcode = result_opcode(op_idx);
        operands_for(op_idx, rn_value, rm_value);
        label = $sformatf("%s in %s", opcode_name(op_idx),
                          user_mode ? "User" : "System");
        expected_cpsr = user_mode ? 32'hB000_00D0 : 32'hB000_00DF;

        for (int word = 0; word < 128; word++)
            u_mem.mem[word] = 32'hEAFF_FFFE;

        u_mem.mem[0]  = 32'hEA00_0006; // reset: B 0x20
        u_mem.mem[8]  = 32'hE59F_0058; // r0 <- Rn value
        u_mem.mem[9]  = 32'hE59F_1058; // r1 <- Rm value
        u_mem.mem[10] = 32'hE59F_2058; // r2 <- NZCV=1011
        u_mem.mem[11] = 32'hE128_F002; // MSR CPSR_f,r2
        u_mem.mem[12] = user_mode
                      ? 32'hE321_F0D0 : 32'hE321_F0DF;
        u_mem.mem[13] = {4'hE, 3'b000, opcode, 1'b1,
                         4'd0, 4'd15, 8'h00, 4'd1};
        u_mem.mem[14] = 32'hE3A0_50EE; // flushed successor
        u_mem.mem[15] = 32'hEAFF_FFFE;

        u_mem.mem[32] = rn_value;
        u_mem.mem[33] = rm_value;
        u_mem.mem[34] = 32'hB000_0000;

        u_mem.mem[TARGET >> 2] = 32'hE10F_6000; // MRS r6,CPSR
        u_mem.mem[(TARGET >> 2) + 1] =
            32'hE3A0_7000 | 32'(case_id);
        u_mem.mem[(TARGET >> 2) + 2] = 32'hEAFF_FFFE;
    endtask

    task automatic run_case(input int case_id);
        string label;
        logic [31:0] expected_cpsr;
        logic saw_target_fetch;

        @(negedge CLK);
        nRESET = 1'b0;
        repeat (4) @(posedge CLK);
        setup_case(case_id, label, expected_cpsr);
        @(negedge CLK);
        nRESET = 1'b1;

        saw_target_fetch = 1'b0;
        repeat (120) begin
            @(negedge CLK);
            if ((TRANS inside {TRANS_N, TRANS_S})
                && !WRITE && !PROT[PROT_BIT_DATA]
                && ADDR == TARGET) begin
                saw_target_fetch = 1'b1;
                if (SIZE !== 2'(SIZE_WORD))
                    fail(case_id, label, "target fetch was not word-sized");
            end
        end

        if (!saw_target_fetch)
            fail(case_id, label, "aligned target fetch was not observed");
        if (u_dut.u_core.u_regfile.regs[7] !== 32'(case_id))
            fail(case_id, label, "target marker did not retire");
        if (u_dut.u_core.u_regfile.regs[5] !== 32'h0000_0000)
            fail(case_id, label, "sequential successor executed");
        if (u_dut.u_core.u_regfile.regs[6] !== expected_cpsr)
            fail(case_id, label, $sformatf(
                "CPSR expected %08x got %08x", expected_cpsr,
                u_dut.u_core.u_regfile.regs[6]));
        if (32'(u_dut.u_core.cpsr) !== expected_cpsr)
            fail(case_id, label, "live CPSR changed");
    endtask

    initial begin
        errors = 0;
        for (int case_id = 1; case_id <= CASE_COUNT; case_id++)
            run_case(case_id);

        if (errors != 0)
            $fatal(1, "[dp_pc_no_spsr_policy] FAIL (%0d errors)", errors);
        $display("[dp_pc_no_spsr_policy] PASS (%0d reset-per-case rows)",
                 CASE_COUNT);
        $finish;
    end

    initial begin
        repeat (CASE_COUNT * 160) @(posedge CLK);
        $fatal(1, "[dp_pc_no_spsr_policy] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, LOCK, WDATA, ABORT, CPnMREQ, CPSEQ,
        CPnTRANS, CPnOPC, CPTBIT, CPnI, DBGACK, DBGnEXEC,
        DBGINSTRVALID, DBGRNG, DBGCOMMTX, DBGCOMMRX, DBGTDO,
        DBGnTDOEN, DMORE};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
