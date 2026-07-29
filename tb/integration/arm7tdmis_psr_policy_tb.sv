// ISA-004 pin-level PSR transfer policy and MSR cycle regression.
//
// One architectural program checks privileged, User, and System behavior:
// reserved fields preserve, invalid modes reject their control field,
// User writes flags only, User/System MRS SPSR are RAZ and MSR SPSR are WI,
// and an attempted CPSR.T write stays in ARM state. The final all-field MSR
// is also measured at the E-stage boundary and must remain a one-cycle data
// operation per TRM Table 7-6.

`timescale 1ns/1ps

module arm7tdmis_psr_policy_tb;

    localparam logic [31:0] TIMED_MSR_PC = 32'h0000_00B4;

    logic CLK;
    logic nRESET;

    arm7tdmis_test_fixture #(
        .CYCLE_LIMIT (400),
        .TEST_NAME   ("psr_policy"),
        .FST_FILE    ("psr_policy.fst")
    ) u_fixture (
        .CFGBIGEND   (1'b0),
        .CLKEN       (1'b1),
        .nIRQ        (1'b1),
        .nFIQ        (1'b1),
        .inject_abort(1'b0),
        .CLK         (CLK),
        .nRESET      (nRESET)
    );

    initial begin
        // Reset vector -> main at 0x40. SWI vector -> System-mode phase
        // at 0xA0. Every unused vector traps locally.
        u_fixture.u_mem.mem[0] = 32'hEA00_000E; // B 0x40
        u_fixture.u_mem.mem[1] = 32'hEAFF_FFFE;
        u_fixture.u_mem.mem[2] = 32'hEA00_0024; // B 0xA0
        for (int word = 3; word < 8; word++)
            u_fixture.u_mem.mem[word] = 32'hEAFF_FFFE;

        // Supervisor phase.
        u_fixture.u_mem.mem[16] = 32'hE59F_00B8; // LDR r0,[pc,#0xB8]
        u_fixture.u_mem.mem[17] = 32'hE12F_F000; // MSR CPSR_fsxc,r0
        u_fixture.u_mem.mem[18] = 32'hE10F_1000; // MRS r1,CPSR
        u_fixture.u_mem.mem[19] = 32'hE16F_F000; // MSR SPSR_fsxc,r0
        u_fixture.u_mem.mem[20] = 32'hE14F_2000; // MRS r2,SPSR
        u_fixture.u_mem.mem[21] = 32'hE59F_30A8; // LDR r3,[pc,#0xA8]
        u_fixture.u_mem.mem[22] = 32'hE121_F003; // MSR CPSR_c,r3 -> FIQ
        u_fixture.u_mem.mem[23] = 32'hE16F_F003; // seed SPSR_fiq
        u_fixture.u_mem.mem[24] = 32'hE321_F0D0; // MSR CPSR_c,#0xD0 -> User

        // User phase. The FIQ SPSR is nonzero, so a default-index leak is
        // observable rather than accidentally reading a reset-zero bank.
        u_fixture.u_mem.mem[25] = 32'hE14F_4000; // MRS r4,SPSR -> RAZ
        u_fixture.u_mem.mem[26] = 32'hE16F_F000; // MSR SPSR_fsxc,r0 -> WI
        u_fixture.u_mem.mem[27] = 32'hE14F_5000; // MRS r5,SPSR -> RAZ
        u_fixture.u_mem.mem[28] = 32'hE12F_F000; // MSR CPSR_fsxc,r0
        u_fixture.u_mem.mem[29] = 32'hE10F_6000; // MRS r6,CPSR
        u_fixture.u_mem.mem[30] = 32'hEF00_0000; // SWI -> vector 0x08
        u_fixture.u_mem.mem[31] = 32'hEAFF_FFFE;

        // SWI handler branches here, then selects privileged System mode.
        u_fixture.u_mem.mem[40] = 32'hE321_F0DF; // MSR CPSR_c,#0xDF
        u_fixture.u_mem.mem[41] = 32'hE14F_8000; // MRS r8,SPSR -> RAZ
        u_fixture.u_mem.mem[42] = 32'hE16F_F000; // MSR SPSR_fsxc,r0 -> WI
        u_fixture.u_mem.mem[43] = 32'hE14F_9000; // MRS r9,SPSR -> RAZ
        u_fixture.u_mem.mem[44] = 32'hE59F_A050; // LDR r10,[pc,#0x50]
        u_fixture.u_mem.mem[45] = 32'hE12F_F00A; // MSR CPSR_fsxc,r10
        u_fixture.u_mem.mem[46] = 32'hE10F_B000; // MRS r11,CPSR
        u_fixture.u_mem.mem[47] = 32'hEAFF_FFFE; // B 0xBC

        u_fixture.u_mem.mem[64] = 32'hAFFF_FF14; // invalid M=10100
        u_fixture.u_mem.mem[65] = 32'h5000_00D1; // nonzero FIQ SPSR seed
        u_fixture.u_mem.mem[66] = 32'h5FFF_FFFF; // valid System, T attempt
    end

    logic        timed_msr_seen;
    logic        timed_msr_done;
    logic        saw_thumb_state;
    int unsigned timed_msr_cycles;

    always_ff @(negedge CLK) begin
        if (!nRESET) begin
            timed_msr_seen   <= 1'b0;
            timed_msr_done   <= 1'b0;
            saw_thumb_state  <= 1'b0;
            timed_msr_cycles <= 0;
        end else begin
            if (u_fixture.CPTBIT)
                saw_thumb_state <= 1'b1;

            if (!timed_msr_seen
                && u_fixture.u_dut.u_core.state_q == 5'd0
                && u_fixture.u_dut.u_core.de_q.valid
                && u_fixture.u_dut.u_core.de_q.pc == TIMED_MSR_PC) begin
                timed_msr_seen   <= 1'b1;
                timed_msr_cycles <= 1;
            end else if (timed_msr_seen && !timed_msr_done) begin
                if (u_fixture.u_dut.u_core.state_q == 5'd0
                    && u_fixture.u_dut.u_core.de_q.valid
                    && u_fixture.u_dut.u_core.de_q.pc != TIMED_MSR_PC)
                    timed_msr_done <= 1'b1;
                else
                    timed_msr_cycles <= timed_msr_cycles + 1;
            end
        end
    end

    int unsigned errors = 0;

    task automatic check_reg(
        input int unsigned idx,
        input logic [31:0] expected,
        input string label
    );
        if (u_fixture.u_dut.u_core.u_regfile.regs[idx] !== expected) begin
            $display("[psr_policy] FAIL %s r%0d expected %08x got %08x",
                     label, idx, expected,
                     u_fixture.u_dut.u_core.u_regfile.regs[idx]);
            errors = errors + 1;
        end
    endtask

    initial begin
        wait (nRESET);
        repeat (230) @(posedge CLK);

        check_reg(1,  32'hA000_00D3, "privileged invalid/reserved/T policy");
        check_reg(2,  32'hA000_0000, "SVC SPSR invalid/reserved policy");
        check_reg(4,  32'h0000_0000, "User MRS SPSR RAZ");
        check_reg(5,  32'h0000_0000, "User MSR SPSR WI");
        check_reg(6,  32'hA000_00D0, "User CPSR flags-only write");
        check_reg(8,  32'h0000_0000, "System MRS SPSR RAZ");
        check_reg(9,  32'h0000_0000, "System MSR SPSR WI");
        check_reg(11, 32'h5000_00DF, "System reserved/T policy");

        if (32'(u_fixture.u_dut.u_core.cpsr) !== 32'h5000_00DF) begin
            $display("[psr_policy] FAIL final CPSR expected 500000DF got %08x",
                     32'(u_fixture.u_dut.u_core.cpsr));
            errors = errors + 1;
        end
        if (!timed_msr_seen || !timed_msr_done || timed_msr_cycles != 1) begin
            $display("[psr_policy] FAIL timed MSR seen/done/cycles=%0b/%0b/%0d",
                     timed_msr_seen, timed_msr_done, timed_msr_cycles);
            errors = errors + 1;
        end
        if (saw_thumb_state) begin
            $display("[psr_policy] FAIL MSR T-bit attempt entered Thumb state");
            errors = errors + 1;
        end
        if (u_fixture.u_dut.u_core.pc_q !== 32'h0000_00BC) begin
            $display("[psr_policy] FAIL final PC expected 000000BC got %08x",
                     u_fixture.u_dut.u_core.pc_q);
            errors = errors + 1;
        end

        if (errors != 0)
            $fatal(1, "[psr_policy] FAIL (%0d errors)", errors);
        $display("[psr_policy] PASS");
        $finish;
    end

endmodule
