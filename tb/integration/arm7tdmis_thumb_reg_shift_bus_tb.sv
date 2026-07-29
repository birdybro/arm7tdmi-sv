// BUS-005 Thumb register-shift address-phase regression.
//
// Thumb LSL/LSR/ASR/ROR by register take an execute I cycle followed by a
// merged S fetch. Both phases must advertise pc+3i (pc+6) with halfword,
// privileged-data controls.

`timescale 1ns/1ps

module arm7tdmis_thumb_reg_shift_bus_tb
    import arm7tdmis_bus_pkg::*;
;

    localparam logic [31:0] SHIFT_PC     = 32'h0000_0040;
    localparam logic [31:0] PREDICT_ADDR = 32'h0000_0046;

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

    task automatic fail(input int case_id, input string message);
        $fatal(1, "[thumb_reg_shift_bus] FAIL case %0d: %s",
               case_id, message);
    endtask

    task automatic check_phase(
        input int case_id,
        input string phase,
        input logic [1:0] expected_trans
    );
        if (ADDR !== PREDICT_ADDR)
            fail(case_id, $sformatf(
                "%s address expected %08x got %08x",
                phase, PREDICT_ADDR, ADDR));
        if (TRANS !== expected_trans)
            fail(case_id, $sformatf(
                "%s TRANS expected %0b got %0b",
                phase, expected_trans, TRANS));
        if (SIZE !== 2'(SIZE_HALFWORD))
            fail(case_id, $sformatf(
                "%s SIZE expected halfword got %0b", phase, SIZE));
        if (PROT !== 2'(PROT_DAT_PRIV))
            fail(case_id, $sformatf(
                "%s PROT expected privileged-data got %0b", phase, PROT));
        if (WRITE !== WRITE_READ || LOCK !== LOCK_FREE || DMORE)
            fail(case_id, $sformatf(
                "%s controls W=%0b L=%0b DMORE=%0b",
                phase, WRITE, LOCK, DMORE));
    endtask

    task automatic setup_case(
        input logic [7:0] case_id,
        input logic [15:0] shift_opcode,
        input logic [31:0] value,
        input logic [31:0] amount
    );
        for (int word = 0; word < 256; word++)
            u_mem.mem[word] = 32'hEAFF_FFFE;

        u_mem.mem[0]  = 32'hEA00_0006; // reset: B 0x20
        for (int word = 1; word < 8; word++)
            u_mem.mem[word] = 32'hE7FF_FFFE;
        u_mem.mem[8]  = 32'hE59F_0058; // r0 <- value
        u_mem.mem[9]  = 32'hE59F_1058; // r1 <- amount
        u_mem.mem[10] = 32'hE59F_2058; // r2 <- Thumb target 0x41
        u_mem.mem[11] = 32'hE12F_FF12; // BX r2
        u_mem.mem[12] = 32'hE7FF_FFFE;
        u_mem.mem[16] = {16'h2700 | {8'h00, case_id},
                         shift_opcode};
        u_mem.mem[17] = 32'hE7FE_E7FE; // B .
        u_mem.mem[32] = value;
        u_mem.mem[33] = amount;
        u_mem.mem[34] = 32'h0000_0041;
    endtask

    task automatic run_case(
        input int case_id,
        input logic [15:0] shift_opcode,
        input logic [31:0] value,
        input logic [31:0] amount,
        input logic [31:0] expected_result
    );
        logic saw_execute;
        logic saw_commit;
        logic completed;

        @(negedge CLK);
        nRESET = 1'b0;
        repeat (4) @(posedge CLK);
        setup_case(8'(case_id), shift_opcode, value, amount);
        @(negedge CLK);
        nRESET = 1'b1;

        saw_execute = 1'b0;
        saw_commit  = 1'b0;
        completed   = 1'b0;

        for (int step = 0; step < 180; step++) begin
            @(negedge CLK);
            if (u_dut.u_core.state_q == 5'd0
                && u_dut.u_core.de_q.valid
                && u_dut.u_core.de_q.thumb
                && u_dut.u_core.de_q.pc == SHIFT_PC) begin
                if (saw_execute)
                    fail(case_id, "execute phase repeated");
                saw_execute = 1'b1;
                check_phase(case_id, "execute prediction", 2'(TRANS_I));
            end

            if (saw_execute && u_dut.u_core.state_q == 5'd9) begin
                if (saw_commit)
                    fail(case_id, "commit phase repeated");
                saw_commit = 1'b1;
                check_phase(case_id, "merged commit", 2'(TRANS_S));
            end

            if (u_dut.u_core.u_regfile.regs[7] == 32'(case_id)) begin
                completed = 1'b1;
                break;
            end
        end

        if (!saw_execute || !saw_commit || !completed)
            fail(case_id, "did not observe execute, commit, and marker");
        if (u_dut.u_core.u_regfile.regs[0] !== expected_result)
            fail(case_id, $sformatf(
                "result expected %08x got %08x",
                expected_result, u_dut.u_core.u_regfile.regs[0]));
    endtask

    initial begin
        run_case(1, 16'h4088, 32'h0000_0001, 32'h0000_0001,
                 32'h0000_0002); // LSL r0,r1
        run_case(2, 16'h40C8, 32'h8000_0000, 32'h0000_001F,
                 32'h0000_0001); // LSR r0,r1
        run_case(3, 16'h4108, 32'h8000_0000, 32'h0000_0004,
                 32'hF800_0000); // ASR r0,r1
        run_case(4, 16'h41C8, 32'h0000_0001, 32'h0000_0001,
                 32'h8000_0000); // ROR r0,r1

        $display("[thumb_reg_shift_bus] PASS (4 shift/phase rows)");
        $finish;
    end

    initial begin
        repeat (1000) @(posedge CLK);
        $fatal(1, "[thumb_reg_shift_bus] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused_outputs = &{1'b0,
        WDATA, RDATA, ABORT,
        CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI,
        DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG,
        DBGCOMMTX, DBGCOMMRX, DBGTDO, DBGnTDOEN
    };
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
