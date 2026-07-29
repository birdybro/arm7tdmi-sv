// EXC-001 ARM-state saved-link matrix:
//   SWI/UNDEF/PABT/IRQ/FIQ +4 and DABT +8.
// Every reset-isolated row starts at ARM address 0x40 with CPSR=0x13 and
// independently checks the selected event, source PC, LR, SPSR, target,
// exception CPSR, and suppression of interrupted/successor side effects.

`timescale 1ns/1ps

/* verilator lint_off DECLFILENAME */
module arm7tdmis_arm_exception_lr_scenario #(
    parameter int    KIND     = 0,
    parameter string FST_FILE = "arm_exception_lr.fst"
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
    logic [31:0] arm_opcode;

    arm7tdmis_test_fixture #(
        .CYCLE_LIMIT (300),
        .INIT_HEX    ("../tb/programs/arm_exception_lr_test.hex"),
        .TEST_NAME   ("arm_exception_lr"),
        .FST_FILE    (FST_FILE)
    ) u_fixture (
        .CFGBIGEND    (1'b0),
        .CLKEN        (1'b1),
        .nIRQ         (nIRQ),
        .nFIQ         (nFIQ),
        .inject_abort (inject_abort),
        .CLK          (CLK),
        .nRESET       (nRESET)
    );

    always_comb begin
        unique case (KIND)
            K_SWI:   arm_opcode = 32'hEF000000; // SWI #0
            K_UNDEF: arm_opcode = 32'hEE000700; // unclaimed p0 CDP
            K_DABT:  arm_opcode = 32'hE5941000; // LDR r1,[r4]
            default: arm_opcode = 32'hE1A00000; // MOV r0,r0
        endcase
    end

    // Replace the instruction at 0x40 while reset is active.
    initial begin
        @(posedge CLK);
        u_fixture.u_mem.mem[16] = arm_opcode;
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

    int unsigned entry_count;
    logic [5:0]  observed_event;
    logic [31:0] observed_source_pc;
    logic [31:0] observed_lr;
    logic [31:0] observed_vector;
    logic [4:0]  observed_mode;
    logic [2:0]  observed_spsr;

    always_ff @(posedge CLK or negedge nRESET) begin
        if (!nRESET) begin
            entry_count        <= 0;
            observed_event     <= '0;
            observed_source_pc <= '0;
            observed_lr        <= '0;
            observed_vector    <= '0;
            observed_mode      <= '0;
            observed_spsr      <= '0;
        end else if (u_fixture.u_dut.u_core.any_exc_fires) begin
            entry_count <= entry_count + 1;
            if (entry_count == 0) begin
                observed_event <= {
                    u_fixture.u_dut.u_core.dabt_fires,
                    u_fixture.u_dut.u_core.fiq_fires,
                    u_fixture.u_dut.u_core.irq_fires,
                    u_fixture.u_dut.u_core.pabt_fires,
                    u_fixture.u_dut.u_core.undef_fires,
                    u_fixture.u_dut.u_core.swi_fires
                };
                observed_source_pc <=
                    u_fixture.u_dut.u_core.dabt_fires
                    ? u_fixture.u_dut.u_core.memory_instr_pc_q
                    : u_fixture.u_dut.u_core.de_q.pc;
                observed_lr     <= u_fixture.u_dut.u_core.exception_lr_value;
                observed_vector <= u_fixture.u_dut.u_core.exc_pc_target_addr;
                observed_mode   <= u_fixture.u_dut.u_core.exc_mode_target;
                observed_spsr   <= u_fixture.u_dut.u_core.exc_spsr_target;
            end
        end
    end

    int unsigned errors;
    logic [5:0]  expected_event;
    logic [4:0]  expected_mode;
    logic [31:0] expected_lr;
    logic [31:0] expected_vector;
    logic [31:0] expected_handler_pc;
    logic [31:0] expected_marker;
    logic [31:0] expected_cpsr;
    logic [4:0]  lr_index;
    logic [2:0]  spsr_index;
    string kind_name;

    initial begin
        done   = 1'b0;
        failed = 1'b0;
        errors = 0;

        expected_event     = 6'b000001;
        expected_mode      = 5'(MODE_SUPERVISOR);
        expected_lr        = 32'h00000044;
        expected_vector    = 32'h00000008;
        expected_handler_pc = 32'h00000094;
        expected_marker    = 32'h00000022;
        expected_cpsr      = 32'h00000093;
        lr_index           = 26;
        spsr_index         = 2;
        kind_name          = "SWI";

        unique case (KIND)
            K_SWI: ;
            K_UNDEF: begin
                kind_name           = "UNDEF";
                expected_event      = 6'b000010;
                expected_mode       = 5'(MODE_UNDEFINED);
                expected_vector     = 32'h00000004;
                expected_handler_pc = 32'h00000084;
                expected_marker     = 32'h00000011;
                expected_cpsr       = 32'h0000009B;
                lr_index            = 30;
                spsr_index          = 4;
            end
            K_PABT: begin
                kind_name           = "PABT";
                expected_event      = 6'b000100;
                expected_mode       = 5'(MODE_ABORT);
                expected_vector     = 32'h0000000C;
                expected_handler_pc = 32'h000000A4;
                expected_marker     = 32'h00000033;
                expected_cpsr       = 32'h00000097;
                lr_index            = 28;
                spsr_index          = 3;
            end
            K_DABT: begin
                kind_name           = "DABT";
                expected_event      = 6'b100000;
                expected_mode       = 5'(MODE_ABORT);
                expected_lr         = 32'h00000048;
                expected_vector     = 32'h00000010;
                expected_handler_pc = 32'h000000B4;
                expected_marker     = 32'h00000044;
                expected_cpsr       = 32'h00000097;
                lr_index            = 28;
                spsr_index          = 3;
            end
            K_IRQ: begin
                kind_name           = "IRQ";
                expected_event      = 6'b001000;
                expected_mode       = 5'(MODE_IRQ);
                expected_vector     = 32'h00000018;
                expected_handler_pc = 32'h000000C4;
                expected_marker     = 32'h00000055;
                expected_cpsr       = 32'h00000092;
                lr_index            = 24;
                spsr_index          = 1;
            end
            default: begin
                kind_name           = "FIQ";
                expected_event      = 6'b010000;
                expected_mode       = 5'(MODE_FIQ);
                expected_vector     = 32'h0000001C;
                expected_handler_pc = 32'h000000D4;
                expected_marker     = 32'h00000066;
                expected_cpsr       = 32'h000000D1;
                lr_index            = 22;
                spsr_index          = 0;
            end
        endcase

        wait (nRESET);
        repeat (235) @(posedge CLK);

        if (entry_count != 1
            || observed_event !== expected_event
            || observed_source_pc !== 32'h00000040
            || observed_lr !== expected_lr
            || observed_vector !== expected_vector
            || observed_mode !== expected_mode
            || observed_spsr !== spsr_index) begin
            $display("[arm_exception_lr/%s] FAIL entry count=%0d event=%06b source=%08x lr=%08x vector=%08x mode=%05b spsr=%0d",
                     kind_name, entry_count, observed_event,
                     observed_source_pc, observed_lr, observed_vector,
                     observed_mode, observed_spsr);
            errors = errors + 1;
        end
        if (u_fixture.u_dut.u_core.u_regfile.regs[lr_index]
            !== expected_lr) begin
            $display("[arm_exception_lr/%s] FAIL LR bank expected %08x got %08x",
                     kind_name, expected_lr,
                     u_fixture.u_dut.u_core.u_regfile.regs[lr_index]);
            errors = errors + 1;
        end
        for (int bank = 0; bank < 5; bank++) begin
            logic [31:0] expected_saved_psr;
            expected_saved_psr = (3'(bank) == spsr_index)
                               ? 32'h00000013 : 32'h00000000;
            if (u_fixture.u_dut.u_core.u_psr.spsr_q[bank]
                !== expected_saved_psr) begin
                $display("[arm_exception_lr/%s] FAIL SPSR[%0d] expected %08x got %08x",
                         kind_name, bank, expected_saved_psr,
                         u_fixture.u_dut.u_core.u_psr.spsr_q[bank]);
                errors = errors + 1;
            end
        end
        if (u_fixture.u_dut.u_core.u_psr.cpsr_q !== expected_cpsr
            || u_fixture.u_dut.u_core.pc_q !== expected_handler_pc
            || u_fixture.u_dut.u_core.u_regfile.regs[7]
               !== expected_marker) begin
            $display("[arm_exception_lr/%s] FAIL cpsr=%08x pc=%08x marker=%08x",
                     kind_name,
                     u_fixture.u_dut.u_core.u_psr.cpsr_q,
                     u_fixture.u_dut.u_core.pc_q,
                     u_fixture.u_dut.u_core.u_regfile.regs[7]);
            errors = errors + 1;
        end
        if (u_fixture.u_dut.u_core.u_regfile.regs[1] !== 32'h0
            || u_fixture.u_dut.u_core.u_regfile.regs[2] !== 32'h0) begin
            $display("[arm_exception_lr/%s] FAIL leaked side effect r1=%08x r2=%08x",
                     kind_name,
                     u_fixture.u_dut.u_core.u_regfile.regs[1],
                     u_fixture.u_dut.u_core.u_regfile.regs[2]);
            errors = errors + 1;
        end

        failed = (errors != 0);
        done   = 1'b1;
    end
endmodule
/* verilator lint_on DECLFILENAME */

module arm7tdmis_arm_exception_lr_tb;
    logic [5:0] done;
    logic [5:0] failed;

    arm7tdmis_arm_exception_lr_scenario #(
        .KIND(0), .FST_FILE("arm_lr_swi.fst")
    ) u_swi (.done(done[0]), .failed(failed[0]));
    arm7tdmis_arm_exception_lr_scenario #(
        .KIND(1), .FST_FILE("arm_lr_undef.fst")
    ) u_undef (.done(done[1]), .failed(failed[1]));
    arm7tdmis_arm_exception_lr_scenario #(
        .KIND(2), .FST_FILE("arm_lr_pabt.fst")
    ) u_pabt (.done(done[2]), .failed(failed[2]));
    arm7tdmis_arm_exception_lr_scenario #(
        .KIND(3), .FST_FILE("arm_lr_dabt.fst")
    ) u_dabt (.done(done[3]), .failed(failed[3]));
    arm7tdmis_arm_exception_lr_scenario #(
        .KIND(4), .FST_FILE("arm_lr_irq.fst")
    ) u_irq (.done(done[4]), .failed(failed[4]));
    arm7tdmis_arm_exception_lr_scenario #(
        .KIND(5), .FST_FILE("arm_lr_fiq.fst")
    ) u_fiq (.done(done[5]), .failed(failed[5]));

    initial begin
        wait (&done);
        if (|failed)
            $fatal(1, "[arm_exception_lr] FAIL");
        $display("[arm_exception_lr] PASS (all six exception classes)");
        $finish;
    end
endmodule
