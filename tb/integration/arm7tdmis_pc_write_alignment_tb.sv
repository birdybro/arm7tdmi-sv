// ISA-006 destination-state PC-write alignment matrix.
//
// Every row starts from reset and executes through the pin-level memory bus.
// It checks the first redirected opcode address/width as well as the PC and
// state that reach Execute.  Low address bits are deliberately set in every
// source value so the memory model's significant-address-bit behavior cannot
// hide a missing architectural alignment step.
//
// Rows: ARM MOV pc, register-shift MOV pc, LDR pc, LDM pc, Thumb POP pc,
// MOVS pc restoring Thumb, LDM^ pc restoring Thumb, MOVS pc restoring ARM,
// BX ARM->Thumb, BX Thumb->ARM, and Thumb MOV pc.

`timescale 1ns/1ps

module arm7tdmis_pc_write_alignment_tb
    import arm7tdmis_bus_pkg::*;
;

    localparam int CASE_COUNT = 11;

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
        $display("[pc_write_alignment] FAIL case %0d: %s", case_id, label);
        errors = errors + 1;
    endtask

    task automatic setup_case(
        input  int          case_id,
        output string       label,
        output logic [31:0] source_pc,
        output logic [31:0] target_pc,
        output logic        target_thumb
    );
        for (int word = 0; word < 128; word++)
            u_mem.mem[word] = 32'hE7FF_FFFE;

        u_mem.mem[0] = 32'hEA00_0006; // B 0x20

        unique case (case_id)
            1: begin
                label        = "ARM MOV pc";
                source_pc    = 32'h0000_0024;
                target_pc    = 32'h0000_0080;
                target_thumb = 1'b0;
                u_mem.mem[8]  = 32'hE59F_0038; // LDR r0,[pc,#0x38]
                u_mem.mem[9]  = 32'hE1A0_F000; // MOV pc,r0
                u_mem.mem[24] = 32'h0000_0083;
            end
            2: begin
                label        = "ARM register-shift MOV pc";
                source_pc    = 32'h0000_0024;
                target_pc    = 32'h0000_00A0;
                target_thumb = 1'b0;
                u_mem.mem[8]  = 32'hE59F_0038; // LDR r0,[pc,#0x38]
                u_mem.mem[9]  = 32'hE1A0_F110; // MOV pc,r0,LSL r1
                u_mem.mem[24] = 32'h0000_00A3;
            end
            3: begin
                label        = "ARM LDR pc";
                source_pc    = 32'h0000_0024;
                target_pc    = 32'h0000_00C0;
                target_thumb = 1'b0;
                u_mem.mem[8]  = 32'hE59F_1038; // LDR r1,[pc,#0x38]
                u_mem.mem[9]  = 32'hE591_F000; // LDR pc,[r1]
                u_mem.mem[24] = 32'h0000_0068;
                u_mem.mem[26] = 32'h0000_00C3;
            end
            4: begin
                label        = "ARM LDM pc";
                source_pc    = 32'h0000_0024;
                target_pc    = 32'h0000_00E0;
                target_thumb = 1'b0;
                u_mem.mem[8]  = 32'hE59F_1038; // LDR r1,[pc,#0x38]
                u_mem.mem[9]  = 32'hE891_8000; // LDMIA r1,{pc}
                u_mem.mem[24] = 32'h0000_0068;
                u_mem.mem[26] = 32'h0000_00E3;
            end
            5: begin
                label        = "Thumb POP pc";
                source_pc    = 32'h0000_0040;
                target_pc    = 32'h0000_0100;
                target_thumb = 1'b1;
                u_mem.mem[8]  = 32'hE59F_D038; // LDR sp,[pc,#0x38]
                u_mem.mem[9]  = 32'hE59F_2038; // LDR r2,[pc,#0x38]
                u_mem.mem[10] = 32'hE12F_FF12; // BX r2
                u_mem.mem[16] = 32'hE7FE_BD00; // POP {pc}; B .
                u_mem.mem[24] = 32'h0000_0068;
                u_mem.mem[25] = 32'h0000_0041;
                u_mem.mem[26] = 32'h0000_0101;
            end
            6: begin
                label        = "MOVS pc restores Thumb";
                source_pc    = 32'h0000_002C;
                target_pc    = 32'h0000_0120;
                target_thumb = 1'b1;
                u_mem.mem[8]  = 32'hE59F_0038; // LDR r0,[pc,#0x38]
                u_mem.mem[9]  = 32'hE59F_1038; // LDR r1,[pc,#0x38]
                u_mem.mem[10] = 32'hE161_F001; // MSR SPSR_c,r1
                u_mem.mem[11] = 32'hE1B0_F000; // MOVS pc,r0
                u_mem.mem[24] = 32'h0000_0121;
                u_mem.mem[25] = 32'h0000_0033; // SVC, T=1
            end
            7: begin
                label        = "LDM^ pc restores Thumb";
                source_pc    = 32'h0000_002C;
                target_pc    = 32'h0000_0140;
                target_thumb = 1'b1;
                u_mem.mem[8]  = 32'hE59F_1038; // LDR r1,[pc,#0x38]
                u_mem.mem[9]  = 32'hE59F_2038; // LDR r2,[pc,#0x38]
                u_mem.mem[10] = 32'hE161_F002; // MSR SPSR_c,r2
                u_mem.mem[11] = 32'hE8D1_8000; // LDMIA r1,{pc}^
                u_mem.mem[24] = 32'h0000_0068;
                u_mem.mem[25] = 32'h0000_0033; // SVC, T=1
                u_mem.mem[26] = 32'h0000_0141;
            end
            8: begin
                label        = "MOVS pc restores ARM";
                source_pc    = 32'h0000_002C;
                target_pc    = 32'h0000_0160;
                target_thumb = 1'b0;
                u_mem.mem[8]  = 32'hE59F_0038; // LDR r0,[pc,#0x38]
                u_mem.mem[9]  = 32'hE59F_1038; // LDR r1,[pc,#0x38]
                u_mem.mem[10] = 32'hE161_F001; // MSR SPSR_c,r1
                u_mem.mem[11] = 32'hE1B0_F000; // MOVS pc,r0
                u_mem.mem[24] = 32'h0000_0163;
                u_mem.mem[25] = 32'h0000_0013; // SVC, T=0
            end
            9: begin
                label        = "BX ARM to Thumb";
                source_pc    = 32'h0000_0024;
                target_pc    = 32'h0000_0180;
                target_thumb = 1'b1;
                u_mem.mem[8]  = 32'hE59F_0038; // LDR r0,[pc,#0x38]
                u_mem.mem[9]  = 32'hE12F_FF10; // BX r0
                u_mem.mem[24] = 32'h0000_0181;
            end
            10: begin
                label        = "BX Thumb to ARM";
                source_pc    = 32'h0000_0040;
                target_pc    = 32'h0000_01A0;
                target_thumb = 1'b0;
                u_mem.mem[8]  = 32'hE59F_0038; // LDR r0,[pc,#0x38]
                u_mem.mem[9]  = 32'hE59F_2038; // LDR r2,[pc,#0x38]
                u_mem.mem[10] = 32'hE12F_FF12; // BX r2
                u_mem.mem[16] = 32'hE7FE_4700; // BX r0; B .
                u_mem.mem[24] = 32'h0000_01A2;
                u_mem.mem[25] = 32'h0000_0041;
            end
            default: begin
                label        = "Thumb MOV pc";
                source_pc    = 32'h0000_0040;
                target_pc    = 32'h0000_01C0;
                target_thumb = 1'b1;
                u_mem.mem[8]  = 32'hE59F_0038; // LDR r0,[pc,#0x38]
                u_mem.mem[9]  = 32'hE59F_2038; // LDR r2,[pc,#0x38]
                u_mem.mem[10] = 32'hE12F_FF12; // BX r2
                u_mem.mem[16] = 32'hE7FE_4687; // MOV pc,r0; B .
                u_mem.mem[24] = 32'h0000_01C1;
                u_mem.mem[25] = 32'h0000_0041;
            end
        endcase

        if (target_thumb)
            u_mem.mem[target_pc[8:2]] =
                {16'hE7FE, (16'h2700 | 16'(case_id))}; // MOVS r7,#id; B .
        else begin
            u_mem.mem[target_pc[8:2]] =
                32'hE3A0_7000 | 32'(case_id);          // MOV r7,#id
            u_mem.mem[target_pc[8:2] + 1] = 32'hEAFF_FFFE; // B .
        end
    endtask

    task automatic run_case(input int case_id);
        string       label;
        logic [31:0] source_pc;
        logic [31:0] target_pc;
        logic        target_thumb;
        logic        redirect_seen;
        logic        target_fetch_seen;
        logic        target_exec_seen;
        logic        wait_for_fetch;
        logic        finished;

        @(negedge CLK);
        nRESET = 1'b0;
        repeat (4) @(posedge CLK);
        setup_case(case_id, label, source_pc, target_pc, target_thumb);
        @(negedge CLK);
        nRESET = 1'b1;

        redirect_seen    = 1'b0;
        target_fetch_seen = 1'b0;
        target_exec_seen = 1'b0;
        wait_for_fetch   = 1'b0;
        finished         = 1'b0;

        for (int step = 0; step < 180; step++) begin
            @(negedge CLK);

            if (!redirect_seen && u_dut.u_core.flush
                && ((u_dut.u_core.de_q.valid
                     && (u_dut.u_core.de_q.pc == source_pc))
                    || (u_dut.u_core.memory_instr_pc_q == source_pc)
                    || (u_dut.u_core.pc_q == source_pc))) begin
                redirect_seen = 1'b1;
                if (u_dut.u_core.early_flush_fetch) begin
                    target_fetch_seen = 1'b1;
                    if (ADDR !== target_pc)
                        fail(case_id, $sformatf(
                            "%s first fetch address expected %08x got %08x",
                            label, target_pc, ADDR));
                    if (SIZE !== (target_thumb ? 2'(SIZE_HALFWORD)
                                               : 2'(SIZE_WORD)))
                        fail(case_id, $sformatf(
                            "%s first fetch SIZE expected %0d got %0d",
                            label,
                            target_thumb ? SIZE_HALFWORD : SIZE_WORD, SIZE));
                end else begin
                    wait_for_fetch = 1'b1;
                end
            end else if (wait_for_fetch
                         && ((TRANS == 2'(TRANS_N))
                             || (TRANS == 2'(TRANS_S)))
                         && !WRITE && !PROT[0]) begin
                wait_for_fetch    = 1'b0;
                target_fetch_seen = 1'b1;
                if (ADDR !== target_pc)
                    fail(case_id, $sformatf(
                        "%s first fetch address expected %08x got %08x",
                        label, target_pc, ADDR));
                if (SIZE !== (target_thumb ? 2'(SIZE_HALFWORD)
                                           : 2'(SIZE_WORD)))
                    fail(case_id, $sformatf(
                        "%s first fetch SIZE expected %0d got %0d",
                        label, target_thumb ? SIZE_HALFWORD : SIZE_WORD, SIZE));
            end

            if (!target_exec_seen && u_dut.u_core.de_q.valid
                && ((target_thumb
                     && (u_dut.u_core.de_q.pc[31:1] == target_pc[31:1]))
                    || (!target_thumb
                        && (u_dut.u_core.de_q.pc[31:2]
                            == target_pc[31:2])))) begin
                target_exec_seen = 1'b1;
                if (u_dut.u_core.de_q.pc !== target_pc)
                    fail(case_id, $sformatf(
                        "%s Execute PC expected %08x got %08x",
                        label, target_pc, u_dut.u_core.de_q.pc));
                if (u_dut.u_core.de_q.thumb !== target_thumb
                    || u_dut.u_core.cpsr.t !== target_thumb)
                    fail(case_id, $sformatf(
                        "%s destination state expected %0b got de/cpsr=%0b/%0b",
                        label, target_thumb, u_dut.u_core.de_q.thumb,
                        u_dut.u_core.cpsr.t));
            end

            if (target_exec_seen && target_fetch_seen
                && (u_dut.u_core.u_regfile.regs[7] == 32'(case_id))) begin
                finished = 1'b1;
                break;
            end
        end

        if (!redirect_seen)
            fail(case_id, {label, " never redirected"});
        if (!target_fetch_seen)
            fail(case_id, {label, " never issued a target opcode fetch"});
        if (!target_exec_seen)
            fail(case_id, {label, " never reached the aligned target"});
        if (!finished)
            fail(case_id, {label, " target marker did not retire"});
    endtask

    initial begin
        errors = 0;
        for (int case_id = 1; case_id <= CASE_COUNT; case_id++)
            run_case(case_id);

        if (errors != 0)
            $fatal(1, "[pc_write_alignment] FAIL (%0d errors)", errors);
        $display("[pc_write_alignment] PASS (%0d cases)", CASE_COUNT);
        $finish;
    end

    initial begin
        repeat (2400) @(posedge CLK);
        $fatal(1, "[pc_write_alignment] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT,
                     CPnI, DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG,
                     DBGCOMMTX, DBGCOMMRX, DBGTDO, DBGnTDOEN, DMORE,
                     LOCK, WDATA, RDATA, ABORT};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
