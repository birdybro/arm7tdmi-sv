// VAL-001 independent differential regression.
//
// The expected post-instruction snapshots are produced from QEMU's CPU log,
// not from an RTL decoder or a duplicated instruction model. This scoreboard
// compares PC/state, r0-r14, the ARMv4T CPSR fields, and final memory effects
// for one mixed ARM/Thumb program.

`timescale 1ns/1ps

`ifndef ARM7TDMIS_VERIFICATION
    `error "qemu_diff requires ARM7TDMIS_VERIFICATION"
`endif

module arm7tdmis_qemu_diff_tb
    import arm7tdmis_bus_pkg::*;
;

    `include "qemu_diff_generated.svh"

    localparam int MEMORY_WORDS = 65536;
    localparam int EXPECTED_WORDS = 18;
    localparam int EXPECTED_BITS = EXPECTED_WORDS * 32;
    localparam int EVENT_INDEX_BITS = $clog2(EXPECTED_EVENTS);
    localparam logic [31:0] PSR_COMPARE_MASK = 32'hf000_00ff;
    localparam logic [31:0] DATA_ADDRESS = 32'h0002_0000;

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

    logic [EXPECTED_BITS-1:0] expected [0:EXPECTED_EVENTS-1];
    int unsigned event_count;
    string program_hex;
    string expected_hex;
    logic measuring;

    function automatic logic [31:0] expected_word(
        input logic [EVENT_INDEX_BITS-1:0] event_index,
        input logic [4:0] word_index
    );
        return expected[event_index][
            ((EXPECTED_WORDS - 1 - int'(word_index)) * 32) +: 32
        ];
    endfunction

    function automatic logic [31:0] physical_gpr(input int reg_number);
        int physical_index;
        physical_index = reg_number < 13 ? reg_number : reg_number + 12;
        return VER_RETIRE_GPRS[(physical_index * 32) +: 32];
    endfunction

    task automatic fail(input string reason);
        $fatal(1, "[qemu_diff] FAIL event %0d: %s", event_count, reason);
    endtask

    task automatic check_final_memory(
        input logic [EVENT_INDEX_BITS-1:0] final_event
    );
        logic [31:0] expected_memory;
        for (int word = 0; word < 5; word++) begin
            // The program's final LDM places data words 0..4 in r8..r12.
            expected_memory = expected_word(
                final_event, 5'(3 + 8 + word)
            );
            if (u_mem.mem[(DATA_ADDRESS >> 2) + word] !== expected_memory)
                fail($sformatf(
                    "memory[%0d] expected %08x got %08x",
                    word, expected_memory,
                    u_mem.mem[(DATA_ADDRESS >> 2) + word]
                ));
        end
    endtask

    always @(posedge CLK) begin
        #1;
        if (VER_RETIRE_VALID) begin
            if (!measuring
                && VER_RETIRE_PC !== expected_word(0, 0)) begin
                // QEMU's board loader and the RTL's reset-vector branch are
                // intentionally outside the normalized measured region.
            end else begin
            measuring <= 1'b1;
            if (event_count >= EXPECTED_EVENTS)
                fail("ghost retirement after QEMU trace");
            if (VER_RETIRE_PC !== expected_word(
                    EVENT_INDEX_BITS'(event_count), 5'd0))
                fail($sformatf(
                    "PC expected %08x got %08x",
                    expected_word(EVENT_INDEX_BITS'(event_count), 5'd0),
                    VER_RETIRE_PC
                ));
            if (VER_RETIRE_THUMB !== expected_word(
                    EVENT_INDEX_BITS'(event_count), 5'd1)[0])
                fail("ARM/Thumb state tag differs from QEMU");
            if ((VER_RETIRE_CPSR & PSR_COMPARE_MASK)
                !== expected_word(EVENT_INDEX_BITS'(event_count), 5'd2))
                fail($sformatf(
                    "CPSR expected %08x got %08x (masked)",
                    expected_word(EVENT_INDEX_BITS'(event_count), 5'd2),
                    VER_RETIRE_CPSR & PSR_COMPARE_MASK
                ));
            for (int reg_number = 0; reg_number < 15; reg_number++) begin
                if (physical_gpr(reg_number)
                    !== expected_word(
                        EVENT_INDEX_BITS'(event_count),
                        5'(3 + reg_number)
                    ))
                    fail($sformatf(
                        "r%0d expected %08x got %08x",
                        reg_number,
                        expected_word(
                            EVENT_INDEX_BITS'(event_count),
                            5'(3 + reg_number)
                        ),
                        physical_gpr(reg_number)
                    ));
            end
            if (VER_RETIRE_INJECTED || VER_RETIRE_EXCEPTION_VALID)
                fail("ordinary QEMU program reported debug/exception event");

            if ((event_count + 1) == EXPECTED_EVENTS) begin
                check_final_memory(EVENT_INDEX_BITS'(event_count));
                $display("[qemu_diff] PASS (%0d QEMU-compared events)",
                         EXPECTED_EVENTS);
                $finish;
            end
            event_count <= event_count + 1;
            end
        end else if (measuring && VER_RETIRE_EXCEPTION_VALID) begin
            fail("exception without a retiring instruction");
        end
    end

    initial begin
        nRESET = 1'b0;
        event_count = 0;
        measuring = 1'b0;
        if (!$value$plusargs("PROGRAM_HEX=%s", program_hex))
            $fatal(1, "[qemu_diff] missing +PROGRAM_HEX");
        if (!$value$plusargs("EXPECTED_HEX=%s", expected_hex))
            $fatal(1, "[qemu_diff] missing +EXPECTED_HEX");
        for (int word = 0; word < MEMORY_WORDS; word++)
            u_mem.mem[word] = 32'h0000_0000;
        $readmemh(program_hex, u_mem.mem);
        $readmemh(expected_hex, expected);
        repeat (4) @(posedge CLK);
        @(negedge CLK);
        nRESET = 1'b1;
    end

    initial begin
        repeat (2500) @(posedge CLK);
        $fatal(1, "[qemu_diff] TIMEOUT after %0d/%0d events",
               event_count, EXPECTED_EVENTS);
    end

    wire _unused_status = &{1'b0,
        CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI,
        DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG,
        DBGCOMMTX, DBGCOMMRX, DBGTDO, DBGnTDOEN, DMORE,
        VER_RETIRE_OPCODE, VER_RETIRE_CONDITION_PASS,
        VER_RETIRE_EXCEPTION, VER_RETIRE_SPSRS};

endmodule
