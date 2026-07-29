// Exhaustive ARMv4T reserved-encoding classification.
//
// ARM ARM DDI 0100I §A3.16 defines the ARM decode bits as [27:20] and
// [7:4].  There are only 4096 combinations, so this test checks every one
// against an independent transcription of the ARMv4T allocation tables.
// Canonical values are supplied for non-decode SBZ/SBO fields; malformed
// values sharing defined decode bits are UNPREDICTABLE and belong to the
// separately documented ISA-016 policy rather than the Undefined space.
//
// The original 16-bit Thumb map is smaller still, so every one of its 65536
// encodings is checked.  The reserved ranges combine the ARMv4T format map
// with encodings allocated only by ARMv5T/ARMv6.

module reserved_decode_tb
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
    int unsigned arm_class_count [0:15];
    int unsigned arm_nv_class_count [0:15];
    int unsigned thumb_reserved_count [0:1];
    int unsigned thumb_policy_unpredictable_count;

    // Independent ARMv4T allocation map for the twelve architectural
    // decode bits.  The order follows the extension-space rules in A3.16,
    // not the RTL decoder's hierarchy.
    function automatic instr_class_e armv4t_class(
        input logic [7:0] op_hi,
        input logic [3:0] op_lo
    );
        case (op_hi[7:5])
            3'b000: begin
                // bit[7]=bit[4]=1 selects multiply/extra-transfer space.
                if (op_lo[3] && op_lo[0]) begin
                    case (op_lo)
                        4'h9: begin
                            if (op_hi inside {[8'h00:8'h03]})
                                return INSTR_MUL;
                            if (op_hi inside {[8'h08:8'h0F]})
                                return INSTR_MULL;
                            if ((op_hi == 8'h10) || (op_hi == 8'h14))
                                return INSTR_SWP;
                            return INSTR_UNDEF;
                        end
                        4'hB: return INSTR_LDRH_STRH;
                        4'hD, 4'hF:
                            return op_hi[0] ? INSTR_LDRH_STRH : INSTR_UNDEF;
                        default: return INSTR_UNDEF;
                    endcase
                end

                // Opcode 10xx with S=0 is control-extension space, not
                // ordinary data processing.
                if ((op_hi == 8'h10) || (op_hi == 8'h12)
                 || (op_hi == 8'h14) || (op_hi == 8'h16)) begin
                    if (((op_hi == 8'h10) || (op_hi == 8'h14))
                     && (op_lo == 4'h0))
                        return INSTR_MRS;
                    if (((op_hi == 8'h12) || (op_hi == 8'h16))
                     && (op_lo == 4'h0))
                        return INSTR_MSR;
                    if ((op_hi == 8'h12) && (op_lo == 4'h1))
                        return INSTR_BX;
                    return INSTR_UNDEF;
                end

                return INSTR_DP;
            end

            3'b001: begin
                // Immediate MRS-shaped holes are architecturally
                // Undefined.  The neighboring decode values are MSR
                // immediate; all other values are ordinary DP immediate.
                if ((op_hi == 8'h30) || (op_hi == 8'h34))
                    return INSTR_UNDEF;
                if ((op_hi == 8'h32) || (op_hi == 8'h36))
                    return INSTR_MSR;
                return INSTR_DP;
            end

            3'b010: return INSTR_LDR_STR;

            // Register-offset single transfers require bit[4]=0.  The
            // bit[4]=1 media space has no ARMv4T allocations.
            3'b011: return op_lo[0] ? INSTR_UNDEF : INSTR_LDR_STR;

            3'b100: return INSTR_LDM_STM;
            3'b101: return INSTR_BRANCH;

            3'b110: begin
                // 11000x0x is the coprocessor extension space used by
                // MCRR/MRRC only in later architectures; all four high
                // decode values are Undefined in ARMv4T.
                if ((op_hi[7:3] == 5'b11000) && !op_hi[1])
                    return INSTR_UNDEF;
                return INSTR_LDC_STC;
            end

            3'b111: begin
                if (op_hi[4])
                    return INSTR_SWI;
                return op_lo[0] ? INSTR_MCR_MRC : INSTR_CDP;
            end

            default: return INSTR_UNDEF;
        endcase
    endfunction

    // Supply architecturally valid values for fields that are outside the
    // decode-bit set but constrained by a particular instruction.
    function automatic logic [31:0] canonical_arm_word(
        input logic [7:0] op_hi,
        input logic [3:0] op_lo,
        input instr_class_e expected
    );
        logic [31:0] word;
        word = 32'hE000_0000;
        word[27:20] = op_hi;
        word[7:4]   = op_lo;

        case (expected)
            INSTR_MUL: begin
                word[19:16] = 4'd1;
                word[15:12] = op_hi[1] ? 4'd2 : 4'd0;
                word[11:8]  = 4'd3;
                word[3:0]   = 4'd4;
            end
            INSTR_MULL: begin
                word[19:16] = 4'd1;
                word[15:12] = 4'd2;
                word[11:8]  = 4'd3;
                word[3:0]   = 4'd4;
            end
            INSTR_MRS: begin
                word[19:16] = 4'hF;
                word[11:0]  = 12'h000;
            end
            INSTR_MSR: begin
                word[19:16] = 4'hF;
                word[15:12] = 4'hF;
                if (op_hi[5] == 1'b0)
                    word[11:4] = 8'h00;
            end
            INSTR_BX: word[19:8] = 12'hFFF;
            INSTR_LDR_STR, INSTR_LDRH_STRH: begin
                // Avoid the transfer aliases covered by the separate
                // ISA-016 policy test: distinct, non-PC Rn/Rd/Rm values
                // keep this test focused on the architectural decode map.
                word[19:16] = 4'd1;
                word[15:12] = 4'd2;
                word[3:0]   = 4'd3;
            end
            INSTR_LDC_STC: word[19:16] = 4'd1;
            default: ;
        endcase

        return word;
    endfunction

    function automatic logic thumb_reserved_v4t(input logic [15:0] word);
        return (word inside {[16'hB100:16'hB3FF]})
            || (word inside {[16'hB600:16'hBBFF]})
            || (word inside {[16'hBE00:16'hBFFF]})
            || (word inside {[16'hDE00:16'hDEFF]})
            || (word inside {[16'hE800:16'hEFFF]});
    endfunction

    // These remain allocated ARMv4T format-map rows. Their operand/SBZ
    // violations are UNPREDICTABLE and separately assigned the project's
    // precise-Undefined ISA-016 policy.
    /* verilator lint_off UNUSEDSIGNAL */
    function automatic logic thumb_policy_unpredictable_v4t(
        input logic [15:0] word
    );
        logic is_fmt5;
        logic [1:0] op;
        is_fmt5 = (word[15:10] == 6'b010001);
        op = word[9:8];
        return is_fmt5
            && (((op != 2'b11)
                 && ((!word[7] && !word[6])
                  || ((op == 2'b01) && ({word[7], word[2:0]} == 4'd15))))
             || ((op == 2'b11)
                 && (word[7] || (word[2:0] != 3'b000))));
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    task automatic fail_arm(
        input logic [7:0] op_hi,
        input logic [3:0] op_lo,
        input instr_class_e expected
    );
        if (errors < 32)
            $display("FAIL [ARM decode %02x/%x word=%08x]: expected class %0d got %0d",
                     op_hi, op_lo, arm_instr, expected, arm_dec.instr_class);
        errors++;
    endtask

    task automatic fail_thumb(
        input logic [15:0] word,
        input logic expected_reserved
    );
        if (errors < 32)
            $display("FAIL [Thumb word=%04x]: expected reserved=%0b, class=%0d unimplemented=%0b",
                     word, expected_reserved, thumb_dec.instr_class,
                     thumb_is_unimplemented);
        errors++;
    endtask

    initial begin
        instr_class_e expected;
        logic expected_reserved;
        logic expected_policy_unpredictable;

        errors = 0;
        arm_instr = 32'h0;
        thumb_instr = 16'h0;
        for (int i = 0; i < 16; i++)
            arm_class_count[i] = 0;
        for (int i = 0; i < 16; i++)
            arm_nv_class_count[i] = 0;
        thumb_reserved_count[0] = 0;
        thumb_reserved_count[1] = 0;
        thumb_policy_unpredictable_count = 0;

        // Exhaust the complete architectural ARM decode-bit domain.
        for (int hi = 0; hi < 256; hi++) begin
            for (int lo = 0; lo < 16; lo++) begin
                expected = armv4t_class(hi[7:0], lo[3:0]);
                arm_instr = canonical_arm_word(hi[7:0], lo[3:0], expected);
                #1;
                arm_class_count[int'(expected)]++;
                if ((arm_dec.instr_class !== expected)
                 || ((expected == INSTR_UNDEF)
                  && (arm_is_unimplemented !== 1'b1)))
                    fail_arm(hi[7:0], lo[3:0], expected);
            end
        end

        // Fixed totals make the reference map fail hard if a future edit
        // silently drops or duplicates an allocated region.
        if ((arm_class_count[INSTR_UNDEF]     != 445)
         || (arm_class_count[INSTR_DP]        != 784)
         || (arm_class_count[INSTR_MSR]       != 34)
         || (arm_class_count[INSTR_MRS]       != 2)
         || (arm_class_count[INSTR_MUL]       != 4)
         || (arm_class_count[INSTR_MULL]      != 8)
         || (arm_class_count[INSTR_BRANCH]    != 512)
         || (arm_class_count[INSTR_BX]        != 1)
         || (arm_class_count[INSTR_LDR_STR]   != 768)
         || (arm_class_count[INSTR_LDRH_STRH] != 64)
         || (arm_class_count[INSTR_LDM_STM]   != 512)
         || (arm_class_count[INSTR_SWP]       != 2)
         || (arm_class_count[INSTR_SWI]       != 256)
         || (arm_class_count[INSTR_CDP]       != 128)
         || (arm_class_count[INSTR_MCR_MRC]   != 128)
         || (arm_class_count[INSTR_LDC_STC]   != 448)) begin
            $display("FAIL [ARM coverage]: class allocation totals changed");
            errors++;
        end

        // ARMv4 defines cond=1111 as UNPREDICTABLE.  This core's stable
        // ISA-016 policy is to trap every such word as Undefined, which
        // also guarantees that no ARMv5+ unconditional extension can leak
        // into the ARM7TDMI-S decode.  Exhaust the lower decode domain.
        for (int hi = 0; hi < 256; hi++) begin
            for (int lo = 0; lo < 16; lo++) begin
                expected = armv4t_class(hi[7:0], lo[3:0]);
                arm_instr = canonical_arm_word(hi[7:0], lo[3:0], expected);
                arm_instr[31:28] = 4'hF;
                #1;
                arm_nv_class_count[int'(arm_dec.instr_class)]++;
                if ((arm_dec.cond !== COND_NV)
                 || (arm_dec.instr_class !== INSTR_UNDEF)
                 || (arm_is_unimplemented !== 1'b1))
                    fail_arm(hi[7:0], lo[3:0], INSTR_UNDEF);
            end
        end

        if (arm_nv_class_count[INSTR_UNDEF] != 4096) begin
            $display("FAIL [ARM cond=1111 coverage]: Undefined rows=%0d, expected 4096",
                     arm_nv_class_count[INSTR_UNDEF]);
            errors++;
        end
        for (int i = 1; i < 16; i++) begin
            if (arm_nv_class_count[i] != 0) begin
                $display("FAIL [ARM cond=1111 coverage]: class %0d has %0d rows",
                         i, arm_nv_class_count[i]);
                errors++;
            end
        end

        // Exhaust every possible original Thumb instruction.
        for (int word = 0; word < 65536; word++) begin
            expected_reserved = thumb_reserved_v4t(word[15:0]);
            expected_policy_unpredictable =
                thumb_policy_unpredictable_v4t(word[15:0]);
            thumb_instr = word[15:0];
            #1;
            thumb_reserved_count[expected_reserved]++;
            if (expected_policy_unpredictable)
                thumb_policy_unpredictable_count++;

            if (expected_reserved) begin
                if ((thumb_dec.instr_class !== INSTR_UNDEF)
                 || (thumb_is_unimplemented !== 1'b1))
                    fail_thumb(word[15:0], expected_reserved);
            end else if (expected_policy_unpredictable) begin
                if ((thumb_dec.instr_class !== INSTR_UNDEF)
                 || (thumb_is_unimplemented !== 1'b1))
                    fail_thumb(word[15:0], expected_reserved);
            end else if (thumb_dec.instr_class === INSTR_UNDEF) begin
                fail_thumb(word[15:0], expected_reserved);
            end
        end

        if ((thumb_reserved_count[0] != 60416)
         || (thumb_reserved_count[1] != 5120)) begin
            $display("FAIL [Thumb coverage]: valid=%0d reserved=%0d, expected 60416/5120",
                     thumb_reserved_count[0], thumb_reserved_count[1]);
            errors++;
        end
        if (thumb_policy_unpredictable_count != 448) begin
            $display("FAIL [Thumb policy coverage]: expected 448 got %0d",
                     thumb_policy_unpredictable_count);
            errors++;
        end

        if (errors != 0)
            $fatal(1, "reserved_decode_tb: FAIL (%0d errors)", errors);
        $display("reserved_decode_tb: PASS (4096 ARM decode rows, 65536 Thumb words, 448 policy traps)");
        $finish;
    end

    initial begin
        #1000000;
        $fatal(1, "reserved_decode_tb: TIMEOUT");
    end

endmodule
