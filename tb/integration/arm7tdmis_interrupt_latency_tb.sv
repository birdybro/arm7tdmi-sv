// EXC-010 minimum/maximum interrupt latency regression.
//
// Both rows put the raw synchronous nFIQ pin behind the same two-flop
// active-high event synchronizer used by arm7tdmi_mister. Latency is counted
// in rising processor-clock edges beginning with the first synchronizer
// sampling edge and ending when the first FIQ-vector address phase is
// accepted. This pin-level endpoint avoids adding behavioral-memory response
// latency to the TRM's processor-cycle definition.
//
// MIN: synchronizer (2) + FIQ entry (2) = 4 cycles.
// MAX: synchronizer (2) + 16-register LDM including PC (20) +
//      Data-Abort entry (3) + FIQ entry (2) = 27 cycles.

`timescale 1ns/1ps

/* verilator lint_off DECLFILENAME */
module arm7tdmis_interrupt_latency_scenario #(
    parameter bit    MAX_CASE = 1'b0,
    parameter string FST_FILE = "interrupt_latency.fst"
) (
    output logic done,
    output logic failed
);
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_types_pkg::*;

    localparam logic [31:0] LOOP_PC = 32'h0000_0050;
    localparam logic [31:0] LDM_PC  = 32'h0000_0058;
    localparam logic [31:0] DATA_BASE = 32'h0000_0200;

    logic CLK;
    initial begin
        CLK = 1'b0;
        forever #5 CLK = ~CLK;
    end

    logic nRESET;
    logic FIQ_ASYNC;
    logic fiq_meta_q;
    logic fiq_sync_q;
    wire  nFIQ = ~fiq_sync_q;

    // This is intentionally identical in shape to the canonical wrapper's
    // event CDC. The raw CPU itself continues to receive a synchronous pin.
    always_ff @(posedge CLK or negedge nRESET) begin
        if (!nRESET) begin
            fiq_meta_q <= 1'b0;
            fiq_sync_q <= 1'b0;
        end else begin
            fiq_meta_q <= FIQ_ASYNC;
            fiq_sync_q <= fiq_meta_q;
        end
    end

    logic [31:0] ADDR;
    logic        WRITE;
    logic [1:0]  SIZE;
    logic [1:0]  PROT;
    logic        LOCK;
    logic [1:0]  TRANS;
    logic [31:0] WDATA;
    logic [31:0] RDATA;
    logic        ABORT;

    logic CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI;
    logic DBGACK, DBGnEXEC, DBGINSTRVALID;
    logic [1:0] DBGRNG;
    logic DBGCOMMTX, DBGCOMMRX, DBGTDO, DBGnTDOEN, DMORE;

    arm7tdmis_top u_dut (
        .CLK,
        .CLKEN             (1'b1),
        .nRESET,
        .CFGBIGEND         (1'b0),
        .nIRQ              (1'b1),
        .nFIQ,
        .ABORT,
        .ADDR,
        .WRITE,
        .SIZE,
        .PROT,
        .LOCK,
        .TRANS,
        .WDATA,
        .RDATA,
        .CPnMREQ,
        .CPSEQ,
        .CPnTRANS,
        .CPnOPC,
        .CPTBIT,
        .CPnI,
        .CPA               (1'b1),
        .CPB               (1'b1),
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

    wire final_ldm_response =
        u_mem.is_active_q
        && !u_mem.write_q
        && (u_mem.addr_q == (DATA_BASE + 32'd60));
    wire inject_abort = MAX_CASE && final_ldm_response;

    arm7tdmis_memory #(
        .WORDS(256)
    ) u_mem (
        .CLK,
        .CLKEN             (1'b1),
        .nRESET,
        .CFGBIGEND         (1'b0),
        .ADDR,
        .WRITE,
        .SIZE,
        .PROT,
        .LOCK,
        .TRANS,
        .WDATA,
        .RDATA,
        .ABORT,
        .inject_abort
    );

    int unsigned errors;
    int unsigned latency_cycles;
    int unsigned measured_latency;
    int unsigned data_responses;
    int unsigned dabt_entries;
    int unsigned fiq_entries;
    int unsigned sync_cycle;
    int unsigned dabt_cycle;
    int unsigned fiq_cycle;
    logic        counting;
    logic        vector_seen;
    logic        final_abort_seen;

    task automatic fail(input string description);
        $display("[interrupt_latency/%s] FAIL: %s",
                 MAX_CASE ? "maximum" : "minimum", description);
        errors = errors + 1;
    endtask

    task automatic wait_execute(input logic [31:0] pc);
        int cycles;
        cycles = 0;
        while (!(u_dut.u_core.state_q == 4'd0
                 && u_dut.u_core.de_q.valid
                 && u_dut.u_core.de_q.pc == pc)) begin
            @(negedge CLK);
            cycles++;
            if (cycles > 160) begin
                fail($sformatf("PC %08x did not reach Execute", pc));
                return;
            end
        end
    endtask

    task automatic wait_inflight(input logic [31:0] pc);
        int cycles;
        cycles = 0;
        while (!(u_dut.u_core.inflight_valid_q
                 && u_dut.u_core.inflight_pc_q == pc)) begin
            @(negedge CLK);
            cycles++;
            if (cycles > 160) begin
                fail($sformatf("PC %08x did not reach the fetch response",
                               pc));
                return;
            end
        end
    endtask

    always_ff @(posedge CLK or negedge nRESET) begin
        if (!nRESET) begin
            latency_cycles  <= 0;
            measured_latency <= 0;
            data_responses  <= 0;
            dabt_entries    <= 0;
            fiq_entries     <= 0;
            sync_cycle      <= 0;
            dabt_cycle      <= 0;
            fiq_cycle       <= 0;
            vector_seen     <= 1'b0;
            final_abort_seen <= 1'b0;
        end else begin
            if (counting && !vector_seen)
                latency_cycles <= latency_cycles + 1;
            if (counting && fiq_sync_q && sync_cycle == 0)
                sync_cycle <= latency_cycles + 1;

            if (MAX_CASE
                && u_mem.is_active_q
                && !u_mem.write_q
                && u_mem.addr_q >= DATA_BASE
                && u_mem.addr_q <= (DATA_BASE + 32'd60))
                data_responses <= data_responses + 1;

            if (ABORT && final_ldm_response)
                final_abort_seen <= 1'b1;

            if (u_dut.u_core.any_exc_fires) begin
                if (u_dut.u_core.dabt_fires)
                    dabt_entries <= dabt_entries + 1;
                if (u_dut.u_core.fiq_fires)
                    fiq_entries <= fiq_entries + 1;
                if (u_dut.u_core.dabt_fires && dabt_cycle == 0)
                    dabt_cycle <= latency_cycles + 1;
                if (u_dut.u_core.fiq_fires && fiq_cycle == 0)
                    fiq_cycle <= latency_cycles + 1;
            end

            if (counting && !vector_seen
                && (TRANS inside {TRANS_N, TRANS_S})
                && !PROT[0]
                && (ADDR == 32'h0000_001C)
                && (u_dut.u_core.cpsr.m == 5'(MODE_FIQ))) begin
                vector_seen      <= 1'b1;
                measured_latency <= latency_cycles + 1;
            end
        end
    end

    initial begin
        int vector_wait_cycles;

        errors         = 0;
        counting       = 1'b0;
        FIQ_ASYNC      = 1'b0;
        nRESET         = 1'b0;
        done           = 1'b0;
        failed         = 1'b0;

        for (int word = 0; word < 256; word++)
            u_mem.mem[word] = 32'hEAFF_FFFE;

        u_mem.mem[0]  = 32'hEA00_000E; // B 0x40
        u_mem.mem[4]  = 32'hE1A0_0000; // DABT-vector NOP
        u_mem.mem[7]  = 32'hE1A0_0000; // FIQ-vector NOP

        u_mem.mem[16] = 32'hE10F_1000; // MRS r1,CPSR
        u_mem.mem[17] = 32'hE3C1_1040; // BIC r1,r1,#0x40
        u_mem.mem[18] = 32'hE121_F001; // MSR CPSR_c,r1
        u_mem.mem[19] = 32'hE1A0_0000; // NOP
        u_mem.mem[20] = MAX_CASE
                      ? 32'hE3A0_0C02  // MOV r0,#0x200
                      : 32'hE1A0_0000; // minimum-latency loop NOP
        u_mem.mem[21] = MAX_CASE
                      ? 32'hE1A0_0000  // NOP before LDM
                      : 32'hEAFF_FFFD; // B 0x50
        u_mem.mem[22] = MAX_CASE
                      ? 32'hE890_FFFF  // LDMIA r0,{r0-r15}
                      : 32'hEAFF_FFFE;
        u_mem.mem[23] = 32'hE3A0_20EE; // must not execute after DABT

        if (!MAX_CASE) begin
            // Keep Execute continuously occupied when the synchronized
            // request arrives. A branch refill is not the minimum case.
            for (int word = 20; word < 48; word++)
                u_mem.mem[word] = 32'hE1A0_0000;
        end

        for (int reg_index = 0; reg_index < 16; reg_index++)
            u_mem.mem[(DATA_BASE >> 2) + reg_index] =
                (reg_index == 15)
                ? 32'h0000_0300
                : (32'hA500_0000 | 32'(reg_index));

        repeat (4) @(posedge CLK);
        @(negedge CLK);
        nRESET = 1'b1;

        if (MAX_CASE) begin
            // Start one pipeline stage before the LDM reaches Decode.
            // The second synchronizer edge then makes nFIQ active just
            // after the preceding instruction's sampling boundary has
            // committed the LDM, leaving the complete 20-cycle
            // instruction in the latency path.
            wait_inflight(LDM_PC);
        end else begin
            wait_execute(LOOP_PC);
        end

        // The next rising edge is latency cycle one and captures the
        // asynchronous level in the first synchronizer stage.
        FIQ_ASYNC = 1'b1;
        counting  = 1'b1;

        vector_wait_cycles = 0;
        while (!vector_seen && vector_wait_cycles < 120) begin
            @(negedge CLK);
            vector_wait_cycles++;
        end
        if (!vector_seen)
            fail("FIQ vector was not reached after the timed request");
        @(negedge CLK);
        FIQ_ASYNC = 1'b0;
        repeat (4) @(posedge CLK);
        #1;

        if (MAX_CASE) begin
            if (measured_latency != 27)
                fail($sformatf(
                    "expected 27 cycles, measured %0d (sync=%0d DABT=%0d FIQ=%0d)",
                    measured_latency, sync_cycle, dabt_cycle, fiq_cycle));
            if (data_responses != 16 || !final_abort_seen)
                fail($sformatf(
                    "expected 16 LDM responses and final abort, got %0d/%b",
                    data_responses, final_abort_seen));
            if (dabt_entries != 1 || fiq_entries != 1)
                fail($sformatf(
                    "expected one DABT then one FIQ, got %0d/%0d",
                    dabt_entries, fiq_entries));
            if (dabt_cycle == 0 || fiq_cycle <= dabt_cycle)
                fail($sformatf(
                    "exception order was not DABT then FIQ (DABT=%0d FIQ=%0d)",
                    dabt_cycle, fiq_cycle));
            if (u_dut.u_core.u_regfile.regs[28] !== (LDM_PC + 32'd8)
                || u_dut.u_core.u_regfile.regs[22] !== 32'h0000_0014)
                fail($sformatf(
                    "exception links lr_abt/lr_fiq=%08x/%08x",
                    u_dut.u_core.u_regfile.regs[28],
                    u_dut.u_core.u_regfile.regs[22]));
            if (u_dut.u_core.u_regfile.regs[2] == 32'h0000_00EE)
                fail("post-abort successor executed");
        end else begin
            if (measured_latency != 4)
                fail($sformatf("expected 4 cycles, measured %0d",
                               measured_latency));
            if (dabt_entries != 0 || fiq_entries != 1)
                fail($sformatf("unexpected entry counts DABT/FIQ=%0d/%0d",
                               dabt_entries, fiq_entries));
        end

        failed = (errors != 0);
        done   = 1'b1;
    end

    initial begin
        $dumpfile(FST_FILE);
        $dumpvars(0, arm7tdmis_interrupt_latency_scenario);
        repeat (600) @(posedge CLK);
        $fatal(1, "[interrupt_latency/%s] TIMEOUT",
               MAX_CASE ? "maximum" : "minimum");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, WRITE, SIZE, LOCK, WDATA, CPnMREQ, CPSEQ,
        CPnTRANS, CPnOPC, CPTBIT, CPnI, DBGACK, DBGnEXEC,
        DBGINSTRVALID, DBGRNG, DBGCOMMTX, DBGCOMMRX, DBGTDO,
        DBGnTDOEN, DMORE};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
/* verilator lint_on DECLFILENAME */

module arm7tdmis_interrupt_latency_tb;
    logic [1:0] done;
    logic [1:0] failed;

    arm7tdmis_interrupt_latency_scenario #(
        .MAX_CASE(1'b0),
        .FST_FILE("interrupt_latency_min.fst")
    ) u_min (.done(done[0]), .failed(failed[0]));

    arm7tdmis_interrupt_latency_scenario #(
        .MAX_CASE(1'b1),
        .FST_FILE("interrupt_latency_max.fst")
    ) u_max (.done(done[1]), .failed(failed[1]));

    initial begin
        wait (&done);
        if (|failed)
            $fatal(1, "[interrupt_latency] FAIL");
        $display("[interrupt_latency] PASS (4-cycle min, 27-cycle max)");
        $finish;
    end
endmodule
