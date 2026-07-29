// ISA-017 exhaustive physical GPR banking regression.
//
// ARM7TDMI-S exposes 31 physical general-purpose registers: 30 banked
// r0-r14 storage locations plus the shared PC. This test independently maps
// every logical register view in all seven modes, checks every physical
// storage location after every write, exhausts force-User and debug routes,
// and verifies PC visibility on all read ports in both instruction states.

`timescale 1ns/1ps

module regfile_banking_tb
    import arm7tdmis_types_pkg::*;
;

    localparam int MODE_COUNT = 7;
    localparam int LOGICAL_GPR_COUNT = 15;

    logic CLK;
    initial begin
        CLK = 1'b0;
        forever #5 CLK = ~CLK;
    end

    logic        CLKEN;
    logic        nRESET;
    logic [4:0]  mode;
    logic        t_bit;
    logic [31:0] pc_in;
    logic [3:0]  ra_addr, rb_addr, rc_addr;
    logic [31:0] ra_data, rb_data, rc_data;
    logic [3:0]  wa_addr;
    logic [31:0] wa_data;
    logic        wa_enable;
    logic        force_user_bank;
    logic        dbg_we;
    logic [3:0]  dbg_addr;
    logic [31:0] dbg_wdata;
    logic        dbg_force_user_bank;
    logic [31:0] dbg_rdata;
    logic        pc_written;

    arm7tdmis_regfile dut (.*);

    logic [31:0] expected [0:30];
    int unsigned errors;
    int unsigned operations;

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

    // Independent architectural reference map. Slot 15 is deliberately
    // absent: the shared PC lives in the core rather than the flat array.
    function automatic logic [4:0] ref_index(
        input logic [3:0] reg_num,
        input logic [4:0] selected_mode
    );
        if (reg_num <= 7)
            return 5'(reg_num);
        if (reg_num <= 12)
            return selected_mode == MODE_FIQ
                 ? 5'(reg_num) + 5'd8 : 5'(reg_num);
        unique case (selected_mode)
            MODE_USER, MODE_SYSTEM: return 5'(reg_num);
            MODE_FIQ:               return 5'(reg_num) + 5'd8;
            MODE_IRQ:               return 5'(reg_num) + 5'd10;
            MODE_SUPERVISOR:        return 5'(reg_num) + 5'd12;
            MODE_ABORT:             return 5'(reg_num) + 5'd14;
            MODE_UNDEFINED:         return 5'(reg_num) + 5'd16;
            default:                return 5'(reg_num);
        endcase
    endfunction

    function automatic logic [31:0] tag(
        input logic [7:0]  route,
        input logic [15:0] sequence_id
    );
        return {8'hA7, route, 16'(sequence_id)};
    endfunction

    task automatic fail(input string message);
        $display("[regfile_banking] FAIL: %s", message);
        errors++;
    endtask

    task automatic check_storage(input string label);
        for (int slot = 0; slot < 31; slot++) begin
            if (dut.regs[slot] !== expected[slot])
                fail($sformatf(
                    "%s slot %0d expected %08x got %08x",
                    label, slot, expected[slot], dut.regs[slot]));
        end
    endtask

    task automatic normal_write(
        input logic [4:0] selected_mode,
        input logic [3:0] reg_num,
        input logic       user_bank,
        input logic [31:0] value
    );
        logic [4:0] slot;

        slot = ref_index(reg_num,
                         user_bank ? 5'(MODE_USER) : selected_mode);
        @(negedge CLK);
        mode            = selected_mode;
        force_user_bank = user_bank;
        wa_addr         = 4'(reg_num);
        wa_data         = value;
        wa_enable       = 1'b1;
        @(posedge CLK);
        @(negedge CLK);
        wa_enable       = 1'b0;
        expected[slot]  = value;
        operations++;
        check_storage($sformatf(
            "normal write %s r%0d force_user=%0b",
            mode_name(selected_mode), reg_num, user_bank));
    endtask

    task automatic debug_write(
        input logic [4:0] selected_mode,
        input logic [3:0] reg_num,
        input logic       user_bank,
        input logic [31:0] value
    );
        logic [4:0] slot;

        slot = ref_index(reg_num,
                         user_bank ? 5'(MODE_USER) : selected_mode);
        @(negedge CLK);
        mode                = selected_mode;
        dbg_force_user_bank = user_bank;
        dbg_addr            = 4'(reg_num);
        dbg_wdata           = value;
        dbg_we              = 1'b1;
        @(posedge CLK);
        @(negedge CLK);
        dbg_we         = 1'b0;
        expected[slot] = value;
        operations++;
        check_storage($sformatf(
            "debug write %s r%0d force_user=%0b",
            mode_name(selected_mode), reg_num, user_bank));
    endtask

    task automatic check_view(
        input logic [4:0] selected_mode,
        input logic [3:0] reg_num,
        input logic       user_bank,
        input logic       debug_user_bank
    );
        logic [4:0] normal_slot;
        logic [4:0] debug_slot;
        string label;

        normal_slot = ref_index(reg_num,
            user_bank ? 5'(MODE_USER) : selected_mode);
        debug_slot = ref_index(reg_num,
            debug_user_bank ? 5'(MODE_USER) : selected_mode);
        label = $sformatf("%s r%0d force=%0b debug_force=%0b",
                          mode_name(selected_mode), reg_num,
                          user_bank, debug_user_bank);

        @(negedge CLK);
        mode                = selected_mode;
        force_user_bank     = user_bank;
        dbg_force_user_bank = debug_user_bank;
        ra_addr             = 4'(reg_num);
        rb_addr             = 4'(reg_num);
        rc_addr             = 4'(reg_num);
        dbg_addr            = 4'(reg_num);
        #1;
        if (ra_data !== expected[normal_slot])
            fail($sformatf("%s port A expected %08x got %08x",
                           label, expected[normal_slot], ra_data));
        if (rb_data !== expected[normal_slot])
            fail($sformatf("%s port B expected %08x got %08x",
                           label, expected[normal_slot], rb_data));
        if (rc_data !== expected[normal_slot])
            fail($sformatf("%s port C expected %08x got %08x",
                           label, expected[normal_slot], rc_data));
        if (dbg_rdata !== expected[debug_slot])
            fail($sformatf("%s debug port expected %08x got %08x",
                           label, expected[debug_slot], dbg_rdata));
        operations++;
    endtask

    task automatic check_pc_views;
        logic [31:0] expected_pc;

        for (int mode_idx = 0; mode_idx < MODE_COUNT; mode_idx++) begin
            for (int state_idx = 0; state_idx < 2; state_idx++) begin
                @(negedge CLK);
                mode                = mode_at(mode_idx);
                t_bit               = 1'(state_idx);
                force_user_bank     = 1'(mode_idx[0]);
                dbg_force_user_bank = !1'(mode_idx[0]);
                pc_in               = 32'hFFFF_FFF8
                                    + 32'(mode_idx * 2 + state_idx);
                ra_addr             = 4'd15;
                rb_addr             = 4'd15;
                rc_addr             = 4'd15;
                dbg_addr            = 4'd15;
                #1;
                expected_pc = pc_in + (state_idx == 0 ? 32'd8 : 32'd4);
                if (ra_data !== expected_pc || rb_data !== expected_pc
                    || rc_data !== expected_pc
                    || dbg_rdata !== expected_pc)
                    fail($sformatf(
                        "%s %s PC view expected %08x got A/B/C/D=%08x/%08x/%08x/%08x",
                        mode_name(mode_at(mode_idx)),
                        state_idx == 0 ? "ARM" : "Thumb",
                        expected_pc, ra_data, rb_data, rc_data, dbg_rdata));
                operations++;
            end
        end
    endtask

    initial begin
        errors                  = 0;
        operations              = 0;
        CLKEN                   = 1'b1;
        nRESET                  = 1'b0;
        mode                    = MODE_USER;
        t_bit                   = 1'b0;
        pc_in                   = 32'h0;
        ra_addr                 = 4'h0;
        rb_addr                 = 4'h0;
        rc_addr                 = 4'h0;
        wa_addr                 = 4'h0;
        wa_data                 = 32'h0;
        wa_enable               = 1'b0;
        force_user_bank         = 1'b0;
        dbg_we                  = 1'b0;
        dbg_addr                = 4'h0;
        dbg_wdata               = 32'h0;
        dbg_force_user_bank     = 1'b0;
        for (int slot = 0; slot < 31; slot++)
            expected[slot] = 32'h0;

        repeat (4) @(posedge CLK);
        @(negedge CLK);
        nRESET = 1'b1;
        check_storage("reset");

        // Exhaust every normal logical write route in every mode.
        for (int mode_idx = 0; mode_idx < MODE_COUNT; mode_idx++) begin
            for (int reg_num = 0; reg_num < LOGICAL_GPR_COUNT; reg_num++) begin
                normal_write(mode_at(mode_idx), 4'(reg_num), 1'b0,
                             tag(8'h10 + 8'(mode_idx),
                                 16'(mode_idx * LOGICAL_GPR_COUNT
                                     + reg_num)));
            end
        end

        // Exhaust all normal and debug read views after aliasing writes.
        for (int mode_idx = 0; mode_idx < MODE_COUNT; mode_idx++) begin
            for (int reg_num = 0; reg_num < LOGICAL_GPR_COUNT; reg_num++)
                check_view(mode_at(mode_idx), 4'(reg_num), 1'b0, 1'b0);
        end

        // LDM/STM^ routing: every non-User mode and logical GPR must select
        // the User bank for both reads and writes.
        for (int mode_idx = 1; mode_idx < MODE_COUNT; mode_idx++) begin
            for (int reg_num = 0; reg_num < LOGICAL_GPR_COUNT; reg_num++) begin
                check_view(mode_at(mode_idx), 4'(reg_num), 1'b1, 1'b1);
                normal_write(mode_at(mode_idx), 4'(reg_num), 1'b1,
                             tag(8'h40 + 8'(mode_idx),
                                 16'(mode_idx * LOGICAL_GPR_COUNT
                                     + reg_num)));
            end
        end

        // Debug current-bank writes work with CLKEN stopped.
        CLKEN = 1'b0;
        for (int mode_idx = 0; mode_idx < MODE_COUNT; mode_idx++) begin
            for (int reg_num = 0; reg_num < LOGICAL_GPR_COUNT; reg_num++) begin
                debug_write(mode_at(mode_idx), 4'(reg_num), 1'b0,
                            tag(8'h70 + 8'(mode_idx),
                                16'(mode_idx * LOGICAL_GPR_COUNT
                                    + reg_num)));
            end
        end

        // Debug LDM/STM^ routing likewise selects User storage from every
        // privileged mode while normal CLKEN remains stopped.
        for (int mode_idx = 1; mode_idx < MODE_COUNT; mode_idx++) begin
            for (int reg_num = 0; reg_num < LOGICAL_GPR_COUNT; reg_num++) begin
                debug_write(mode_at(mode_idx), 4'(reg_num), 1'b1,
                            tag(8'hB0 + 8'(mode_idx),
                                16'(mode_idx * LOGICAL_GPR_COUNT
                                    + reg_num)));
            end
        end
        CLKEN = 1'b1;

        check_pc_views();
        check_storage("after PC reads");

        // Normal PC writes produce only the core-facing request and never
        // touch flat storage.
        @(negedge CLK);
        wa_addr   = 4'd15;
        wa_data   = 32'h1234_5678;
        wa_enable = 1'b1;
        #1;
        if (!pc_written)
            fail("enabled r15 write did not assert pc_written");
        check_storage("enabled PC write");
        CLKEN = 1'b0;
        #1;
        if (pc_written)
            fail("pc_written ignored CLKEN");
        CLKEN     = 1'b1;
        wa_enable = 1'b0;

        // Debug r15 is read-only and reset dominates debug and normal writes,
        // even when CLKEN is stopped.
        dbg_addr  = 4'd15;
        dbg_wdata = 32'hDEAD_BEEF;
        dbg_we    = 1'b1;
        CLKEN     = 1'b0;
        @(posedge CLK);
        @(negedge CLK);
        dbg_we    = 1'b0;
        check_storage("debug PC write ignored");

        wa_addr   = 4'd8;
        wa_data   = 32'hFFFF_FFFF;
        wa_enable = 1'b1;
        dbg_addr  = 4'd13;
        dbg_wdata = 32'hFFFF_FFFF;
        dbg_we    = 1'b1;
        nRESET    = 1'b0;
        @(posedge CLK);
        @(negedge CLK);
        for (int slot = 0; slot < 31; slot++)
            expected[slot] = 32'h0;
        check_storage("reset priority");
        if (pc_written)
            fail("pc_written asserted during reset");

        if (errors != 0)
            $fatal(1, "[regfile_banking] FAIL (%0d errors)", errors);
        $display("[regfile_banking] PASS (%0d exhaustive operations)",
                 operations);
        $finish;
    end

    initial begin
        #1000000;
        $fatal(1, "[regfile_banking] TIMEOUT");
    end

endmodule
