// ISA-004 policy regression for architecturally reserved/UNPREDICTABLE PSR
// operations. The soft-core policy is deterministic and recoverable:
//   * CPSR/SPSR[27:8] preserve their prior value on every MSR field write;
//   * a selected control byte whose M[4:0] is not one of the seven ARMv4T
//     modes is rejected, while independently selected flags still commit;
//   * CPSR.T writes through MSR are dropped;
//   * User/System have no SPSR: the read view is zero and write/restore are
//     ignored; and
//   * User can update CPSR.NZCV but cannot update privileged controls.

`timescale 1ns/1ps

module psr_policy_tb
    import arm7tdmis_psr_pkg::*;
    import arm7tdmis_types_pkg::*;
;

    logic CLK;
    initial begin
        CLK = 1'b0;
        forever #5 CLK = ~CLK;
    end

    logic        CLKEN;
    logic        nRESET;
    psr_t        cpsr;
    psr_t        spsr;
    logic        spsr_valid;
    logic        cpsr_write_en;
    logic [31:0] cpsr_write_data;
    logic [3:0]  cpsr_write_mask;
    logic        spsr_write_en;
    logic [31:0] spsr_write_data;
    logic [3:0]  spsr_write_mask;
    logic        cpsr_restore_en;
    logic        bx_set_t_en;
    logic        bx_set_t_value;
    logic        exc_enter_en;
    logic [2:0]  exc_target_spsr_idx;
    psr_t        exc_new_cpsr;

    arm7tdmis_psr dut (.*);

    int unsigned errors;

    task automatic check32(
        input string label,
        input logic [31:0] actual,
        input logic [31:0] expected
    );
        if (actual !== expected) begin
            $display("[psr_policy] FAIL %s expected %08x got %08x",
                     label, expected, actual);
            errors = errors + 1;
        end
    endtask

    task automatic write_cpsr(
        input logic [31:0] data,
        input logic [3:0] mask
    );
        @(negedge CLK);
        cpsr_write_data = data;
        cpsr_write_mask = mask;
        cpsr_write_en   = 1'b1;
        @(posedge CLK);
        @(negedge CLK);
        cpsr_write_en = 1'b0;
    endtask

    task automatic write_spsr(
        input logic [31:0] data,
        input logic [3:0] mask
    );
        @(negedge CLK);
        spsr_write_data = data;
        spsr_write_mask = mask;
        spsr_write_en   = 1'b1;
        @(posedge CLK);
        @(negedge CLK);
        spsr_write_en = 1'b0;
    endtask

    task automatic enter_exception(
        input psr_t value,
        input logic [2:0] bank
    );
        @(negedge CLK);
        exc_new_cpsr        = value;
        exc_target_spsr_idx = bank;
        exc_enter_en        = 1'b1;
        @(posedge CLK);
        @(negedge CLK);
        exc_enter_en = 1'b0;
    endtask

    task automatic restore_cpsr;
        @(negedge CLK);
        cpsr_restore_en = 1'b1;
        @(posedge CLK);
        @(negedge CLK);
        cpsr_restore_en = 1'b0;
    endtask

    initial begin
        psr_t seeded_cpsr;

        errors               = 0;
        CLKEN                = 1'b1;
        nRESET               = 1'b0;
        cpsr_write_en        = 1'b0;
        cpsr_write_data      = 32'h0;
        cpsr_write_mask      = 4'h0;
        spsr_write_en        = 1'b0;
        spsr_write_data      = 32'h0;
        spsr_write_mask      = 4'h0;
        cpsr_restore_en      = 1'b0;
        bx_set_t_en          = 1'b0;
        bx_set_t_value       = 1'b0;
        exc_enter_en         = 1'b0;
        exc_target_spsr_idx  = 3'd0;
        exc_new_cpsr         = '0;

        repeat (4) @(posedge CLK);
        @(negedge CLK);
        nRESET = 1'b1;

        // Seed nonzero reserved storage through the atomic exception path,
        // then prove every software-reserved field is read-modify-write
        // preserved rather than merely stuck at reset zero.
        seeded_cpsr          = PSR_RESET_VALUE;
        seeded_cpsr.reserved = 20'hABCDE;
        enter_exception(seeded_cpsr, 3'd2);
        check32("seeded CPSR", 32'(cpsr), 32'h0ABC_DED3);

        write_cpsr(32'h0054_3200, 4'b0110);
        check32("CPSR x/s fields preserve reserved bits",
                32'(cpsr), 32'h0ABC_DED3);

        // Invalid mode 10100 rejects only the selected control field. The
        // independently selected flags nibble still updates to 1010.
        write_cpsr(32'hA000_0014, 4'b1001);
        check32("invalid CPSR mode rejected per field",
                32'(cpsr), 32'hAABC_DED3);

        // A valid control write can change mode, I/F, but an attempted T=1
        // is dropped by the frozen ARM7TDMI-S policy.
        write_cpsr(32'h0000_00F1, 4'b0001);
        check32("valid CPSR control with T drop",
                32'(cpsr), 32'hAABC_DED1);
        check32("FIQ has SPSR", 32'(spsr_valid), 32'd1);

        // Exercise SPSR preservation and the same invalid-mode policy in FIQ.
        write_spsr(32'h5000_00D3, 4'b1001);
        check32("valid SPSR flags/control", 32'(spsr), 32'h5000_00D3);
        write_spsr(32'h0FED_CB00, 4'b0110);
        check32("SPSR x/s fields preserve", 32'(spsr), 32'h5000_00D3);
        write_spsr(32'hA000_0014, 4'b1001);
        check32("invalid SPSR mode rejected per field",
                32'(spsr), 32'hA000_00D3);

        // Enter User directly from privileged FIQ. Its absent SPSR must not
        // expose the FIQ bank selected by the internal default index.
        write_cpsr(32'h0000_00D0, 4'b0001);
        check32("entered User", 32'(cpsr.m), 32'(MODE_USER));
        check32("User has no SPSR", 32'(spsr_valid), 32'd0);
        check32("User SPSR RAZ", 32'(spsr), 32'h0);

        write_spsr(32'hFFFF_FFFF, 4'b1111);
        check32("User SPSR write ignored", 32'(spsr), 32'h0);
        restore_cpsr();
        check32("User SPSR restore ignored", 32'(cpsr.m), 32'(MODE_USER));

        write_cpsr(32'h5FFF_FFD3, 4'b1111);
        check32("User writes flags only",
                32'(cpsr), 32'h5ABC_DED0);

        // Return to SVC through the architectural exception path, then
        // enter System. System is privileged but shares User's bank and
        // likewise has no SPSR.
        seeded_cpsr          = PSR_RESET_VALUE;
        seeded_cpsr.reserved = 20'hABCDE;
        enter_exception(seeded_cpsr, 3'd2);
        write_cpsr(32'h0000_00DF, 4'b0001);
        check32("entered System", 32'(cpsr.m), 32'(MODE_SYSTEM));
        check32("System has no SPSR", 32'(spsr_valid), 32'd0);
        check32("System SPSR RAZ", 32'(spsr), 32'h0);

        write_spsr(32'hFFFF_FFFF, 4'b1111);
        restore_cpsr();
        check32("System SPSR write/restore ignored",
                32'(cpsr), 32'h0ABC_DEDF);

        if (errors != 0)
            $fatal(1, "psr_policy_tb: FAIL (%0d errors)", errors);
        $display("psr_policy_tb: PASS");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "psr_policy_tb: TIMEOUT");
    end

endmodule
