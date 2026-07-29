// ISA-016 exhaustive static UNPREDICTABLE-policy decoder regression.
//
// ARMv4T labels the operand/SBZ violations below UNPREDICTABLE, not
// architecturally Undefined. INSTR_UNDEF is this implementation's selected
// precise-trap policy; these checks must never be cited as an architectural
// promise that another ARM implementation traps the same encodings.

module unpredictable_decode_tb
    import arm7tdmis_types_pkg::*;
    import arm7tdmis_instr_pkg::*;
;

    logic [31:0] arm_instr;
    decoded_t    arm_dec;
    logic        arm_is_dataproc;
    logic        arm_is_unimplemented;

    logic [15:0] thumb_instr;
    decoded_t    thumb_dec;
    logic        thumb_is_dataproc;
    logic        thumb_is_unimplemented;

    arm7tdmis_decoder arm_dut (
        .instr            (arm_instr),
        .dec              (arm_dec),
        .is_dataproc      (arm_is_dataproc),
        .is_unimplemented (arm_is_unimplemented)
    );

    arm7tdmis_thumb_decoder thumb_dut (
        .thumb_instr      (thumb_instr),
        .dec              (thumb_dec),
        .is_dataproc      (thumb_is_dataproc),
        .is_unimplemented (thumb_is_unimplemented)
    );

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, arm_dec, arm_is_dataproc,
                     thumb_dec, thumb_is_dataproc};
    /* verilator lint_on UNUSEDSIGNAL */

    int unsigned errors;
    int unsigned arm_trap_rows;
    int unsigned thumb_trap_rows;
    int unsigned defined_policy_rows;

    function automatic logic [31:0] dp_word(
        input logic       immediate,
        input logic [3:0] opcode,
        input logic       set_flags,
        input logic [3:0] rn,
        input logic [3:0] rd
    );
        logic [11:0] operand2;
        operand2 = immediate ? 12'h001 : 12'h002;
        return {4'hE, 2'b00, immediate, opcode, set_flags,
                rn, rd, operand2};
    endfunction

    function automatic logic [31:0] mul_word(
        input logic       accumulate,
        input logic [3:0] rd,
        input logic [3:0] rn,
        input logic [3:0] rs,
        input logic [3:0] rm
    );
        return {4'hE, 6'b000000, accumulate, 1'b0,
                rd, rn, rs, 4'b1001, rm};
    endfunction

    function automatic logic [31:0] mull_word(
        input logic       unsigned_form,
        input logic       accumulate,
        input logic [3:0] rd_hi,
        input logic [3:0] rd_lo,
        input logic [3:0] rs,
        input logic [3:0] rm
    );
        return {4'hE, 5'b00001, unsigned_form, accumulate, 1'b0,
                rd_hi, rd_lo, rs, 4'b1001, rm};
    endfunction

    function automatic logic [31:0] msr_reg_word(
        input logic       spsr,
        input logic [3:0] field_mask,
        input logic [3:0] rm
    );
        return {4'hE, 5'b00010, spsr, 2'b10, field_mask,
                4'hF, 8'h00, rm};
    endfunction

    function automatic logic [31:0] mrs_word(
        input logic       spsr,
        input logic [3:0] sbo,
        input logic [3:0] rd,
        input logic [3:0] sbz_hi,
        input logic [3:0] sbz_lo
    );
        return {4'hE, 5'b00010, spsr, 2'b00, sbo, rd,
                sbz_hi, 4'h0, sbz_lo};
    endfunction

    function automatic logic [31:0] msr_reg_fields_word(
        input logic       spsr,
        input logic [3:0] field_mask,
        input logic [3:0] sbo,
        input logic [3:0] sbz,
        input logic [3:0] rm
    );
        return {4'hE, 5'b00010, spsr, 2'b10, field_mask,
                sbo, sbz, 4'h0, rm};
    endfunction

    function automatic logic [31:0] msr_imm_word(
        input logic       spsr,
        input logic [3:0] field_mask
    );
        return {4'hE, 5'b00110, spsr, 2'b10, field_mask,
                4'hF, 4'h0, 8'h01};
    endfunction

    function automatic logic [31:0] msr_imm_fields_word(
        input logic       spsr,
        input logic [3:0] field_mask,
        input logic [3:0] sbo
    );
        return {4'hE, 5'b00110, spsr, 2'b10, field_mask,
                sbo, 4'h0, 8'h01};
    endfunction

    function automatic logic [31:0] bx_fields_word(
        input logic [3:0] sbo_19_16,
        input logic [3:0] sbo_15_12,
        input logic [3:0] sbo_11_8
    );
        return {4'hE, 8'h12, sbo_19_16, sbo_15_12,
                sbo_11_8, 4'h1, 4'd1};
    endfunction

    function automatic logic [31:0] swp_fields_word(
        input logic       byte_access,
        input logic [3:0] sbz
    );
        return {4'hE, 5'b00010, byte_access, 2'b00,
                4'd1, 4'd2, sbz, 4'h9, 4'd3};
    endfunction

    function automatic logic [31:0] extra_reg_fields_word(
        input logic       load,
        input logic       signed_access,
        input logic       halfword,
        input logic [3:0] sbz
    );
        return {4'hE, 3'b000, 1'b1, 1'b1, 1'b0, 1'b0, load,
                4'd1, 4'd2, sbz, 1'b1, signed_access,
                halfword, 1'b1, 4'd3};
    endfunction

    function automatic logic [31:0] cp_ls_word(
        input logic pre_index,
        input logic up,
        input logic long_transfer,
        input logic writeback,
        input logic load,
        input logic [3:0] rn
    );
        return {4'hE, 3'b110, pre_index, up, long_transfer,
                writeback, load, rn, 4'd2, 4'd1, 8'h04};
    endfunction

    task automatic expect_arm_trap(input logic [31:0] word);
        arm_instr = word;
        #1;
        arm_trap_rows++;
        if ((arm_dec.instr_class !== INSTR_UNDEF)
         || (arm_is_unimplemented !== 1'b1)) begin
            if (errors < 24)
                $display("FAIL [ARM policy word=%08x]: class=%0d unimplemented=%0b",
                         word, arm_dec.instr_class, arm_is_unimplemented);
            errors++;
        end
    endtask

    task automatic expect_thumb_trap(input logic [15:0] word);
        thumb_instr = word;
        #1;
        thumb_trap_rows++;
        if ((thumb_dec.instr_class !== INSTR_UNDEF)
         || (thumb_is_unimplemented !== 1'b1)) begin
            if (errors < 24)
                $display("FAIL [Thumb policy word=%04x]: class=%0d unimplemented=%0b",
                         word, thumb_dec.instr_class,
                         thumb_is_unimplemented);
            errors++;
        end
    endtask

    task automatic expect_arm_defined(
        input logic [31:0] word,
        input instr_class_e expected
    );
        arm_instr = word;
        #1;
        defined_policy_rows++;
        if ((arm_dec.instr_class !== expected)
         || (arm_is_unimplemented !== 1'b0)) begin
            $display("FAIL [ARM defined policy word=%08x]: expected=%0d class=%0d",
                     word, expected, arm_dec.instr_class);
            errors++;
        end
    endtask

    task automatic expect_thumb_defined(
        input logic [15:0] word,
        input instr_class_e expected
    );
        thumb_instr = word;
        #1;
        defined_policy_rows++;
        if ((thumb_dec.instr_class !== expected)
         || (thumb_is_unimplemented !== 1'b0)) begin
            $display("FAIL [Thumb defined policy word=%04x]: expected=%0d class=%0d",
                     word, expected, thumb_dec.instr_class);
            errors++;
        end
    endtask

    initial begin
        errors              = 0;
        arm_trap_rows       = 0;
        thumb_trap_rows     = 0;
        defined_policy_rows = 0;
        arm_instr           = 32'h0;
        thumb_instr         = 16'h0;

        // Data-processing allocated-field constraints.
        for (int immediate = 0; immediate < 2; immediate++) begin
            for (int opcode = 8; opcode <= 11; opcode++) begin
                for (int rd = 1; rd < 16; rd++)
                    expect_arm_trap(dp_word(
                        immediate[0], opcode[3:0], 1'b1,
                        4'd1, rd[3:0]));
            end
            for (int mov_kind = 0; mov_kind < 2; mov_kind++) begin
                for (int rn = 1; rn < 16; rn++)
                    expect_arm_trap(dp_word(
                        immediate[0], mov_kind[0] ? 4'hF : 4'hD,
                        1'b0, rn[3:0], 4'd2));
            end
        end

        // Short multiply: MUL's accumulator field is SBZ and r15 is
        // excluded from every actual operand/destination position.
        for (int rn = 1; rn < 15; rn++)
            expect_arm_trap(mul_word(1'b0, 4'd1, rn[3:0], 4'd2, 4'd3));
        expect_arm_trap(mul_word(1'b0, 4'd15, 4'd0, 4'd2, 4'd3));
        expect_arm_trap(mul_word(1'b0, 4'd1, 4'd0, 4'd15, 4'd3));
        expect_arm_trap(mul_word(1'b0, 4'd1, 4'd0, 4'd2, 4'd15));
        expect_arm_trap(mul_word(1'b1, 4'd15, 4'd4, 4'd2, 4'd3));
        expect_arm_trap(mul_word(1'b1, 4'd1, 4'd15, 4'd2, 4'd3));
        expect_arm_trap(mul_word(1'b1, 4'd1, 4'd4, 4'd15, 4'd3));
        expect_arm_trap(mul_word(1'b1, 4'd1, 4'd4, 4'd2, 4'd15));

        // The obsolete Rd=Rm restriction is deliberately implemented as
        // real-r4p3 deterministic multiplication, not as a trap.
        expect_arm_defined(mul_word(1'b0, 4'd3, 4'd0, 4'd2, 4'd3),
                           INSTR_MUL);
        expect_arm_defined(mul_word(1'b1, 4'd3, 4'd4, 4'd2, 4'd3),
                           INSTR_MUL);

        // Long multiply: all four named registers exclude r15 and the
        // destination pair must be distinct. Cover every U/A form.
        for (int form = 0; form < 4; form++) begin
            expect_arm_trap(mull_word(
                form[1], form[0], 4'd15, 4'd2, 4'd3, 4'd4));
            expect_arm_trap(mull_word(
                form[1], form[0], 4'd1, 4'd15, 4'd3, 4'd4));
            expect_arm_trap(mull_word(
                form[1], form[0], 4'd1, 4'd2, 4'd15, 4'd4));
            expect_arm_trap(mull_word(
                form[1], form[0], 4'd1, 4'd2, 4'd3, 4'd15));
            for (int rd = 0; rd < 15; rd++)
                expect_arm_trap(mull_word(
                    form[1], form[0], rd[3:0], rd[3:0], 4'd3, 4'd4));
        end

        // PSR transfer operand and field restrictions.
        expect_arm_trap(32'hE10F_F000); // MRS pc,CPSR
        expect_arm_trap(32'hE14F_F000); // MRS pc,SPSR
        expect_arm_trap(msr_reg_word(1'b0, 4'h0, 4'd1));
        expect_arm_trap(msr_reg_word(1'b1, 4'h0, 4'd1));
        expect_arm_trap(msr_imm_word(1'b0, 4'h0));
        expect_arm_trap(msr_imm_word(1'b1, 4'h0));
        expect_arm_trap(msr_reg_word(1'b0, 4'h8, 4'd15));
        expect_arm_trap(msr_reg_word(1'b1, 4'h8, 4'd15));

        // Exhaust the non-decode SBZ/SBO fields in every ARMv4T
        // miscellaneous instruction. Each field value is varied while
        // every other field remains canonical, so no violation can hide
        // behind a second malformed field.
        for (int r = 0; r < 2; r++) begin
            for (int field = 0; field < 15; field++) begin
                expect_arm_trap(mrs_word(
                    r[0], field[3:0], 4'd1, 4'h0, 4'h0));
                expect_arm_trap(msr_reg_fields_word(
                    r[0], 4'h8, field[3:0], 4'h0, 4'd1));
                expect_arm_trap(msr_imm_fields_word(
                    r[0], 4'h8, field[3:0]));
            end
            for (int sbz = 1; sbz < 256; sbz++)
                expect_arm_trap(mrs_word(
                    r[0], 4'hF, 4'd1, sbz[7:4], sbz[3:0]));
            for (int sbz = 1; sbz < 16; sbz++)
                expect_arm_trap(msr_reg_fields_word(
                    r[0], 4'h8, 4'hF, sbz[3:0], 4'd1));
        end

        for (int field = 0; field < 15; field++) begin
            expect_arm_trap(bx_fields_word(
                field[3:0], 4'hF, 4'hF));
            expect_arm_trap(bx_fields_word(
                4'hF, field[3:0], 4'hF));
            expect_arm_trap(bx_fields_word(
                4'hF, 4'hF, field[3:0]));
        end

        for (int byte_access = 0; byte_access < 2; byte_access++)
            for (int sbz = 1; sbz < 16; sbz++)
                expect_arm_trap(swp_fields_word(
                    byte_access[0], sbz[3:0]));

        // Register-offset STRH/LDRH/LDRSB/LDRSH all share an SBZ nibble.
        // Cover every nonzero value in every allocated form.
        for (int form = 0; form < 4; form++)
            for (int sbz = 1; sbz < 16; sbz++)
                expect_arm_trap(extra_reg_fields_word(
                    form != 0, form >= 2, (form != 2), sbz[3:0]));

        // Coprocessor offset/unindexed pc bases remain defined. Any W=1
        // form with Rn=pc is the statically unsafe writeback case.
        for (int p = 0; p < 2; p++)
            for (int u = 0; u < 2; u++)
                for (int n = 0; n < 2; n++)
                    for (int l = 0; l < 2; l++)
                        expect_arm_trap(cp_ls_word(
                            p[0], u[0], n[0], 1'b1, l[0], 4'd15));
        expect_arm_defined(
            cp_ls_word(1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 4'd15),
            INSTR_LDC_STC);
        expect_arm_defined(
            cp_ls_word(1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 4'd15),
            INSTR_LDC_STC);

        // Exhaust all statically unsafe Thumb Format-5 encodings.
        for (int op = 0; op < 3; op++)
            for (int low_fields = 0; low_fields < 64; low_fields++)
                expect_thumb_trap({
                    6'b010001, op[1:0], 2'b00, low_fields[5:0]});

        // High CMP Rn=pc; H2/Rm remains free.
        for (int source = 0; source < 16; source++)
            expect_thumb_trap({
                6'b010001, 2'b01, 1'b1, source[3:0], 3'b111});

        // BX H1=1 is the pre-v5 BLX-register spelling. H1=0 still requires
        // its three low SBZ bits to be zero.
        for (int source = 0; source < 16; source++) begin
            for (int low = 0; low < 8; low++)
                expect_thumb_trap({
                    6'b010001, 2'b11, 1'b1, source[3:0], low[2:0]});
            for (int low = 1; low < 8; low++)
                expect_thumb_trap({
                    6'b010001, 2'b11, 1'b0, source[3:0], low[2:0]});
        end

        // Thumb MUL Rd=Rm uses deterministic r4p3 read-before-write
        // behavior. All eight square encodings remain executable.
        for (int reg_idx = 0; reg_idx < 8; reg_idx++)
            expect_thumb_defined({
                6'b010000, 4'b1101, reg_idx[2:0], reg_idx[2:0]},
                INSTR_MUL);

        if (arm_trap_rows != 1066) begin
            $display("FAIL [ARM policy row count]: expected 1066 got %0d",
                     arm_trap_rows);
            errors++;
        end
        if (thumb_trap_rows != 448) begin
            $display("FAIL [Thumb policy row count]: expected 448 got %0d",
                     thumb_trap_rows);
            errors++;
        end
        if (defined_policy_rows != 12) begin
            $display("FAIL [defined policy row count]: expected 12 got %0d",
                     defined_policy_rows);
            errors++;
        end

        if (errors != 0)
            $fatal(1, "unpredictable_decode_tb: FAIL (%0d errors)", errors);
        $display("unpredictable_decode_tb: PASS (1066 ARM traps, 448 Thumb traps, 12 deterministic rows)");
        $finish;
    end

    initial begin
        #2000000;
        $fatal(1, "unpredictable_decode_tb: TIMEOUT");
    end

endmodule
