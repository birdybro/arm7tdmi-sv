// VAL-002 seeded shared-ARMv4T differential scoreboard.
//
// The expected post-instruction states and five permitted memory words come
// from QEMU, not from DUT hierarchy. Privileged r8-r14 comparisons select the
// physical bank named by the expected post-instruction CPSR mode.

`timescale 1ns/1ps

`ifndef ARM7TDMIS_VERIFICATION
    `error "random_diff requires ARM7TDMIS_VERIFICATION"
`endif

module arm7tdmis_random_diff_tb
    import arm7tdmis_bus_pkg::*;
;

    localparam int MEMORY_WORDS = 65536;
    localparam int MAX_EXPECTED_EVENTS = 2048;
    localparam int EXPECTED_WORDS_PER_EVENT = 19;
    localparam int EXPECTED_BITS = EXPECTED_WORDS_PER_EVENT * 32;
    localparam int EVENT_INDEX_BITS = $clog2(MAX_EXPECTED_EVENTS);
    localparam logic [31:0] PSR_COMPARE_MASK = 32'hf000_00ff;
    localparam logic [31:0] DATA_ADDRESS = 32'h0001_0000;
    localparam logic [31:0] NO_EXCEPTION = 32'hffff_ffff;

    logic CLK;
    initial CLK = 1'b0;
    always #5 CLK = ~CLK;

    logic nRESET;
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

    logic         VER_RETIRE_VALID;
    logic [31:0]  VER_RETIRE_PC;
    logic [31:0]  VER_RETIRE_OPCODE;
    logic         VER_RETIRE_THUMB;
    logic         VER_RETIRE_CONDITION_PASS;
    logic         VER_RETIRE_INJECTED;
    logic         VER_RETIRE_EXCEPTION_VALID;
    logic [2:0]   VER_RETIRE_EXCEPTION;
    logic [991:0] VER_RETIRE_GPRS;
    logic [31:0]  VER_RETIRE_CPSR;
    logic [159:0] VER_RETIRE_SPSRS;

    arm7tdmis_top u_dut (
        .CLK, .CLKEN(1'b1), .nRESET, .CFGBIGEND(1'b0),
        .nIRQ(1'b1), .nFIQ(1'b1), .ABORT,
        .ADDR, .WRITE, .SIZE, .PROT, .LOCK, .TRANS, .WDATA, .RDATA,
        .CPnMREQ, .CPSEQ, .CPnTRANS, .CPnOPC, .CPTBIT, .CPnI,
        .CPA(1'b1), .CPB(1'b1),
        .DBGEN(1'b0), .DBGRQ(1'b0), .DBGBREAK(1'b0),
        .DBGACK, .DBGnEXEC, .DBGINSTRVALID, .DBGEXT(2'b00),
        .DBGRNG, .DBGCOMMTX, .DBGCOMMRX,
        .DBGTCKEN(1'b0), .DBGTMS(1'b0), .DBGTDI(1'b0),
        .DBGTDO, .DBGnTRST(1'b1), .DBGnTDOEN, .DMORE,
        .VER_RETIRE_VALID, .VER_RETIRE_PC, .VER_RETIRE_OPCODE,
        .VER_RETIRE_THUMB, .VER_RETIRE_CONDITION_PASS,
        .VER_RETIRE_INJECTED, .VER_RETIRE_EXCEPTION_VALID,
        .VER_RETIRE_EXCEPTION, .VER_RETIRE_GPRS, .VER_RETIRE_CPSR,
        .VER_RETIRE_SPSRS
    );

    arm7tdmis_memory #(.WORDS(MEMORY_WORDS)) u_mem (
        .CLK, .CLKEN(1'b1), .nRESET, .CFGBIGEND(1'b0),
        .ADDR, .WRITE, .SIZE, .PROT, .LOCK, .TRANS, .WDATA, .RDATA,
        .ABORT, .inject_abort(1'b0)
    );

    logic [EXPECTED_BITS-1:0] expected [0:MAX_EXPECTED_EVENTS-1];
    logic [31:0] permitted_memory [0:4];
    int unsigned expected_events;
    int unsigned event_count;
    int unsigned timeout_cycles;
    int unsigned seed;
    string program_hex;
    string expected_hex;
    string permitted_memory_hex;
    logic measuring;

    function automatic logic [31:0] expected_word(
        input logic [EVENT_INDEX_BITS-1:0] event_index,
        input logic [4:0] word_index
    );
        return expected[event_index][
            ((EXPECTED_WORDS_PER_EVENT - 1 - int'(word_index)) * 32) +: 32
        ];
    endfunction

    function automatic int active_physical_index(
        input int register_number,
        input logic [4:0] mode
    );
        if (register_number <= 7)
            return register_number;
        if (register_number <= 12)
            return (mode == 5'h11)
                 ? register_number + 8 : register_number;
        unique case (mode)
            5'h10, 5'h1f: return register_number;
            5'h11: return register_number + 8;
            5'h12: return register_number + 10;
            5'h13: return register_number + 12;
            5'h17: return register_number + 14;
            5'h1b: return register_number + 16;
            default: return register_number;
        endcase
    endfunction

    function automatic logic [31:0] active_gpr(
        input int register_number,
        input logic [4:0] mode
    );
        int physical_index;
        physical_index = active_physical_index(register_number, mode);
        return VER_RETIRE_GPRS[(physical_index * 32) +: 32];
    endfunction

    task automatic fail(input string reason);
        $fatal(1, "[random_diff] FAIL seed=%0d event=%0d: %s",
               seed, event_count, reason);
    endtask

    task automatic check_permitted_memory;
        for (int word = 0; word < 5; word++) begin
            if (u_mem.mem[(DATA_ADDRESS >> 2) + word]
                !== permitted_memory[word])
                fail($sformatf(
                    "permitted memory[%0d] expected %08x got %08x",
                    word, permitted_memory[word],
                    u_mem.mem[(DATA_ADDRESS >> 2) + word]
                ));
        end
    endtask

    always @(posedge CLK) begin
        logic [31:0] expected_exception;
        logic [4:0] expected_mode;
        #1;
        if (VER_RETIRE_VALID) begin
            if (!measuring && VER_RETIRE_PC !== expected_word('0, 5'd0)) begin
                // Reset-vector setup is intentionally outside measurement.
            end else begin
                measuring <= 1'b1;
                if (event_count >= expected_events)
                    fail("ghost retirement after QEMU trace");
                if (VER_RETIRE_PC !== expected_word(
                        EVENT_INDEX_BITS'(event_count), 5'd0))
                    fail($sformatf(
                        "PC expected %08x got %08x",
                        expected_word(
                            EVENT_INDEX_BITS'(event_count), 5'd0
                        ),
                        VER_RETIRE_PC
                    ));
                if (VER_RETIRE_THUMB !== expected_word(
                        EVENT_INDEX_BITS'(event_count), 5'd1)[0])
                    fail("ARM/Thumb state differs from QEMU");
                if ((VER_RETIRE_CPSR & PSR_COMPARE_MASK)
                    !== expected_word(
                        EVENT_INDEX_BITS'(event_count), 5'd2))
                    fail($sformatf(
                        "CPSR expected %08x got %08x",
                        expected_word(
                            EVENT_INDEX_BITS'(event_count), 5'd2
                        ),
                        VER_RETIRE_CPSR & PSR_COMPARE_MASK
                    ));
                expected_exception = expected_word(
                    EVENT_INDEX_BITS'(event_count), 5'd3);
                if (expected_exception == NO_EXCEPTION) begin
                    if (VER_RETIRE_EXCEPTION_VALID)
                        fail("unexpected architectural exception");
                end else begin
                    if (!VER_RETIRE_EXCEPTION_VALID)
                        fail("QEMU exception was not reported");
                    if (VER_RETIRE_EXCEPTION !== expected_exception[2:0])
                        fail($sformatf(
                            "exception expected %0d got %0d",
                            expected_exception[2:0], VER_RETIRE_EXCEPTION
                        ));
                end
                expected_mode = expected_word(
                    EVENT_INDEX_BITS'(event_count), 5'd2)[4:0];
                for (int register_number = 0;
                     register_number < 15; register_number++) begin
                    if (active_gpr(register_number, expected_mode)
                        !== expected_word(
                            EVENT_INDEX_BITS'(event_count),
                            5'(4 + register_number)
                        ))
                        fail($sformatf(
                            "r%0d expected %08x got %08x in mode %02x",
                            register_number,
                            expected_word(
                                EVENT_INDEX_BITS'(event_count),
                                5'(4 + register_number)
                            ),
                            active_gpr(register_number, expected_mode),
                            expected_mode
                        ));
                end
                if (VER_RETIRE_INJECTED)
                    fail("ordinary program reported debug injection");

                if ((event_count + 1) == expected_events) begin
                    check_permitted_memory();
                    $display(
                        "[random_diff] PASS seed=%0d events=%0d",
                        seed, expected_events
                    );
                    $finish;
                end
                event_count <= event_count + 1;
            end
        end else if (measuring && VER_RETIRE_EXCEPTION_VALID) begin
            fail("exception event has no retiring instruction");
        end
    end

    initial begin
        nRESET = 1'b0;
        event_count = 0;
        measuring = 1'b0;
        if (!$value$plusargs("PROGRAM_HEX=%s", program_hex))
            $fatal(1, "[random_diff] missing +PROGRAM_HEX");
        if (!$value$plusargs("EXPECTED_HEX=%s", expected_hex))
            $fatal(1, "[random_diff] missing +EXPECTED_HEX");
        if (!$value$plusargs(
                "PERMITTED_MEMORY_HEX=%s", permitted_memory_hex))
            $fatal(1, "[random_diff] missing +PERMITTED_MEMORY_HEX");
        if (!$value$plusargs("EXPECTED_EVENTS=%d", expected_events))
            $fatal(1, "[random_diff] missing +EXPECTED_EVENTS");
        if (!$value$plusargs("SEED=%d", seed))
            $fatal(1, "[random_diff] missing +SEED");
        if (expected_events == 0 || expected_events > MAX_EXPECTED_EVENTS)
            $fatal(1, "[random_diff] invalid EXPECTED_EVENTS=%0d",
                   expected_events);
        timeout_cycles = 1000 + (expected_events * 20);
        for (int word = 0; word < MEMORY_WORDS; word++)
            u_mem.mem[word] = 32'h0000_0000;
        $readmemh(program_hex, u_mem.mem);
        $readmemh(expected_hex, expected);
        $readmemh(permitted_memory_hex, permitted_memory);
        repeat (4) @(posedge CLK);
        @(negedge CLK);
        nRESET = 1'b1;
    end

    initial begin
        wait (timeout_cycles > 0);
        repeat (timeout_cycles) @(posedge CLK);
        $fatal(1, "[random_diff] TIMEOUT seed=%0d after %0d/%0d events",
               seed, event_count, expected_events);
    end

    wire _unused_status = &{1'b0,
        CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI,
        DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG,
        DBGCOMMTX, DBGCOMMRX, DBGTDO, DBGnTDOEN, DMORE,
        VER_RETIRE_OPCODE, VER_RETIRE_CONDITION_PASS, VER_RETIRE_SPSRS};

endmodule
