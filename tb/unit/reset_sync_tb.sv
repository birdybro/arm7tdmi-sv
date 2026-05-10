// Unit test for arm7tdmis_reset_sync.
//
// Coverage:
//   - Power-on (nRESET=0 from time 0): core_nreset stays LOW
//   - Async assert: dropping nRESET LOW propagates to core_nreset within
//     one rising-edge sample (the flops async-clear)
//   - Sync deassert: raising nRESET HIGH propagates through 2 CLK edges
//     before core_nreset goes HIGH
//   - Short pulse rejection: a 1-cycle nRESET HIGH followed by LOW does
//     not glitch core_nreset HIGH (the 2-stage shifter swallows it)

module reset_sync_tb;

    localparam int CLK_HALF = 5;

    logic CLK;
    initial begin
        CLK = 1'b0;
        forever #(CLK_HALF) CLK = ~CLK;
    end

    logic nRESET;
    logic core_nreset;

    arm7tdmis_reset_sync dut (.*);

    int errors;

    task automatic check1(string label, logic actual, logic expected);
        if (actual !== expected) begin
            $display("FAIL [%s] @%0t: expected %0b, got %0b",
                     label, $time, expected, actual);
            errors = errors + 1;
        end
    endtask

    initial begin
        errors = 0;
        nRESET = 1'b0;

        // T1: power-on — core_nreset must be LOW
        #1;
        check1("power-on", core_nreset, 1'b0);

        // Wait several cycles still in reset
        repeat (3) @(posedge CLK);
        #1;
        check1("held in reset", core_nreset, 1'b0);

        // T2: sync deassert — release nRESET, expect 2 cycles of latency
        @(negedge CLK);
        nRESET = 1'b1;

        // Cycle 1 after deassert: q1 captures 1, q2 still 0 → core_nreset=0
        @(posedge CLK);
        #1;
        check1("deassert cycle 1: still LOW", core_nreset, 1'b0);

        // Cycle 2: q2 picks up q1 → core_nreset goes HIGH
        @(posedge CLK);
        #1;
        check1("deassert cycle 2: HIGH", core_nreset, 1'b1);

        // T3: stays HIGH while nRESET=1
        repeat (5) @(posedge CLK);
        #1;
        check1("steady state HIGH", core_nreset, 1'b1);

        // T4: async assert — drop nRESET LOW, core_nreset clears asynchronously
        nRESET = 1'b0;
        #1;
        check1("async assert: immediate LOW", core_nreset, 1'b0);

        // T5: short-pulse rejection — release for less than 2 CLK
        @(negedge CLK);
        nRESET = 1'b1;
        @(posedge CLK);
        #1;
        // q1=1, q2=0 → still LOW
        check1("short pulse cycle 1", core_nreset, 1'b0);
        nRESET = 1'b0;
        #1;
        // async clear fires, q1 and q2 both go to 0; core_nreset must be LOW
        check1("short pulse: async-clear back to LOW", core_nreset, 1'b0);

        // Hold reset for several cycles to settle
        repeat (3) @(posedge CLK);
        #1;
        check1("settled LOW after pulse", core_nreset, 1'b0);

        if (errors == 0) begin
            $display("reset_sync_tb: PASS");
            $finish;
        end else begin
            $fatal(1, "reset_sync_tb: FAIL (%0d errors)", errors);
        end
    end

    initial begin
        #100000;
        $fatal(1, "reset_sync_tb: TIMEOUT");
    end

endmodule
