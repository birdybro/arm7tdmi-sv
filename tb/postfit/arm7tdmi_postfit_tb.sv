// FPGA-006 fitted-netlist scoreboard.
//
// This test sees only the synthesized arm7tdmi_mister boundary. It checks an
// architectural program, both frozen endian profiles, reset during a held
// request, randomized CPU/memory stalls, buffered completion while CPU_CE is
// low, asynchronous IRQ entry, and stable valid/ready request payloads.

`timescale 1ps/1ps

`ifndef POSTFIT_BIG_ENDIAN
    `define POSTFIT_BIG_ENDIAN 0
`endif

module arm7tdmi_postfit_tb;
    localparam integer POSTFIT_ENDIAN = `POSTFIT_BIG_ENDIAN;

    reg CLK;
    initial CLK = 1'b0;
    always #5000 CLK = ~CLK;

    reg RESET_N;
    reg forced_cpu_ce;
    reg forced_mem_ready;
    reg random_mode;
    reg IRQ_ASYNC;
    reg [15:0] lfsr_q;

    wire CPU_CE = random_mode ? (lfsr_q[0] || lfsr_q[4])
                              : forced_cpu_ce;

    wire        MEM_VALID;
    wire        MEM_READY = random_mode
                          ? (MEM_VALID && (lfsr_q[2:1] != 2'b00))
                          : forced_mem_ready;
    wire [31:0] MEM_ADDR;
    wire        MEM_WRITE;
    wire [31:0] MEM_WDATA;
    wire [3:0]  MEM_BYTE_ENABLE;
    wire        MEM_CODE;
    wire        MEM_PRIVILEGED;
    wire        MEM_LOCK;
    wire        MEM_SEQUENTIAL;
    wire        MEM_MORE;
    wire [31:0] MEM_RDATA;

    wire CPnMREQ;
    wire CPSEQ;
    wire CPnTRANS;
    wire CPnOPC;
    wire CPTBIT;
    wire CPnI;
    wire DBG_STEP_READY;
    wire DBG_STEP_RSP_VALID;
    wire DBG_STEP_TDO;
    wire DBG_STEP_TDO_OE;
    wire DBGACK;
    wire DBGnEXEC;
    wire DBGINSTRVALID;
    wire [1:0] DBGRNG;
    wire DBGCOMMTX;
    wire DBGCOMMRX;

    arm7tdmi_mister u_dut (
        .CLK,
        .RESET_N,
        .CPU_CE,
        .IRQ_ASYNC,
        .FIQ_ASYNC             (1'b0),
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
        .MEM_ERROR             (1'b0),
        .CPnMREQ,
        .CPSEQ,
        .CPnTRANS,
        .CPnOPC,
        .CPTBIT,
        .CPnI,
        .CPA                   (1'b1),
        .CPB                   (1'b1),
        .DEBUG_ENABLE_ASYNC    (1'b0),
        .DBGRQ_ASYNC           (1'b0),
        .DBGBREAK_ASYNC        (1'b0),
        .DBGEXT_ASYNC          (2'b00),
        .DBG_STEP_VALID        (1'b0),
        .DBG_STEP_READY,
        .DBG_STEP_TMS          (1'b0),
        .DBG_STEP_TDI          (1'b0),
        .DBG_STEP_RSP_VALID,
        .DBG_STEP_RSP_READY    (1'b1),
        .DBG_STEP_TDO,
        .DBG_STEP_TDO_OE,
        .DBGACK,
        .DBGnEXEC,
        .DBGINSTRVALID,
        .DBGRNG,
        .DBGCOMMTX,
        .DBGCOMMRX
    );

    reg [31:0] memory [0:255];
    assign MEM_RDATA = memory[MEM_ADDR[9:2]];

    integer errors;
    integer accepted_count;
    integer accepted_while_ce_low;
    integer current_wait;
    integer longest_wait;
    reg saw_reset_vector;
    reg saw_irq_vector;
    reg saw_code;
    reg saw_data;
    reg saw_word_write;
    reg saw_byte_write;
    reg saw_halfword_write;

    localparam integer REQUEST_WIDTH = 74;
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
    reg [REQUEST_WIDTH-1:0] held_request_q;
    reg request_held_q;

    task check;
        input condition;
        input [8*96-1:0] description;
        begin
            if (!condition) begin
                $display("[postfit] FAIL: %0s", description);
                errors = errors + 1;
            end
        end
    endtask

    always @(posedge CLK or negedge RESET_N) begin
        if (!RESET_N)
            lfsr_q <= 16'h1ace;
        else
            lfsr_q <= {
                lfsr_q[14:0],
                lfsr_q[15] ^ lfsr_q[13] ^ lfsr_q[12] ^ lfsr_q[10]
            };
    end

    always @(posedge CLK or negedge RESET_N) begin
        if (!RESET_N) begin
            accepted_count <= 0;
            accepted_while_ce_low <= 0;
            current_wait <= 0;
            longest_wait <= 0;
            saw_reset_vector <= 1'b0;
            saw_irq_vector <= 1'b0;
            saw_code <= 1'b0;
            saw_data <= 1'b0;
            saw_word_write <= 1'b0;
            saw_byte_write <= 1'b0;
            saw_halfword_write <= 1'b0;
            held_request_q <= {REQUEST_WIDTH{1'b0}};
            request_held_q <= 1'b0;
        end else if (MEM_VALID) begin
`ifdef POSTFIT_TRACE
            $display(
                "[postfit-trace] t=%0t ce=%b ready=%b addr=%08x wr=%b data=%08x be=%b",
                $time, CPU_CE, MEM_READY, MEM_ADDR, MEM_WRITE,
                MEM_WDATA, MEM_BYTE_ENABLE
            );
