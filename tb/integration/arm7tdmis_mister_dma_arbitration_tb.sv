// MIST-012 system-level DMA/arbitration regression.
//
// A permanently contending synthetic DMA master shares one memory with the
// canonical wrapper. The arbiter honors the CPU's two-transfer SWP lock and
// DMORE-predicted STM/LDM chains while otherwise granting DMA in idle gaps.
// CPU_CE and memory completion are independently randomized. One LDR receives
// MEM_ERROR and must reach the architectural data-abort handler before normal
// execution resumes.

`timescale 1ns/1ps

module arm7tdmis_mister_dma_arbitration_tb;

    logic CLK;
    initial CLK = 1'b0;
    always #5 CLK = ~CLK;

    logic RESET_N;
    logic [15:0] lfsr_q;
    wire CPU_CE = lfsr_q[1] || lfsr_q[4];

    logic        MEM_VALID;
    logic        MEM_READY;
    logic [31:0] MEM_ADDR;
    logic        MEM_WRITE;
    logic [31:0] MEM_WDATA;
    logic [3:0]  MEM_BYTE_ENABLE;
    logic        MEM_CODE;
    logic        MEM_PRIVILEGED;
    logic        MEM_LOCK;
    logic        MEM_SEQUENTIAL;
    logic        MEM_MORE;
    logic [31:0] MEM_RDATA;
    logic        MEM_ERROR;

    logic CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI;
    logic DBG_STEP_READY, DBG_STEP_RSP_VALID;
    logic DBG_STEP_TDO, DBG_STEP_TDO_OE;
    logic DBGACK, DBGnEXEC, DBGINSTRVALID;
    logic [1:0] DBGRNG;
    logic DBGCOMMTX, DBGCOMMRX;

    arm7tdmi_mister u_dut (
        .CLK,
        .RESET_N,
        .CPU_CE,
        .IRQ_ASYNC            (1'b0),
        .FIQ_ASYNC            (1'b0),
        .MEM_VALID,
        .MEM_READY,
        .MEM_ADDR,
        .MEM_WRITE,
        .MEM_WDATA,
        .MEM_BYTE_ENABLE,
        .MEM_CODE,
        .MEM_PRIVILEGED,
        .MEM_LOCK,
        .MEM_SEQUENTIAL,
        .MEM_MORE,
        .MEM_RDATA,
        .MEM_ERROR,
        .CPnMREQ,
        .CPSEQ,
        .CPnTRANS,
        .CPnOPC,
        .CPTBIT,
        .CPnI,
        .CPA                  (1'b1),
        .CPB                  (1'b1),
        .DEBUG_ENABLE_ASYNC   (1'b0),
        .DBGRQ_ASYNC          (1'b0),
        .DBGBREAK_ASYNC       (1'b0),
        .DBGEXT_ASYNC         (2'b00),
        .DBG_STEP_VALID       (1'b0),
        .DBG_STEP_READY,
        .DBG_STEP_TMS         (1'b0),
        .DBG_STEP_TDI         (1'b0),
        .DBG_STEP_RSP_VALID,
        .DBG_STEP_RSP_READY   (1'b1),
        .DBG_STEP_TDO,
        .DBG_STEP_TDO_OE,
        .DBGACK,
        .DBGnEXEC,
        .DBGINSTRVALID,
        .DBGRNG,
        .DBGCOMMTX,
        .DBGCOMMRX
    );

    logic [31:0] memory [0:255];
    assign MEM_RDATA = memory[MEM_ADDR[9:2]];

    logic lock_owned_q;
    logic more_owned_q;
    logic error_sent_q;
    logic request_held_q;
    logic [73:0] held_request_q;
    logic [31:0] chain_addr_q;

    int unsigned cpu_accepts;
    int unsigned cpu_wait_cycles;
    int unsigned cpu_accepts_while_ce_low;
    int unsigned dma_grants;
    int unsigned locked_accepts;
    int unsigned locked_pairs;
    int unsigned more_chain_starts;
    int unsigned more_chain_followers;
    int unsigned error_completions;

    wire [73:0] request_payload = {
        MEM_ADDR,
        MEM_WDATA,
        MEM_BYTE_ENABLE,
        MEM_WRITE,
        MEM_CODE,
        MEM_PRIVILEGED,
        MEM_LOCK,
        MEM_SEQUENTIAL,
        MEM_MORE
    };

    // CPU always wins an active request. DMA uses otherwise-idle slots only,
    // except that lock/more ownership deliberately reserves gaps between
    // related CPU transfers.
    wire cpu_grant = MEM_VALID;
    wire dma_grant = !MEM_VALID && !lock_owned_q && !more_owned_q
                   && lfsr_q[7];
    wire memory_allows_cpu = lfsr_q[0] || lfsr_q[3];
    wire cpu_completion = cpu_grant && memory_allows_cpu;
    wire inject_error = !error_sent_q
                      && !MEM_WRITE
                      && MEM_ADDR == 32'h0000_0180;

    assign MEM_READY = cpu_completion;
    assign MEM_ERROR = cpu_completion && inject_error;

    task automatic fail(input string description);
        $fatal(1, "[mister_dma_arbitration] FAIL: %s", description);
    endtask

    always_ff @(posedge CLK or negedge RESET_N) begin
        if (!RESET_N) begin
            lfsr_q <= 16'hBEEF;
        end else begin
            lfsr_q <= {
                lfsr_q[14:0],
                lfsr_q[15] ^ lfsr_q[13] ^ lfsr_q[12] ^ lfsr_q[10]
            };
        end
    end

    always_ff @(posedge CLK or negedge RESET_N) begin
        if (!RESET_N) begin
            lock_owned_q            <= 1'b0;
            more_owned_q            <= 1'b0;
            error_sent_q            <= 1'b0;
            request_held_q          <= 1'b0;
            held_request_q          <= '0;
            chain_addr_q            <= 32'h0000_0000;
            cpu_accepts             <= 0;
            cpu_wait_cycles         <= 0;
            cpu_accepts_while_ce_low <= 0;
            dma_grants              <= 0;
            locked_accepts          <= 0;
            locked_pairs            <= 0;
            more_chain_starts       <= 0;
            more_chain_followers    <= 0;
            error_completions       <= 0;
        end else begin
            if (request_held_q) begin
                if (!MEM_VALID)
                    fail("MEM_VALID dropped under arbitration backpressure");
                if (request_payload != held_request_q)
                    fail("CPU request payload changed under backpressure");
            end

            if (MEM_VALID && !MEM_READY) begin
                cpu_wait_cycles <= cpu_wait_cycles + 1;
                if (!request_held_q)
                    held_request_q <= request_payload;
                request_held_q <= 1'b1;
            end

            if (cpu_completion) begin
                cpu_accepts    <= cpu_accepts + 1;
                request_held_q <= 1'b0;
                if (!CPU_CE)
                    cpu_accepts_while_ce_low <=
                        cpu_accepts_while_ce_low + 1;

                if (MEM_ERROR) begin
                    error_sent_q      <= 1'b1;
                    error_completions <= error_completions + 1;
                end else if (MEM_WRITE) begin
                    for (int lane = 0; lane < 4; lane++) begin
                        if (MEM_BYTE_ENABLE[lane])
                            memory[MEM_ADDR[9:2]][lane*8 +: 8]
                                <= MEM_WDATA[lane*8 +: 8];
                    end
                end

                if (lock_owned_q && !MEM_LOCK)
                    fail("non-locked CPU transfer split a SWP pair");
                if (MEM_LOCK) begin
                    locked_accepts <= locked_accepts + 1;
                    if (!lock_owned_q) begin
                        lock_owned_q <= 1'b1;
                    end else begin
                        lock_owned_q <= 1'b0;
                        locked_pairs <= locked_pairs + 1;
                    end
                end

                if (more_owned_q) begin
                    if (!MEM_SEQUENTIAL || MEM_CODE || MEM_LOCK)
                        fail("DMORE follower lost data/sequential class");
                    if (MEM_ADDR != chain_addr_q + 32'd4)
                        fail("DMORE follower did not increment by four");
                    more_chain_followers <= more_chain_followers + 1;
                end else if (MEM_MORE) begin
                    more_chain_starts <= more_chain_starts + 1;
                end
                more_owned_q <= MEM_MORE;
                chain_addr_q <= MEM_ADDR;
            end

            if (dma_grant) begin
                if (lock_owned_q)
                    fail("DMA granted between locked SWP transfers");
                if (more_owned_q)
                    fail("DMA granted inside a DMORE chain");
                dma_grants <= dma_grants + 1;
                memory[8'hF0] <= memory[8'hF0] + 32'd1;
            end
        end
    end

    initial begin
        RESET_N = 1'b0;
        for (int word = 0; word < 256; word++)
            memory[word] = 32'hEAFF_FFFE;

        memory[0]  = 32'hEA00_000E; // reset: B 0x40
        memory[1]  = 32'hEAFF_FFFE;
        memory[2]  = 32'hEAFF_FFFE;
        memory[3]  = 32'hEAFF_FFFE;
        memory[4]  = 32'hEA00_002A; // DABT: B 0xC0
        memory[5]  = 32'hEAFF_FFFE;
        memory[6]  = 32'hEAFF_FFFE;
        memory[7]  = 32'hEAFF_FFFE;

        memory[16] = 32'hE3A0_0C01; // MOV r0,#0x100
        memory[17] = 32'hE3A0_1011; // MOV r1,#0x11
        memory[18] = 32'hE3A0_2022; // MOV r2,#0x22
        memory[19] = 32'hE3A0_3033; // MOV r3,#0x33
        memory[20] = 32'hE1A0_B000; // MOV r11,r0
        memory[21] = 32'hE8A0_000E; // STMIA r0!,{r1-r3}
        memory[22] = 32'hE8BB_000E; // LDMIA r11!,{r1-r3}
        memory[23] = 32'hE280_5034; // ADD r5,r0,#0x34 -> 0x140
        memory[24] = 32'hE105_4091; // SWP r4,r1,[r5]
        memory[25] = 32'hE285_7040; // ADD r7,r5,#0x40 -> 0x180
        memory[26] = 32'hE287_A040; // ADD r10,r7,#0x40 -> 0x1C0
        memory[27] = 32'hE597_6000; // LDR r6,[r7] -> injected error
        memory[28] = 32'hE58A_4008; // STR r4,[r10,#8]
        memory[29] = 32'hE3A0_90A5; // MOV r9,#0xA5
        memory[30] = 32'hE58A_9000; // STR r9,[r10]
        memory[31] = 32'hEAFF_FFFE; // B .

        memory[48] = 32'hE3A0_800D; // DABT: MOV r8,#0xD
        memory[49] = 32'hE58A_8004; //       STR r8,[r10,#4]
        memory[50] = 32'hE25E_F004; //       SUBS pc,lr,#4 (skip LDR)

        memory[8'h50] = 32'hDEAD_BEEF; // SWP location 0x140
        memory[8'h60] = 32'hCAFE_BABE; // aborted LDR location 0x180
        memory[8'hF0] = 32'h0000_0000; // synthetic DMA counter

        repeat (5) @(posedge CLK);
        @(negedge CLK);
        RESET_N = 1'b1;

        wait (memory[8'h70] == 32'h0000_00A5);
        repeat (20) @(posedge CLK);
        #1;

        if (memory[8'h40] != 32'h0000_0011
            || memory[8'h41] != 32'h0000_0022
            || memory[8'h42] != 32'h0000_0033)
            fail("STM/LDM shared-memory payload is wrong");
        if (memory[8'h50] != 32'h0000_0011)
            fail("SWP write did not complete atomically");
        if (memory[8'h72] != 32'hDEAD_BEEF)
            fail("SWP read result was not preserved across the abort");
        if (memory[8'h71] != 32'h0000_000D)
            fail("MEM_ERROR did not reach the data-abort handler");
        if (locked_accepts != 2 || locked_pairs != 1)
            fail("arbiter did not observe exactly one complete SWP lock pair");
        if (more_chain_starts < 2 || more_chain_followers < 4)
            fail("STM/LDM DMORE chains were not both exercised");
        if (cpu_wait_cycles == 0)
            fail("memory arbitration never stalled the CPU");
        if (cpu_accepts_while_ce_low == 0)
            fail("no completion occurred independently of CPU_CE");
        if (dma_grants == 0 || memory[8'hF0] == 0)
            fail("contending DMA master never made progress");
        if (error_completions != 1)
            fail("injected bus error did not complete exactly once");
        if (lock_owned_q || more_owned_q)
            fail("arbiter ownership remained held after completion");
        if (cpu_accepts < 20)
            fail("too few CPU requests completed");

        $display(
            "[mister_dma_arbitration] PASS cpu=%0d waits=%0d dma=%0d",
            cpu_accepts, cpu_wait_cycles, dma_grants
        );
        $finish;
    end

    initial begin
        #1_000_000;
        $fatal(1, "[mister_dma_arbitration] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{
        1'b0, CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI,
        DBG_STEP_READY, DBG_STEP_RSP_VALID, DBG_STEP_TDO,
        DBG_STEP_TDO_OE, DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG,
        DBGCOMMTX, DBGCOMMRX
    };
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
