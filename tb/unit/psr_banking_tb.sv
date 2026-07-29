// ISA-017 exhaustive physical SPSR banking regression.
//
// ARM7TDMI-S has five physical SPSRs, selected by FIQ, IRQ, Supervisor,
// Abort, and Undefined mode. User and System have no SPSR. This test checks
// every write, read, restore, exception-save, absent-bank, reset, and mode
// transition route against an independent mode-to-bank reference map.

`timescale 1ns/1ps

module psr_banking_tb
    import arm7tdmis_psr_pkg::*;
    import arm7tdmis_types_pkg::*;
;

    localparam int SPSR_COUNT = 5;
    localparam int MODE_COUNT = 7;

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

    logic [31:0] expected_spsr [0:4];
    int unsigned errors;
    int unsigned operations;

    function automatic logic [4:0] bank_mode(input int bank);
        unique case (bank)
            0: return 5'(MODE_FIQ);
            1: return 5'(MODE_IRQ);
            2: return 5'(MODE_SUPERVISOR);
            3: return 5'(MODE_ABORT);
            default: return 5'(MODE_UNDEFINED);
        endcase
    endfunction

    function automatic logic [4:0] mode_at(input int index);
        unique case (index)
            0: return 5'(MODE_USER);
            1: return 5'(MODE_SYSTEM);
            2: return 5'(MODE_FIQ);
            3: return 5'(MODE_IRQ);
            4: return 5'(MODE_SUPERVISOR);
            5: return 5'(MODE_ABORT);
            default: return 5'(MODE_UNDEFINED);
        endcase
    endfunction

    function automatic int ref_bank(input logic [4:0] selected_mode);
        unique case (selected_mode)
            MODE_FIQ:        return 0;
            MODE_IRQ:        return 1;
            MODE_SUPERVISOR: return 2;
            MODE_ABORT:      return 3;
            MODE_UNDEFINED:  return 4;
            default:         return -1;
        endcase
    endfunction

    function automatic string mode_name(input logic [4:0] selected_mode);
        unique case (selected_mode)
            MODE_USER:       return "User";
            MODE_SYSTEM:     return "System";
            MODE_FIQ:        return "FIQ";
            MODE_IRQ:        return "IRQ";
            MODE_SUPERVISOR: return "Supervisor";
            MODE_ABORT:      return "Abort";
            MODE_UNDEFINED:  return "Undefined";
            default:         return "invalid";
        endcase
    endfunction

    function automatic logic [31:0] bank_value(input int bank);
        logic [31:0] value;
        value = 32'h0;
        value[31:28] = 4'(bank + 1);
        value[7:5] = 3'(bank);
        value[4:0] = MODE_SYSTEM;
        return value;
    endfunction

    function automatic psr_t exception_value(input int bank);
        psr_t value;
        value = '0;
        value.n = bank == 0;
        value.z = bank == 1;
        value.c = bank == 2;
        value.v = bank >= 3;
        value.reserved = 20'h51000 + 20'(bank);
        value.i = 1'b1;
        value.f = bank == 0;
        value.t = bank[0];
        value.m = bank_mode(bank);
        return value;
    endfunction

    task automatic fail(input string message);
        $display("[psr_banking] FAIL: %s", message);
        errors++;
    endtask

    task automatic check_physical(input string label);
        for (int bank = 0; bank < SPSR_COUNT; bank++) begin
            if (dut.spsr_q[bank] !== expected_spsr[bank])
                fail($sformatf(
                    "%s SPSR bank %0d expected %08x got %08x",
                    label, bank, expected_spsr[bank],
                    dut.spsr_q[bank]));
        end
    endtask

    task automatic write_cpsr(
        input logic [31:0] value,
        input logic [3:0]  mask
    );
        @(negedge CLK);
        cpsr_write_data = value;
        cpsr_write_mask = mask;
        cpsr_write_en   = 1'b1;
        @(posedge CLK);
        @(negedge CLK);
        cpsr_write_en = 1'b0;
        operations++;
    endtask

    task automatic select_mode(
        input logic [4:0] selected_mode,
        input logic [3:0] flags
    );
        logic [31:0] value;
        value = 32'h0;
        value[31:28] = flags;
        value[7:6] = 2'b11;
        value[4:0] = selected_mode;
        write_cpsr(value, 4'b1001);
        if (cpsr.m !== selected_mode || {cpsr.n, cpsr.z, cpsr.c, cpsr.v}
            !== flags)
            fail($sformatf(
                "select %s flags %x produced CPSR %08x",
                mode_name(selected_mode), flags, 32'(cpsr)));
    endtask

    task automatic write_current_spsr(input logic [31:0] value);
        int bank;

        bank = ref_bank(cpsr.m);
        @(negedge CLK);
        spsr_write_data = value;
        spsr_write_mask = 4'b1001;
        spsr_write_en   = 1'b1;
        @(posedge CLK);
        @(negedge CLK);
        spsr_write_en = 1'b0;
        operations++;
        if (bank >= 0)
            expected_spsr[bank] = value;
    endtask

    task automatic restore_current_spsr;
        @(negedge CLK);
        cpsr_restore_en = 1'b1;
        @(posedge CLK);
        @(negedge CLK);
        cpsr_restore_en = 1'b0;
        operations++;
    endtask

    task automatic enter_exception(
        input logic [2:0] bank,
        input psr_t new_cpsr
    );
        logic [31:0] saved_cpsr;

        saved_cpsr = 32'(cpsr);
        @(negedge CLK);
        exc_target_spsr_idx = 3'(bank);
        exc_new_cpsr        = new_cpsr;
        exc_enter_en        = 1'b1;
        @(posedge CLK);
        @(negedge CLK);
        exc_enter_en = 1'b0;
        expected_spsr[bank] = saved_cpsr;
        operations++;
    endtask

    task automatic apply_reset;
        @(negedge CLK);
        nRESET = 1'b0;
        repeat (2) @(posedge CLK);
        @(negedge CLK);
        for (int bank = 0; bank < SPSR_COUNT; bank++)
            expected_spsr[bank] = 32'h0;
        check_physical("reset");
        if (32'(cpsr) !== 32'(PSR_RESET_VALUE))
            fail($sformatf("reset CPSR expected %08x got %08x",
                           32'(PSR_RESET_VALUE), 32'(cpsr)));
        nRESET = 1'b1;
    endtask

    initial begin
        logic [31:0] before_absent;

        errors               = 0;
        operations           = 0;
        CLKEN                = 1'b1;
        nRESET               = 1'b1;
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
        for (int bank = 0; bank < SPSR_COUNT; bank++)
            expected_spsr[bank] = 32'h0;

        apply_reset();

        // Write a distinct valid value through each current-mode SPSR view.
        for (int bank = 0; bank < SPSR_COUNT; bank++) begin
            select_mode(bank_mode(bank), 4'(8 + bank));
            write_current_spsr(bank_value(bank));
            check_physical($sformatf("write bank %0d", bank));
            if (!spsr_valid || 32'(spsr) !== bank_value(bank))
                fail($sformatf(
                    "%s SPSR view expected %08x got valid=%0b data=%08x",
                    mode_name(bank_mode(bank)), bank_value(bank),
                    spsr_valid, 32'(spsr)));
        end

        // Exhaust visibility and validity in all seven modes.
        for (int mode_idx = 1; mode_idx < MODE_COUNT; mode_idx++) begin
            int bank;
            select_mode(mode_at(mode_idx), 4'(mode_idx));
            bank = ref_bank(mode_at(mode_idx));
            if (bank >= 0) begin
                if (!spsr_valid || 32'(spsr) !== expected_spsr[bank])
                    fail($sformatf(
                        "%s selected wrong SPSR expected %08x got %08x",
                        mode_name(mode_at(mode_idx)),
                        expected_spsr[bank], 32'(spsr)));
            end else if (spsr_valid || 32'(spsr) !== 32'h0) begin
                fail($sformatf("%s did not expose SPSR RAZ/invalid",
                               mode_name(mode_at(mode_idx))));
            end
            operations++;
        end

        // Restore independently from all five banks. Every seeded SPSR
        // returns to privileged System so the next mode remains selectable.
        for (int bank = 0; bank < SPSR_COUNT; bank++) begin
            select_mode(bank_mode(bank), 4'h0);
            restore_current_spsr();
            if (32'(cpsr) !== expected_spsr[bank])
                fail($sformatf(
                    "restore bank %0d expected CPSR %08x got %08x",
                    bank, expected_spsr[bank], 32'(cpsr)));
            check_physical($sformatf("restore bank %0d", bank));
        end

        // System has no SPSR: read zero and ignore write/restore.
        before_absent = 32'(cpsr);
        if (cpsr.m !== MODE_SYSTEM || spsr_valid || 32'(spsr) !== 32'h0)
            fail("System SPSR view was not RAZ/invalid");
        write_current_spsr(32'hF000_00D3);
        restore_current_spsr();
        if (32'(cpsr) !== before_absent)
            fail("System SPSR write/restore changed CPSR");
        check_physical("System SPSR write/restore");

        // Enter User from privileged System, then repeat the absent-bank
        // checks. Reset is the only transition used afterward.
        select_mode(MODE_USER, 4'hA);
        before_absent = 32'(cpsr);
        if (spsr_valid || 32'(spsr) !== 32'h0)
            fail("User SPSR view was not RAZ/invalid");
        write_current_spsr(32'hF000_00D3);
        restore_current_spsr();
        if (32'(cpsr) !== before_absent)
            fail("User SPSR write/restore changed CPSR");
        check_physical("User SPSR write/restore");

        // Start a clean phase and prove every exception target index saves
        // the complete old CPSR into the matching physical bank.
        apply_reset();
        for (int bank = 0; bank < SPSR_COUNT; bank++) begin
            psr_t new_cpsr;
            select_mode(MODE_SYSTEM, 4'(bank + 1));
            new_cpsr = exception_value(bank);
            enter_exception(3'(bank), new_cpsr);
            if (32'(cpsr) !== 32'(new_cpsr))
                fail($sformatf(
                    "exception bank %0d CPSR expected %08x got %08x",
                    bank, 32'(new_cpsr), 32'(cpsr)));
            if (!spsr_valid || 32'(spsr) !== expected_spsr[bank])
                fail($sformatf(
                    "exception bank %0d saved view expected %08x got %08x",
                    bank, expected_spsr[bank], 32'(spsr)));
            check_physical($sformatf("exception save bank %0d", bank));
        end

        // CLKEN suppresses writes and restores to every bank.
        CLKEN = 1'b0;
        spsr_write_data = 32'hFFFF_FFFF;
        spsr_write_mask = 4'hF;
        spsr_write_en = 1'b1;
        cpsr_restore_en = 1'b1;
        @(posedge CLK);
        @(negedge CLK);
        spsr_write_en = 1'b0;
        cpsr_restore_en = 1'b0;
        check_physical("CLKEN-low suppression");

        // Reset dominates simultaneous requests with CLKEN low.
        nRESET = 1'b0;
        spsr_write_en = 1'b1;
        exc_enter_en = 1'b1;
        @(posedge CLK);
        @(negedge CLK);
        for (int bank = 0; bank < SPSR_COUNT; bank++)
            expected_spsr[bank] = 32'h0;
        check_physical("reset priority");
        if (32'(cpsr) !== 32'(PSR_RESET_VALUE))
            fail("reset priority did not restore CPSR");

        if (errors != 0)
            $fatal(1, "[psr_banking] FAIL (%0d errors)", errors);
        $display("[psr_banking] PASS (%0d exhaustive operations)",
                 operations);
        $finish;
    end

    initial begin
        #1000000;
        $fatal(1, "[psr_banking] TIMEOUT");
    end

endmodule
