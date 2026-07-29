// EXC-001 Thumb-state saved-link matrix:
//   SWI/UNDEF +2, PABT/IRQ/FIQ +4, DABT +8.
// Every case begins from the same unmasked SVC Thumb context (CPSR=0x33)
// and checks the destination SPSR as well as the banked LR.

`timescale 1ns/1ps

/* verilator lint_off DECLFILENAME */
module arm7tdmis_thumb_exception_lr_scenario #(
    parameter int    KIND     = 0,
    parameter string FST_FILE = "thumb_exception_lr.fst"
) (
    output logic done,
    output logic failed
);
    import arm7tdmis_types_pkg::*;

    localparam int K_SWI   = 0;
    localparam int K_UNDEF = 1;
    localparam int K_PABT  = 2;
    localparam int K_DABT  = 3;
    localparam int K_IRQ   = 4;
    localparam int K_FIQ   = 5;

    logic CLK;
    logic nRESET;
    logic nIRQ;
    logic nFIQ;
    logic inject_abort;
    logic [15:0] thumb_opcode;

    arm7tdmis_test_fixture #(
        .CYCLE_LIMIT (300),
        .INIT_HEX    ("../tb/programs/thumb_exception_lr_test.hex"),
        .TEST_NAME   ("thumb_exception_lr"),
        .FST_FILE    (FST_FILE)
    ) u_fixture (
        .CFGBIGEND   (1'b0),
        .CLKEN       (1'b1),
        .nIRQ        (nIRQ),
        .nFIQ        (nFIQ),
        .inject_abort(inject_abort),
        .CLK         (CLK),
        .nRESET      (nRESET)
    );

    always_comb begin
        unique case (KIND)
            K_SWI:   thumb_opcode = 16'hDF00; // SWI #0
            K_UNDEF: thumb_opcode = 16'hDE00; // reserved cond=1110
            K_DABT:  thumb_opcode = 16'h6821; // LDR r1,[r4,#0]
            default: thumb_opcode = 16'h46C0; // MOV r8,r8 (NOP)
        endcase
    end

    initial begin
        @(posedge CLK);
        u_fixture.u_mem.mem[16] = {16'hE7FE, thumb_opcode};
    end

    wire collision_window =
        (u_fixture.u_dut.u_core.state_q == 5'd0)
        && u_fixture.u_dut.u_core.de_q.valid
        && (u_fixture.u_dut.u_core.de_q.pc == 32'h00000040);

    assign nIRQ = ((KIND == K_IRQ) && collision_window) ? 1'b0 : 1'b1;
    assign nFIQ = ((KIND == K_FIQ) && collision_window) ? 1'b0 : 1'b1;

    always_comb begin
        inject_abort = 1'b0;
        if (KIND == K_PABT)
            inject_abort = u_fixture.u_mem.is_active_q
                         && (u_fixture.u_mem.addr_q == 32'h00000040);
        else if (KIND == K_DABT)
            inject_abort = (u_fixture.u_dut.u_core.state_q == 5'd1);
    end

    int unsigned errors;
    logic [4:0] expected_mode;
    logic [31:0] expected_lr;
    logic [31:0] expected_pc;
    logic [31:0] expected_marker;
    logic [4:0] lr_index;
    logic [2:0] spsr_index;
    string kind_name;

    initial begin
        done   = 1'b0;
        failed = 1'b0;
        errors = 0;

        unique case (KIND)
            K_SWI: begin
                kind_name       = "SWI";
                expected_mode   = 5'(MODE_SUPERVISOR);
                expected_lr     = 32'h00000042;
                expected_pc     = 32'h00000094;
                expected_marker = 32'h00000022;
                lr_index        = 26;
                spsr_index      = 2;
            end
            K_UNDEF: begin
                kind_name       = "UNDEF";
                expected_mode   = 5'(MODE_UNDEFINED);
                expected_lr     = 32'h00000042;
                expected_pc     = 32'h00000084;
                expected_marker = 32'h00000011;
                lr_index        = 30;
                spsr_index      = 4;
            end
            K_PABT: begin
                kind_name       = "PABT";
                expected_mode   = 5'(MODE_ABORT);
                expected_lr     = 32'h00000044;
                expected_pc     = 32'h000000A4;
                expected_marker = 32'h00000033;
                lr_index        = 28;
                spsr_index      = 3;
            end
            K_DABT: begin
                kind_name       = "DABT";
                expected_mode   = 5'(MODE_ABORT);
                expected_lr     = 32'h00000048;
                expected_pc     = 32'h000000B4;
                expected_marker = 32'h00000044;
                lr_index        = 28;
                spsr_index      = 3;
            end
            K_IRQ: begin
                kind_name       = "IRQ";
                expected_mode   = 5'(MODE_IRQ);
                expected_lr     = 32'h00000044;
                expected_pc     = 32'h000000C4;
                expected_marker = 32'h00000055;
                lr_index        = 24;
                spsr_index      = 1;
            end
            default: begin
                kind_name       = "FIQ";
                expected_mode   = 5'(MODE_FIQ);
                expected_lr     = 32'h00000044;
                expected_pc     = 32'h000000D4;
                expected_marker = 32'h00000066;
                lr_index        = 22;
                spsr_index      = 0;
            end
        endcase

        wait (nRESET);
        repeat (235) @(posedge CLK);

        if (u_fixture.u_dut.u_core.u_regfile.regs[lr_index]
            !== expected_lr) begin
            $display("[thumb_exception_lr/%s] FAIL LR expected %08x got %08x",
                     kind_name, expected_lr,
                     u_fixture.u_dut.u_core.u_regfile.regs[lr_index]);
            errors = errors + 1;
        end
        if (u_fixture.u_dut.u_core.u_psr.spsr_q[spsr_index]
            !== 32'h00000033) begin
            $display("[thumb_exception_lr/%s] FAIL SPSR expected 00000033 got %08x",
                     kind_name,
                     u_fixture.u_dut.u_core.u_psr.spsr_q[spsr_index]);
            errors = errors + 1;
        end
        if (u_fixture.u_dut.u_core.cpsr.m !== expected_mode
            || u_fixture.u_dut.u_core.cpsr.t !== 1'b0
            || u_fixture.u_dut.u_core.pc_q !== expected_pc
            || u_fixture.u_dut.u_core.u_regfile.regs[7]
               !== expected_marker) begin
            $display("[thumb_exception_lr/%s] FAIL mode=%05b T=%b pc=%08x marker=%08x",
                     kind_name, u_fixture.u_dut.u_core.cpsr.m,
                     u_fixture.u_dut.u_core.cpsr.t,
                     u_fixture.u_dut.u_core.pc_q,
                     u_fixture.u_dut.u_core.u_regfile.regs[7]);
            errors = errors + 1;
        end
        if ((KIND == K_DABT)
            && (u_fixture.u_dut.u_core.u_regfile.regs[1] !== 32'h0)) begin
            $display("[thumb_exception_lr/DABT] FAIL aborted LDR changed r1 to %08x",
                     u_fixture.u_dut.u_core.u_regfile.regs[1]);
            errors = errors + 1;
        end

        failed = (errors != 0);
        done   = 1'b1;
    end
endmodule
/* verilator lint_on DECLFILENAME */

module arm7tdmis_thumb_exception_lr_tb;
    logic [5:0] done;
    logic [5:0] failed;

    arm7tdmis_thumb_exception_lr_scenario #(
        .KIND(0), .FST_FILE("thumb_lr_swi.fst")
    ) u_swi (.done(done[0]), .failed(failed[0]));
    arm7tdmis_thumb_exception_lr_scenario #(
        .KIND(1), .FST_FILE("thumb_lr_undef.fst")
    ) u_undef (.done(done[1]), .failed(failed[1]));
    arm7tdmis_thumb_exception_lr_scenario #(
        .KIND(2), .FST_FILE("thumb_lr_pabt.fst")
    ) u_pabt (.done(done[2]), .failed(failed[2]));
    arm7tdmis_thumb_exception_lr_scenario #(
        .KIND(3), .FST_FILE("thumb_lr_dabt.fst")
    ) u_dabt (.done(done[3]), .failed(failed[3]));
    arm7tdmis_thumb_exception_lr_scenario #(
        .KIND(4), .FST_FILE("thumb_lr_irq.fst")
    ) u_irq (.done(done[4]), .failed(failed[4]));
    arm7tdmis_thumb_exception_lr_scenario #(
        .KIND(5), .FST_FILE("thumb_lr_fiq.fst")
    ) u_fiq (.done(done[5]), .failed(failed[5]));

    initial begin
        wait (&done);
        if (|failed)
            $fatal(1, "[thumb_exception_lr] FAIL");
        $display("[thumb_exception_lr] PASS (all six exception classes)");
        $finish;
    end
endmodule
