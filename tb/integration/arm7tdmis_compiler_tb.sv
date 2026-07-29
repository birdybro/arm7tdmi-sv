// VAL-009 pinned-compiler execution regression.
//
// A release-pinned arm-none-eabi GCC builds the loaded image from independent
// ARM and Thumb translation units.  The program exercises compiler-generated
// calls in both directions, word/halfword/byte memory operations, a loop, and
// stack use.  Completion is accepted only after the architectural retirement
// interface has observed both instruction states and both interworking
// directions.

`timescale 1ns/1ps

`ifndef ARM7TDMIS_VERIFICATION
    `error "compiler requires ARM7TDMIS_VERIFICATION"
`endif

module arm7tdmis_compiler_tb
    import arm7tdmis_bus_pkg::*;
;

    localparam int MEMORY_WORDS = 16384;
    localparam int MAILBOX_WORD = 32'h0000_8000 >> 2;
    localparam logic [31:0] MAILBOX_DONE = 32'hd06e_0009;

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

    string program_hex;
    int unsigned retirement_count;
    logic saw_arm;
    logic saw_thumb;
    logic saw_arm_to_thumb;
    logic saw_thumb_to_arm;
    logic have_previous_state;
    logic previous_thumb;

    task automatic fail(input string reason);
        $fatal(1, "[compiler] FAIL after %0d retirements: %s",
               retirement_count, reason);
    endtask

    task automatic check_mailbox;
        if (!saw_arm || !saw_thumb)
            fail("program did not retire both ARM and Thumb instructions");
        if (!saw_arm_to_thumb || !saw_thumb_to_arm)
            fail("program did not retire both interworking directions");
        if (u_mem.mem[MAILBOX_WORD + 0] !== 32'h434f_4d50)
            fail("signature mismatch");
        if (u_mem.mem[MAILBOX_WORD + 1] !== 32'h0000_005d)
            fail("Thumb loop/Thumb-to-ARM result mismatch");
        if (u_mem.mem[MAILBOX_WORD + 2] !== 32'h0000_0057)
            fail("ARM arithmetic result mismatch");
        if (u_mem.mem[MAILBOX_WORD + 3] !== 32'h00f8_12cc)
            fail("mixed-width memory checksum mismatch");
        if (u_mem.mem[MAILBOX_WORD + 4] !== 32'h0000_005d)
            fail("Thumb word store mismatch");
        if (u_mem.mem[MAILBOX_WORD + 5] !== 32'h00f8_1291)
            fail("Thumb halfword/byte stores mismatch");
    endtask

    always @(posedge CLK) begin
        #1;
        if (VER_RETIRE_VALID) begin
            retirement_count <= retirement_count + 1;
            if (VER_RETIRE_INJECTED || VER_RETIRE_EXCEPTION_VALID)
                fail("ordinary compiler program reported debug/exception event");

            if (VER_RETIRE_THUMB)
                saw_thumb <= 1'b1;
            else
                saw_arm <= 1'b1;
            if (have_previous_state && !previous_thumb && VER_RETIRE_THUMB)
                saw_arm_to_thumb <= 1'b1;
            if (have_previous_state && previous_thumb && !VER_RETIRE_THUMB)
                saw_thumb_to_arm <= 1'b1;
            previous_thumb <= VER_RETIRE_THUMB;
            have_previous_state <= 1'b1;
        end else if (VER_RETIRE_EXCEPTION_VALID) begin
            fail("exception lacked a retiring instruction");
        end

        if (nRESET
            && u_mem.mem[MAILBOX_WORD + 7] === MAILBOX_DONE) begin
            check_mailbox();
            $display(
                "[compiler] PASS (%0d retirements, ARM/Thumb bidirectional)",
                retirement_count
            );
            $finish;
        end
    end

    initial begin
        nRESET = 1'b0;
        retirement_count = 0;
        saw_arm = 1'b0;
        saw_thumb = 1'b0;
        saw_arm_to_thumb = 1'b0;
        saw_thumb_to_arm = 1'b0;
        have_previous_state = 1'b0;
        previous_thumb = 1'b0;
        if (!$value$plusargs("PROGRAM_HEX=%s", program_hex))
            $fatal(1, "[compiler] missing +PROGRAM_HEX");
        for (int word = 0; word < MEMORY_WORDS; word++)
            u_mem.mem[word] = 32'h0000_0000;
        $readmemh(program_hex, u_mem.mem);
        repeat (4) @(posedge CLK);
        @(negedge CLK);
        nRESET = 1'b1;
    end

    initial begin
        repeat (5000) @(posedge CLK);
        $fatal(1, "[compiler] TIMEOUT after %0d retirements",
               retirement_count);
    end

    wire _unused_status = &{1'b0,
        CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI,
        DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG,
        DBGCOMMTX, DBGCOMMRX, DBGTDO, DBGnTDOEN, DMORE,
        VER_RETIRE_PC, VER_RETIRE_OPCODE, VER_RETIRE_EXCEPTION,
        VER_RETIRE_CONDITION_PASS, VER_RETIRE_GPRS, VER_RETIRE_CPSR,
        VER_RETIRE_SPSRS};

endmodule
