// VAL-002 ARM7-specific endian and legacy-unaligned memory policy scoreboard.
//
// A generated program writes every observed value to a bounded output area.
// The Python oracle supplies permitted effects for both CFGBIGEND profiles.

`timescale 1ns/1ps

module arm7tdmis_random_policy_tb
    import arm7tdmis_bus_pkg::*;
;

    localparam int MEMORY_WORDS = 65536;
    localparam int MAX_EXPECTED_WORDS = 512;
    localparam logic [31:0] DATA_ADDRESS = 32'h0001_8000;
    localparam logic [31:0] OUTPUT_ADDRESS = 32'h0001_a000;

    logic CLK;
    initial CLK = 1'b0;
    always #5 CLK = ~CLK;

    logic nRESET;
    logic big_endian;
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
        .CLK, .CLKEN(1'b1), .nRESET, .CFGBIGEND(big_endian),
        .nIRQ(1'b1), .nFIQ(1'b1), .ABORT,
        .ADDR, .WRITE, .SIZE, .PROT, .LOCK, .TRANS, .WDATA, .RDATA,
        .CPnMREQ, .CPSEQ, .CPnTRANS, .CPnOPC, .CPTBIT, .CPnI,
        .CPA(1'b1), .CPB(1'b1),
        .DBGEN(1'b0), .DBGRQ(1'b0), .DBGBREAK(1'b0),
        .DBGACK, .DBGnEXEC, .DBGINSTRVALID, .DBGEXT(2'b00),
        .DBGRNG, .DBGCOMMTX, .DBGCOMMRX,
        .DBGTCKEN(1'b0), .DBGTMS(1'b0), .DBGTDI(1'b0),
        .DBGTDO, .DBGnTRST(1'b1), .DBGnTDOEN, .DMORE
    );

    arm7tdmis_memory #(.WORDS(MEMORY_WORDS)) u_mem (
        .CLK, .CLKEN(1'b1), .nRESET, .CFGBIGEND(big_endian),
        .ADDR, .WRITE, .SIZE, .PROT, .LOCK, .TRANS, .WDATA, .RDATA,
        .ABORT, .inject_abort(1'b0)
    );

    logic [31:0] expected_memory [0:MAX_EXPECTED_WORDS-1];
    int unsigned expected_words;
    int unsigned data_words;
    logic [31:0] big_endian_arg;
    int unsigned seed;
    string program_hex;
    string expected_memory_hex;

    task automatic fail(input string reason);
        $fatal(1, "[random_policy] FAIL seed=%0d endian=%0d: %s",
               seed, big_endian, reason);
    endtask

    task automatic check_expected_memory;
        for (int word = 0; word < expected_words; word++) begin
            if (u_mem.mem[(OUTPUT_ADDRESS >> 2) + word]
                !== expected_memory[word])
                fail($sformatf(
                    "output[%0d] expected %08x got %08x",
                    word, expected_memory[word],
                    u_mem.mem[(OUTPUT_ADDRESS >> 2) + word]
                ));
        end
        for (int word = 0; word < data_words; word++) begin
            if (u_mem.mem[(DATA_ADDRESS >> 2) + word]
                !== expected_memory[expected_words + word])
                fail($sformatf(
                    "data[%0d] expected %08x got %08x",
                    word, expected_memory[expected_words + word],
                    u_mem.mem[(DATA_ADDRESS >> 2) + word]
                ));
        end
    endtask

    always @(posedge CLK) begin
        #1;
        if (nRESET && expected_words > 0
            && u_mem.mem[(OUTPUT_ADDRESS >> 2) + expected_words - 1]
               === expected_memory[expected_words - 1]) begin
            check_expected_memory();
            $display(
                "[random_policy] PASS seed=%0d BIG_ENDIAN=%0d EXPECTED_WORDS=%0d",
                seed, big_endian, expected_words
            );
            $finish;
        end
    end

    initial begin
        nRESET = 1'b0;
        big_endian = 1'b0;
        if (!$value$plusargs("PROGRAM_HEX=%s", program_hex))
            $fatal(1, "[random_policy] missing +PROGRAM_HEX");
        if (!$value$plusargs(
                "EXPECTED_MEMORY_HEX=%s", expected_memory_hex))
            $fatal(1, "[random_policy] missing +EXPECTED_MEMORY_HEX");
        if (!$value$plusargs("EXPECTED_WORDS=%d", expected_words))
            $fatal(1, "[random_policy] missing +EXPECTED_WORDS");
        if (!$value$plusargs("DATA_WORDS=%d", data_words))
            $fatal(1, "[random_policy] missing +DATA_WORDS");
        if (!$value$plusargs("BIG_ENDIAN=%d", big_endian_arg))
            $fatal(1, "[random_policy] missing +BIG_ENDIAN");
        if (!$value$plusargs("SEED=%d", seed))
            $fatal(1, "[random_policy] missing +SEED");
        if (expected_words == 0
            || expected_words + data_words > MAX_EXPECTED_WORDS)
            $fatal(1, "[random_policy] invalid expected-memory size");
        big_endian = big_endian_arg[0];
        for (int word = 0; word < MEMORY_WORDS; word++)
            u_mem.mem[word] = 32'h0000_0000;
        $readmemh(program_hex, u_mem.mem);
        $readmemh(expected_memory_hex, expected_memory);
        repeat (4) @(posedge CLK);
        @(negedge CLK);
        nRESET = 1'b1;
    end

    initial begin
        repeat (10000) @(posedge CLK);
        $fatal(1, "[random_policy] TIMEOUT seed=%0d endian=%0d",
               seed, big_endian);
    end

    wire _unused_status = &{1'b0,
        CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI,
        DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG,
        DBGCOMMTX, DBGCOMMRX, DBGTDO, DBGnTDOEN, DMORE,
        big_endian_arg[31:1]};

endmodule
