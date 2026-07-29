// ISA-016 address-space rollover policy matrix.
//
// ARMv4T makes branch-target overflow, sequential instruction execution, and
// multiword transfers across the top of the 32-bit address space
// UNPREDICTABLE. This implementation uses ordinary modulo-2^32 address
// arithmetic. These checks freeze that project policy for ARM B/BL,
// Thumb B/conditional-B/BL, sequential execution in both states, ARM and
// Thumb LDM/STM, and Thumb PUSH/POP. They are not portable ARM software
// guarantees.

`timescale 1ns/1ps

module arm7tdmis_address_wrap_policy_tb
    import arm7tdmis_bus_pkg::*;
;

    localparam int CASE_COUNT = 13;

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

    // The low address bits intentionally alias the top of the address
    // space into the final two words. Raw ADDR is checked independently.
    arm7tdmis_memory #(
        .WORDS(256)
    ) u_mem (
        .CLK(CLK), .CLKEN(1'b1), .nRESET(nRESET),
        .CFGBIGEND(1'b0),
        .ADDR(ADDR), .WRITE(WRITE), .SIZE(SIZE), .PROT(PROT),
        .LOCK(LOCK), .TRANS(TRANS), .WDATA(WDATA), .RDATA(RDATA),
        .ABORT(ABORT), .inject_abort(1'b0)
    );

    int unsigned errors;

    function automatic logic is_thumb_case(input int case_id);
        return ((case_id >= 4) && (case_id <= 7)) || (case_id >= 10);
    endfunction

    function automatic logic is_sequential_case(input int case_id);
        return case_id inside {3, 7};
    endfunction

    function automatic logic [31:0] high_entry(input int case_id);
        if (case_id <= 3)
            return 32'hFFFF_FFF8;
        if (case_id inside {4, 5})
            return 32'hFFFF_FFFC;
        return 32'hFFFF_FFFA;
    endfunction

    function automatic logic [31:0] wrapped_target(input int case_id);
        return is_sequential_case(case_id)
             ? 32'h0000_0000 : 32'h0000_0040;
    endfunction

    task automatic fail(input int case_id, input string message);
        $display("[address_wrap_policy] FAIL case %0d: %s",
                 case_id, message);
        errors++;
    endtask

    task automatic setup_case(input int case_id);
        logic [31:0] entry_value;

        for (int word = 0; word < 256; word++)
            u_mem.mem[word] = 32'hEAFF_FFFE;

        entry_value = high_entry(case_id)
                    | (is_thumb_case(case_id) ? 32'h1 : 32'h0);

        u_mem.mem[0]  = 32'hEA00_0006; // reset: B 0x20
        u_mem.mem[8]  = 32'hE59F_0058; // r0 <- entry at 0x80
        u_mem.mem[9]  = 32'hE151_0001; // CMP r1,r1: taken Thumb BEQ
        u_mem.mem[10] = is_thumb_case(case_id)
                      ? 32'hE12F_FF10  // BX r0
                      : 32'hE1A0_F000; // MOV pc,r0
        u_mem.mem[11] = 32'hE3A0_50EE; // flushed setup successor
        u_mem.mem[32] = entry_value;

        unique case (case_id)
            1: begin
                // At 0xfffffff8, visible ARM PC wraps to zero.
                u_mem.mem[254] = 32'hEA00_0010; // B 0x40
                u_mem.mem[255] = 32'hE3A0_50EE; // flushed
            end
            2: begin
                u_mem.mem[254] = 32'hEB00_0010; // BL 0x40
                u_mem.mem[255] = 32'hE3A0_50EE; // flushed
            end
            3: begin
                u_mem.mem[254] = 32'hE3A0_1001; // r1 := 1
                u_mem.mem[255] = 32'hE3A0_2002; // r2 := 2
            end
            4: begin
                // At 0xfffffffc, visible Thumb PC wraps to zero.
                u_mem.mem[255] = 32'h25EE_E020; // B 0x40; flushed MOVS
            end
            5: begin
                u_mem.mem[255] = 32'h25EE_D020; // BEQ 0x40; flushed MOVS
            end
            6: begin
                // Prefix visible PC is 0xfffffffe; suffix adds 0x42.
                u_mem.mem[254] = 32'hF000_E7FE; // 0xfffffffa BL prefix
                u_mem.mem[255] = 32'h25EE_F821; // suffix; flushed MOVS
            end
            default: begin
                u_mem.mem[254] = 32'h2101_E7FE; // 0xfffffffa r1 := 1
                u_mem.mem[255] = 32'h2303_2202; // r2 := 2; r3 := 3
            end
        endcase

        if (!is_sequential_case(case_id)) begin
            if (is_thumb_case(case_id)) begin
                u_mem.mem[16] = {
                    16'hE7FE, (16'h2700 | 16'(case_id))
                };
            end else begin
                u_mem.mem[16] = 32'hE3A0_7000 | 32'(case_id);
                u_mem.mem[17] = 32'hEAFF_FFFE;
            end
        end
    endtask

    task automatic setup_transfer_case(input int case_id);
        logic [31:0] base_value;
        logic [31:0] opcode;

        for (int word = 0; word < 256; word++)
            u_mem.mem[word] = 32'hEAFF_FFFE;

        base_value = (case_id == 13)
                   ? 32'h0000_0004 : 32'hFFFF_FFFC;

        u_mem.mem[0]  = 32'hEA00_0006; // reset: B 0x20; second load word
        u_mem.mem[8]  = 32'hE59F_0058; // r0 <- 0xfffffffc
        u_mem.mem[9]  = 32'hE59F_1058; // r1 <- store seed 1
        u_mem.mem[10] = 32'hE59F_2058; // r2 <- store seed 2
        u_mem.mem[32] = 32'hFFFF_FFFC;
        u_mem.mem[33] = 32'h1111_1111;
        u_mem.mem[34] = 32'h2222_2222;
        u_mem.mem[255] = 32'hA1A2_A3A4;

        if (case_id <= 9) begin
            opcode = (case_id == 8)
                   ? 32'hE8B0_0006  // LDMIA r0!,{r1,r2}
                   : 32'hE8A0_0006; // STMIA r0!,{r1,r2}
            u_mem.mem[11] = opcode;
            u_mem.mem[12] = 32'hE3A0_7000 | 32'(case_id);
            u_mem.mem[13] = 32'hEAFF_FFFE;
        end else begin
            // Thumb cases additionally seed SP and enter at 0x40.
            u_mem.mem[11] = 32'hE59F_D058; // sp <- mem[35]
            u_mem.mem[12] = 32'hE59F_3058; // r3 <- Thumb target
            u_mem.mem[13] = 32'hE12F_FF13; // BX r3
            u_mem.mem[35] = base_value;
            u_mem.mem[36] = 32'h0000_0041;

            unique case (case_id)
                10: opcode = 32'h0000_C806; // LDMIA r0!,{r1,r2}
                11: opcode = 32'h0000_C006; // STMIA r0!,{r1,r2}
                12: opcode = 32'h0000_BC06; // POP {r1,r2}
                default: opcode = 32'h0000_B406; // PUSH {r1,r2}
            endcase
            u_mem.mem[16] = {
                (16'h2700 | 16'(case_id)), opcode[15:0]
            };
            u_mem.mem[17] = 32'hE7FE_E7FE;
        end
    endtask

    task automatic run_case(input int case_id);
        logic saw_high_fetch;
        logic saw_wrap_fetch;
        logic installed_zero_target;
        logic [1:0] expected_size;

        @(negedge CLK);
        nRESET = 1'b0;
        repeat (4) @(posedge CLK);
        setup_case(case_id);
        @(negedge CLK);
        nRESET = 1'b1;

        saw_high_fetch       = 1'b0;
        saw_wrap_fetch       = 1'b0;
        installed_zero_target = 1'b0;
        expected_size = is_thumb_case(case_id)
                      ? 2'(SIZE_HALFWORD) : 2'(SIZE_WORD);

        repeat (150) begin
            @(negedge CLK);
            if ((TRANS inside {TRANS_N, TRANS_S})
                && !WRITE && !PROT[PROT_BIT_DATA]) begin
                if (ADDR == high_entry(case_id)) begin
                    saw_high_fetch = 1'b1;
                    if (SIZE !== expected_size)
                        fail(case_id, "high entry fetch has wrong size");
                    if (is_sequential_case(case_id)
                        && !installed_zero_target) begin
                        // Reset has already retired. Install the opcode that
                        // sequential rollover must fetch at address zero.
                        u_mem.mem[0] = (case_id == 3)
                                     ? 32'hE3A0_7003
                                     : 32'hE7FE_2707;
                        installed_zero_target = 1'b1;
                    end
                end
                if (saw_high_fetch
                    && ADDR == wrapped_target(case_id)) begin
                    saw_wrap_fetch = 1'b1;
                    if (SIZE !== expected_size)
                        fail(case_id, "wrapped target fetch has wrong size");
                end
            end
        end

        if (!saw_high_fetch)
            fail(case_id, "top-of-address-space fetch was not observed");
        if (!saw_wrap_fetch)
            fail(case_id, "modulo-2^32 target fetch was not observed");
        if (u_dut.u_core.u_regfile.regs[7] !== 32'(case_id))
            fail(case_id, "wrapped completion marker did not retire");
        if (u_dut.u_core.u_regfile.regs[5] !== 32'h0000_0000)
            fail(case_id, "flushed successor executed");
        if (u_dut.u_core.cpsr.t !== is_thumb_case(case_id))
            fail(case_id, "wrapped execution state mismatch");

        if (case_id == 2
            && u_dut.u_core.u_regfile.regs[26] !== 32'hFFFF_FFFC)
            fail(case_id, "ARM BL link did not wrap-compatible commit");
        if (case_id == 3) begin
            if (u_dut.u_core.u_regfile.regs[1] !== 32'h0000_0001
             || u_dut.u_core.u_regfile.regs[2] !== 32'h0000_0002)
                fail(case_id, "ARM sequential high instructions did not retire");
        end
        if (case_id == 6
            && u_dut.u_core.u_regfile.regs[26] !== 32'hFFFF_FFFF)
            fail(case_id, "Thumb BL link did not wrap-compatible commit");
        if (case_id == 7) begin
            if (u_dut.u_core.u_regfile.regs[1] !== 32'h0000_0001
             || u_dut.u_core.u_regfile.regs[2] !== 32'h0000_0002
             || u_dut.u_core.u_regfile.regs[3] !== 32'h0000_0003)
                fail(case_id, "Thumb sequential high instructions did not retire");
        end
    endtask

    task automatic run_transfer_case(input int case_id);
        logic        is_load;
        logic [31:0] expected_base;
        int unsigned data_cycles;

        @(negedge CLK);
        nRESET = 1'b0;
        repeat (4) @(posedge CLK);
        setup_transfer_case(case_id);
        @(negedge CLK);
        nRESET = 1'b1;

        is_load = case_id inside {8, 10, 12};
        expected_base = (case_id == 13)
                      ? 32'hFFFF_FFFC : 32'h0000_0004;
        data_cycles = 0;

        repeat (150) begin
            @(negedge CLK);
            if ((TRANS inside {TRANS_N, TRANS_S})
                && PROT[PROT_BIT_DATA]
                && (ADDR inside {32'hFFFF_FFFC, 32'h0000_0000})) begin
                if (data_cycles >= 2) begin
                    fail(case_id, "issued more than two data beats");
                end else begin
                    if (ADDR !== (data_cycles == 0
                               ? 32'hFFFF_FFFC : 32'h0000_0000))
                        fail(case_id, $sformatf(
                            "beat %0d address expected %08x got %08x",
                            data_cycles,
                            data_cycles == 0
                                ? 32'hFFFF_FFFC : 32'h0000_0000,
                            ADDR));
                    if (SIZE !== 2'(SIZE_WORD)
                        || WRITE !== !is_load
                        || TRANS !== (data_cycles == 0
                                   ? 2'(TRANS_N) : 2'(TRANS_S)))
                        fail(case_id, $sformatf(
                            "beat %0d SIZE/WRITE/TRANS=%02b/%0b/%02b",
                            data_cycles, SIZE, WRITE, TRANS));
                    // ADDR describes the next transfer while DMORE
                    // describes the currently returning data transfer.
                    // It therefore rises with the second address phase,
                    // while the first beat is completing.
                    if (DMORE !== (data_cycles == 1))
                        fail(case_id, $sformatf(
                            "beat %0d DMORE expected %0b got %0b",
                            data_cycles, data_cycles == 1, DMORE));
                end
                data_cycles++;
            end
        end

        if (data_cycles != 2)
            fail(case_id, $sformatf(
                "expected two data beats, observed %0d", data_cycles));
        if (DMORE)
            fail(case_id, "DMORE remained asserted after the final beat");
        if (u_dut.u_core.u_regfile.regs[7] !== 32'(case_id))
            fail(case_id, "post-transfer completion marker did not retire");
        if (is_thumb_case(case_id) && !u_dut.u_core.cpsr.t)
            fail(case_id, "Thumb transfer left Thumb state");

        if (is_load) begin
            if (u_dut.u_core.u_regfile.regs[1] !== 32'hA1A2_A3A4
             || u_dut.u_core.u_regfile.regs[2] !== 32'hEA00_0006)
                fail(case_id, $sformatf(
                    "wrapped load data r1/r2=%08x/%08x",
                    u_dut.u_core.u_regfile.regs[1],
                    u_dut.u_core.u_regfile.regs[2]));
        end else begin
            if (u_mem.mem[255] !== 32'h1111_1111
             || u_mem.mem[0] !== 32'h2222_2222)
                fail(case_id, $sformatf(
                    "wrapped store memory=%08x/%08x",
                    u_mem.mem[255], u_mem.mem[0]));
        end

        if (case_id <= 11) begin
            if (u_dut.u_core.u_regfile.regs[0] !== expected_base)
                fail(case_id, "r0 writeback did not wrap modulo 2^32");
        end else if (u_dut.u_core.u_regfile.regs[25] !== expected_base) begin
            fail(case_id, "Supervisor SP writeback did not wrap modulo 2^32");
        end
    endtask

    initial begin
        errors = 0;
        for (int case_id = 1; case_id <= CASE_COUNT; case_id++) begin
            if (case_id <= 7)
                run_case(case_id);
            else
                run_transfer_case(case_id);
        end

        if (errors != 0)
            $fatal(1, "[address_wrap_policy] FAIL (%0d errors)", errors);
        $display("[address_wrap_policy] PASS (%0d reset-per-case rows)",
                 CASE_COUNT);
        $finish;
    end

    initial begin
        repeat (CASE_COUNT * 220) @(posedge CLK);
        $fatal(1, "[address_wrap_policy] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, LOCK, WDATA, ABORT, CPnMREQ, CPSEQ,
        CPnTRANS, CPnOPC, CPTBIT, CPnI, DBGACK, DBGnEXEC,
        DBGINSTRVALID, DBGRNG, DBGCOMMTX, DBGCOMMRX, DBGTDO,
        DBGnTDOEN, DMORE};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
