// EXC-010 synchronous interrupt sampling matrix.
//
// The raw ARM7TDMI-S boundary samples active-low, level-sensitive nIRQ and
// nFIQ only on rising CLK edges for which CLKEN is HIGH. Eight reset-isolated
// rows prove reset masking, a request held through mask removal, pulses and
// held levels during CLKEN stalls, edge timing, and FIQ-over-IRQ selection
// followed by service of the still-asserted IRQ level.

`timescale 1ns/1ps

/* verilator lint_off DECLFILENAME */
module arm7tdmis_interrupt_sampling_scenario #(
    parameter int    CASE_ID  = 0,
    parameter string FST_FILE = "interrupt_sampling.fst"
) (
    output logic done,
    output logic failed
);
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_types_pkg::*;

    localparam int C_MASKED_PULSE = 0;
    localparam int C_HELD_IRQ     = 1;
    localparam int C_HELD_FIQ     = 2;
    localparam int C_STALL_PULSE  = 3;
    localparam int C_STALL_IRQ    = 4;
    localparam int C_STALL_FIQ    = 5;
    localparam int C_LATE_IRQ     = 6;
    localparam int C_BOTH_LEVELS  = 7;

    logic CLK;
    logic nRESET;
    logic CLKEN;
    logic nIRQ;
    logic nFIQ;

    initial begin
        CLKEN = 1'b1;
        nIRQ  = 1'b1;
        nFIQ  = 1'b1;
        if (CASE_ID == C_MASKED_PULSE) begin
            nIRQ = 1'b0;
            nFIQ = 1'b0;
        end else if (CASE_ID == C_HELD_IRQ) begin
            nIRQ = 1'b0;
        end else if (CASE_ID == C_HELD_FIQ) begin
            nFIQ = 1'b0;
        end
    end

    arm7tdmis_test_fixture #(
        .CYCLE_LIMIT (500),
        .MEMORY_WORDS(256),
        .TEST_NAME   ("interrupt_sampling_matrix"),
        .FST_FILE    (FST_FILE)
    ) u_fixture (
        .CFGBIGEND    (1'b0),
        .CLKEN,
        .nIRQ,
        .nFIQ,
        .inject_abort (1'b0),
        .CLK,
        .nRESET
    );

    // Common program. Reset starts with I=F=1, then 0x40..0x48 clears
    // both masks before entering the two-instruction loop at 0x50.
    initial begin
        @(posedge CLK);
        for (int word = 0; word < 256; word++)
            u_fixture.u_mem.mem[word] = 32'hEAFF_FFFE;

        u_fixture.u_mem.mem[0]  = 32'hEA00_000E; // B 0x40
        u_fixture.u_mem.mem[6]  = 32'hEA00_0018; // IRQ vector -> 0x80
        u_fixture.u_mem.mem[7]  = 32'hEA00_001F; // FIQ vector -> 0xA0

        u_fixture.u_mem.mem[16] = 32'hE10F_0000; // MRS r0,CPSR
        u_fixture.u_mem.mem[17] = 32'hE3C0_00C0; // BIC r0,r0,#0xC0
        u_fixture.u_mem.mem[18] = 32'hE121_F000; // MSR CPSR_c,r0
        u_fixture.u_mem.mem[19] = 32'hE3A0_5000; // MOV r5,#0
        u_fixture.u_mem.mem[20] = 32'hE285_5001; // ADD r5,r5,#1
        u_fixture.u_mem.mem[21] = 32'hEAFF_FFFD; // B 0x50

        u_fixture.u_mem.mem[32] = 32'hE3A0_6091; // IRQ marker
        u_fixture.u_mem.mem[33] = 32'hEAFF_FFFE; // IRQ stop

        u_fixture.u_mem.mem[40] = 32'hE3A0_70F1; // FIQ marker
        u_fixture.u_mem.mem[41] =
            (CASE_ID == C_BOTH_LEVELS) ? 32'hE25E_F004 // return
                                       : 32'hEAFF_FFFE; // FIQ stop
    end

    int unsigned errors;
    int unsigned entry_count;
    logic [5:0]  entry_event [0:2];
    logic [31:0] entry_pc    [0:2];
    logic [31:0] entry_lr    [0:2];
    logic [4:0]  entry_mode  [0:2];

    function automatic string case_name;
        unique case (CASE_ID)
            C_MASKED_PULSE: return "masked-pulse";
            C_HELD_IRQ:     return "held-IRQ";
            C_HELD_FIQ:     return "held-FIQ";
            C_STALL_PULSE:  return "stalled-pulse";
            C_STALL_IRQ:    return "stalled-IRQ";
            C_STALL_FIQ:    return "stalled-FIQ";
            C_LATE_IRQ:     return "late-IRQ";
            default:        return "FIQ+IRQ";
        endcase
    endfunction

    task automatic fail(input string description);
        $display("[interrupt_sampling_matrix/%s] FAIL: %s",
                 case_name(), description);
        errors = errors + 1;
    endtask

    task automatic wait_execute(input logic [31:0] pc);
        int cycles;
        cycles = 0;
        while (!(u_fixture.u_dut.u_core.state_q == 4'd0
                 && u_fixture.u_dut.u_core.de_q.valid
                 && u_fixture.u_dut.u_core.de_q.pc == pc)) begin
            @(negedge CLK);
            cycles++;
            if (cycles > 140) begin
                fail($sformatf("PC %08x did not reach Execute", pc));
                return;
            end
        end
    endtask

    task automatic wait_entries(input int expected);
        int cycles;
        cycles = 0;
        while (entry_count < expected) begin
            @(negedge CLK);
            cycles++;
            if (cycles > 140) begin
                fail($sformatf("only %0d/%0d exception entries observed",
                               entry_count, expected));
                return;
            end
        end
    endtask

    task automatic check_entry(
        input int          index,
        input logic [5:0]  expected_event,
        input logic [4:0]  expected_mode,
        input int          lr_bank,
        input int          spsr_bank
    );
        if (entry_event[index] !== expected_event
            || entry_mode[index] !== expected_mode)
            fail($sformatf(
                "entry %0d event/mode expected %06b/%05b got %06b/%05b",
                index, expected_event, expected_mode,
                entry_event[index], entry_mode[index]));
        if (u_fixture.u_dut.u_core.u_regfile.regs[lr_bank]
            !== entry_lr[index])
            fail($sformatf(
                "entry %0d LR bank %0d expected captured %08x got %08x",
                index, lr_bank, entry_lr[index],
                u_fixture.u_dut.u_core.u_regfile.regs[lr_bank]));
        if (u_fixture.u_dut.u_core.u_psr.spsr_q[spsr_bank]
            !== 32'h0000_0013)
            fail($sformatf(
                "entry %0d SPSR bank %0d expected 00000013 got %08x",
                index, spsr_bank,
                u_fixture.u_dut.u_core.u_psr.spsr_q[spsr_bank]));
    endtask

    always_ff @(posedge CLK or negedge nRESET) begin
        if (!nRESET) begin
            entry_count <= 0;
            for (int entry = 0; entry < 3; entry++) begin
                entry_event[entry] <= '0;
                entry_pc[entry]    <= '0;
                entry_lr[entry]    <= '0;
                entry_mode[entry]  <= '0;
            end
        end else if (CLKEN && u_fixture.u_dut.u_core.any_exc_fires) begin
            if (entry_count < 3) begin
                entry_event[entry_count] <= {
                    u_fixture.u_dut.u_core.dabt_fires,
                    u_fixture.u_dut.u_core.fiq_fires,
                    u_fixture.u_dut.u_core.irq_fires,
                    u_fixture.u_dut.u_core.pabt_fires,
                    u_fixture.u_dut.u_core.undef_fires,
                    u_fixture.u_dut.u_core.swi_fires
                };
                entry_pc[entry_count] <= u_fixture.u_dut.u_core.de_q.pc;
                entry_lr[entry_count] <=
                    u_fixture.u_dut.u_core.exception_lr_value;
                entry_mode[entry_count] <=
                    u_fixture.u_dut.u_core.exc_mode_target;
            end
            entry_count <= entry_count + 1;
        end
    end

    initial begin
        logic [31:0] frozen_fetch;
        logic [31:0] frozen_inflight;
        logic [31:0] frozen_fd;
        logic [31:0] frozen_de_pc;
        logic [31:0] frozen_addr;
        logic [1:0]  frozen_trans;
        logic [1:0]  frozen_prot;
        logic [1:0]  frozen_size;

        done   = 1'b0;
        failed = 1'b0;
        errors = 0;

        wait (nRESET);

        unique case (CASE_ID)
            C_MASKED_PULSE: begin
                wait_execute(32'h0000_0040);
                if (!u_fixture.u_dut.u_core.cpsr.i
                    || !u_fixture.u_dut.u_core.cpsr.f
                    || entry_count != 0)
                    fail("reset masks did not suppress IRQ/FIQ levels");
                // Release both levels before the unmasking MSR.
                nIRQ = 1'b1;
                nFIQ = 1'b1;
                wait_execute(32'h0000_0050);
                repeat (12) @(posedge CLK);
                if (entry_count != 0
                    || u_fixture.u_dut.u_core.cpsr.m
                       !== 5'(MODE_SUPERVISOR)
                    || u_fixture.u_dut.u_core.u_regfile.regs[5] == 32'h0)
                    fail("masked pulse leaked after masks were removed");
            end

            C_HELD_IRQ: begin
                wait_entries(1);
                @(negedge CLK);
                nIRQ = 1'b1;
                check_entry(0, 6'b001000, 5'(MODE_IRQ), 24, 1);
                if (entry_pc[0] < 32'h0000_004C
                    || entry_lr[0] !== (entry_pc[0] + 32'd4))
                    fail($sformatf(
                        "held IRQ entered before unmask or saved wrong link pc/lr=%08x/%08x",
                        entry_pc[0], entry_lr[0]));
                wait_execute(32'h0000_0084);
                if (u_fixture.u_dut.u_core.u_regfile.regs[6]
                    !== 32'h0000_0091)
                    fail("IRQ handler marker missing");
            end

            C_HELD_FIQ: begin
                wait_entries(1);
                @(negedge CLK);
                nFIQ = 1'b1;
                check_entry(0, 6'b010000, 5'(MODE_FIQ), 22, 0);
                if (entry_pc[0] < 32'h0000_004C
                    || entry_lr[0] !== (entry_pc[0] + 32'd4))
                    fail($sformatf(
                        "held FIQ entered before unmask or saved wrong link pc/lr=%08x/%08x",
                        entry_pc[0], entry_lr[0]));
                wait_execute(32'h0000_00A4);
                if (u_fixture.u_dut.u_core.u_regfile.regs[7]
                    !== 32'h0000_00F1)
                    fail("FIQ handler marker missing");
            end

            C_STALL_PULSE: begin
                wait_execute(32'h0000_0050);
                @(negedge CLK);
                CLKEN          = 1'b0;
                frozen_fetch   = u_fixture.u_dut.u_core.fetch_pc_q;
                frozen_inflight = u_fixture.u_dut.u_core.inflight_pc_q;
                frozen_fd      = u_fixture.u_dut.u_core.fd_q.instr;
                frozen_de_pc   = u_fixture.u_dut.u_core.de_q.pc;
                frozen_addr    = u_fixture.ADDR;
                frozen_trans   = u_fixture.TRANS;
                frozen_prot    = u_fixture.PROT;
                frozen_size    = u_fixture.SIZE;
                nIRQ           = 1'b0;
                nFIQ           = 1'b0;
                #1;
                if (u_fixture.u_dut.u_core.any_exc_fires
                    || u_fixture.u_dut.u_core.dbg_exception_entry)
                    fail("interrupt became an event while CLKEN was LOW");
                repeat (3) begin
                    @(posedge CLK);
                    #1;
                    if (u_fixture.u_dut.u_core.fetch_pc_q !== frozen_fetch
                        || u_fixture.u_dut.u_core.inflight_pc_q
                           !== frozen_inflight
                        || u_fixture.u_dut.u_core.fd_q.instr !== frozen_fd
                        || u_fixture.u_dut.u_core.de_q.pc !== frozen_de_pc
                        || u_fixture.ADDR !== frozen_addr
                        || u_fixture.TRANS !== frozen_trans
                        || u_fixture.PROT !== frozen_prot
                        || u_fixture.SIZE !== frozen_size)
                        fail("core or raw bus changed during stalled pulse");
                end
                @(negedge CLK);
                nIRQ = 1'b1;
                nFIQ = 1'b1;
                repeat (2) @(posedge CLK);
                if (entry_count != 0)
                    fail("stalled pulse was retained after deassertion");
                @(negedge CLK);
                CLKEN = 1'b1;
                repeat (12) @(posedge CLK);
                if (entry_count != 0)
                    fail("stalled pulse caused a later exception");
            end

            C_STALL_IRQ, C_STALL_FIQ: begin
                wait_execute(32'h0000_0050);
                @(negedge CLK);
                CLKEN = 1'b0;
                if (CASE_ID == C_STALL_IRQ)
                    nIRQ = 1'b0;
                else
                    nFIQ = 1'b0;
                repeat (4) @(posedge CLK);
                if (entry_count != 0
                    || u_fixture.u_dut.u_core.cpsr.m
                       !== 5'(MODE_SUPERVISOR))
                    fail("held stalled level changed architectural state");
                @(negedge CLK);
                CLKEN = 1'b1;
                wait_entries(1);
                @(negedge CLK);
                nIRQ = 1'b1;
                nFIQ = 1'b1;
                if (CASE_ID == C_STALL_IRQ)
                    check_entry(0, 6'b001000, 5'(MODE_IRQ), 24, 1);
                else
                    check_entry(0, 6'b010000, 5'(MODE_FIQ), 22, 0);
            end

            C_LATE_IRQ: begin
                wait_execute(32'h0000_0050);
                @(posedge CLK);
                #1;
                // This request missed the edge just taken. It can affect
                // combinational next-edge selection, but not state until
                // the following rising edge.
                nIRQ = 1'b0;
                #1;
                if (entry_count != 0
                    || u_fixture.u_dut.u_core.cpsr.m
                       !== 5'(MODE_SUPERVISOR))
                    fail("late IRQ changed state before a sampling edge");
                @(posedge CLK);
                #1;
                if (u_fixture.u_dut.u_core.cpsr.m !== 5'(MODE_IRQ))
                    fail("late IRQ was not accepted on the next edge");
                @(negedge CLK);
                nIRQ = 1'b1;
                wait_entries(1);
                check_entry(0, 6'b001000, 5'(MODE_IRQ), 24, 1);
            end

            default: begin
                wait_execute(32'h0000_0050);
                nIRQ = 1'b0;
                nFIQ = 1'b0;
                wait_entries(1);
                @(negedge CLK);
                nFIQ = 1'b1;
                check_entry(0, 6'b010000, 5'(MODE_FIQ), 22, 0);

                // FIQ returns with the still-active IRQ level. The IRQ
                // must be selected after CPSR is restored and must not
                // be lost in the first priority decision.
                wait_entries(2);
                @(negedge CLK);
                nIRQ = 1'b1;
                check_entry(1, 6'b001000, 5'(MODE_IRQ), 24, 1);
                wait_execute(32'h0000_0084);
                if (u_fixture.u_dut.u_core.u_regfile.regs[7]
                    !== 32'h0000_00F1
                    || u_fixture.u_dut.u_core.u_regfile.regs[6]
                       !== 32'h0000_0091)
                    fail("FIQ/IRQ handlers did not execute in priority order");
            end
        endcase

        failed = (errors != 0);
        done   = 1'b1;
    end

    initial begin
        $dumpfile(FST_FILE);
        $dumpvars(0, arm7tdmis_interrupt_sampling_scenario);
    end
endmodule
/* verilator lint_on DECLFILENAME */

module arm7tdmis_interrupt_sampling_matrix_tb;
    logic [7:0] done;
    logic [7:0] failed;

    arm7tdmis_interrupt_sampling_scenario #(
        .CASE_ID(0), .FST_FILE("interrupt_masked_pulse.fst")
    ) u_masked_pulse (.done(done[0]), .failed(failed[0]));
    arm7tdmis_interrupt_sampling_scenario #(
        .CASE_ID(1), .FST_FILE("interrupt_held_irq.fst")
    ) u_held_irq (.done(done[1]), .failed(failed[1]));
    arm7tdmis_interrupt_sampling_scenario #(
        .CASE_ID(2), .FST_FILE("interrupt_held_fiq.fst")
    ) u_held_fiq (.done(done[2]), .failed(failed[2]));
    arm7tdmis_interrupt_sampling_scenario #(
        .CASE_ID(3), .FST_FILE("interrupt_stall_pulse.fst")
    ) u_stall_pulse (.done(done[3]), .failed(failed[3]));
    arm7tdmis_interrupt_sampling_scenario #(
        .CASE_ID(4), .FST_FILE("interrupt_stall_irq.fst")
    ) u_stall_irq (.done(done[4]), .failed(failed[4]));
    arm7tdmis_interrupt_sampling_scenario #(
        .CASE_ID(5), .FST_FILE("interrupt_stall_fiq.fst")
    ) u_stall_fiq (.done(done[5]), .failed(failed[5]));
    arm7tdmis_interrupt_sampling_scenario #(
        .CASE_ID(6), .FST_FILE("interrupt_late_irq.fst")
    ) u_late_irq (.done(done[6]), .failed(failed[6]));
    arm7tdmis_interrupt_sampling_scenario #(
        .CASE_ID(7), .FST_FILE("interrupt_both_levels.fst")
    ) u_both_levels (.done(done[7]), .failed(failed[7]));

    initial begin
        wait (&done);
        if (|failed)
            $fatal(1, "[interrupt_sampling_matrix] FAIL");
        $display("[interrupt_sampling_matrix] PASS (8 rows)");
        $finish;
    end
endmodule
