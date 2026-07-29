// ISA-016 invalid-SPSR exception-return policy regression.
//
// Reset initializes SPSR_svc and r14_svc to deterministic zero even though
// ARMv4T makes those reset values UNPREDICTABLE. MOVS pc immediately after
// reset therefore encounters an invalid restored mode. The selected safe
// policy is to reject the invalid SPSR restore, retain the complete current
// CPSR, and still commit the ordinary ARM-aligned PC result. This is project
// behavior, not a software-visible ARM guarantee.

`timescale 1ns/1ps

module arm7tdmis_invalid_spsr_return_policy_tb
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_psr_pkg::*;
    import arm7tdmis_types_pkg::*;
;

    localparam logic [31:0] RAW_TARGET = 32'h0000_0103;
    localparam logic [31:0] TARGET     = 32'h0000_0100;

    logic CLK;
    logic nRESET;

    arm7tdmis_test_fixture #(
        .CYCLE_LIMIT (220),
        .TEST_NAME   ("invalid_spsr_return_policy"),
        .FST_FILE    ("invalid_spsr_return_policy.fst")
    ) u_fixture (
        .CFGBIGEND   (1'b0),
        .CLKEN       (1'b1),
        .nIRQ        (1'b1),
        .nFIQ        (1'b1),
        .inject_abort(1'b0),
        .CLK,
        .nRESET
    );

    int unsigned errors = 0;
    logic target_fetch_seen;

    task automatic fail(input string message);
        $display("[invalid_spsr_return_policy] FAIL: %s", message);
        errors++;
    endtask

    initial begin
        for (int word = 0; word < 4096; word++)
            u_fixture.u_mem.mem[word] = 32'hEAFF_FFFE;

        u_fixture.u_mem.mem[0]  = 32'hEA00_0006; // reset: B 0x20
        u_fixture.u_mem.mem[8]  = 32'hE59F_0058; // LDR r0,[pc,#0x58]
        u_fixture.u_mem.mem[9]  = 32'hE1B0_F000; // MOVS pc,r0
        u_fixture.u_mem.mem[10] = 32'hE3A0_50EE; // flushed successor
        u_fixture.u_mem.mem[32] = RAW_TARGET;
        u_fixture.u_mem.mem[64] = 32'hE10F_6000; // target: MRS r6,CPSR
        u_fixture.u_mem.mem[65] = 32'hE3A0_7001; // completion marker
        u_fixture.u_mem.mem[66] = 32'hEAFF_FFFE;
    end

    always_ff @(negedge CLK) begin
        if (!nRESET) begin
            target_fetch_seen <= 1'b0;
        end else if (!target_fetch_seen
                  && (u_fixture.TRANS inside {TRANS_N, TRANS_S})
                  && !u_fixture.WRITE
                  && !u_fixture.PROT[PROT_BIT_DATA]
                  && (u_fixture.ADDR == TARGET)) begin
            target_fetch_seen <= 1'b1;
            if (u_fixture.SIZE !== 2'(SIZE_WORD))
                fail("redirected fetch was not an ARM word");
            if (!u_fixture.PROT[PROT_BIT_PRIV])
                fail("redirected fetch used the invalid SPSR mode privilege");
        end
    end

    initial begin
        wait (nRESET);
        repeat (150) @(posedge CLK);

        if (!target_fetch_seen)
            fail("aligned target fetch was not observed");
        if (u_fixture.u_dut.u_core.u_regfile.regs[5] !== 32'h0000_0000)
            fail("sequential successor after MOVS pc executed");
        if (u_fixture.u_dut.u_core.u_regfile.regs[7] !== 32'h0000_0001)
            fail("target completion marker did not retire");
        if (u_fixture.u_dut.u_core.u_regfile.regs[6]
            !== 32'(PSR_RESET_VALUE))
            fail($sformatf(
                "MRS observed %08x instead of retained reset CPSR %08x",
                u_fixture.u_dut.u_core.u_regfile.regs[6],
                32'(PSR_RESET_VALUE)));
        if (32'(u_fixture.u_dut.u_core.cpsr) !== 32'(PSR_RESET_VALUE))
            fail($sformatf(
                "final CPSR expected %08x got %08x",
                32'(PSR_RESET_VALUE), 32'(u_fixture.u_dut.u_core.cpsr)));
        if (u_fixture.u_dut.u_core.u_psr.spsr_q[2] !== 32'h0000_0000)
            fail("reset SPSR_svc policy value changed");

        if (errors != 0)
            $fatal(1, "[invalid_spsr_return_policy] FAIL (%0d errors)",
                   errors);
        $display("[invalid_spsr_return_policy] PASS");
        $finish;
    end

endmodule
