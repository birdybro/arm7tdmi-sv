// ISA-013 regression: an ARM instruction whose condition fails has no
// architectural or external side effects.  With Z=1, a sequence of NE
// register, flag, memory, SWP, multiply, coprocessor, undefined, SWI, and
// branch instructions must reduce to inert pipeline cycles.

module arm7tdmis_cond_suppress_tb
    import arm7tdmis_bus_pkg::*;
;

    logic CLK;
    logic nRESET;

    arm7tdmis_test_fixture #(
        .CYCLE_LIMIT (240),
        .INIT_HEX    ("../tb/programs/cond_suppress_test.hex"),
        .TEST_NAME   ("cond_suppress"),
        .FST_FILE    ("cond_suppress.fst")
    ) u_fixture (
        .CFGBIGEND   (1'b0),
        .CLKEN       (1'b1),
        .nIRQ        (1'b1),
        .nFIQ        (1'b1),
        .inject_abort(1'b0),
        .CLK         (CLK),
        .nRESET      (nRESET)
    );

    int unsigned data_cycles;
    int unsigned lock_cycles;
    int unsigned cp_request_cycles;

    always_ff @(posedge CLK or negedge nRESET) begin
        if (!nRESET) begin
            data_cycles      <= 0;
            lock_cycles      <= 0;
            cp_request_cycles <= 0;
        end else begin
            if ((u_fixture.TRANS inside {TRANS_N, TRANS_S})
                && u_fixture.PROT[PROT_BIT_DATA])
                data_cycles <= data_cycles + 1;
            if (u_fixture.LOCK)
                lock_cycles <= lock_cycles + 1;
            if (!u_fixture.CPnI)
                cp_request_cycles <= cp_request_cycles + 1;
        end
    end

    int unsigned errors = 0;

    initial begin
        wait (nRESET);
        repeat (170) @(posedge CLK);

        if (data_cycles != 0 || lock_cycles != 0) begin
            $display("[cond_suppress] FAIL data cycles=%0d LOCK cycles=%0d",
                     data_cycles, lock_cycles);
            errors = errors + 1;
        end

        if (cp_request_cycles != 0) begin
            $display("[cond_suppress] FAIL condition-failed MRC asserted CPnI for %0d cycles",
                     cp_request_cycles);
            errors = errors + 1;
        end

        for (int i = 1; i <= 7; i = i + 1) begin
            if (u_fixture.u_dut.u_core.u_regfile.regs[i] !== 32'h00000000) begin
                $display("[cond_suppress] FAIL r%0d changed to %08x",
                         i, u_fixture.u_dut.u_core.u_regfile.regs[i]);
                errors = errors + 1;
            end
        end

        if (u_fixture.u_dut.u_core.u_regfile.regs[8] !== 32'h00000055) begin
            $display("[cond_suppress] FAIL completion marker missing");
            errors = errors + 1;
        end

        if (u_fixture.u_dut.u_core.u_regfile.regs[9] !== 32'h00000000
            || u_fixture.u_dut.u_core.cpsr.m !== 5'b10011) begin
            $display("[cond_suppress] FAIL handler=%08x mode=%05b",
                     u_fixture.u_dut.u_core.u_regfile.regs[9],
                     u_fixture.u_dut.u_core.cpsr.m);
            errors = errors + 1;
        end

        if ({u_fixture.u_dut.u_core.cpsr.n,
             u_fixture.u_dut.u_core.cpsr.z,
             u_fixture.u_dut.u_core.cpsr.c,
             u_fixture.u_dut.u_core.cpsr.v} !== 4'b0110) begin
            $display("[cond_suppress] FAIL flags changed: NZCV=%04b",
                     {u_fixture.u_dut.u_core.cpsr.n,
                      u_fixture.u_dut.u_core.cpsr.z,
                      u_fixture.u_dut.u_core.cpsr.c,
                      u_fixture.u_dut.u_core.cpsr.v});
            errors = errors + 1;
        end

        if (errors != 0)
            $fatal(1, "[cond_suppress] FAIL (%0d errors)", errors);
        $display("[cond_suppress] PASS");
        $finish;
    end

endmodule
