// MIST-001/MIST-002 fail-first regression for the canonical FPGA wrapper.
//
// The memory model accepts the first fetch while CPU_CE is low to prove that
// the wrapper buffers an independently completed response. It then applies
// deterministic pseudo-random CPU enables and memory waits. Every request
// payload must remain stable under backpressure, each valid/ready handshake
// is counted once, and an ARM program verifies word/byte/halfword writes plus
// a readback through the conventional request interface.

`timescale 1ns/1ps

module arm7tdmis_mister_wrapper_tb;

    logic CLK;
    initial CLK = 1'b0;
    always #5 CLK = ~CLK;

    logic RESET_N;
    logic random_mode;
    logic forced_cpu_ce;
    logic forced_mem_ready;
    logic [15:0] lfsr_q;

    wire CPU_CE = random_mode ? (lfsr_q[0] || lfsr_q[3])
                              : forced_cpu_ce;

    logic        MEM_VALID;
    wire         MEM_READY = random_mode
                           ? (MEM_VALID && (lfsr_q[2:1] != 2'b00))
                           : forced_mem_ready;
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
    integer accepted_while_ce_low;
    integer longest_wait;
    integer current_wait;
    logic   saw_code;
    logic   saw_data;
    logic   saw_nonsequential;
    logic   saw_sequential;
    logic   saw_word_write;
    logic   saw_byte_write;
    logic   saw_halfword_write;

    localparam int REQUEST_WIDTH = 74;
    logic [REQUEST_WIDTH-1:0] held_request_q;
    logic                     request_held_q;
    wire [REQUEST_WIDTH-1:0] request_payload = {
        MEM_ADDR,
        MEM_WRITE,
        MEM_WDATA,
        MEM_BYTE_ENABLE,
        MEM_CODE,
        MEM_PRIVILEGED,
        MEM_LOCK,
        MEM_SEQUENTIAL,
        MEM_MORE
    };

    task automatic check(input logic condition, input string description);
        if (!condition) begin
            $display("[mister_wrapper] FAIL: %s", description);
            errors++;
        end
    endtask

    always_ff @(posedge CLK or negedge RESET_N) begin
        if (!RESET_N)
            lfsr_q <= 16'h1ACE;
        else
            lfsr_q <= {lfsr_q[14:0],
                       lfsr_q[15] ^ lfsr_q[13] ^ lfsr_q[12] ^ lfsr_q[10]};
    end

    always_ff @(posedge CLK or negedge RESET_N) begin
        if (!RESET_N) begin
            accepted_count       <= 0;
            accepted_while_ce_low <= 0;
            longest_wait         <= 0;
            current_wait         <= 0;
            held_request_q       <= '0;
            request_held_q       <= 1'b0;
            saw_code             <= 1'b0;
            saw_data             <= 1'b0;
            saw_nonsequential    <= 1'b0;
            saw_sequential       <= 1'b0;
            saw_word_write       <= 1'b0;
            saw_byte_write       <= 1'b0;
            saw_halfword_write   <= 1'b0;
        end else begin
            if (MEM_VALID) begin
                check(!$isunknown(request_payload),
                      "request contains unknown control or data");
                check(MEM_BYTE_ENABLE != 4'b0000,
                      "active request has no byte lanes");
                check(MEM_PRIVILEGED,
                      "reset program unexpectedly issued a User request");
                check(!(MEM_WRITE && MEM_CODE),
                      "instruction fetch was marked as a write");

                if (MEM_ADDR < 32'h0000_0080)
                    check(MEM_CODE, "program fetch was not marked as code");
                else
                    check(!MEM_CODE, "data transfer was marked as code");

                saw_code          <= saw_code || MEM_CODE;
                saw_data          <= saw_data || !MEM_CODE;
                saw_nonsequential <= saw_nonsequential || !MEM_SEQUENTIAL;
                saw_sequential    <= saw_sequential || MEM_SEQUENTIAL;

                if (request_held_q)
                    check(request_payload == held_request_q,
                          "request payload changed before ready");

                if (MEM_READY) begin
                    accepted_count <= accepted_count + 1;
                    if (!CPU_CE)
                        accepted_while_ce_low <=
                            accepted_while_ce_low + 1;
                    if (current_wait > longest_wait)
                        longest_wait <= current_wait;
                    current_wait   <= 0;
                    request_held_q <= 1'b0;

                    if (MEM_WRITE) begin
                        for (int lane = 0; lane < 4; lane++) begin
                            if (MEM_BYTE_ENABLE[lane])
                                memory[MEM_ADDR[9:2]][lane*8 +: 8]
                                    <= MEM_WDATA[lane*8 +: 8];
                        end

                        if (MEM_ADDR == 32'h0000_0080) begin
                            check(MEM_BYTE_ENABLE == 4'b1111,
                                  "word store byte enables are wrong");
                            saw_word_write <= 1'b1;
                        end
                        if (MEM_ADDR == 32'h0000_0081) begin
                            check(MEM_BYTE_ENABLE == 4'b0010,
                                  "little-endian byte store lane is wrong");
                            check(MEM_WDATA[15:8] == 8'hAA,
                                  "byte store data is not lane-aligned");
                            saw_byte_write <= 1'b1;
                        end
                        if (MEM_ADDR == 32'h0000_0082) begin
                            check(MEM_BYTE_ENABLE == 4'b1100,
                                  "little-endian halfword lanes are wrong");
                            check(MEM_WDATA[31:16] == 16'h0055,
                                  "halfword store data is not lane-aligned");
                            saw_halfword_write <= 1'b1;
                        end
                    end
                end else begin
                    if (!request_held_q)
                        held_request_q <= request_payload;
                    request_held_q <= 1'b1;
                    current_wait   <= current_wait + 1;
                end
            end else begin
                check(!request_held_q,
                      "MEM_VALID dropped before a held request completed");
                current_wait <= 0;
            end
        end
    end

    initial begin
        errors           = 0;
        RESET_N          = 1'b0;
        random_mode      = 1'b0;
        forced_cpu_ce    = 1'b0;
        forced_mem_ready = 1'b0;

        for (int word_index = 0; word_index < 256; word_index++)
            memory[word_index] = 32'h0000_0000;

        // ARM program:
        //   r0 = 0x80
        //   word [0x80] = 0x11; byte [0x81] = 0xAA;
        //   halfword [0x82] = 0x0055
        //   [0x88] = readback [0x80]; [0x84] = completion signature
        memory[0]  = 32'hE3A0_0080; // MOV  r0,#0x80
        memory[1]  = 32'hE3A0_1011; // MOV  r1,#0x11
        memory[2]  = 32'hE580_1000; // STR  r1,[r0]
        memory[3]  = 32'hE3A0_20AA; // MOV  r2,#0xAA
        memory[4]  = 32'hE5C0_2001; // STRB r2,[r0,#1]
        memory[5]  = 32'hE3A0_3055; // MOV  r3,#0x55
        memory[6]  = 32'hE1C0_30B2; // STRH r3,[r0,#2]
        memory[7]  = 32'hE590_4000; // LDR  r4,[r0]
        memory[8]  = 32'hE580_4008; // STR  r4,[r0,#8]
        memory[9]  = 32'hE3A0_50A5; // MOV  r5,#0xA5
        memory[10] = 32'hE580_5004; // STR  r5,[r0,#4]
        memory[11] = 32'hEAFF_FFFE; // B    .

        repeat (5) @(posedge CLK);
        @(negedge CLK);
        RESET_N       = 1'b1;
        forced_cpu_ce = 1'b1;

        // Accept the first request while CPU_CE is deliberately low. A
        // standard valid/ready target must not have to know about CPU_CE.
        wait (MEM_VALID);
        @(negedge CLK);
        forced_cpu_ce    = 1'b0;
        forced_mem_ready = 1'b1;
        @(posedge CLK);
        #1;
        check(!MEM_VALID,
              "completed request was not removed while CPU_CE was low");
        forced_mem_ready = 1'b0;

        repeat (4) begin
            @(posedge CLK);
            #1;
            check(!MEM_VALID,
                  "new request appeared before buffered response was consumed");
        end

        @(negedge CLK);
        random_mode = 1'b1;

        wait (memory[33] == 32'h0000_00A5);
        repeat (10) @(posedge CLK);
        #1;

        check(memory[32] == 32'h0055_AA11,
              $sformatf("mixed-width stores produced %08x", memory[32]));
        check(memory[34] == 32'h0055_AA11,
              $sformatf("readback store produced %08x", memory[34]));
        check(accepted_count > 15, "too few memory transactions completed");
        check(accepted_while_ce_low > 0,
              "no response completed independently of CPU_CE");
        check(longest_wait >= 1, "random memory never inserted a wait");
        check(saw_code && saw_data,
              "code/data metadata did not cover both access classes");
        check(saw_nonsequential && saw_sequential,
              "N/S hints did not cover both request classes");
        check(saw_word_write && saw_byte_write && saw_halfword_write,
              "write-size coverage is incomplete");
        check(!DBG_STEP_READY && !DBG_STEP_RSP_VALID
              && !DBG_STEP_TDO && !DBG_STEP_TDO_OE,
              "disabled debug transport was not tied off");
        check(!$isunknown({
                  CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI,
                  DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG,
                  DBGCOMMTX, DBGCOMMRX
              }), "optional/status outputs contain unknown state");

        if (errors != 0)
            $fatal(1, "[mister_wrapper] FAIL (%0d errors)", errors);
        $display("[mister_wrapper] PASS");
        $finish;
    end

    initial begin
        #500_000;
        $fatal(1, "[mister_wrapper] TIMEOUT");
    end

endmodule
