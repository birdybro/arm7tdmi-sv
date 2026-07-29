// MIST-003 regression for wrapper-owned reset and asynchronous event CDC.
//
// Active-high board IRQ/FIQ levels arrive during normal execution, an
// outstanding request, and a response buffered while CPU_CE is low. The
// synchronizers must continue running while the raw CPU bus is stalled, and
// each event must reach its architectural vector after the stalled transfer
// completes. A final asynchronous reset cancels a held request and proves a
// clean reset-vector restart.

`timescale 1ns/1ps

module arm7tdmis_mister_cdc_reset_tb;

    logic CLK;
    initial CLK = 1'b0;
    always #5 CLK = ~CLK;

    logic RESET_N;
    logic CPU_CE;
    logic IRQ_ASYNC;
    logic FIQ_ASYNC;
    logic ready_enable;

    logic        MEM_VALID;
    wire         MEM_READY = MEM_VALID && ready_enable;
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

    logic        CPnMREQ;
    logic        CPSEQ;
    logic        CPnTRANS;
    logic        CPnOPC;
    logic        CPTBIT;
    logic        CPnI;
    logic        DBG_STEP_READY;
    logic        DBG_STEP_RSP_VALID;
    logic        DBG_STEP_TDO;
    logic        DBG_STEP_TDO_OE;
    logic        DBGACK;
    logic        DBGnEXEC;
    logic        DBGINSTRVALID;
    logic [1:0]  DBGRNG;
    logic        DBGCOMMTX;
    logic        DBGCOMMRX;

    arm7tdmi_mister u_dut (
        .CLK,
        .RESET_N,
        .CPU_CE,
        .IRQ_ASYNC,
        .FIQ_ASYNC,
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
        .MEM_ERROR            (1'b0),
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

    integer errors;
    integer accepted_count;
    logic   saw_reset_vector_after_restart;

    task automatic check(input logic condition, input string description);
        if (!condition) begin
            $display("[mister_cdc_reset] FAIL: %s", description);
            errors++;
        end
    endtask

    always_ff @(posedge CLK or negedge RESET_N) begin
        if (!RESET_N) begin
            accepted_count <= 0;
        end else if (MEM_VALID && MEM_READY) begin
            accepted_count <= accepted_count + 1;
            if (MEM_WRITE) begin
                for (int lane = 0; lane < 4; lane++) begin
                    if (MEM_BYTE_ENABLE[lane])
                        memory[MEM_ADDR[9:2]][lane*8 +: 8]
                            <= MEM_WDATA[lane*8 +: 8];
                end
            end
        end
    end

    always_ff @(posedge CLK or negedge RESET_N) begin
        if (!RESET_N)
            saw_reset_vector_after_restart <= 1'b0;
        else if (MEM_VALID && MEM_CODE && MEM_ADDR == 32'h0000_0000)
            saw_reset_vector_after_restart <= 1'b1;
    end

    task automatic wait_for_main_write;
        begin
            wait (MEM_VALID && MEM_WRITE
                  && MEM_ADDR == 32'h0000_0100);
            #1;
        end
    endtask

    task automatic drain_event_synchronizers;
        begin
            repeat (5) @(posedge CLK);
        end
    endtask

    initial begin
        logic [31:0] held_addr;
        logic [31:0] held_wdata;
        logic [3:0]  held_be;
        logic [31:0] heartbeat_before;

        errors        = 0;
        RESET_N       = 1'b0;
        CPU_CE        = 1'b1;
        IRQ_ASYNC     = 1'b0;
        FIQ_ASYNC     = 1'b0;
        ready_enable  = 1'b1;

        for (int word_index = 0; word_index < 256; word_index++)
            memory[word_index] = 32'h0000_0000;

        // Vectors and main loop. The loop enables IRQ/FIQ, increments a
        // heartbeat at 0x100, and returns from each handler.
        memory[0]  = 32'hEA00_000E; // B reset_main (0x40)
        memory[1]  = 32'hEAFF_FFFE;
        memory[2]  = 32'hEAFF_FFFE;
        memory[3]  = 32'hEAFF_FFFE;
        memory[4]  = 32'hEAFF_FFFE;
        memory[5]  = 32'hEAFF_FFFE;
        memory[6]  = 32'hEA00_0018; // B irq_handler (0x80)
        memory[7]  = 32'hEA00_001F; // B fiq_handler (0xA0)

        memory[16] = 32'hE3A0_0C01; // MOV r0,#0x100
        memory[17] = 32'hE10F_1000; // MRS r1,CPSR
        memory[18] = 32'hE3C1_10C0; // BIC r1,r1,#0xC0
        memory[19] = 32'hE121_F001; // MSR CPSR_c,r1
        memory[20] = 32'hE282_2001; // ADD r2,r2,#1
        memory[21] = 32'hE580_2000; // STR r2,[r0]
        memory[22] = 32'hEAFF_FFFC; // B 0x50

        memory[32] = 32'hE3A0_3049; // IRQ: MOV r3,#'I'
        memory[33] = 32'hE580_3004; //      STR r3,[r0,#4]
        memory[34] = 32'hE25E_F004; //      SUBS pc,lr,#4

        memory[40] = 32'hE3A0_4046; // FIQ: MOV r4,#'F'
        memory[41] = 32'hE580_4008; //      STR r4,[r0,#8]
        memory[42] = 32'hE25E_F004; //      SUBS pc,lr,#4

        repeat (5) @(posedge CLK);
        @(negedge CLK);
        // Deassert deliberately between edges. All wrapper/reset domains
        // must remain asserted through one complete synchronizer stage and
        // release together only on the second rising edge.
        #2 RESET_N = 1'b1;
        #1;
        check(!u_dut.wrapper_reset_n,
              "wrapper reset released asynchronously between clocks");
        @(posedge CLK);
        #1;
        check(!u_dut.wrapper_reset_n,
              "wrapper reset skipped its first release stage");
        @(posedge CLK);
        #1;
        check(u_dut.wrapper_reset_n,
              "wrapper reset did not release on its second clock edge");

        wait (memory[64] >= 32'd2);

        // Normal running phase: an asynchronous IRQ must not become an
        // architectural request on the first synchronizer edge.
        @(negedge CLK);
        memory[65] = 32'h0000_0000;
        heartbeat_before = memory[64];
        #2 IRQ_ASYNC = 1'b1;
        @(posedge CLK);
        #1;
        check(memory[65] == 32'h0000_0000,
              "IRQ bypassed the first synchronizer stage");
        wait (memory[65] == 32'h0000_0049);
        IRQ_ASYNC = 1'b0;
        drain_event_synchronizers();
        wait (memory[64] > heartbeat_before);

        // Outstanding-request phase: synchronize FIQ while the raw core is
        // frozen behind a non-ready data write.
        @(negedge CLK);
        memory[66] = 32'h0000_0000;
        wait_for_main_write();
        ready_enable = 1'b0;
        held_addr  = MEM_ADDR;
        held_wdata = MEM_WDATA;
        held_be    = MEM_BYTE_ENABLE;
        @(negedge CLK);
        #2 FIQ_ASYNC = 1'b1;
        repeat (4) begin
            @(posedge CLK);
            #1;
            check(MEM_VALID
                  && MEM_ADDR == held_addr
                  && MEM_WDATA == held_wdata
                  && MEM_BYTE_ENABLE == held_be,
                  "stalled request changed while FIQ synchronized");
            check(memory[66] == 32'h0000_0000,
                  "FIQ handler ran before stalled request completed");
        end
        @(negedge CLK);
        ready_enable = 1'b1;
        wait (memory[66] == 32'h0000_0046);
        FIQ_ASYNC = 1'b0;
        drain_event_synchronizers();

        // Buffered-response phase: memory completes while CE is low. IRQ
        // synchronization is independent of both the memory slot and CPU CE.
        @(negedge CLK);
        memory[65] = 32'h0000_0000;
        wait_for_main_write();
        ready_enable = 1'b0;
        @(negedge CLK);
        CPU_CE       = 1'b0;
        ready_enable = 1'b1;
        #2 IRQ_ASYNC = 1'b1;
        @(posedge CLK);
        #1;
        check(!MEM_VALID,
              "accepted response was not buffered while CPU_CE was low");
        repeat (4) begin
            @(posedge CLK);
            #1;
            check(!MEM_VALID,
                  "new request appeared while buffered response was held");
            check(memory[65] == 32'h0000_0000,
                  "IRQ handler ran while CPU_CE was low");
        end
        @(negedge CLK);
        CPU_CE = 1'b1;
        wait (memory[65] == 32'h0000_0049);
        IRQ_ASYNC = 1'b0;
        drain_event_synchronizers();

        // Reset phase: asynchronous assertion cancels a held transaction
        // immediately. Deassertion must restart at vector 0 with clean
        // architectural state (the first heartbeat value is one).
        wait_for_main_write();
        ready_enable = 1'b0;
        @(negedge CLK);
        #2 RESET_N = 1'b0;
        #1;
        check(!MEM_VALID, "reset did not cancel the outstanding request");
        memory[64] = 32'hDEAD_BEEF;
        repeat (3) begin
            @(posedge CLK);
            #1;
            check(!MEM_VALID, "request appeared while reset was asserted");
        end
        @(negedge CLK);
        ready_enable = 1'b1;
        RESET_N      = 1'b1;
        wait (saw_reset_vector_after_restart);
        wait (memory[64] == 32'h0000_0001);

        check(accepted_count > 0,
              "no post-reset memory transaction completed");
        check(!$isunknown({
                  MEM_PRIVILEGED, MEM_LOCK, MEM_SEQUENTIAL, MEM_MORE,
                  CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI,
                  DBG_STEP_READY, DBG_STEP_RSP_VALID,
                  DBG_STEP_TDO, DBG_STEP_TDO_OE,
                  DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG,
                  DBGCOMMTX, DBGCOMMRX
              }), "wrapper status contains unknown state");

        if (errors != 0)
            $fatal(1, "[mister_cdc_reset] FAIL (%0d errors)", errors);
        $display("[mister_cdc_reset] PASS");
        $finish;
    end

    initial begin
        #1_000_000;
        $fatal(1, "[mister_cdc_reset] TIMEOUT");
    end

endmodule
