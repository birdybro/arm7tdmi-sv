// EXC-002 pairwise priority regression. The cases create simultaneous
// FIQ+IRQ, IRQ+PABT, PABT+UNDEF, and PABT+SWI requests at the same ARM
// instruction. Together they prove every realizable adjacent selection
// below Data Abort in the non-reset priority chain.

`timescale 1ns/1ps

/* verilator lint_off DECLFILENAME */
module arm7tdmis_exception_priority_scenario #(
    parameter int    CASE_ID  = 0,
    parameter string FST_FILE = "exception_priority.fst"
) (
    output logic done,
    output logic failed
);
    import arm7tdmis_types_pkg::*;

    localparam int CASE_FIQ_IRQ     = 0;
    localparam int CASE_IRQ_PABT    = 1;
    localparam int CASE_PABT_UNDEF  = 2;
    localparam int CASE_PABT_SWI    = 3;

    logic CLK;
    logic nRESET;
    logic nIRQ;
    logic nFIQ;
    logic inject_abort;

    arm7tdmis_test_fixture #(
        .CYCLE_LIMIT (260),
        .INIT_HEX    ("../tb/programs/exception_priority_test.hex"),
        .TEST_NAME   ("exception_priority"),
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

    // The low-priority side is encoded in the faulted instruction itself.
    // Patch while reset is low.
    initial begin
        @(posedge CLK);
        unique case (CASE_ID)
            CASE_PABT_UNDEF:
                u_fixture.u_mem.mem[64] = 32'hEE000700;
            CASE_PABT_SWI:
                u_fixture.u_mem.mem[64] = 32'hEF000000;
            default:
                u_fixture.u_mem.mem[64] = 32'hE1A00000;
        endcase
    end

    wire collision_window =
        (u_fixture.u_dut.u_core.state_q == 4'd0)
        && u_fixture.u_dut.u_core.de_q.valid
        && (u_fixture.u_dut.u_core.de_q.pc == 32'h00000100);

    always_comb begin
        nIRQ = 1'b1;
        nFIQ = 1'b1;
        if (collision_window) begin
            if (CASE_ID == CASE_FIQ_IRQ) begin
                nIRQ = 1'b0;
                nFIQ = 1'b0;
            end else if (CASE_ID == CASE_IRQ_PABT) begin
                nIRQ = 1'b0;
            end
        end
    end

    assign inject_abort =
        (CASE_ID != CASE_FIQ_IRQ)
        && u_fixture.u_mem.is_active_q
        && (u_fixture.u_mem.addr_q == 32'h00000100);

    int unsigned errors;
    logic [4:0] expected_mode;
    logic [31:0] expected_pc;
    logic [30:0] marker_mask;
    logic [31:0] expected_lr;
    int lr_index;
    string case_name;

    initial begin
        done        = 1'b0;
        failed      = 1'b0;
        errors      = 0;
        marker_mask = '0;

        unique case (CASE_ID)
            CASE_FIQ_IRQ: begin
                case_name     = "FIQ>IRQ";
                expected_mode = 5'(MODE_FIQ);
                expected_pc   = 32'h000000B4;
                marker_mask[6] = 1'b1;
                lr_index      = 22;
                expected_lr   = 32'h00000104;
            end
            CASE_IRQ_PABT: begin
                case_name     = "IRQ>PABT";
                expected_mode = 5'(MODE_IRQ);
                expected_pc   = 32'h000000A4;
                marker_mask[5] = 1'b1;
                lr_index      = 24;
                expected_lr   = 32'h00000104;
            end
            CASE_PABT_UNDEF: begin
                case_name     = "PABT>UNDEF";
                expected_mode = 5'(MODE_ABORT);
                expected_pc   = 32'h00000094;
                marker_mask[4] = 1'b1;
                lr_index      = 28;
                expected_lr   = 32'h00000104;
            end
            default: begin
                case_name     = "PABT>SWI";
                expected_mode = 5'(MODE_ABORT);
                expected_pc   = 32'h00000094;
                marker_mask[4] = 1'b1;
                lr_index      = 28;
                expected_lr   = 32'h00000104;
            end
        endcase

        wait (nRESET);
        repeat (205) @(posedge CLK);

        if (u_fixture.u_dut.u_core.cpsr.m !== expected_mode
            || u_fixture.u_dut.u_core.pc_q !== expected_pc) begin
            $display("[exception_priority/%s] FAIL mode=%05b pc=%08x expected %05b/%08x",
                     case_name, u_fixture.u_dut.u_core.cpsr.m,
                     u_fixture.u_dut.u_core.pc_q, expected_mode,
                     expected_pc);
            errors = errors + 1;
        end
        if (u_fixture.u_dut.u_core.u_regfile.regs[lr_index]
            !== expected_lr) begin
            $display("[exception_priority/%s] FAIL LR bank %0d expected %08x got %08x",
                     case_name, lr_index, expected_lr,
                     u_fixture.u_dut.u_core.u_regfile.regs[lr_index]);
            errors = errors + 1;
        end
        for (int r = 3; r <= 6; r++) begin
            logic [31:0] expected_marker;
            expected_marker = marker_mask[r] ? {24'h0, 4'(r), 4'(r)}
                                             : 32'h0;
            if (u_fixture.u_dut.u_core.u_regfile.regs[r]
                !== expected_marker) begin
                $display("[exception_priority/%s] FAIL r%0d expected %08x got %08x",
                         case_name, r, expected_marker,
                         u_fixture.u_dut.u_core.u_regfile.regs[r]);
                errors = errors + 1;
            end
        end

        failed = (errors != 0);
        done   = 1'b1;
    end
endmodule
/* verilator lint_on DECLFILENAME */

module arm7tdmis_exception_priority_tb;
    logic [3:0] done;
    logic [3:0] failed;

    arm7tdmis_exception_priority_scenario #(
        .CASE_ID  (0),
        .FST_FILE ("exception_priority_fiq_irq.fst")
    ) u_fiq_irq (.done(done[0]), .failed(failed[0]));

    arm7tdmis_exception_priority_scenario #(
        .CASE_ID  (1),
        .FST_FILE ("exception_priority_irq_pabt.fst")
    ) u_irq_pabt (.done(done[1]), .failed(failed[1]));

    arm7tdmis_exception_priority_scenario #(
        .CASE_ID  (2),
        .FST_FILE ("exception_priority_pabt_undef.fst")
    ) u_pabt_undef (.done(done[2]), .failed(failed[2]));

    arm7tdmis_exception_priority_scenario #(
        .CASE_ID  (3),
        .FST_FILE ("exception_priority_pabt_swi.fst")
    ) u_pabt_swi (.done(done[3]), .failed(failed[3]));

    initial begin
        wait (&done);
        if (|failed)
            $fatal(1, "[exception_priority] FAIL");
        $display("[exception_priority] PASS (4 priority collisions)");
        $finish;
    end
endmodule
