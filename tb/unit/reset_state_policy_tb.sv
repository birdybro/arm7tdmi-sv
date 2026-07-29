// ISA-016 / EXC-009 deterministic reset-state policy regression.
//
// ARMv4T does not give software useful values for the general-purpose
// register banks on Reset, and specifically describes r14_svc and SPSR_svc
// as UNPREDICTABLE.  The FPGA implementation deliberately initializes every
// GPR storage slot and every SPSR bank to zero.  These checks freeze that
// implementation policy; they are not an architectural promise to software.

module reset_state_policy_tb
    import arm7tdmis_instr_pkg::*;
    import arm7tdmis_psr_pkg::*;
    import arm7tdmis_types_pkg::*;
;

    logic CLK;
    initial begin
        CLK = 1'b0;
        forever #5 CLK = ~CLK;
    end

    logic CLKEN = 1'b0;
    logic nRESET = 1'b0;

    logic [4:0]  mode = MODE_SUPERVISOR;
    logic        t_bit = 1'b0;
    logic [31:0] pc_in = 32'hFFFF_FFFC;
    logic [3:0]  ra_addr = 4'd0;
    logic [3:0]  rb_addr = 4'd0;
    logic [3:0]  rc_addr = 4'd0;
    logic [31:0] ra_data;
    logic [31:0] rb_data;
    logic [31:0] rc_data;
    logic [3:0]  wa_addr = 4'd0;
    logic [31:0] wa_data = 32'hFFFF_FFFF;
    logic        wa_enable = 1'b0;
    logic        force_user_bank = 1'b0;
    logic        dbg_we = 1'b0;
    logic [3:0]  dbg_addr = 4'd0;
    logic [31:0] dbg_wdata = 32'hFFFF_FFFF;
    logic        dbg_force_user_bank = 1'b0;
    logic [31:0] dbg_rdata;
    logic        pc_written;

    psr_t cpsr;
    psr_t spsr;
    logic spsr_valid;
    logic        cpsr_write_en = 1'b0;
    logic [31:0] cpsr_write_data = 32'hFFFF_FFFF;
    logic [3:0]  cpsr_write_mask = 4'hF;
    logic        spsr_write_en = 1'b0;
    logic [31:0] spsr_write_data = 32'hFFFF_FFFF;
    logic [3:0]  spsr_write_mask = 4'hF;
    logic        cpsr_restore_en = 1'b0;
    logic        bx_set_t_en = 1'b0;
    logic        bx_set_t_value = 1'b1;
    logic        exc_enter_en = 1'b0;
    logic [2:0]  exc_target_spsr_idx = 3'd0;
    psr_t        exc_new_cpsr = psr_t'(32'hFFFF_FFFF);

    arm7tdmis_regfile u_regfile (
        .*
    );

    arm7tdmis_psr u_psr (
        .*
    );

    int unsigned errors = 0;

    task automatic fail(input string label);
        $display("FAIL [reset_state_policy]: %s", label);
        errors++;
    endtask

    initial begin
        // Reset must dominate CLKEN. Four active edges also make this test
        // independent of simulator initialization of unpacked arrays.
        repeat (4) @(posedge CLK);
        @(negedge CLK);

        for (int idx = 0; idx < 31; idx++) begin
            if (u_regfile.regs[idx] !== 32'h0000_0000)
                fail($sformatf(
                    "GPR storage slot %0d expected zero, got %08x",
                    idx, u_regfile.regs[idx]));
        end

        for (int idx = 0; idx < 5; idx++) begin
            if (u_psr.spsr_q[idx] !== 32'h0000_0000)
                fail($sformatf(
                    "SPSR bank %0d expected zero, got %08x",
                    idx, u_psr.spsr_q[idx]));
        end

        if (32'(cpsr) !== 32'(PSR_RESET_VALUE))
            fail($sformatf(
                "CPSR expected %08x, got %08x",
                32'(PSR_RESET_VALUE), 32'(cpsr)));
        if (32'(spsr) !== 32'h0000_0000 || !spsr_valid)
            fail("Supervisor SPSR reset view is not valid zero");
        if (pc_written)
            fail("reset exposed a spurious PC write");

        if (errors != 0)
            $fatal(1, "reset_state_policy_tb: FAIL (%0d errors)", errors);
        $display(
            "reset_state_policy_tb: PASS (31 storage slots, 5 SPSRs, CPSR)");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "reset_state_policy_tb: TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, ra_data, rb_data, rc_data, dbg_rdata};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
