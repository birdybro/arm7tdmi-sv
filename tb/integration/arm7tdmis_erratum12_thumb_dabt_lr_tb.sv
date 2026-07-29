// ERR-001 / ARM7TDMI-S erratum [12] corrected-behavior regression.
//
// The affected sequence is Thumb STR, STMIA, or PUSH at a halfword address
// ending in binary 10, followed immediately by a PC-relative LDR.  If the
// store aborts, r14_abt must retain halfword resolution.  For the opcode at
// 0x42 the architectural Data Abort link is 0x4A, never the word-rounded
// 0x48 produced by affected revisions.

`timescale 1ns/1ps

/* verilator lint_off DECLFILENAME */
module arm7tdmis_erratum12_thumb_dabt_lr_scenario #(
    parameter int unsigned STORE_KIND = 0
) (
    output logic done,
    output logic failed
);
    import arm7tdmis_types_pkg::*;

    localparam int unsigned KIND_STR   = 0;
    localparam int unsigned KIND_STMIA = 1;
    localparam int unsigned KIND_PUSH  = 2;

    localparam logic [15:0] STORE_OPCODE =
        (STORE_KIND == KIND_STR)   ? 16'h6001  // STR r1,[r0,#0]
      : (STORE_KIND == KIND_STMIA) ? 16'hC002  // STMIA r0!,{r1}
                                    : 16'hB402; // PUSH {r1}
    localparam logic [31:0] DATA_ADDR =
        (STORE_KIND == KIND_PUSH) ? 32'h0000_00FC : 32'h0000_0100;

    logic CLK;
    logic nRESET;
    logic inject_abort;

    arm7tdmis_test_fixture #(
        .CYCLE_LIMIT  (260),
        .MEMORY_WORDS (128),
        .TEST_NAME    ("erratum12_thumb_dabt_lr"),
        .FST_FILE     ("erratum12_thumb_dabt_lr.fst")
    ) u_fixture (
        .CFGBIGEND    (1'b0),
        .CLKEN        (1'b1),
        .nIRQ         (1'b1),
        .nFIQ         (1'b1),
        .inject_abort,
        .CLK,
        .nRESET
    );

    assign inject_abort = u_fixture.u_mem.is_active_q
                       && u_fixture.u_mem.write_q
                       && (u_fixture.u_mem.addr_q == DATA_ADDR);

    initial begin : initialize_program
        for (int i = 0; i < 128; i++)
            u_fixture.u_mem.mem[i] = 32'hE1A0_0000;

        u_fixture.u_mem.mem[0] = 32'hEA00_0006; // Reset: B 0x20
        u_fixture.u_mem.mem[4] = 32'hEA00_001A; // DABT: B 0x80

        u_fixture.u_mem.mem[8]  = 32'hE3A0_0C01; // MOV r0,#0x100
        u_fixture.u_mem.mem[9]  = 32'hE3A0_1055; // MOV r1,#0x55
        u_fixture.u_mem.mem[10] = 32'hE3A0_DC01; // MOV sp,#0x100
        u_fixture.u_mem.mem[11] = 32'hE3A0_3041; // MOV r3,#0x41
        u_fixture.u_mem.mem[12] = 32'hE12F_FF13; // BX r3

        // 0x40 NOP; 0x42 aborting store.  The immediately following
        // PC-relative LDR is present specifically to trigger the erratum.
        u_fixture.u_mem.mem[16] = {STORE_OPCODE, 16'h46C0};
        u_fixture.u_mem.mem[17] = 32'h46C0_4A00; // LDR r2,[pc,#0]; NOP
        u_fixture.u_mem.mem[18] = 32'hCAFE_BABE; // literal if wrongly run

        u_fixture.u_mem.mem[32] = 32'hE3A0_7012; // handler marker
        u_fixture.u_mem.mem[33] = 32'hEAFF_FFFE;

        u_fixture.u_mem.mem[63] = 32'h1122_3344;
        u_fixture.u_mem.mem[64] = 32'h5566_7788;
    end

    bit abort_seen;
    bit dabt_seen;
    always_ff @(posedge CLK) begin
        if (!nRESET) begin
            abort_seen <= 1'b0;
            dabt_seen  <= 1'b0;
        end else begin
            if (u_fixture.ABORT)
                abort_seen <= 1'b1;
            if (u_fixture.u_dut.u_core.dabt_fires)
                dabt_seen <= 1'b1;
        end
    end

    string kind_name;
    int unsigned errors;
    initial begin : check_result
        done   = 1'b0;
        failed = 1'b0;
        errors = 0;
        kind_name = (STORE_KIND == KIND_STR) ? "STR"
                  : (STORE_KIND == KIND_STMIA) ? "STMIA" : "PUSH";

        wait (nRESET);
        for (int i = 0; i < 180; i++) begin
            @(posedge CLK);
            if (u_fixture.u_dut.u_core.u_regfile.regs[7] == 32'h12)
                break;
        end

        if (!abort_seen || !dabt_seen) begin
            $display("[erratum12/%s] FAIL abort/dabt=%0b/%0b",
                     kind_name, abort_seen, dabt_seen);
            errors++;
        end
        if (u_fixture.u_dut.u_core.u_regfile.regs[28]
            !== 32'h0000_004A) begin
            $display("[erratum12/%s] FAIL r14_abt expected 0000004a got %08x",
                     kind_name,
                     u_fixture.u_dut.u_core.u_regfile.regs[28]);
            errors++;
        end
        if (u_fixture.u_dut.u_core.u_psr.spsr_q[3]
            !== 32'h0000_00F3) begin
            $display("[erratum12/%s] FAIL SPSR_abt expected 000000f3 got %08x",
                     kind_name, u_fixture.u_dut.u_core.u_psr.spsr_q[3]);
            errors++;
        end
        if ((u_fixture.u_dut.u_core.cpsr.m !== 5'(MODE_ABORT))
            || u_fixture.u_dut.u_core.cpsr.t
            || (u_fixture.u_dut.u_core.u_regfile.regs[7] !== 32'h12)) begin
            $display("[erratum12/%s] FAIL mode/T/marker=%05b/%0b/%08x",
                     kind_name, u_fixture.u_dut.u_core.cpsr.m,
                     u_fixture.u_dut.u_core.cpsr.t,
                     u_fixture.u_dut.u_core.u_regfile.regs[7]);
            errors++;
        end
        if (u_fixture.u_dut.u_core.u_regfile.regs[2] !== 32'h0) begin
            $display("[erratum12/%s] FAIL following PC-relative LDR executed",
                     kind_name);
            errors++;
        end
        if (u_fixture.u_mem.mem[63] !== 32'h1122_3344
            || u_fixture.u_mem.mem[64] !== 32'h5566_7788) begin
            $display("[erratum12/%s] FAIL aborted store changed memory %08x/%08x",
                     kind_name, u_fixture.u_mem.mem[63],
                     u_fixture.u_mem.mem[64]);
            errors++;
        end

        failed = (errors != 0);
        done   = 1'b1;
    end
endmodule
/* verilator lint_on DECLFILENAME */

module arm7tdmis_erratum12_thumb_dabt_lr_tb;
    logic [2:0] done;
    logic [2:0] failed;

    arm7tdmis_erratum12_thumb_dabt_lr_scenario #(
        .STORE_KIND (0)
    ) u_str (.done(done[0]), .failed(failed[0]));

    arm7tdmis_erratum12_thumb_dabt_lr_scenario #(
        .STORE_KIND (1)
    ) u_stmia (.done(done[1]), .failed(failed[1]));

    arm7tdmis_erratum12_thumb_dabt_lr_scenario #(
        .STORE_KIND (2)
    ) u_push (.done(done[2]), .failed(failed[2]));

    initial begin
        wait (&done);
        if (|failed)
            $fatal(1, "[erratum12_thumb_dabt_lr] FAIL scenarios=%03b",
                   failed);
        $display("[erratum12_thumb_dabt_lr] PASS");
        $finish;
    end
endmodule
