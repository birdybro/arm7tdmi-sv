// Unit test for arm7tdmis_multiplier (TASKS.md §5.3). Combinational.
//
// Coverage:
//   - MUL:    simple, zero result, sign-distinct (low 32 bits unaffected)
//   - MLA:    accumulate into 32-bit
//   - UMULL:  high half non-zero (verify zero-extension path)
//   - SMULL:  signed multiply with negative operand → 64-bit sign extension
//   - UMLAL:  64-bit accumulate
//   - SMLAL:  signed 64-bit accumulate (negative+positive cases)
//   - cycle_count (m parameter): m=1 (all-0 or all-1 top), m=2, m=3, m=4
//   - N flag from product[63] for long, product[31] for short
//   - Z flag covers both halves for long

module multiplier_tb;

    logic        is_signed, is_long, accumulate;
    logic [31:0] op_a, op_b, acc_lo, acc_hi;
    logic [31:0] result_lo, result_hi;
    logic        n_out, z_out;
    logic [3:0]  flag_we;
    logic [2:0]  cycle_count;

    arm7tdmis_multiplier dut (.*);

    int errors;

    task automatic check(string label,
                         logic [31:0] elo, logic [31:0] ehi,
                         logic en, logic ez, logic [2:0] em);
        #1;
        if (result_lo !== elo) begin
            $display("FAIL [%s]: lo expected %08x got %08x", label, elo, result_lo);
            errors = errors + 1;
        end
        if (result_hi !== ehi) begin
            $display("FAIL [%s]: hi expected %08x got %08x", label, ehi, result_hi);
            errors = errors + 1;
        end
        if (n_out !== en) begin
            $display("FAIL [%s]: N expected %0b got %0b", label, en, n_out);
            errors = errors + 1;
        end
        if (z_out !== ez) begin
            $display("FAIL [%s]: Z expected %0b got %0b", label, ez, z_out);
            errors = errors + 1;
        end
        if (cycle_count !== em) begin
            $display("FAIL [%s]: m expected %0d got %0d", label, em, cycle_count);
            errors = errors + 1;
        end
        if (flag_we !== 4'b1100) begin
            $display("FAIL [%s]: flag_we expected 1100 got %04b", label, flag_we);
            errors = errors + 1;
        end
    endtask

    initial begin
        errors     = 0;
        is_signed  = 1'b0;
        is_long    = 1'b0;
        accumulate = 1'b0;
        op_a       = 32'h0;
        op_b       = 32'h0;
        acc_lo     = 32'h0;
        acc_hi     = 32'h0;

        // ---- MUL ----
        // 5 * 7 = 35; Rs=7 → top 24 bits = 0 → m=1
        is_signed = 0; is_long = 0; accumulate = 0;
        op_a = 32'd5; op_b = 32'd7;
        check("MUL 5*7", 32'd35, 32'h0, 1'b0, 1'b0, 3'd1);

        // 0 * X = 0
        op_a = 32'h0; op_b = 32'h12345678;
        check("MUL 0*X (m=4)", 32'h0, 32'h0, 1'b0, 1'b1, 3'd4);

        // -1 * 5 (low 32 bits): 0xFFFFFFFF * 5 = 0x4FFFFFFFB → low 32 = 0xFFFFFFFB
        op_a = 32'hFFFFFFFF; op_b = 32'd5;
        check("MUL -1*5 low", 32'hFFFFFFFB, 32'h0, 1'b1, 1'b0, 3'd1);

        // ---- MLA: 5*7 + 10 = 45 ----
        is_signed = 0; is_long = 0; accumulate = 1;
        op_a = 32'd5; op_b = 32'd7; acc_lo = 32'd10;
        check("MLA 5*7+10", 32'd45, 32'h0, 1'b0, 1'b0, 3'd1);

        // ---- UMULL: 0x80000000 * 2 = 0x100000000 → hi=1, lo=0 ----
        is_signed = 0; is_long = 1; accumulate = 0;
        op_a = 32'h80000000; op_b = 32'd2;
        check("UMULL 0x80000000*2", 32'h0, 32'h1, 1'b0, 1'b0, 3'd1);

        // ---- UMULL where both halves non-zero: 0xFFFFFFFF * 0xFFFFFFFF
        // = (2^32-1)^2 = 2^64 - 2*2^32 + 1 = 0xFFFFFFFE_00000001
        op_a = 32'hFFFFFFFF; op_b = 32'hFFFFFFFF;
        // op_b = 0xFFFFFFFF → top 24 bits = 0xFFFFFF (all 1) → m=1
        check("UMULL -1*-1 unsigned", 32'h00000001, 32'hFFFFFFFE, 1'b1, 1'b0, 3'd1);

        // ---- SMULL: -1 (signed) * 2 = -2 = 0xFFFFFFFFFFFFFFFE
        is_signed = 1; is_long = 1; accumulate = 0;
        op_a = 32'hFFFFFFFF; op_b = 32'd2;
        check("SMULL -1*2", 32'hFFFFFFFE, 32'hFFFFFFFF, 1'b1, 1'b0, 3'd1);

        // SMULL: -2 * -2 = 4 (positive)
        op_a = 32'hFFFFFFFE; op_b = 32'hFFFFFFFE;
        check("SMULL -2*-2", 32'h00000004, 32'h00000000, 1'b0, 1'b0, 3'd1);

        // SMULL: large negative * positive: 0x80000000 (= -2^31) * 2 = -2^32
        // = 0xFFFFFFFF_00000000
        op_a = 32'h80000000; op_b = 32'd2;
        check("SMULL -2^31*2", 32'h00000000, 32'hFFFFFFFF, 1'b1, 1'b0, 3'd1);

        // ---- UMLAL: existing acc {0, 5} + 3 * 7 = 26 lo, 0 hi ----
        is_signed = 0; is_long = 1; accumulate = 1;
        op_a = 32'd3; op_b = 32'd7; acc_lo = 32'd5; acc_hi = 32'h0;
        check("UMLAL 3*7+5", 32'd26, 32'h0, 1'b0, 1'b0, 3'd1);

        // UMLAL with carry into hi: 0xFFFFFFFF * 2 + {0, 0} = 0x1FFFFFFFE
        // → lo=0xFFFFFFFE, hi=1
        op_a = 32'hFFFFFFFF; op_b = 32'd2; acc_lo = 32'h0; acc_hi = 32'h0;
        check("UMLAL -1*2+0", 32'hFFFFFFFE, 32'h00000001, 1'b0, 1'b0, 3'd1);

        // ---- SMLAL: -1 * 2 + {0, 5} = -2 + 5 = 3 (lo), 0 (hi)
        // -2 = 0xFFFFFFFE_FFFFFFFE; +5 = wait that's wrong sign extension.
        // -2 64-bit = 0xFFFFFFFF_FFFFFFFE; + 5 = 0xFFFFFFFF_00000003 (low overflow into hi=0xFFFFFFFF)
        // Actually 0xFFFFFFFE + 5 = 0x100000003 → carry into hi: 0xFFFFFFFF + 1 = 0x100000000
        // → lo = 0x00000003, hi = 0x00000000
        is_signed = 1; is_long = 1; accumulate = 1;
        op_a = 32'hFFFFFFFF; op_b = 32'd2; acc_lo = 32'd5; acc_hi = 32'h0;
        check("SMLAL -1*2+5", 32'h00000003, 32'h00000000, 1'b0, 1'b0, 3'd1);

        // ---- cycle_count (m parameter) coverage ----
        // m=1 with top 24 zeros: Rs = 0x000000FF
        is_signed = 0; is_long = 0; accumulate = 0;
        op_a = 32'd1; op_b = 32'h000000FF;
        check("m=1 top zero", 32'h000000FF, 32'h0, 1'b0, 1'b0, 3'd1);

        // m=1 with top 24 ones: Rs = 0xFFFFFF00 (top 24 bits = 0xFFFFFF)
        op_a = 32'd1; op_b = 32'hFFFFFF00;
        // result = 0xFFFFFF00; top bit = 1 → N=1
        check("m=1 top one", 32'hFFFFFF00, 32'h0, 1'b1, 1'b0, 3'd1);

        // m=2: Rs = 0x0000FF00 (top 24 = 0x0000FF, not all 0/1; top 16 = 0 → m=2)
        op_a = 32'd1; op_b = 32'h0000FF00;
        check("m=2", 32'h0000FF00, 32'h0, 1'b0, 1'b0, 3'd2);

        // m=3: Rs = 0x00FF0000 (top 24 not all 0/1; top 16 not all 0/1; top 8 = 0 → m=3)
        op_a = 32'd1; op_b = 32'h00FF0000;
        check("m=3", 32'h00FF0000, 32'h0, 1'b0, 1'b0, 3'd3);

        // m=4: Rs = 0x10000000 (none of the early-term patterns match)
        op_a = 32'd1; op_b = 32'h10000000;
        check("m=4", 32'h10000000, 32'h0, 1'b0, 1'b0, 3'd4);

        if (errors == 0) begin
            $display("multiplier_tb: PASS");
            $finish;
        end else begin
            $fatal(1, "multiplier_tb: FAIL (%0d errors)", errors);
        end
    end

    initial begin
        #100000;
        $fatal(1, "multiplier_tb: TIMEOUT");
    end

endmodule
