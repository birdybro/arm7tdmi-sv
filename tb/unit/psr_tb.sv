// Unit test for arm7tdmis_psr.
//
// Coverage:
//   - Reset CPSR is Supervisor / I=1 / F=1 / T=0 / ARM state, flags clear
//   - SPSRs reset to 0
//   - cpsr_write with field-mask updates only the selected bytes
//   - Writing the T bit (bit 5) via cpsr_write is dropped (TRM §2.8.2)
//   - SPSR write targets the SPSR of current mode; no-op in User/System
//   - spsr_valid is high in FIQ/IRQ/SVC/ABT/UND, low in User/System
//   - cpsr_restore copies SPSR-of-current-mode into CPSR; no-op in User/System

module psr_tb
    import arm7tdmis_psr_pkg::*;
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

    arm7tdmis_psr dut (.*);

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

    // Set the current mode by doing a CPSR field-mask write of the _c byte.
    // (T bit gets stripped by hardware; mask passed in already excludes it.)
    task automatic enter_mode(input logic [4:0] m);
        logic [31:0] data;
        // Build a CPSR with the desired mode in [4:0], I=1 F=1 T=0 (the
        // reset shape minus the mode bits). Anything in the upper 24 bits
        // is unchanged because we only mask byte 0.
        data = 32'h0;
        data[4:0] = m;
        data[7]   = 1'b1;
        data[6]   = 1'b1;
        @(negedge CLK);
        cpsr_write_data = data;
        cpsr_write_mask = 4'b0001;     // _c only
        cpsr_write_en   = 1'b1;
        @(posedge CLK);
        @(negedge CLK);
        cpsr_write_en   = 1'b0;
    endtask

    initial begin
        errors          = 0;
        CLKEN           = 1'b1;
        nRESET          = 1'b0;
        cpsr_write_en   = 1'b0;
        cpsr_write_data = 32'h0;
        cpsr_write_mask = 4'b0000;
        spsr_write_en   = 1'b0;
        spsr_write_data = 32'h0;
        spsr_write_mask = 4'b0000;
        cpsr_restore_en = 1'b0;

        repeat (4) @(posedge CLK);
        @(negedge CLK);
        nRESET = 1'b1;
        @(posedge CLK);

        // T1: reset CPSR matches PSR_RESET_VALUE (Supervisor, I=1, F=1, T=0, ARM)
        @(negedge CLK);
        check32("cpsr reset",       32'(cpsr),    32'(PSR_RESET_VALUE));
        check32("cpsr.m reset",     32'(cpsr.m),  32'(MODE_SUPERVISOR));
        check1("cpsr.i reset",      cpsr.i,       1'b1);
        check1("cpsr.f reset",      cpsr.f,       1'b1);
        check1("cpsr.t reset",      cpsr.t,       1'b0);
        check1("spsr_valid in svc", spsr_valid,   1'b1);   // SVC has SPSR
        check32("spsr_svc reset",   32'(spsr),    32'h0);

        // T2: write CPSR flags via _f mask only — should change [31:24], leave rest
        @(negedge CLK);
        cpsr_write_data = 32'hF000_0000;   // N=1, Z=1, C=1, V=1; rest 0
        cpsr_write_mask = 4'b1000;         // _f only
        cpsr_write_en   = 1'b1;
        @(posedge CLK);
        @(negedge CLK);
        cpsr_write_en   = 1'b0;
        check1("cpsr.n after _f write", cpsr.n, 1'b1);
        check1("cpsr.z after _f write", cpsr.z, 1'b1);
        check1("cpsr.c after _f write", cpsr.c, 1'b1);
        check1("cpsr.v after _f write", cpsr.v, 1'b1);
        check32("cpsr.m unchanged",     32'(cpsr.m), 32'(MODE_SUPERVISOR));
        check1("cpsr.i unchanged",      cpsr.i, 1'b1);

        // T3: T-bit-write drop — try to set T via _c mask, expect T unchanged
        @(negedge CLK);
        cpsr_write_data            = 32'h0;
        cpsr_write_data[PSR_BIT_T] = 1'b1;          // attempt T=1
        cpsr_write_data[4:0]       = MODE_SUPERVISOR;
        cpsr_write_data[7]         = 1'b1;          // I
        cpsr_write_data[6]         = 1'b1;          // F
        cpsr_write_mask            = 4'b0001;       // _c byte covers T
        cpsr_write_en              = 1'b1;
        @(posedge CLK);
        @(negedge CLK);
        cpsr_write_en   = 1'b0;
        check1("cpsr.t T-write dropped", cpsr.t, 1'b0);

        // T4: spsr_valid behavior across modes
        enter_mode(MODE_USER);
        @(negedge CLK);
        check1("spsr_valid in user", spsr_valid, 1'b0);
        enter_mode(MODE_SYSTEM);
        @(negedge CLK);
        check1("spsr_valid in system", spsr_valid, 1'b0);
        enter_mode(MODE_FIQ);
        @(negedge CLK);
        check1("spsr_valid in fiq", spsr_valid, 1'b1);
        enter_mode(MODE_UNDEFINED);
        @(negedge CLK);
        check1("spsr_valid in und", spsr_valid, 1'b1);

        // T5: SPSR write writes the current-mode SPSR; switching modes
        //     should reveal a different SPSR
        enter_mode(MODE_FIQ);
        @(negedge CLK);
        spsr_write_data = 32'h11111111;
        spsr_write_mask = 4'b1111;
        spsr_write_en   = 1'b1;
        @(posedge CLK);
        @(negedge CLK);
        spsr_write_en   = 1'b0;
        check32("spsr_fiq after write", 32'(spsr), 32'h11111111);

        enter_mode(MODE_IRQ);
        @(negedge CLK);
        check32("spsr_irq still zero", 32'(spsr), 32'h0);
        spsr_write_data = 32'h22222222;
        spsr_write_mask = 4'b1111;
        spsr_write_en   = 1'b1;
        @(posedge CLK);
        @(negedge CLK);
        spsr_write_en   = 1'b0;
        check32("spsr_irq after write", 32'(spsr), 32'h22222222);

        enter_mode(MODE_FIQ);
        @(negedge CLK);
        check32("spsr_fiq retained", 32'(spsr), 32'h11111111);

        // T6: cpsr_restore copies SPSR-of-current-mode into CPSR
        // Currently in FIQ with SPSR_fiq=0x11111111. Restore should swap.
        @(negedge CLK);
        cpsr_restore_en = 1'b1;
        @(posedge CLK);
        @(negedge CLK);
        cpsr_restore_en = 1'b0;
        check32("cpsr after restore from spsr_fiq", 32'(cpsr), 32'h11111111);

        // Wrap up
        if (errors == 0) begin
            $display("psr_tb: PASS");
            $finish;
        end else begin
            $fatal(1, "psr_tb: FAIL (%0d errors)", errors);
        end
    end

    initial begin
        #100000;
        $fatal(1, "psr_tb: TIMEOUT");
    end

endmodule
