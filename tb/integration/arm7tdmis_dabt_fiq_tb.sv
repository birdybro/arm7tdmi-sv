// EXC-003 regression: if an enabled FIQ is sampled with a Data Abort,
// DABT wins the first entry, then the core vectors immediately to FIQ.
// SUBS pc,lr_fiq,#4 must resume the untouched DABT vector.

`timescale 1ns/1ps

module arm7tdmis_dabt_fiq_tb
    import arm7tdmis_types_pkg::*;
;

    logic CLK;
    logic nRESET;
    logic nFIQ;
    logic inject_abort;

    arm7tdmis_test_fixture #(
        .CYCLE_LIMIT (320),
        .INIT_HEX    ("../tb/programs/dabt_fiq_test.hex"),
        .TEST_NAME   ("dabt_fiq"),
        .FST_FILE    ("dabt_fiq.fst")
    ) u_fixture (
        .CFGBIGEND   (1'b0),
        .CLKEN       (1'b1),
        .nIRQ        (1'b1),
        .nFIQ        (nFIQ),
        .inject_abort(inject_abort),
        .CLK         (CLK),
        .nRESET      (nRESET)
    );

    assign inject_abort =
        (u_fixture.u_dut.u_core.state_q == 4'd1); // S_DDATA

    // A one-enabled-cycle FIQ pulse exactly coincident with the abort
    // response. The core must retain this event internally after nFIQ
    // returns high.
    assign nFIQ = u_fixture.ABORT ? 1'b0 : 1'b1;

    int unsigned entry_stage;
    always_ff @(posedge CLK or negedge nRESET) begin
        if (!nRESET) begin
            entry_stage <= 0;
        end else begin
            unique case (entry_stage)
                0: if (u_fixture.u_dut.u_core.cpsr.m
                       == 5'(MODE_ABORT))
                       entry_stage <= 1;
                1: if (u_fixture.u_dut.u_core.cpsr.m
                       == 5'(MODE_FIQ))
                       entry_stage <= 2;
                2: if (u_fixture.u_dut.u_core.cpsr.m
                       == 5'(MODE_ABORT))
                       entry_stage <= 3;
                default: ;
            endcase
        end
    end

    int unsigned errors = 0;

    initial begin
        wait (nRESET);
        repeat (255) @(posedge CLK);

        if (entry_stage != 3) begin
            $display("[dabt_fiq] FAIL entry sequence reached stage %0d, expected ABT->FIQ->ABT",
                     entry_stage);
            errors = errors + 1;
        end
        if (u_fixture.u_dut.u_core.u_regfile.regs[28]
            !== 32'h00000030) begin
            $display("[dabt_fiq] FAIL lr_abt expected 00000030 got %08x",
                     u_fixture.u_dut.u_core.u_regfile.regs[28]);
            errors = errors + 1;
        end
        if (u_fixture.u_dut.u_core.u_regfile.regs[22]
            !== 32'h00000014) begin
            $display("[dabt_fiq] FAIL lr_fiq expected 00000014 got %08x",
                     u_fixture.u_dut.u_core.u_regfile.regs[22]);
            errors = errors + 1;
        end
        if (u_fixture.u_dut.u_core.u_psr.spsr_q[3]
            !== 32'h00000013) begin
            $display("[dabt_fiq] FAIL spsr_abt expected 00000013 got %08x",
                     u_fixture.u_dut.u_core.u_psr.spsr_q[3]);
            errors = errors + 1;
        end
        if (u_fixture.u_dut.u_core.u_psr.spsr_q[0]
            !== 32'h00000097) begin
            $display("[dabt_fiq] FAIL spsr_fiq expected 00000097 got %08x",
                     u_fixture.u_dut.u_core.u_psr.spsr_q[0]);
            errors = errors + 1;
        end
        if (u_fixture.u_dut.u_core.u_regfile.regs[1] !== 32'h0
            || u_fixture.u_dut.u_core.u_regfile.regs[2] !== 32'h0
            || u_fixture.u_dut.u_core.u_regfile.regs[3]
               !== 32'h000000AB
            || u_fixture.u_dut.u_core.u_regfile.regs[6]
               !== 32'h000000F1) begin
            $display("[dabt_fiq] FAIL markers r1=%08x r2=%08x r3=%08x r6=%08x",
                     u_fixture.u_dut.u_core.u_regfile.regs[1],
                     u_fixture.u_dut.u_core.u_regfile.regs[2],
                     u_fixture.u_dut.u_core.u_regfile.regs[3],
                     u_fixture.u_dut.u_core.u_regfile.regs[6]);
            errors = errors + 1;
        end
        if (u_fixture.u_dut.u_core.cpsr.m !== 5'(MODE_ABORT)
            || u_fixture.u_dut.u_core.cpsr.f !== 1'b0
            || u_fixture.u_dut.u_core.pc_q !== 32'h00000014) begin
            $display("[dabt_fiq] FAIL final cpsr mode=%05b F=%b pc=%08x",
                     u_fixture.u_dut.u_core.cpsr.m,
                     u_fixture.u_dut.u_core.cpsr.f,
                     u_fixture.u_dut.u_core.pc_q);
            errors = errors + 1;
        end

        if (errors != 0)
            $fatal(1, "[dabt_fiq] FAIL (%0d errors)", errors);
        $display("[dabt_fiq] PASS");
        $finish;
    end
endmodule
