// Executable MIST-010 acceptance test for the generic integration example.
//
// The built-in ARM/Thumb program runs seven self-test groups, emits "G" after
// the non-interrupt tests, takes a timer IRQ and emits "I", then publishes the
// PASS/signature MMIO pair and emits "P". The host backpressures every byte
// while CPU_CE is randomized. No hierarchy is used to observe the result.

`timescale 1ns/1ps

module arm7tdmi_generic_soc_tb;

    logic CLK;
    initial CLK = 1'b0;
    always #5 CLK = ~CLK;

    logic RESET_N;
    logic random_ce;
    logic [15:0] lfsr_q;
    wire CPU_CE = !random_ce || lfsr_q[0] || lfsr_q[3];

    logic       UART_TX_READY;
    logic       UART_TX_VALID;
    logic [7:0] UART_TX_DATA;
    logic       TIMER_IRQ;
    logic       saw_timer_irq;
    logic [31:0] TEST_STATUS;
    logic [31:0] TEST_SIGNATURE;
    logic [7:1]  saw_test;

    arm7tdmi_generic_soc u_dut (
        .CLK,
        .RESET_N,
        .CPU_CE,
        .UART_TX_READY,
        .UART_TX_VALID,
        .UART_TX_DATA,
        .TIMER_IRQ,
        .TEST_STATUS,
        .TEST_SIGNATURE
    );

    always_ff @(posedge CLK or negedge RESET_N) begin
        if (!RESET_N) begin
            lfsr_q       <= 16'h4D35;
            saw_timer_irq <= 1'b0;
            saw_test      <= '0;
        end else begin
            lfsr_q <= {
                lfsr_q[14:0],
                lfsr_q[15] ^ lfsr_q[13] ^ lfsr_q[12] ^ lfsr_q[10]
            };
            saw_timer_irq <= saw_timer_irq || TIMER_IRQ;
            if (TEST_STATUS == 32'h5255_4e21
                && TEST_SIGNATURE >= 32'd1
                && TEST_SIGNATURE <= 32'd7) begin
                saw_test[TEST_SIGNATURE[2:0]] <= 1'b1;
            end
            if (TEST_STATUS == 32'h4641_494c)
                $fatal(1, "[generic_soc] ROM self-test %0d failed",
                       TEST_SIGNATURE);
        end
    end

    task automatic accept_uart_byte(
        input logic [7:0] expected,
        input string      description
    );
        begin
            wait (UART_TX_VALID);
            if (UART_TX_DATA != expected)
                $fatal(1, "[generic_soc] wrong %s byte: %02x",
                       description, UART_TX_DATA);

            // Exercise stable UART backpressure for longer than the CPU's
            // two-flop interrupt synchronization latency.
            repeat (8) begin
                @(posedge CLK);
                #1;
                if (!UART_TX_VALID || UART_TX_DATA != expected)
                    $fatal(1,
                           "[generic_soc] %s byte changed under backpressure",
                           description);
            end

            @(negedge CLK);
            UART_TX_READY = 1'b1;
            @(posedge CLK);
            #1;
            UART_TX_READY = 1'b0;
        end
    endtask

    initial begin
        RESET_N       = 1'b0;
        random_ce     = 1'b0;
        UART_TX_READY = 1'b0;

        repeat (5) @(posedge CLK);
        @(negedge CLK);
        RESET_N = 1'b1;

        accept_uart_byte(8'h47, "RAM-check");
        random_ce = 1'b1;
        accept_uart_byte(8'h49, "timer-IRQ");
        accept_uart_byte(8'h50, "final-PASS");

        repeat (10) @(posedge CLK);
        if (!saw_timer_irq)
            $fatal(1, "[generic_soc] timer IRQ was never asserted");
        if (saw_test != 7'b111_1111)
            $fatal(1, "[generic_soc] missing test progress: %07b", saw_test);
        if (TEST_STATUS != 32'h5041_5353)
            $fatal(1, "[generic_soc] final status is not PASS: %08x",
                   TEST_STATUS);
        if (TEST_SIGNATURE != 32'ha7d1_c0de)
            $fatal(1, "[generic_soc] wrong final signature: %08x",
                   TEST_SIGNATURE);
        if (!CPU_CE)
            @(posedge CLK);

        $display("[generic_soc] PASS");
        $finish;
    end

    initial begin
        #2_000_000;
        $fatal(1, "[generic_soc] TIMEOUT");
    end

endmodule
