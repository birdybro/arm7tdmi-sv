// ISA-005 normal-execution r15 operand regression.
//
// Covers every distinct architectural PC value outside coprocessor/debug
// paths: ordinary ARM +8, ARM register-controlled-shift Rm +12, STR/STM
// store-data +12, ARM BL link, ordinary Thumb +4, and both Thumb
// word-aligned PC-relative forms from an address whose visible PC has bit 1.

`timescale 1ns/1ps

module arm7tdmis_pc_operands_tb;

    logic CLK;
    logic nRESET;

    arm7tdmis_test_fixture #(
        .CYCLE_LIMIT (360),
        .TEST_NAME   ("pc_operands"),
        .FST_FILE    ("pc_operands.fst")
    ) u_fixture (
        .CFGBIGEND   (1'b0),
        .CLKEN       (1'b1),
        .nIRQ        (1'b1),
        .nFIQ        (1'b1),
        .inject_abort(1'b0),
        .CLK,
        .nRESET
    );

    initial begin
        u_fixture.u_mem.mem[0] = 32'hEA00_000E; // B 0x40
        for (int word = 1; word < 8; word++)
            u_fixture.u_mem.mem[word] = 32'hE7FF_FFFE;

        u_fixture.u_mem.mem[16] = 32'hE1A0_000F; // 0x40 MOV r0,pc
        u_fixture.u_mem.mem[17] = 32'hE3A0_1000; // 0x44 MOV r1,#0
        u_fixture.u_mem.mem[18] = 32'hE1A0_211F; // 0x48 MOV r2,pc,LSL r1
        u_fixture.u_mem.mem[19] = 32'hE3A0_3C02; // 0x4C MOV r3,#0x200
        u_fixture.u_mem.mem[20] = 32'hE583_F000; // 0x50 STR pc,[r3]
        u_fixture.u_mem.mem[21] = 32'hE9A3_8000; // 0x54 STMIB r3!,{pc}
        u_fixture.u_mem.mem[22] = 32'hEB00_0004; // 0x58 BL 0x70
        for (int word = 23; word < 28; word++)
            u_fixture.u_mem.mem[word] = 32'hE7FF_FFFE;

        u_fixture.u_mem.mem[28] = 32'hE1A0_400E; // 0x70 MOV r4,lr
        u_fixture.u_mem.mem[29] = 32'hE3A0_5080; // 0x74 MOV r5,#0x80
        u_fixture.u_mem.mem[30] = 32'hE385_5001; // 0x78 ORR r5,r5,#1
        u_fixture.u_mem.mem[31] = 32'hE12F_FF15; // 0x7C BX r5

        // 0x80 MOV r6,pc; 0x82 LDR r7,[pc,#0x3C]. At 0x82 the
        // architectural base is (0x82+4)&~3 = 0x84, not 0x86.
        u_fixture.u_mem.mem[32] = 32'h4F0F_467E;
        // 0x84 NOP; 0x86 ADD r1,pc,#0. The aligned result is 0x88.
        u_fixture.u_mem.mem[33] = 32'hA100_46C0;
        u_fixture.u_mem.mem[34] = 32'hE7FE_E7FE; // 0x88 B 0x88

        u_fixture.u_mem.mem[48]  = 32'hCAFE_BABE; // literal at 0xC0
        u_fixture.u_mem.mem[128] = 32'hDEAD_0000; // STR destination 0x200
        u_fixture.u_mem.mem[129] = 32'hDEAD_0001; // STM destination 0x204
    end

    int unsigned errors = 0;

    task automatic check_reg(
        input logic [4:0] physical_idx,
        input logic [31:0] expected,
        input string label
    );
        if (u_fixture.u_dut.u_core.u_regfile.regs[physical_idx] !== expected) begin
            $display("[pc_operands] FAIL %s expected %08x got %08x",
                     label, expected,
                     u_fixture.u_dut.u_core.u_regfile.regs[physical_idx]);
            errors = errors + 1;
        end
    endtask

    initial begin
        wait (nRESET);
        repeat (240) @(posedge CLK);

        check_reg(0, 32'h0000_0048, "ARM ordinary MOV r0,pc (+8)");
        check_reg(2, 32'h0000_0054,
                  "ARM register-shift MOV r2,pc,LSL r1 (+12)");
        check_reg(3, 32'h0000_0204, "STMIB base writeback");
        check_reg(4, 32'h0000_005C, "ARM BL link value");
        check_reg(6, 32'h0000_0084, "Thumb MOV r6,pc (+4)");
        check_reg(7, 32'hCAFE_BABE, "Thumb aligned literal load");
        check_reg(1, 32'h0000_0088, "Thumb aligned ADD r1,pc,#0");

        if (u_fixture.u_mem.mem[128] !== 32'h0000_005C) begin
            $display("[pc_operands] FAIL STR pc expected 0000005C got %08x",
                     u_fixture.u_mem.mem[128]);
            errors = errors + 1;
        end
        if (u_fixture.u_mem.mem[129] !== 32'h0000_0060) begin
            $display("[pc_operands] FAIL STM pc expected 00000060 got %08x",
                     u_fixture.u_mem.mem[129]);
            errors = errors + 1;
        end
        if (!u_fixture.u_dut.u_core.cpsr.t
            || u_fixture.u_dut.u_core.pc_q !== 32'h0000_0088) begin
            $display("[pc_operands] FAIL final T/PC expected 1/00000088 got %0b/%08x",
                     u_fixture.u_dut.u_core.cpsr.t,
                     u_fixture.u_dut.u_core.pc_q);
            errors = errors + 1;
        end

        if (errors != 0)
            $fatal(1, "[pc_operands] FAIL (%0d errors)", errors);
        $display("[pc_operands] PASS");
        $finish;
    end

endmodule
