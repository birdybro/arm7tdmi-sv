// Unit coverage for all 19 ARMv4T Thumb encoding formats.
//
// These checks are intentionally decoder-local: they prove classification
// and normalized micro-op fields without reusing the integration core. The
// instruction values were independently assembled for -march=armv4t where
// applicable; reserved encodings come directly from the ARMv4T format map.

module thumb_decoder_tb
    import arm7tdmis_types_pkg::*;
    import arm7tdmis_instr_pkg::*;
;

    logic [15:0] thumb_instr;
    decoded_t    dec;
    logic        is_dataproc;
    logic        is_unimplemented;

    arm7tdmis_thumb_decoder dut (.*);

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, dec, is_dataproc, is_unimplemented};
    /* verilator lint_on UNUSEDSIGNAL */

    int unsigned errors;

    task automatic settle(input logic [15:0] encoding);
        thumb_instr = encoding;
        #1;
    endtask

    task automatic check_class(input string label, input instr_class_e expected);
        if (dec.instr_class !== expected) begin
            $display("FAIL [%s]: class expected %0d, got %0d",
                     label, expected, dec.instr_class);
            errors = errors + 1;
        end
    endtask

    task automatic check4(
        input string label,
        input logic [3:0] actual,
        input logic [3:0] expected
    );
        if (actual !== expected) begin
            $display("FAIL [%s]: expected %x, got %x", label, expected, actual);
            errors = errors + 1;
        end
    endtask

    task automatic check8(
        input string label,
        input logic [7:0] actual,
        input logic [7:0] expected
    );
        if (actual !== expected) begin
            $display("FAIL [%s]: expected %02x, got %02x", label, expected, actual);
            errors = errors + 1;
        end
    endtask

    task automatic check1(
        input string label,
        input logic actual,
        input logic expected
    );
        if (actual !== expected) begin
            $display("FAIL [%s]: expected %0b, got %0b", label, expected, actual);
            errors = errors + 1;
        end
    endtask

    initial begin
        errors = 0;
        thumb_instr = 16'h0000;

        // Format 1: move shifted register. Encoded zero means 32 for
        // immediate LSR/ASR, but an ordinary zero for LSL.
        settle(16'h0048);  // LSLS r0,r1,#1
        check_class("fmt1 LSL", INSTR_DP);
        check4("fmt1 LSL op", 4'(dec.shifter_op), 4'(SHIFT_LSL));
        check8("fmt1 LSL amount", dec.shifter_amount, 8'd1);

        settle(16'h081A);  // LSRS r2,r3,#32 (imm5 field is zero)
        check_class("fmt1 LSR encoded zero", INSTR_DP);
        check4("fmt1 LSR op", 4'(dec.shifter_op), 4'(SHIFT_LSR));
        check8("fmt1 LSR amount", dec.shifter_amount, 8'd32);

        settle(16'h102C);  // ASRS r4,r5,#32 (imm5 field is zero)
        check_class("fmt1 ASR encoded zero", INSTR_DP);
        check4("fmt1 ASR op", 4'(dec.shifter_op), 4'(SHIFT_ASR));
        check8("fmt1 ASR amount", dec.shifter_amount, 8'd32);

        // Format 2: add/subtract register or imm3.
        settle(16'h1888);  // ADDS r0,r1,r2
        check_class("fmt2 ADD register", INSTR_DP);
        check4("fmt2 rn", dec.rn, 4'd1);
        check4("fmt2 rm", dec.rm, 4'd2);

        settle(16'h1FE3);  // SUBS r3,r4,#7
        check_class("fmt2 SUB imm3", INSTR_DP);
        check1("fmt2 immediate", dec.dp_use_imm, 1'b1);

        // Format 3: immediate data processing.
        settle(16'h2012);  // MOVS r0,#0x12
        check_class("fmt3 MOV immediate", INSTR_DP);
        check4("fmt3 rd", dec.rd, 4'd0);

        // Format 4: ALU operations, including register-specified shifts.
        settle(16'h4008);  // ANDS r0,r1
        check_class("fmt4 AND", INSTR_DP);
        check4("fmt4 AND op", 4'(dec.alu_op), 4'(ALU_AND));

        settle(16'h409A);  // LSLS r2,r3
        check_class("fmt4 LSL register", INSTR_DP);
        check1("fmt4 shift uses Rs", dec.shifter_use_rs, 1'b1);
        check4("fmt4 shift Rs", dec.rs, 4'd3);

        // Format 5: high-register operations and BX.
        settle(16'h4488);  // ADD r8,r1
        check_class("fmt5 high ADD", INSTR_DP);
        check4("fmt5 high rd", dec.rd, 4'd8);

        settle(16'h4720);  // BX r4
        check_class("fmt5 BX", INSTR_BX);
        check4("fmt5 BX rm", dec.rm, 4'd4);

        // Format 6: PC-relative load.
        settle(16'h4803);  // LDR r0,[PC,#12]
        check_class("fmt6 PC-relative LDR", INSTR_LDR_STR);
        check4("fmt6 rn is PC", dec.rn, 4'd15);
        check1("fmt6 load", dec.ls_load, 1'b1);

        // Formats 7 and 8: register-offset transfers.
        settle(16'h5088);  // STR r0,[r1,r2]
        check_class("fmt7 STR register", INSTR_LDR_STR);
        check1("fmt7 store", dec.ls_load, 1'b0);

        settle(16'h5763);  // LDRSB r3,[r4,r5]
        check_class("fmt8 LDRSB", INSTR_LDRH_STRH);
        check1("fmt8 signed", dec.hs_signed, 1'b1);
        check1("fmt8 byte", dec.hs_halfword, 1'b0);

        // Formats 9 through 13: immediate/SP/PC addressing.
        settle(16'h68C8);  // LDR r0,[r1,#12]
        check_class("fmt9 LDR immediate", INSTR_LDR_STR);
        check1("fmt9 load", dec.ls_load, 1'b1);

        settle(16'h895A);  // LDRH r2,[r3,#10]
        check_class("fmt10 LDRH immediate", INSTR_LDRH_STRH);
        check1("fmt10 halfword", dec.hs_halfword, 1'b1);

        settle(16'h9404);  // STR r4,[SP,#16]
        check_class("fmt11 SP-relative STR", INSTR_LDR_STR);
        check4("fmt11 rn is SP", dec.rn, 4'd13);

        settle(16'hA503);  // ADD r5,PC,#12
        check_class("fmt12 PC address", INSTR_DP);
        check4("fmt12 PC rn", dec.rn, 4'd15);
        check1("fmt12 PC alignment", dec.dp_pc_align, 1'b1);

        settle(16'hAE05);  // ADD r6,SP,#20
        check_class("fmt12 SP address", INSTR_DP);
        check4("fmt12 SP rn", dec.rn, 4'd13);

        settle(16'hB087);  // SUB SP,#28
        check_class("fmt13 SP adjust", INSTR_DP);
        check4("fmt13 rd", dec.rd, 4'd13);

        // Formats 14 and 15: stack and low-register block transfers.
        settle(16'hB505);  // PUSH {r0,r2,lr}
        check_class("fmt14 PUSH", INSTR_LDM_STM);
        check1("fmt14 PUSH store", dec.block_load, 1'b0);
        check1("fmt14 PUSH LR", dec.block_reg_list[14], 1'b1);

        settle(16'hBD05);  // POP {r0,r2,pc}
        check_class("fmt14 POP", INSTR_LDM_STM);
        check1("fmt14 POP load", dec.block_load, 1'b1);
        check1("fmt14 POP PC", dec.block_reg_list[15], 1'b1);

        settle(16'hC105);  // STMIA r1!,{r0,r2}
        check_class("fmt15 STMIA", INSTR_LDM_STM);
        check1("fmt15 STM store", dec.block_load, 1'b0);

        settle(16'hC905);  // LDMIA r1!,{r0,r2}
        check_class("fmt15 LDMIA", INSTR_LDM_STM);
        check1("fmt15 LDM load", dec.block_load, 1'b1);

        // Formats 16 and 17 share 1101. Condition 1110 is reserved in
        // ARMv4T Thumb and must trap Undefined; 1111 is SWI.
        settle(16'hD002);  // BEQ +4
        check_class("fmt16 BEQ", INSTR_BRANCH);
        check4("fmt16 condition", 4'(dec.cond), 4'(COND_EQ));

        settle(16'hDE00);  // reserved condition 1110
        check_class("fmt16 reserved cond 1110", INSTR_UNDEF);
        check1("fmt16 reserved flagged unimplemented", is_unimplemented, 1'b1);

        settle(16'hDF34);  // SWI #0x34
        check_class("fmt17 SWI", INSTR_SWI);
        check8("fmt17 comment", dec.swi_comment[7:0], 8'h34);

        // Formats 18 and 19: unconditional B and two-halfword BL.
        settle(16'hE000);  // B +0
        check_class("fmt18 B", INSTR_BRANCH);
        check1("fmt18 no link", dec.branch_link, 1'b0);

        settle(16'hF000);  // BL prefix, high offset zero
        check_class("fmt19 BL prefix", INSTR_DP);
        check4("fmt19 prefix writes LR", dec.rd, 4'd14);

        settle(16'hF800);  // BL suffix, low offset zero
        check_class("fmt19 BL suffix", INSTR_BRANCH);
        check1("fmt19 suffix link", dec.branch_link, 1'b1);
        check1("fmt19 Thumb link form", dec.branch_thumb_link, 1'b1);

        // A representative reserved hole outside every valid format.
        settle(16'hB100);
        check_class("reserved 0xB1xx hole", INSTR_UNDEF);
        check1("reserved hole flagged unimplemented", is_unimplemented, 1'b1);

        if (errors != 0)
            $fatal(1, "thumb_decoder_tb: FAIL (%0d errors)", errors);
        $display("thumb_decoder_tb: PASS");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "thumb_decoder_tb: TIMEOUT");
    end

endmodule
