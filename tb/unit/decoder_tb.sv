// Unit test for arm7tdmis_decoder (TASKS.md §8). Combinational.
//
// One representative opcode per instruction class plus a couple of key
// field checks per class. The goal isn't exhaustive coverage of every
// ARMv4T encoding — it's to catch regressions in the classification tree
// and make sure the decoded_t fields land in the right bit positions.

module decoder_tb
    import arm7tdmis_types_pkg::*;
    import arm7tdmis_instr_pkg::*;
;

    logic [31:0] instr;
    decoded_t    dec;
    logic        is_dataproc;
    logic        is_unimplemented;

    arm7tdmis_decoder dut (.*);

    // Many decoder outputs are exercised by class checks but not every
    // individual field is read; collapse the remainder into a single
    // discarded wire so lint stays clean.
    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, dec, is_dataproc, is_unimplemented};
    /* verilator lint_on UNUSEDSIGNAL */

    int errors;

    task automatic check_class(string label, instr_class_e expected);
        #1;
        if (dec.instr_class !== expected) begin
            $display("FAIL [%s]: class expected %0d got %0d",
                     label, expected, dec.instr_class);
            errors = errors + 1;
        end
    endtask

    // check_eq* arguments are evaluated at call time, so the test calls
    // check_class first for each new `instr` (its #1 settles dec) before
    // chaining field checks.
    task automatic check_eq32(string label, logic [31:0] actual, logic [31:0] expected);
        if (actual !== expected) begin
            $display("FAIL [%s]: expected %08x got %08x", label, expected, actual);
            errors = errors + 1;
        end
    endtask

    task automatic check_eq4(string label, logic [3:0] actual, logic [3:0] expected);
        if (actual !== expected) begin
            $display("FAIL [%s]: expected %01x got %01x", label, expected, actual);
            errors = errors + 1;
        end
    endtask

    task automatic check_eq1(string label, logic actual, logic expected);
        if (actual !== expected) begin
            $display("FAIL [%s]: expected %0b got %0b", label, expected, actual);
            errors = errors + 1;
        end
    endtask

    initial begin
        errors = 0;
        instr  = 32'h0;

        // ---- DP-immediate: MOV r0, #5 → 0xE3A00005 ----
        instr = 32'hE3A00005;
        check_class("MOV r0,#5", INSTR_DP);
        check_eq4("  alu_op",  4'(dec.alu_op),  4'(ALU_MOV));
        check_eq4("  rd",      dec.rd,          4'd0);
        check_eq1("  dp_use_imm", dec.dp_use_imm, 1'b1);
        check_eq1("  is_test_op", dec.is_test_op, 1'b0);

        // ---- DP-register: MOV r0, r1 (LSL #0) → 0xE1A00001 ----
        instr = 32'hE1A00001;
        check_class("MOV r0,r1", INSTR_DP);
        check_eq4("  rm",      dec.rm,          4'd1);
        check_eq1("  dp_use_imm", dec.dp_use_imm, 1'b0);

        // ---- DP test op: TST r0, #5 → 0xE3100005 ----
        instr = 32'hE3100005;
        check_class("TST r0,#5", INSTR_DP);
        check_eq4("  alu_op", 4'(dec.alu_op), 4'(ALU_TST));
        check_eq1("  is_test_op", dec.is_test_op, 1'b1);
        check_eq1("  s_bit", dec.s_bit, 1'b1);

        // ---- BX r0 → 0xE12FFF10 ----
        instr = 32'hE12FFF10;
        check_class("BX r0", INSTR_BX);
        check_eq4("  rm", dec.rm, 4'd0);

        // ---- BX r14 → 0xE12FFF1E ----
        instr = 32'hE12FFF1E;
        check_class("BX r14", INSTR_BX);
        check_eq4("  rm", dec.rm, 4'd14);

        // ---- B label (offset 0) → 0xEA000000 ----
        // PC-relative: branch_offset is sign-extended (offset24<<2)
        instr = 32'hEA000000;
        check_class("B +0", INSTR_BRANCH);
        check_eq1("  branch_link", dec.branch_link, 1'b0);
        check_eq32("  branch_offset", dec.branch_offset, 32'h0);

        // ---- BL label → 0xEB000000 ----
        instr = 32'hEB000000;
        check_class("BL +0", INSTR_BRANCH);
        check_eq1("  branch_link", dec.branch_link, 1'b1);

        // ---- B with negative offset (branch back 4 bytes) → 0xEAFFFFFE ----
        // offset24 = 0xFFFFFE = -2 signed; <<2 = -8 → branch_offset = 32'hFFFFFFF8
        instr = 32'hEAFFFFFE;
        check_class("B -8", INSTR_BRANCH);
        check_eq32("  branch_offset", dec.branch_offset, 32'hFFFFFFF8);

        // ---- MUL r4, r1, r2 → 0xE0040291 ----
        // cond=AL, 0000 0000 (A=0,S=0), Rd=4, Rn=0, Rs=2, 1001, Rm=1
        instr = 32'hE0040291;
        check_class("MUL r4,r1,r2", INSTR_MUL);
        check_eq4("  rn (=Rd_mul=4)", dec.rn, 4'd4);
        check_eq1("  mul_accumulate", dec.mul_accumulate, 1'b0);

        // ---- MLA r4, r1, r2, r3 → 0xE0243291 ----
        // cond=AL, 0000 0010, Rd=4, Rn=3, Rs=2, 1001, Rm=1
        instr = 32'hE0243291;
        check_class("MLA r4,r1,r2,r3", INSTR_MUL);
        check_eq1("  mul_accumulate", dec.mul_accumulate, 1'b1);

        // ---- UMULL r0, r1, r3, r2 → 0xE0C10293 ----
        // cond=AL, 0000 1100 (bit23=1, U=1 unsigned, A=0, S=0)
        // RdHi=1, RdLo=0, Rs=2, 1001, Rm=3
        instr = 32'hE0C10293;
        check_class("UMULL", INSTR_MULL);
        check_eq1("  mul_signed (UMULL)", dec.mul_signed, 1'b0);

        // ---- SMLAL → 0xE0A10293 (bit23=1, U=0 signed, A=1, S=0 → 0000 1010) ----
        instr = 32'hE0A10293;
        check_class("SMLAL", INSTR_MULL);
        check_eq1("  mul_signed (SMLAL)", dec.mul_signed, 1'b1);
        check_eq1("  mul_accumulate", dec.mul_accumulate, 1'b1);

        // ---- SWP r0, r1, [r2] → 0xE1020091 ----
        // cond=AL, 00010000 (B=0), Rn=2, Rd=0, 00001001, Rm=1
        instr = 32'hE1020091;
        check_class("SWP r0,r1,[r2]", INSTR_SWP);
        check_eq4("  rn", dec.rn, 4'd2);
        check_eq4("  rd", dec.rd, 4'd0);
        check_eq4("  rm", dec.rm, 4'd1);

        // ---- MRS r0, CPSR → 0xE10F0000 ----
        instr = 32'hE10F0000;
        check_class("MRS r0,CPSR", INSTR_MRS);
        check_eq1("  psr_use_spsr (CPSR)", dec.psr_use_spsr, 1'b0);
        check_eq4("  rd", dec.rd, 4'd0);

        // ---- MRS r0, SPSR → 0xE14F0000 ----
        instr = 32'hE14F0000;
        check_class("MRS r0,SPSR", INSTR_MRS);
        check_eq1("  psr_use_spsr (SPSR)", dec.psr_use_spsr, 1'b1);

        // ---- MSR CPSR_f, r0 → 0xE128F000 ----
        // cond 00010 010 1000 1111 0000 0000 Rm. Mask=0b1000 (_f only).
        instr = 32'hE128F000;
        check_class("MSR CPSR_f,r0", INSTR_MSR);
        check_eq1("  msr_use_imm", dec.msr_use_imm, 1'b0);
        check_eq4("  msr_field_mask (_f)", dec.msr_field_mask, 4'b1000);

        // ---- MSR CPSR_c, #5 → 0xE321F005 ----
        // cond 0011 0010 0001 1111 0000_rot4 imm8
        instr = 32'hE321F005;
        check_class("MSR CPSR_c,#5", INSTR_MSR);
        check_eq1("  msr_use_imm", dec.msr_use_imm, 1'b1);
        check_eq4("  msr_field_mask (_c)", dec.msr_field_mask, 4'b0001);

        // ---- LDR r0, [r1] → 0xE5910000 ----
        // cond 0101 1001 (P=1,U=1,B=0,W=0,L=1), Rn=1, Rd=0, offset=0
        instr = 32'hE5910000;
        check_class("LDR r0,[r1]", INSTR_LDR_STR);
        check_eq1("  ls_load", dec.ls_load, 1'b1);
        check_eq1("  ls_byte", dec.ls_byte, 1'b0);
        check_eq1("  ls_pre_index", dec.ls_pre_index, 1'b1);
        check_eq1("  ls_up", dec.ls_up, 1'b1);
        check_eq1("  ls_use_imm", dec.ls_use_imm, 1'b1);

        // ---- STR r0, [r1] → 0xE5810000 (L=0) ----
        instr = 32'hE5810000;
        check_class("STR r0,[r1]", INSTR_LDR_STR);
        check_eq1("  ls_load", dec.ls_load, 1'b0);

        // ---- LDRB r0, [r1] → 0xE5D10000 (B=1) ----
        instr = 32'hE5D10000;
        check_class("LDRB r0,[r1]", INSTR_LDR_STR);
        check_eq1("  ls_byte", dec.ls_byte, 1'b1);
        check_eq1("  ls_load", dec.ls_load, 1'b1);

        // ---- LDR with register offset → 0xE7910002 (cond 0111 1001 Rn Rd 0000 0000 Rm) ----
        // bit[27:25]=011, bit[4]=0 -> still INSTR_LDR_STR
        instr = 32'hE7910002;
        check_class("LDR r0,[r1,r2]", INSTR_LDR_STR);
        check_eq1("  ls_use_imm", dec.ls_use_imm, 1'b0);

        // ---- LDRH r0, [r1] → 0xE1D100B0 ----
        // bits[27:25]=000, P=1, U=1, I=1 (bit 22), W=0, L=1, Rn=1, Rd=0, offsetH=0, 1011, offsetL=0
        instr = 32'hE1D100B0;
        check_class("LDRH r0,[r1]", INSTR_LDRH_STRH);
        check_eq1("  hs_halfword", dec.hs_halfword, 1'b1);
        check_eq1("  hs_signed",   dec.hs_signed,   1'b0);

        // ---- LDRSB → 0xE1D100D0 (S=1, H=0) ----
        instr = 32'hE1D100D0;
        check_class("LDRSB", INSTR_LDRH_STRH);
        check_eq1("  hs_signed", dec.hs_signed, 1'b1);
        check_eq1("  hs_halfword", dec.hs_halfword, 1'b0);

        // ---- LDRSH → 0xE1D100F0 (S=1, H=1) ----
        instr = 32'hE1D100F0;
        check_class("LDRSH", INSTR_LDRH_STRH);
        check_eq1("  hs_signed", dec.hs_signed, 1'b1);
        check_eq1("  hs_halfword", dec.hs_halfword, 1'b1);

        // ---- LDMIA r1, {r0,r1,r2} → 0xE8910007 ----
        instr = 32'hE8910007;
        check_class("LDMIA r1,{r0-r2}", INSTR_LDM_STM);
        check_eq1("  block_load", dec.block_load, 1'b1);
        check_eq1("  block_up", dec.block_up, 1'b1);
        check_eq1("  block_pre_index", dec.block_pre_index, 1'b0);

        // ---- STMIA r1!, {r0-r3} → 0xE8A1000F (W=1, L=0) ----
        instr = 32'hE8A1000F;
        check_class("STMIA r1!,{r0-r3}", INSTR_LDM_STM);
        check_eq1("  block_writeback", dec.block_writeback, 1'b1);
        check_eq1("  block_load", dec.block_load, 1'b0);

        // ---- SWI #0x123 → 0xEF000123 ----
        instr = 32'hEF000123;
        check_class("SWI #0x123", INSTR_SWI);

        // ---- CDP → 0xEE000000 ----
        instr = 32'hEE000000;
        check_class("CDP", INSTR_CDP);

        // ---- MCR → 0xEE000010 (bit 4 = 1, bit 20 = 0 -> MCR) ----
        instr = 32'hEE000010;
        check_class("MCR", INSTR_MCR_MRC);

        // ---- LDC → 0xED910000 (bits[27:25]=110) ----
        instr = 32'hED910000;
        check_class("LDC", INSTR_LDC_STC);

        // ---- Undefined: cond 011 _ _ _ _ _ _ _ 1 ____ (bit 4 = 1 in the
        //      LDR/STR register-offset slot)
        instr = 32'hE6000010;
        check_class("UNDEF (0x011 + bit4)", INSTR_UNDEF);

        // ---- Undefined: cond 0011 0000 ... (the 001 1 0R00 hole) ----
        instr = 32'hE3000000;
        check_class("UNDEF (DP-imm hole)", INSTR_UNDEF);

        // ---- Common: cond field always decoded ----
        instr = 32'h0A000000;     // B EQ — cond=0x0=EQ
        // check_eq4 takes value args evaluated at call time; chain through
        // a check_class first so its #1 settles dec.cond.
        check_class("B EQ (class)", INSTR_BRANCH);
        check_eq4("  EQ-cond", 4'(dec.cond), 4'(COND_EQ));

        if (errors == 0) begin
            $display("decoder_tb: PASS");
            $finish;
        end else begin
            $fatal(1, "decoder_tb: FAIL (%0d errors)", errors);
        end
    end

    initial begin
        #100000;
        $fatal(1, "decoder_tb: TIMEOUT");
    end

endmodule
