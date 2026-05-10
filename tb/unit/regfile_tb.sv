// Unit test for arm7tdmis_regfile.
//
// Coverage:
//   - Reset clears all 31 GPRs to 0
//   - Shared-register write/read (r5)
//   - Banked r13 across User vs Supervisor
//   - Banked r8 across User vs FIQ
//   - PC read returns stored + PC_AHEAD_ARM (8) in ARM, + PC_AHEAD_THUMB (4) in Thumb
//   - pc_written asserts when r15 is written
//   - System mode shares User register set (no SPSR but same r0..r14)
//   - force_user_bank overrides current mode for read

module regfile_tb
    import arm7tdmis_types_pkg::*;
;

    localparam int CLK_HALF = 5;

    logic CLK;
    initial begin
        CLK = 1'b0;
        forever #(CLK_HALF) CLK = ~CLK;
    end

    logic        CLKEN;
    logic        nRESET;
    logic [4:0]  mode;
    logic        t_bit;
    logic [3:0]  ra_addr, rb_addr, rc_addr, wa_addr;
    logic [31:0] ra_data, rb_data, rc_data, wa_data;
    logic        wa_enable;
    logic        force_user_bank;
    logic        pc_written;

    arm7tdmis_regfile dut (.*);

    // The test only sources from port A; tag B/C as intentionally unused so
    // the lint stays clean while the additional ports stand ready for
    // multi-source-operand tests.
    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused_rbc = &{1'b0, rb_data, rc_data};
    /* verilator lint_on UNUSEDSIGNAL */

    int errors;

    task automatic check32(string label, logic [31:0] actual, logic [31:0] expected);
        if (actual !== expected) begin
            $display("FAIL [%s]: expected %08x, got %08x", label, expected, actual);
            errors = errors + 1;
        end
    endtask

    task automatic check1(string label, logic actual, logic expected);
        if (actual !== expected) begin
            $display("FAIL [%s]: expected %0b, got %0b", label, expected, actual);
            errors = errors + 1;
        end
    endtask

    // Drive a single-cycle write (called from initial — uses event control)
    task automatic write_reg(input logic [3:0] addr, input logic [31:0] data,
                             input logic [4:0] m);
        @(negedge CLK);
        mode      = m;
        wa_addr   = addr;
        wa_data   = data;
        wa_enable = 1'b1;
        @(posedge CLK);
        @(negedge CLK);
        wa_enable = 1'b0;
    endtask

    initial begin
        // Initial values
        errors          = 0;
        CLKEN           = 1'b1;
        nRESET          = 1'b0;
        mode            = MODE_USER;
        t_bit           = 1'b0;
        ra_addr         = 4'd0;
        rb_addr         = 4'd0;
        rc_addr         = 4'd0;
        wa_addr         = 4'd0;
        wa_data         = 32'h0;
        wa_enable       = 1'b0;
        force_user_bank = 1'b0;

        // Hold reset for a few cycles
        repeat (4) @(posedge CLK);
        @(negedge CLK);
        nRESET = 1'b1;
        @(posedge CLK);

        // T1: post-reset, all registers read 0 (sample r5)
        @(negedge CLK);
        ra_addr = 4'd5;
        @(negedge CLK);
        check32("r5 reset", ra_data, 32'h0);

        // T2: write/read r5 (shared)
        write_reg(4'd5, 32'h12345678, MODE_USER);
        ra_addr = 4'd5;
        @(negedge CLK);
        check32("r5 write/read", ra_data, 32'h12345678);

        // T3: r13 banking — User vs Supervisor
        write_reg(4'd13, 32'hAAAA0000, MODE_USER);
        write_reg(4'd13, 32'hBBBB0000, MODE_SUPERVISOR);
        @(negedge CLK);
        mode = MODE_USER;     ra_addr = 4'd13;
        @(negedge CLK);
        check32("r13 user", ra_data, 32'hAAAA0000);
        @(negedge CLK);
        mode = MODE_SUPERVISOR; ra_addr = 4'd13;
        @(negedge CLK);
        check32("r13 svc", ra_data, 32'hBBBB0000);

        // T4: r8 banking — User vs FIQ
        write_reg(4'd8, 32'hCCCC0000, MODE_USER);
        write_reg(4'd8, 32'hDDDD0000, MODE_FIQ);
        @(negedge CLK);
        mode = MODE_USER; ra_addr = 4'd8;
        @(negedge CLK);
        check32("r8 user", ra_data, 32'hCCCC0000);
        @(negedge CLK);
        mode = MODE_FIQ; ra_addr = 4'd8;
        @(negedge CLK);
        check32("r8 fiq", ra_data, 32'hDDDD0000);

        // T5: PC read offset in ARM state (+8)
        write_reg(4'd15, 32'h00001000, MODE_USER);
        @(negedge CLK);
        mode = MODE_USER; t_bit = 1'b0; ra_addr = 4'd15;
        @(negedge CLK);
        check32("PC ARM", ra_data, 32'h00001008);

        // T6: PC read offset in Thumb state (+4)
        @(negedge CLK);
        t_bit = 1'b1;
        @(negedge CLK);
        check32("PC Thumb", ra_data, 32'h00001004);

        // Reset Thumb bit so subsequent PC writes via write_reg behave as ARM
        @(negedge CLK);
        t_bit = 1'b0;

        // T7: pc_written asserts during r15 write
        @(negedge CLK);
        wa_addr   = 4'd15;
        wa_data   = 32'h00002000;
        wa_enable = 1'b1;
        @(posedge CLK);
        // Sample shortly after the rising edge
        #1;
        check1("pc_written", pc_written, 1'b1);
        @(negedge CLK);
        wa_enable = 1'b0;
        @(posedge CLK);
        #1;
        check1("pc_written cleared", pc_written, 1'b0);

        // T8: System mode shares User registers
        write_reg(4'd13, 32'hEEEE0000, MODE_USER);
        @(negedge CLK);
        mode = MODE_SYSTEM; ra_addr = 4'd13;
        @(negedge CLK);
        check32("r13 system shares user", ra_data, 32'hEEEE0000);

        // T9: force_user_bank overrides mode for reads
        write_reg(4'd13, 32'h11111111, MODE_USER);
        write_reg(4'd13, 32'h22222222, MODE_IRQ);
        @(negedge CLK);
        mode = MODE_IRQ; ra_addr = 4'd13; force_user_bank = 1'b1;
        @(negedge CLK);
        check32("r13 IRQ + force_user_bank", ra_data, 32'h11111111);
        @(negedge CLK);
        force_user_bank = 1'b0;

        // Wrap up
        if (errors == 0) begin
            $display("regfile_tb: PASS");
            $finish;
        end else begin
            $fatal(1, "regfile_tb: FAIL (%0d errors)", errors);
        end
    end

    // Watchdog
    initial begin
        #100000;
        $fatal(1, "regfile_tb: TIMEOUT");
    end

endmodule
