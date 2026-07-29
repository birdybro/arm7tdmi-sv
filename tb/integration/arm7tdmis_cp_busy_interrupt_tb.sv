// CP-005/006 regression: a valid unmasked IRQ or FIQ abandons an
// indefinitely busy coprocessor instruction.
//
// TRM §4.4.4 requires CPnI to go HIGH while CPA/CPB still advertise
// low/high. The coprocessor then discards its idempotent busy-wait work.
// The abandoned CDP must not complete, the next ARM instruction must not
// execute, and interrupt return state must identify the CDP for restart.

`timescale 1ns/1ps

/* verilator lint_off DECLFILENAME */
module arm7tdmis_cp_busy_interrupt_scenario #(
    parameter bit    IS_FIQ   = 1'b0,
    parameter string FST_FILE = "cp_busy_interrupt.fst"
) (
    output logic done,
    output logic failed
);
    import arm7tdmis_bus_pkg::*;

    localparam logic [4:0] EXPECTED_MODE = IS_FIQ ? 5'b10001 : 5'b10010;
    localparam int unsigned LR_INDEX = IS_FIQ ? 22 : 24;
    localparam int unsigned SPSR_INDEX = IS_FIQ ? 0 : 1;
    localparam logic [31:0] HANDLER_MARKER = IS_FIQ
                                                 ? 32'h0000_00F1
                                                 : 32'h0000_0091;

    logic CLK;
    initial begin
        CLK = 1'b0;
        forever #5 CLK = ~CLK;
    end

    logic nRESET;
    initial begin
        nRESET = 1'b0;
        repeat (4) @(posedge CLK);
        nRESET = 1'b1;
    end

    logic nIRQ, nFIQ;
    initial begin
        nIRQ = 1'b1;
        nFIQ = 1'b1;
    end

    logic [31:0] ADDR;
    logic        WRITE;
    logic [1:0]  SIZE;
    logic [1:0]  PROT;
    logic        LOCK;
    logic [1:0]  TRANS;
    logic [31:0] WDATA, RDATA;
    logic        ABORT;

    logic CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI;
    logic CPA, CPB;
    logic DBGACK, DBGnEXEC, DBGINSTRVALID;
    logic [1:0] DBGRNG;
    logic DBGCOMMTX, DBGCOMMRX, DBGTDO, DBGnTDOEN, DMORE;

    arm7tdmis_top u_dut (
        .CLK,
        .CLKEN             (1'b1),
        .nRESET,
        .CFGBIGEND         (1'b0),
        .nIRQ,
        .nFIQ,
        .ABORT,
        .ADDR, .WRITE, .SIZE, .PROT, .LOCK, .TRANS, .WDATA, .RDATA,
        .CPnMREQ, .CPSEQ, .CPnTRANS, .CPnOPC, .CPTBIT, .CPnI, .CPA, .CPB,
        .DBGEN             (1'b0),
        .DBGRQ             (1'b0),
        .DBGBREAK          (1'b0),
        .DBGACK,
        .DBGnEXEC,
        .DBGINSTRVALID,
        .DBGEXT            (2'b00),
        .DBGRNG,
        .DBGCOMMTX,
        .DBGCOMMRX,
        .DBGTCKEN          (1'b0),
        .DBGTMS            (1'b0),
        .DBGTDI            (1'b0),
        .DBGTDO,
        .DBGnTRST          (1'b1),
        .DBGnTDOEN,
        .DMORE
    );

    arm7tdmis_memory #(
        .WORDS    (256),
        .INIT_HEX ("../tb/programs/cp_busy_interrupt_test.hex")
    ) u_mem (
        .CLK,
        .CLKEN       (1'b1),
        .nRESET,
        .CFGBIGEND   (1'b0),
        .ADDR,
        .WRITE,
        .SIZE,
        .PROT,
        .LOCK,
        .TRANS,
        .WDATA,
        .RDATA,
        .ABORT,
        .inject_abort(1'b0)
    );

    // Advertise absent until CPnI identifies the CDP, then busy-wait
    // forever. Keep low/high driven through the abandonment cycle so the
    // test observes the mandated CPnI-high cancellation handshake.
    logic request_seen_q;
    logic abandoned_q;

    always_comb begin
        CPA = 1'b1;
        CPB = 1'b1;
        if ((!request_seen_q && !CPnI)
            || (request_seen_q && !abandoned_q)) begin
            CPA = 1'b0;
            CPB = 1'b1;
        end
    end

    int unsigned busy_cycles_q;
    int unsigned abandon_count_q;
    int unsigned completion_states_q;
    int unsigned protocol_errors_q;

    always_ff @(posedge CLK) begin
        if (!nRESET) begin
            request_seen_q      <= 1'b0;
            abandoned_q         <= 1'b0;
            busy_cycles_q       <= 0;
            abandon_count_q     <= 0;
            completion_states_q <= 0;
            protocol_errors_q   <= 0;
        end else begin
            if (!request_seen_q && !CPnI)
                request_seen_q <= 1'b1;

            if (request_seen_q && !abandoned_q) begin
                if (!CPnI) begin
                    busy_cycles_q <= busy_cycles_q + 1;
                    if (TRANS !== 2'(TRANS_I)) begin
                        $display("[cp_busy_interrupt/%s] FAIL busy TRANS=%02b",
                                 IS_FIQ ? "FIQ" : "IRQ", TRANS);
                        protocol_errors_q <= protocol_errors_q + 1;
                    end
                end else begin
                    abandoned_q     <= 1'b1;
                    abandon_count_q <= abandon_count_q + 1;
                    if (CPA !== 1'b0 || CPB !== 1'b1) begin
                        $display("[cp_busy_interrupt/%s] FAIL abandon CPA/CPB=%b/%b",
                                 IS_FIQ ? "FIQ" : "IRQ", CPA, CPB);
                        protocol_errors_q <= protocol_errors_q + 1;
                    end
                end
            end

            if (u_dut.u_core.state_q inside {4'd13, 4'd14, 4'd15})
                completion_states_q <= completion_states_q + 1;
        end
    end

    // Present the selected interrupt only after three complete busy-wait
    // cycles. Keep it level-active until exception entry proves it was
    // sampled, then release it to avoid repeated entry.
    initial begin
        wait (nRESET);
        wait (u_dut.u_core.state_q == 4'd12 && !CPnI);
        repeat (3) @(posedge CLK);
        if (IS_FIQ)
            nFIQ = 1'b0;
        else
            nIRQ = 1'b0;
        wait (u_dut.u_core.cpsr.m == EXPECTED_MODE);
        @(posedge CLK);
        nIRQ = 1'b1;
        nFIQ = 1'b1;
    end

    int unsigned errors;

    initial begin
        $dumpfile(FST_FILE);
        $dumpvars(0, arm7tdmis_cp_busy_interrupt_scenario);
        done   = 1'b0;
        failed = 1'b0;
        errors = 0;

        wait (nRESET);
        repeat (160) @(posedge CLK);
        #1;

        errors = errors + protocol_errors_q;
        if (!request_seen_q || !abandoned_q || abandon_count_q != 1
            || busy_cycles_q < 3) begin
            $display("[cp_busy_interrupt/%s] FAIL request/abandon/count/busy=%b/%b/%0d/%0d",
                     IS_FIQ ? "FIQ" : "IRQ", request_seen_q, abandoned_q,
                     abandon_count_q, busy_cycles_q);
            errors = errors + 1;
        end
        if (completion_states_q != 0) begin
            $display("[cp_busy_interrupt/%s] FAIL entered %0d CP completion states",
                     IS_FIQ ? "FIQ" : "IRQ", completion_states_q);
            errors = errors + 1;
        end
        if (u_dut.u_core.u_regfile.regs[0] !== 32'h0
            || u_dut.u_core.u_regfile.regs[5] !== HANDLER_MARKER) begin
            $display("[cp_busy_interrupt/%s] FAIL flow r0/r5=%08x/%08x",
                     IS_FIQ ? "FIQ" : "IRQ",
                     u_dut.u_core.u_regfile.regs[0],
                     u_dut.u_core.u_regfile.regs[5]);
            errors = errors + 1;
        end
        if (u_dut.u_core.u_regfile.regs[LR_INDEX] !== 32'h0000_0028
            || u_dut.u_core.u_psr.spsr_q[SPSR_INDEX] !== 32'h0000_0013
            || u_dut.u_core.cpsr.m !== EXPECTED_MODE) begin
            $display("[cp_busy_interrupt/%s] FAIL LR/SPSR/mode=%08x/%08x/%05b",
                     IS_FIQ ? "FIQ" : "IRQ",
                     u_dut.u_core.u_regfile.regs[LR_INDEX],
                     u_dut.u_core.u_psr.spsr_q[SPSR_INDEX],
                     u_dut.u_core.cpsr.m);
            errors = errors + 1;
        end

        failed = (errors != 0);
        done   = 1'b1;
    end

    initial begin
        repeat (220) @(posedge CLK);
        $fatal(1, "[cp_busy_interrupt/%s] TIMEOUT",
               IS_FIQ ? "FIQ" : "IRQ");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT,
                     DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG, DBGCOMMTX,
                     DBGCOMMRX, DBGTDO, DBGnTDOEN, DMORE};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
/* verilator lint_on DECLFILENAME */

module arm7tdmis_cp_busy_interrupt_tb;
    logic [1:0] done;
    logic [1:0] failed;

    arm7tdmis_cp_busy_interrupt_scenario #(
        .IS_FIQ(1'b0),
        .FST_FILE("cp_busy_irq.fst")
    ) u_irq (.done(done[0]), .failed(failed[0]));

    arm7tdmis_cp_busy_interrupt_scenario #(
        .IS_FIQ(1'b1),
        .FST_FILE("cp_busy_fiq.fst")
    ) u_fiq (.done(done[1]), .failed(failed[1]));

    initial begin
        wait (&done);
        if (|failed)
            $fatal(1, "[cp_busy_interrupt] FAIL");
        $display("[cp_busy_interrupt] PASS (IRQ and FIQ)");
        $finish;
    end
endmodule
