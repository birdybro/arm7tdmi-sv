// Harness mutation sentinel: this bench must fail.
//
// The release harness compiles and runs it, then requires a nonzero simulator
// status. If a simulator assertion, $fatal, shell pipeline, or result wrapper
// accidentally converts failure to success, the enclosing self-test fails.

module expected_failure_tb;
    initial begin
        #1;
        $fatal(1, "[harness-self-test] EXPECTED FAILURE");
    end
endmodule