`endif
            check(MEM_BYTE_ENABLE != 4'b0000,
                  "active request has no byte enables");
            check(MEM_PRIVILEGED,
                  "validation program unexpectedly issued user access");
            check(!(MEM_WRITE && MEM_CODE),
                  "instruction request was marked as write");

            if (request_held_q)
                check(request_payload == held_request_q,
                      "request payload changed before ready");

            saw_reset_vector <= saw_reset_vector
                             || (MEM_CODE && MEM_ADDR == 32'h0000_0000);
            saw_irq_vector <= saw_irq_vector
                           || (MEM_CODE && MEM_ADDR == 32'h0000_0018);
            saw_code <= saw_code || MEM_CODE;
            saw_data <= saw_data || !MEM_CODE;

            if (MEM_READY) begin
                accepted_count <= accepted_count + 1;
                if (!CPU_CE)
                    accepted_while_ce_low <= accepted_while_ce_low + 1;
                if (current_wait > longest_wait)
                    longest_wait <= current_wait;
                current_wait <= 0;
                request_held_q <= 1'b0;

                if (MEM_WRITE) begin
                    if (MEM_ADDR == 32'h0000_0201) begin
                        if (POSTFIT_ENDIAN)
                            check(MEM_BYTE_ENABLE == 4'b0100,
                                  "big endian lane for byte store is wrong");
                        else
                            check(MEM_BYTE_ENABLE == 4'b0010,
                                  "little endian lane for byte store is wrong");
                        saw_byte_write <= 1'b1;
                    end
                    if (MEM_ADDR == 32'h0000_0202) begin
                        if (POSTFIT_ENDIAN)
                            check(MEM_BYTE_ENABLE == 4'b0011,
                                  "big endian lane for halfword store is wrong");
                        else
                            check(MEM_BYTE_ENABLE == 4'b1100,
                                  "little endian lane for halfword store is wrong");
                        saw_halfword_write <= 1'b1;
                    end
                    if (MEM_ADDR == 32'h0000_020c
                        && MEM_BYTE_ENABLE == 4'b1111)
                        saw_word_write <= 1'b1;

                    if (MEM_ADDR[31:10] == 0) begin
                        if (MEM_BYTE_ENABLE[0])
                            memory[MEM_ADDR[9:2]][7:0]
                                <= MEM_WDATA[7:0];
                        if (MEM_BYTE_ENABLE[1])
                            memory[MEM_ADDR[9:2]][15:8]
                                <= MEM_WDATA[15:8];
                        if (MEM_BYTE_ENABLE[2])
                            memory[MEM_ADDR[9:2]][23:16]
                                <= MEM_WDATA[23:16];
                        if (MEM_BYTE_ENABLE[3])
                            memory[MEM_ADDR[9:2]][31:24]
                                <= MEM_WDATA[31:24];
                    end
                end
            end else begin
                if (!request_held_q)
                    held_request_q <= request_payload;
                request_held_q <= 1'b1;
                current_wait <= current_wait + 1;
            end
        end else begin
            check(!request_held_q,
                  "MEM_VALID dropped before a held request completed");
            current_wait <= 0;
        end
    end

    initial begin
        integer index;
        errors = 0;
        RESET_N = 1'b0;
        forced_cpu_ce = 1'b0;
        forced_mem_ready = 1'b0;
        random_mode = 1'b0;
        IRQ_ASYNC = 1'b0;

        for (index = 0; index < 256; index = index + 1)
            memory[index] = 32'h0000_0000;

        memory[0] = 32'hea00_0006;  // Reset: B main (0x20)
        memory[1] = 32'heaff_fffe;  // Undefined: B .
        memory[2] = 32'heaff_fffe;  // SWI: B .
        memory[3] = 32'heaff_fffe;  // Prefetch abort: B .
        memory[4] = 32'heaff_fffe;  // Data abort: B .
        memory[5] = 32'heaff_fffe;  // Reserved: B .
        memory[6] = 32'hea00_0038;  // IRQ: B irq_handler (0x100)
        memory[7] = 32'heaff_fffe;  // FIQ: B .

        memory[8]  = 32'he3a0_0c02; // MOV  r0,#0x200
        memory[9]  = 32'he3a0_6000; // MOV  r6,#0
        memory[10] = 32'he10f_7000; // MRS  r7,cpsr
        memory[11] = 32'he3c7_7080; // BIC  r7,r7,#0x80 (unmask IRQ)
        memory[12] = 32'he121_f007; // MSR  cpsr_c,r7
        memory[13] = 32'he3a0_10aa; // MOV  r1,#0xAA
        memory[14] = 32'he5c0_1001; // STRB r1,[r0,#1]
        memory[15] = 32'he3a0_2055; // MOV  r2,#0x55
        memory[16] = 32'he1c0_20b2; // STRH r2,[r0,#2]
        memory[17] = 32'he3a0_30a5; // MOV  r3,#0xA5
        memory[18] = 32'he3a0_5011; // MOV  r5,#0x11
        memory[19] = 32'he580_500c; // STR  r5,[r0,#12]
        memory[20] = 32'he580_3004; // STR  r3,[r0,#4]
        memory[21] = 32'he286_6001; // ADD  r6,r6,#1
        memory[22] = 32'heaff_fffd; // B    0x54

        memory[64] = 32'he3a0_4066; // MOV  r4,#0x66
        memory[65] = 32'he580_4008; // STR  r4,[r0,#8]
        memory[66] = 32'he25e_f004; // SUBS pc,lr,#4

        // First boot: hold the reset-vector transaction, then asynchronously
        // reset the fitted wrapper while that request is outstanding.
        repeat (5) @(posedge CLK);
        @(negedge CLK);
        RESET_N = 1'b1;
        forced_cpu_ce = 1'b1;
        wait (MEM_VALID);
        repeat (3) @(posedge CLK);
        @(negedge CLK);
        RESET_N = 1'b0;
        #100;
        check(!MEM_VALID, "reset did not cancel held wrapper request");

        // Second boot: accept a response while CPU_CE is low and retain it
        // until randomized CPU and memory enables resume.
        repeat (4) @(posedge CLK);
        @(negedge CLK);
        RESET_N = 1'b1;
        wait (MEM_VALID);
        @(negedge CLK);
        forced_cpu_ce = 1'b0;
        forced_mem_ready = 1'b1;
        @(posedge CLK);
        #100;
        check(!MEM_VALID,
              "response accepted with CPU_CE low was not buffered");
        forced_mem_ready = 1'b0;
        repeat (3) @(posedge CLK);
        random_mode = 1'b1;

        wait (memory[129] == 32'h0000_00a5);
        IRQ_ASYNC = 1'b1;
        wait (saw_irq_vector);
        IRQ_ASYNC = 1'b0;
        wait (memory[130] == 32'h0000_0066);
        repeat (12) @(posedge CLK);
        #100;

        if (POSTFIT_ENDIAN)
            check(memory[128] == 32'h00aa_0055,
                  "big endian lane result is wrong");
        else
            check(memory[128] == 32'h0055_aa00,
                  "little endian lane result is wrong");
        check(memory[131] == 32'h0000_0011,
              "architectural smoke signature is wrong");
        check(saw_reset_vector, "reset vector was not fetched");
        check(saw_irq_vector, "IRQ exception vector was not fetched");
        check(saw_code && saw_data,
              "wrapper did not expose both code and data transactions");
        check(saw_word_write && saw_byte_write && saw_halfword_write,
              "post-fit write-size coverage is incomplete");
        check(accepted_count >= 30,
              "too few fitted-netlist transactions completed");
        check(accepted_while_ce_low > 0,
              "no request completed independently of CPU_CE");
        check(longest_wait >= 2,
              "random memory stalls were not observed");
        check(!DBG_STEP_READY && !DBG_STEP_RSP_VALID
              && !DBG_STEP_TDO && !DBG_STEP_TDO_OE,
              "trimmed debug transport was not tied off");
        check(!$isunknown({
                  MEM_VALID, MEM_ADDR, MEM_WRITE, MEM_WDATA,
                  MEM_BYTE_ENABLE, MEM_CODE, MEM_PRIVILEGED,
                  MEM_LOCK, MEM_SEQUENTIAL, MEM_MORE,
                  CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI,
                  DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG,
                  DBGCOMMTX, DBGCOMMRX
              }), "fitted outputs contain unknown state");

        if (errors != 0)
            $fatal(1, "[postfit] FAIL endian=%0d errors=%0d",
                   POSTFIT_ENDIAN, errors);
        $display(
            "[postfit] PASS endian=%0d accepted=%0d ce_low=%0d longest_wait=%0d",
            POSTFIT_ENDIAN, accepted_count, accepted_while_ce_low,
            longest_wait
        );
        $finish;
    end

    initial begin
        #20_000_000;
        $fatal(1, "[postfit] TIMEOUT endian=%0d", POSTFIT_ENDIAN);
    end
endmodule
