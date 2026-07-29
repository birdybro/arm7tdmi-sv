// ERR-001 / ARM7TDMI-S erratum [2] corrected-behavior regression.
//
// FR002-PRDC-002719 7.0 describes a false Undefined exception when:
//   * an ALU write to r15 or BX enters or remains in Thumb state,
//   * the second discarded branch-shadow halfword looks Undefined in Thumb,
//   * and the destination instruction is SWI or returns Prefetch Abort.
//
// Exercise ARM->Thumb and Thumb->Thumb through both BX and the applicable
// ALU-to-PC form, crossed with both destination outcomes. The deliberately
// Undefined 0xDE00 shadow halfwords must never become architecturally
// visible; the destination exception must win.

`timescale 1ns/1ps

/* verilator lint_off DECLFILENAME */
module arm7tdmis_erratum2_exception_priority_scenario #(
    parameter bit SOURCE_THUMB = 1'b0,
    parameter bit ALU_PC_WRITE = 1'b0,
    parameter bit TARGET_ABORT = 1'b0
) (
    output logic done,
    output logic failed
);
    import arm7tdmis_instr_pkg::*;

    logic CLK;
    logic nRESET;
    logic inject_abort;

    arm7tdmis_test_fixture #(
        .CYCLE_LIMIT  (260),
        .MEMORY_WORDS (128),
        .TEST_NAME    ("erratum2_exception_priority"),
        .FST_FILE     ("erratum2_exception_priority.fst")
    ) u_fixture (
        .CFGBIGEND    (1'b0),
        .CLKEN        (1'b1),
        .nIRQ         (1'b1),
        .nFIQ         (1'b1),
        .inject_abort (inject_abort),
        .CLK           (CLK),
        .nRESET        (nRESET)
    );

    // ABORT is response-timed and belongs only to the Thumb target at 0xA0.
    assign inject_abort = TARGET_ABORT
                       && u_fixture.u_mem.is_active_q
                       && !u_fixture.u_mem.write_q
                       && (u_fixture.u_mem.addr_q == 32'h0000_00A0);

    initial begin : initialize_program
        // Fill every reachable location with a condition-failed ARM no-op.
        for (int i = 0; i < 128; i++)
            u_fixture.u_mem.mem[i] = 32'h0000_0000;

        u_fixture.u_mem.mem[0] = 32'hEA00_000E; // Reset: B 0x40
        u_fixture.u_mem.mem[1] = 32'hEAFF_FFFE; // Undef: trap if selected
        u_fixture.u_mem.mem[2] = 32'hEA00_002C; // SWI: B 0xC0
        u_fixture.u_mem.mem[3] = 32'hEA00_002F; // PABT: B 0xD0

        if (!SOURCE_THUMB) begin
            u_fixture.u_mem.mem[16] = 32'hE3A0_00A1; // 0x40 MOV r0,#0xA1
            if (!ALU_PC_WRITE) begin
                u_fixture.u_mem.mem[17] = 32'hE12F_FF10; // 0x44 BX r0
                // Both discarded ARM words contain Thumb UDF halfwords.
                u_fixture.u_mem.mem[18] = 32'hDE00_DE00;
                u_fixture.u_mem.mem[19] = 32'hDE00_DE00;
            end else begin
                u_fixture.u_mem.mem[17] = 32'hE3A0_1033; // SPSR: SVC, T=1
                u_fixture.u_mem.mem[18] = 32'hE161_F001; // MSR SPSR_c,r1
                u_fixture.u_mem.mem[19] = 32'hE1B0_F000; // MOVS pc,r0
                u_fixture.u_mem.mem[20] = 32'hDE00_DE00;
                u_fixture.u_mem.mem[21] = 32'hDE00_DE00;
            end
        end else begin
            u_fixture.u_mem.mem[16] = 32'hE3A0_0081; // 0x40 MOV r0,#0x81
            u_fixture.u_mem.mem[17] = 32'hE12F_FF10; // 0x44 BX r0
            u_fixture.u_mem.mem[32] = ALU_PC_WRITE
                ? 32'h468F_21A1 // 0x80 MOVS r1,#0xA1; MOV pc,r1
                : 32'h4708_21A1; // 0x80 MOVS r1,#0xA1; BX r1
            u_fixture.u_mem.mem[33] = 32'hDE00_DE00; // second Thumb shadow is UDF
        end

        // Target Thumb instruction is SWI #0.  In TARGET_ABORT scenarios its
        // fetch is aborted, so it must instead take Prefetch Abort.
        u_fixture.u_mem.mem[40] = 32'h46C0_DF00;
        u_fixture.u_mem.mem[48] = 32'hEAFF_FFFE; // 0xC0 SWI handler loop
        u_fixture.u_mem.mem[52] = 32'hEAFF_FFFE; // 0xD0 PABT handler loop
    end

    bit saw_source_pc_write;
    bit saw_target_fetch;
    bit saw_expected;
    bit saw_wrong_exception;
    bit saw_undef;

    always_ff @(posedge CLK) begin
        if (!nRESET) begin
            saw_source_pc_write <= 1'b0;
            saw_target_fetch    <= 1'b0;
            saw_expected        <= 1'b0;
            saw_wrong_exception <= 1'b0;
            saw_undef           <= 1'b0;
        end else begin
            if ((u_fixture.u_dut.u_core.state_q == 5'd0)
                && u_fixture.u_dut.u_core.de_q.valid
                && (u_fixture.u_dut.u_core.de_q.pc
                    == (SOURCE_THUMB ? 32'h0000_0082
                       : ALU_PC_WRITE ? 32'h0000_004C
                                      : 32'h0000_0044))
                && u_fixture.u_dut.u_core.writes_pc_exec)
                saw_source_pc_write <= 1'b1;

            if (u_fixture.u_mem.is_active_q
                && !u_fixture.u_mem.write_q
                && (u_fixture.u_mem.addr_q == 32'h0000_00A0))
                saw_target_fetch <= 1'b1;

            if (u_fixture.u_dut.u_core.undef_fires)
                saw_undef <= 1'b1;

            if (TARGET_ABORT) begin
                if (u_fixture.u_dut.u_core.pabt_fires)
                    saw_expected <= 1'b1;
                if (u_fixture.u_dut.u_core.swi_fires)
                    saw_wrong_exception <= 1'b1;
            end else begin
                if (u_fixture.u_dut.u_core.swi_fires)
                    saw_expected <= 1'b1;
                if (u_fixture.u_dut.u_core.pabt_fires)
                    saw_wrong_exception <= 1'b1;
            end
        end
    end

    string source_name;
    string target_name;
    int unsigned errors;

    initial begin : check_result
        done   = 1'b0;
        failed = 1'b0;
        errors = 0;
        source_name = {
            SOURCE_THUMB ? "Thumb-to-Thumb/" : "ARM-to-Thumb/",
            ALU_PC_WRITE ? "ALU-PC" : "BX"
        };
        target_name = TARGET_ABORT ? "PABT" : "SWI";

        wait (nRESET);
        for (int i = 0; i < 180; i++) begin
            @(posedge CLK);
            if (saw_expected)
                break;
        end
        repeat (4) @(posedge CLK);

        if (!saw_source_pc_write) begin
            $display("[erratum2/%s/%s] FAIL source PC write did not execute",
                     source_name, target_name);
            errors++;
        end
        if (!saw_target_fetch) begin
            $display("[erratum2/%s/%s] FAIL target fetch was not observed",
                     source_name, target_name);
            errors++;
        end
        if (!saw_expected) begin
            $display("[erratum2/%s/%s] FAIL destination exception did not fire",
                     source_name, target_name);
            errors++;
        end
        if (saw_undef || saw_wrong_exception) begin
            $display("[erratum2/%s/%s] FAIL undef/wrong=%0b/%0b",
                     source_name, target_name, saw_undef,
                     saw_wrong_exception);
            errors++;
        end

        failed = (errors != 0);
        done   = 1'b1;
    end
endmodule
/* verilator lint_on DECLFILENAME */

module arm7tdmis_erratum2_exception_priority_tb;
    logic [7:0] done;
    logic [7:0] failed;

    arm7tdmis_erratum2_exception_priority_scenario #(
        .SOURCE_THUMB (1'b0),
        .ALU_PC_WRITE (1'b0),
        .TARGET_ABORT (1'b0)
    ) u_arm_bx_swi (.done(done[0]), .failed(failed[0]));

    arm7tdmis_erratum2_exception_priority_scenario #(
        .SOURCE_THUMB (1'b0),
        .ALU_PC_WRITE (1'b0),
        .TARGET_ABORT (1'b1)
    ) u_arm_bx_pabt (.done(done[1]), .failed(failed[1]));

    arm7tdmis_erratum2_exception_priority_scenario #(
        .SOURCE_THUMB (1'b1),
        .ALU_PC_WRITE (1'b0),
        .TARGET_ABORT (1'b0)
    ) u_thumb_bx_swi (.done(done[2]), .failed(failed[2]));

    arm7tdmis_erratum2_exception_priority_scenario #(
        .SOURCE_THUMB (1'b1),
        .ALU_PC_WRITE (1'b0),
        .TARGET_ABORT (1'b1)
    ) u_thumb_bx_pabt (.done(done[3]), .failed(failed[3]));

    arm7tdmis_erratum2_exception_priority_scenario #(
        .SOURCE_THUMB (1'b0),
        .ALU_PC_WRITE (1'b1),
        .TARGET_ABORT (1'b0)
    ) u_arm_alu_swi (.done(done[4]), .failed(failed[4]));

    arm7tdmis_erratum2_exception_priority_scenario #(
        .SOURCE_THUMB (1'b0),
        .ALU_PC_WRITE (1'b1),
        .TARGET_ABORT (1'b1)
    ) u_arm_alu_pabt (.done(done[5]), .failed(failed[5]));

    arm7tdmis_erratum2_exception_priority_scenario #(
        .SOURCE_THUMB (1'b1),
        .ALU_PC_WRITE (1'b1),
        .TARGET_ABORT (1'b0)
    ) u_thumb_alu_swi (.done(done[6]), .failed(failed[6]));

    arm7tdmis_erratum2_exception_priority_scenario #(
        .SOURCE_THUMB (1'b1),
        .ALU_PC_WRITE (1'b1),
        .TARGET_ABORT (1'b1)
    ) u_thumb_alu_pabt (.done(done[7]), .failed(failed[7]));

    initial begin
        wait (&done);
        if (|failed)
            $fatal(1, "[erratum2_exception_priority] FAIL scenarios=%08b",
                   failed);
        $display("[erratum2_exception_priority] PASS");
        $finish;
    end
endmodule
