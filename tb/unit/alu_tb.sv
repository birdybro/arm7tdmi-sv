// Unit test for arm7tdmis_alu (TASKS.md §5.2). Combinational — no clock.
//
// Coverage: every op exercised at least once with a deterministic input
// where the expected result and all four flags can be derived by hand.
// Special focus on:
//   - V flag for both signed-overflow directions (positive→negative,
//     negative→positive) on ADD and SUB
//   - C flag matching ARM convention (1 = no borrow on subtraction)
//   - shifter_carry passthrough for logic ops
//   - flag_we mask is 4'b1110 for logic, 4'b1111 for arithmetic

module alu_tb
    import arm7tdmis_types_pkg::*;
;

    alu_op_e     op;
    logic [31:0] op_a, op_b;
    logic        cpsr_c, shifter_carry;
    logic [31:0] result;
    logic        n_out, z_out, c_out, v_out;
    logic [3:0]  flag_we;

    arm7tdmis_alu dut (.*);

    int errors;

    task automatic check(string label,
                         logic [31:0] er, logic en, logic ez, logic ec, logic ev,
                         logic [3:0] efw);
        #1;
        if (result !== er) begin
            $display("FAIL [%s]: result expected %08x got %08x", label, er, result);
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
        if (c_out !== ec) begin
            $display("FAIL [%s]: C expected %0b got %0b", label, ec, c_out);
            errors = errors + 1;
        end
        if (v_out !== ev) begin
            $display("FAIL [%s]: V expected %0b got %0b", label, ev, v_out);
            errors = errors + 1;
        end
        if (flag_we !== efw) begin
            $display("FAIL [%s]: flag_we expected %04b got %04b", label, efw, flag_we);
            errors = errors + 1;
        end
    endtask

    initial begin
        errors = 0;

        // ---- Logic ops: shifter_carry → c_out, v_out=0, flag_we=4'b1110 ----
        cpsr_c = 1'b0;

        // AND with shifter_carry=1
        op = ALU_AND; op_a = 32'hFFFFFFFF; op_b = 32'h12345678; shifter_carry = 1'b1;
        check("AND", 32'h12345678, 1'b0, 1'b0, 1'b1, 1'b0, 4'b1110);

        // AND with shifter_carry=0 (verify passthrough)
        op = ALU_AND; op_a = 32'hF0F0F0F0; op_b = 32'h0F0F0F0F; shifter_carry = 1'b0;
        check("AND zero", 32'h00000000, 1'b0, 1'b1, 1'b0, 1'b0, 4'b1110);

        // EOR
        op = ALU_EOR; op_a = 32'h55555555; op_b = 32'hAAAAAAAA; shifter_carry = 1'b1;
        check("EOR", 32'hFFFFFFFF, 1'b1, 1'b0, 1'b1, 1'b0, 4'b1110);

        // ORR
        op = ALU_ORR; op_a = 32'h0F0F_0F0F; op_b = 32'hF0F0_F0F0; shifter_carry = 1'b0;
        check("ORR", 32'hFFFFFFFF, 1'b1, 1'b0, 1'b0, 1'b0, 4'b1110);

        // BIC: a & ~b
        op = ALU_BIC; op_a = 32'hFFFFFFFF; op_b = 32'h00FF00FF; shifter_carry = 1'b1;
        check("BIC", 32'hFF00FF00, 1'b1, 1'b0, 1'b1, 1'b0, 4'b1110);

        // MOV
        op = ALU_MOV; op_a = 32'hDEADBEEF; op_b = 32'h12345678; shifter_carry = 1'b0;
        check("MOV", 32'h12345678, 1'b0, 1'b0, 1'b0, 1'b0, 4'b1110);

        // MVN
        op = ALU_MVN; op_a = 32'h00000000; op_b = 32'h0; shifter_carry = 1'b1;
        check("MVN", 32'hFFFFFFFF, 1'b1, 1'b0, 1'b1, 1'b0, 4'b1110);

        // TST: AND-flags-only (decoder suppresses Rd write); flag_we still 4'b1110
        op = ALU_TST; op_a = 32'h0F0F_0F0F; op_b = 32'hF0F0_F0F0; shifter_carry = 1'b1;
        check("TST", 32'h00000000, 1'b0, 1'b1, 1'b1, 1'b0, 4'b1110);

        // TEQ: EOR-flags-only
        op = ALU_TEQ; op_a = 32'hAAAAAAAA; op_b = 32'h55555555; shifter_carry = 1'b0;
        check("TEQ", 32'hFFFFFFFF, 1'b1, 1'b0, 1'b0, 1'b0, 4'b1110);

        // ---- Arithmetic ops ----
        shifter_carry = 1'b0;     // doesn't matter for arith
        cpsr_c        = 1'b0;

        // ADD: 1 + 1 = 2; no carry, no overflow
        op = ALU_ADD; op_a = 32'h1; op_b = 32'h1;
        check("ADD 1+1", 32'h2, 1'b0, 1'b0, 1'b0, 1'b0, 4'b1111);

        // ADD overflow positive→negative: 0x7FFFFFFF + 1 = 0x80000000
        op = ALU_ADD; op_a = 32'h7FFFFFFF; op_b = 32'h1;
        check("ADD V+", 32'h80000000, 1'b1, 1'b0, 1'b0, 1'b1, 4'b1111);

        // ADD overflow negative→positive: 0x80000000 + 0x80000000 = 0x100000000 (C=1)
        op = ALU_ADD; op_a = 32'h80000000; op_b = 32'h80000000;
        check("ADD V-", 32'h0, 1'b0, 1'b1, 1'b1, 1'b1, 4'b1111);

        // ADD with C carry-out, no V: 0xFFFFFFFF + 1 = 0
        op = ALU_ADD; op_a = 32'hFFFFFFFF; op_b = 32'h1;
        check("ADD C", 32'h0, 1'b0, 1'b1, 1'b1, 1'b0, 4'b1111);

        // ADC with C in: 1 + 1 + 1 = 3
        op = ALU_ADC; op_a = 32'h1; op_b = 32'h1; cpsr_c = 1'b1;
        check("ADC", 32'h3, 1'b0, 1'b0, 1'b0, 1'b0, 4'b1111);
        cpsr_c = 1'b0;

        // CMN: same as ADD for flags; flag_we=4'b1111 (decoder suppresses Rd)
        op = ALU_CMN; op_a = 32'h7FFFFFFF; op_b = 32'h1;
        check("CMN V+", 32'h80000000, 1'b1, 1'b0, 1'b0, 1'b1, 4'b1111);

        // SUB equal → zero, C=1 (no borrow), V=0
        op = ALU_SUB; op_a = 32'h5; op_b = 32'h5;
        check("SUB equal", 32'h0, 1'b0, 1'b1, 1'b1, 1'b0, 4'b1111);

        // SUB borrow: 0 - 1 = 0xFFFFFFFF; C=0 (borrow), V=0
        op = ALU_SUB; op_a = 32'h0; op_b = 32'h1;
        check("SUB borrow", 32'hFFFFFFFF, 1'b1, 1'b0, 1'b0, 1'b0, 4'b1111);

        // SUB V overflow: 0x80000000 - 1 = 0x7FFFFFFF (signed: most-negative -1 → wraps positive)
        op = ALU_SUB; op_a = 32'h80000000; op_b = 32'h1;
        check("SUB V", 32'h7FFFFFFF, 1'b0, 1'b0, 1'b1, 1'b1, 4'b1111);

        // SBC with C=1 (no previous borrow): equivalent to plain SUB
        op = ALU_SBC; op_a = 32'h5; op_b = 32'h3; cpsr_c = 1'b1;
        check("SBC C=1", 32'h2, 1'b0, 1'b0, 1'b1, 1'b0, 4'b1111);

        // SBC with C=0 (previous borrow): 5 - 3 - 1 = 1
        op = ALU_SBC; op_a = 32'h5; op_b = 32'h3; cpsr_c = 1'b0;
        check("SBC C=0", 32'h1, 1'b0, 1'b0, 1'b1, 1'b0, 4'b1111);
        cpsr_c = 1'b0;

        // CMP: same as SUB
        op = ALU_CMP; op_a = 32'h5; op_b = 32'h5;
        check("CMP equal", 32'h0, 1'b0, 1'b1, 1'b1, 1'b0, 4'b1111);

        op = ALU_CMP; op_a = 32'h3; op_b = 32'h5;
        check("CMP less", 32'hFFFFFFFE, 1'b1, 1'b0, 1'b0, 1'b0, 4'b1111);

        // RSB: op_b - op_a → 5 - 3 = 2 (with op_a=3, op_b=5)
        op = ALU_RSB; op_a = 32'h3; op_b = 32'h5;
        check("RSB 5-3", 32'h2, 1'b0, 1'b0, 1'b1, 1'b0, 4'b1111);

        // RSB borrow: op_b - op_a where op_b<op_a: op_a=5, op_b=3 → 3 - 5 = 0xFFFFFFFE
        op = ALU_RSB; op_a = 32'h5; op_b = 32'h3;
        check("RSB borrow", 32'hFFFFFFFE, 1'b1, 1'b0, 1'b0, 1'b0, 4'b1111);

        // RSC with C=1: op_b - op_a (no borrow): same as RSB
        op = ALU_RSC; op_a = 32'h3; op_b = 32'h5; cpsr_c = 1'b1;
        check("RSC C=1", 32'h2, 1'b0, 1'b0, 1'b1, 1'b0, 4'b1111);

        // RSC with C=0 (previous borrow): op_b - op_a - 1 → 5 - 3 - 1 = 1
        op = ALU_RSC; op_a = 32'h3; op_b = 32'h5; cpsr_c = 1'b0;
        check("RSC C=0", 32'h1, 1'b0, 1'b0, 1'b1, 1'b0, 4'b1111);

        if (errors == 0) begin
            $display("alu_tb: PASS");
            $finish;
        end else begin
            $fatal(1, "alu_tb: FAIL (%0d errors)", errors);
        end
    end

    initial begin
        #100000;
        $fatal(1, "alu_tb: TIMEOUT");
    end

endmodule
