// EXC-008 debug-flush regression.
//
// A one-cycle DBGRQ is sampled on the same edge that an ABORT response tags
// the younger fetch at 0x28. The halted pipeline must visibly retain that
// instruction-associated PABT metadata. A real scan-chain-1 write of r15
// then redirects resume to 0x80 and must discard every old pipeline tag.
// RESTART must execute the new target without entering the PABT handler.

`timescale 1ns/1ps

module arm7tdmis_pabt_debug_flush_tb
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_debug_pkg::*;
    import arm7tdmis_jtag_tb_pkg::*;
    import arm7tdmis_types_pkg::*;
;

    localparam int CYCLE_LIMIT = 5000;
    localparam logic [31:0] DEBUG_LDM_PC = 32'hE890_8000;
    localparam logic [31:0] DEBUG_NOP = 32'hE1A0_8008;
    localparam logic [31:0] DEBUG_RETURN_BRANCH = 32'hEAFF_FFFA;
    localparam logic [31:0] RESUME_PC = 32'h0000_0080;

    logic CLK = 1'b0;
    initial forever #5 CLK = ~CLK;

    logic nRESET = 1'b0;
    logic CLKEN = 1'b0;
    logic DBGnTRST = 1'b0;
    logic DBGTCKEN = 1'b0;
    logic DBGTMS = 1'b1;
    logic DBGTDI = 1'b0;
    logic DBGRQ;
    logic inject_abort;
    logic ABORT;
    logic [31:0] ADDR;
    logic [31:0] WDATA;
    logic [31:0] RDATA;
    logic WRITE;
    logic [1:0] SIZE;
    logic [1:0] PROT;
    logic [1:0] TRANS;
    logic LOCK;
    logic CPnMREQ;
    logic CPSEQ;
    logic CPnTRANS;
    logic CPnOPC;
    logic CPTBIT;
    logic CPnI;
    logic DBGACK;
    logic DBGnEXEC;
    logic DBGINSTRVALID;
    logic [1:0] DBGRNG;
    logic DBGCOMMTX;
    logic DBGCOMMRX;
    logic DBGTDO;
    logic DBGnTDOEN;
    logic DMORE;

    arm7tdmis_top u_dut (
        .CLK,
        .CLKEN,
        .nRESET,
        .CFGBIGEND        (1'b0),
        .nIRQ             (1'b1),
        .nFIQ             (1'b1),
        .ABORT,
        .ADDR,
        .WRITE,
        .SIZE,
        .PROT,
        .LOCK,
        .TRANS,
        .WDATA,
        .RDATA,
        .CPnMREQ,
        .CPSEQ,
        .CPnTRANS,
        .CPnOPC,
        .CPTBIT,
        .CPnI,
        .CPA              (1'b1),
        .CPB              (1'b1),
        .DBGEN            (1'b1),
        .DBGRQ,
        .DBGBREAK         (1'b0),
        .DBGACK,
        .DBGnEXEC,
        .DBGINSTRVALID,
        .DBGEXT           (2'b00),
        .DBGRNG,
        .DBGCOMMTX,
        .DBGCOMMRX,
        .DBGTCKEN,
        .DBGTMS,
        .DBGTDI,
        .DBGTDO,
        .DBGnTRST,
        .DBGnTDOEN,
        .DMORE
    );

    arm7tdmis_memory #(
        .WORDS    (256),
        .INIT_HEX ("../tb/programs/pabt_debug_flush_test.hex")
    ) u_mem (
        .CLK,
        .CLKEN,
        .nRESET,
        .CFGBIGEND        (1'b0),
        .ADDR,
        .WRITE,
        .SIZE,
        .PROT,
        .LOCK,
        .TRANS,
        .WDATA,
        .RDATA,
        .ABORT,
        .inject_abort
    );

    logic request_armed;
    wire aborted_response = u_mem.is_active_q
                          && !u_mem.write_q
                          && (u_mem.addr_q == 32'h0000_0028);
    assign DBGRQ        = request_armed && aborted_response;
    assign inject_abort = request_armed && aborted_response;

    int unsigned pabt_entries;
    logic seen_collision;
    always_ff @(posedge CLK) begin
        if (!nRESET) begin
            request_armed <= 1'b1;
            pabt_entries  <= 0;
            seen_collision <= 1'b0;
        end else begin
            if (DBGRQ && ABORT) begin
                request_armed <= 1'b0;
                seen_collision <= 1'b1;
            end
            if (u_dut.u_core.pabt_fires)
                pabt_entries <= pabt_entries + 1;
        end
    end

    int unsigned errors = 0;

    task automatic fail(input string description);
        $display("[pabt_debug_flush] FAIL: %s", description);
        errors = errors + 1;
    endtask

    task automatic tck(input logic tms, input logic tdi);
        @(negedge CLK);
        DBGTMS   = tms;
        DBGTDI   = tdi;
        DBGTCKEN = 1'b1;
        @(posedge CLK);
        #1;
        DBGTCKEN = 1'b0;
    endtask

    task automatic load_ir(input logic [3:0] instruction);
        tck(1'b1, 1'b0);
        tck(1'b1, 1'b0);
        tck(1'b0, 1'b0);
        tck(1'b0, 1'b0);
        for (int i = 0; i < 4; i++)
            tck(i == 3, instruction[i]);
        tck(1'b1, 1'b0);
        tck(1'b0, 1'b0);
    endtask

    task automatic shift_dr(
        input logic [37:0] serial_in,
        output logic [37:0] serial_out
    );
        serial_out = '0;
        tck(1'b1, 1'b0);
        tck(1'b0, 1'b0);
        tck(1'b0, 1'b0);
        for (int i = 0; i < SCAN_CHAIN1_WIDTH; i++) begin
            serial_out[i] = DBGTDO;
            tck(i == (SCAN_CHAIN1_WIDTH - 1), serial_in[i]);
        end
        tck(1'b1, 1'b0);
        tck(1'b0, 1'b0);
    endtask

    task automatic select_chain1;
        load_ir(4'(IR_SCAN_N));
        tck(1'b1, 1'b0);
        tck(1'b0, 1'b0);
        tck(1'b0, 1'b0);
        for (int i = 0; i < 4; i++)
            tck(i == 3, i == 0);
        tck(1'b1, 1'b0);
        tck(1'b0, 1'b0);
        load_ir(4'(IR_INTEST));
    endtask

    task automatic clock_out(
        input logic [31:0] data,
        input logic        break_bit
    );
        logic [37:0] ignored;
        shift_dr(chain1_serial_in(data, break_bit), ignored);
        if (&{1'b0, ignored})
            fail("unreachable clock-out sentinel");
    endtask

    initial begin : run_test
        bit halted;
        bit target_executed;
        bit metadata_present;

        $dumpfile("pabt_debug_flush.fst");
        $dumpvars(0, arm7tdmis_pabt_debug_flush_tb);

        repeat (4) @(posedge CLK);
        nRESET = 1'b1;
        repeat (2) @(posedge CLK);
        DBGnTRST = 1'b1;
        CLKEN = 1'b1;

        halted = 1'b0;
        for (int i = 0; i < 160; i++) begin
            @(posedge CLK);
            #1;
            if (DBGACK) begin
                halted = 1'b1;
                break;
            end
        end
        if (!halted)
            fail("coincident DBGRQ did not halt the core");
        if (!seen_collision)
            fail("ABORT and DBGRQ were not sampled together");
        if (pabt_entries != 0)
            fail("younger Prefetch Abort fired before debug redirect");

        metadata_present =
            (u_dut.u_core.fd_q.valid
             && (u_dut.u_core.fd_q.pc == 32'h0000_0028)
             && u_dut.u_core.fd_q.pabort)
            || (u_dut.u_core.de_q.valid
                && (u_dut.u_core.de_q.pc == 32'h0000_0028)
                && u_dut.u_core.de_q.pabort)
            || (u_dut.u_core.halt_response_valid_q
                && u_dut.u_core.halt_response_abort_q);
        if (!metadata_present)
            fail("halted pipeline did not retain the aborted fetch tag");

        tck(1'b0, 1'b0);
        select_chain1();

        // Load a replacement PC using the architectural debug-speed path.
        clock_out(DEBUG_LDM_PC, 1'b0);
        clock_out(DEBUG_NOP, 1'b0);
        clock_out(DEBUG_NOP, 1'b0);
        clock_out(RESUME_PC, 1'b0);
        repeat (4)
            clock_out(DEBUG_NOP, 1'b0);

        if (u_dut.u_core.fd_q.pabort
            || u_dut.u_core.de_q.pabort
            || u_dut.u_core.halt_response_abort_q)
            fail("scan-loaded PC did not clear old PABT metadata");

        clock_out(DEBUG_NOP, 1'b1);
        clock_out(DEBUG_RETURN_BRANCH, 1'b0);
        load_ir(4'(IR_RESTART));

        target_executed = 1'b0;
        for (int i = 0; i < 180; i++) begin
            @(posedge CLK);
            #1;
            if (u_dut.u_core.u_regfile.regs[6] == 32'h0000_0066) begin
                target_executed = 1'b1;
                break;
            end
        end
        if (!target_executed)
            fail("redirected debug-resume target did not execute");
        if (pabt_entries != 0
            || u_dut.u_core.u_regfile.regs[9] !== 32'h0000_0000
            || u_dut.u_core.u_regfile.regs[28] !== 32'h0000_0000
            || u_dut.u_core.u_psr.spsr_q[3] !== 32'h0000_0000)
            fail($sformatf(
                "flushed PABT leaked entry=%0d marker=%08x lr=%08x spsr=%08x",
                pabt_entries,
                u_dut.u_core.u_regfile.regs[9],
                u_dut.u_core.u_regfile.regs[28],
                u_dut.u_core.u_psr.spsr_q[3]));
        if (u_dut.u_core.u_regfile.regs[2] !== 32'h0000_0000)
            fail("flushed instruction at 0x28 executed");
        if (u_dut.u_core.cpsr.m !== 5'(MODE_SUPERVISOR))
            fail("debug resume changed processor mode");

        if (errors != 0)
            $fatal(1, "[pabt_debug_flush] FAIL (%0d errors)", errors);
        $display("[pabt_debug_flush] PASS");
        $finish;
    end

    initial begin
        repeat (CYCLE_LIMIT) @(posedge CLK);
        $fatal(1, "[pabt_debug_flush] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, ADDR, WDATA, WRITE, SIZE, PROT, LOCK, TRANS,
        CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI,
        DBGnEXEC, DBGINSTRVALID, DBGRNG, DBGCOMMTX, DBGCOMMRX,
        DBGnTDOEN, DMORE};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
