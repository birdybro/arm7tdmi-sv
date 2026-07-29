// DBG-001 complete core-facing DBGEN-disable regression.
//
// TRM §5.7 requires DBGEN LOW to make the core ignore DBGRQ and DBGBREAK,
// force DBGACK LOW, and pass interrupts uninhibited. Appendix A also gates
// DBGEXT, DBGRNG, and both DCC status pins. Each scenario first uses public
// JTAG to arm every internal source that could interfere:
//   * forced DBGACK and INTDIS;
//   * monitor mode;
//   * an instruction breakpoint; and
//   * a data watchpoint.
// DBGEN is then lowered before execution while DBGRQ, DBGBREAK, and DBGEXT
// are held active. Both matched instructions must execute and the selected
// IRQ/FIQ must still reach its vector.

`timescale 1ns/1ps

/* verilator lint_off DECLFILENAME */
module arm7tdmis_debug_dbgen_sources_scenario #(
    parameter bit FIQ_SCENARIO = 1'b0
) (
    input  logic CLK,
    output logic done,
    output logic failed
);
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_types_pkg::*;
    import arm7tdmis_debug_pkg::*;
    import arm7tdmis_jtag_tb_pkg::*;

    localparam logic [31:0] BREAKPOINT_PC = 32'h0000_0028;
    localparam logic [31:0] WATCH_ADDR    = 32'h0000_0100;
    localparam logic [31:0] VECTOR =
        FIQ_SCENARIO ? 32'h0000_001C : 32'h0000_0018;
    localparam logic [4:0] EXPECTED_MODE =
        FIQ_SCENARIO ? 5'(MODE_FIQ) : 5'(MODE_IRQ);

    logic nRESET = 1'b0;
    logic CLKEN = 1'b0;
    logic DBGEN = 1'b1;
    logic DBGRQ = 1'b0;
    logic DBGBREAK = 1'b0;
    logic DBGTCKEN = 1'b0;
    logic DBGTMS = 1'b1;
    logic DBGTDI = 1'b0;
    logic DBGnTRST = 1'b0;
    logic nIRQ, nFIQ;

    logic [31:0] ADDR, WDATA, RDATA;
    logic WRITE;
    logic [1:0] SIZE, PROT, TRANS;
    logic LOCK, ABORT;
    logic CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI;
    logic DBGACK, DBGnEXEC, DBGINSTRVALID;
    logic [1:0] DBGRNG;
    logic DBGCOMMTX, DBGCOMMRX, DBGTDO, DBGnTDOEN, DMORE;

    arm7tdmis_top u_dut (
        .CLK,
        .CLKEN,
        .nRESET,
        .CFGBIGEND        (1'b0),
        .nIRQ,
        .nFIQ,
        .ABORT,
        .ADDR, .WRITE, .SIZE, .PROT, .LOCK, .TRANS, .WDATA, .RDATA,
        .CPnMREQ, .CPSEQ, .CPnTRANS, .CPnOPC, .CPTBIT, .CPnI,
        .CPA              (1'b1),
        .CPB              (1'b1),
        .DBGEN,
        .DBGRQ,
        .DBGBREAK,
        .DBGACK,
        .DBGnEXEC,
        .DBGINSTRVALID,
        .DBGEXT           (2'b11),
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
        .WORDS    (128),
        .INIT_HEX ("../tb/programs/debug_dbgen_sources_test.hex")
    ) u_mem (
        .CLK,
        .CLKEN,
        .nRESET,
        .CFGBIGEND        (1'b0),
        .ADDR, .WRITE, .SIZE, .PROT, .LOCK, .TRANS, .WDATA, .RDATA,
        .ABORT,
        .inject_abort     (1'b0)
    );

    wire program_ready =
        u_dut.u_core.u_regfile.regs[2] == 32'h0000_0002;
    assign nIRQ = (!FIQ_SCENARIO && program_ready) ? 1'b0 : 1'b1;
    assign nFIQ = ( FIQ_SCENARIO && program_ready) ? 1'b0 : 1'b1;

    logic [37:0] ignored_scan;

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
        input int unsigned width,
        input logic [37:0] scan_in
    );
        tck(1'b1, 1'b0);
        tck(1'b0, 1'b0);
        tck(1'b0, 1'b0);
        for (int i = 0; i < width; i++) begin
            ignored_scan[i] = DBGTDO;
            tck(i == (width - 1), scan_in[i]);
        end
        tck(1'b1, 1'b0);
        tck(1'b0, 1'b0);
    endtask

    task automatic write_ice(
        input logic [4:0] address,
        input logic [31:0] data
    );
        shift_dr(38, chain2_serial_in(1'b1, address, data));
    endtask

    logic disabled_phase;
    logic target_fetch_seen;
    logic watched_data_seen;
    logic vector_seen;
    logic output_violation;
    always_ff @(posedge CLK) begin
        if (!nRESET) begin
            target_fetch_seen <= 1'b0;
            watched_data_seen <= 1'b0;
            vector_seen       <= 1'b0;
            output_violation  <= 1'b0;
        end else if (disabled_phase) begin
            if (TRANS[1] && !PROT[0] && (ADDR == BREAKPOINT_PC))
                target_fetch_seen <= 1'b1;
            if (TRANS[1] && PROT[0] && (ADDR == WATCH_ADDR))
                watched_data_seen <= 1'b1;
            if (TRANS[1] && !PROT[0] && (ADDR == VECTOR))
                vector_seen <= 1'b1;
            if (DBGACK || (DBGRNG != 2'b00)
                || DBGCOMMTX || DBGCOMMRX)
                output_violation <= 1'b1;
        end
    end

    task automatic fail(input string description);
        $display("[debug_dbgen_sources/%s] FAIL %s",
                 FIQ_SCENARIO ? "FIQ" : "IRQ", description);
        failed = 1'b1;
    endtask

    initial begin : run
        bit handler_executed;

        done             = 1'b0;
        failed           = 1'b0;
        disabled_phase   = 1'b0;

        @(posedge CLK);
        u_mem.mem[64] = 32'hCAFE_BABE;

        repeat (3) @(posedge CLK);
        nRESET = 1'b1;
        repeat (2) @(posedge CLK);
        DBGnTRST = 1'b1;
        tck(1'b0, 1'b0);

        load_ir(4'(IR_SCAN_N));
        shift_dr(4, 38'd2);
        load_ir(4'(IR_INTEST));

        // Disable the comparators while programming, as required by §5.7.
        write_ice(5'h00, 32'h0000_0020);

        // WP0: exact privileged ARM opcode fetch at 0x28.
        write_ice(5'h08, BREAKPOINT_PC);
        write_ice(5'h09, 32'h0000_0003);
        write_ice(5'h0A, 32'h0000_0000);
        write_ice(5'h0B, 32'hFFFF_FFFF);
        write_ice(5'h0C, 32'h0000_0114);
        write_ice(5'h0D, 32'h0000_00E0);

        // WP1: exact privileged word read from 0x100.
        write_ice(5'h10, WATCH_ADDR);
        write_ice(5'h11, 32'h0000_0000);
        write_ice(5'h12, 32'h0000_0000);
        write_ice(5'h13, 32'hFFFF_FFFF);
        write_ice(5'h14, 32'h0000_0118);
        write_ice(5'h15, 32'h0000_00E0);

        // Force DBGACK, disable interrupts, select monitor mode, and
        // re-enable comparators. DBGEN must override all four settings.
        write_ice(5'h00, 32'h0000_0015);

        @(negedge CLK);
        DBGEN         = 1'b0;
        DBGRQ         = 1'b1;
        DBGBREAK      = 1'b1;
        disabled_phase = 1'b1;
        CLKEN         = 1'b1;

        handler_executed = 1'b0;
        for (int i = 0; i < 320; i++) begin
            @(posedge CLK);
            #1;
            if ((!FIQ_SCENARIO
                 && (u_dut.u_core.u_regfile.regs[6] == 32'h0000_0066))
                || (FIQ_SCENARIO
                    && (u_dut.u_core.u_regfile.regs[7]
                        == 32'h0000_0077))) begin
                handler_executed = 1'b1;
                break;
            end
        end

        if (!handler_executed)
            fail("interrupt did not pass through disabled debug logic");
        if (!target_fetch_seen)
            fail("armed instruction breakpoint address was not fetched");
        if (!watched_data_seen)
            fail("armed data-watchpoint address was not accessed");
        if (!vector_seen)
            fail("selected interrupt vector was not fetched");
        if (output_violation)
            fail("a DBGEN-qualified output asserted while disabled");
        if (DBGACK || (DBGRNG != 2'b00)
            || DBGCOMMTX || DBGCOMMRX)
            fail("debug outputs were not LOW at completion");
        if (u_dut.u_core.u_regfile.regs[1] !== 32'h0000_0001)
            fail("breakpointed instruction did not execute");
        if (u_dut.u_core.u_regfile.regs[3] !== 32'hCAFE_BABE)
            fail("watchpointed load did not complete");
        if (u_dut.u_core.u_regfile.regs[2] !== 32'h0000_0002)
            fail("instruction after watched load did not execute");
        if (u_dut.u_core.cpsr.m !== EXPECTED_MODE)
            fail($sformatf("interrupt mode expected %05b got %05b",
                           EXPECTED_MODE, u_dut.u_core.cpsr.m));

        done = 1'b1;
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, WRITE, SIZE, LOCK, WDATA, CPnMREQ, CPSEQ,
        CPnTRANS, CPnOPC, CPTBIT, CPnI, DBGnEXEC, DBGINSTRVALID,
        DBGTDO, DBGnTDOEN, DMORE, ignored_scan};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
/* verilator lint_on DECLFILENAME */

module arm7tdmis_debug_dbgen_sources_tb;
    localparam int CYCLE_LIMIT = 2200;

    logic CLK = 1'b0;
    initial forever #5 CLK = ~CLK;

    logic [1:0] done;
    logic [1:0] failed;

    arm7tdmis_debug_dbgen_sources_scenario #(
        .FIQ_SCENARIO(1'b0)
    ) u_irq (
        .CLK, .done(done[0]), .failed(failed[0])
    );
    arm7tdmis_debug_dbgen_sources_scenario #(
        .FIQ_SCENARIO(1'b1)
    ) u_fiq (
        .CLK, .done(done[1]), .failed(failed[1])
    );

    initial begin
        $dumpfile("debug_dbgen_sources.fst");
        $dumpvars(0, arm7tdmis_debug_dbgen_sources_tb);
        wait (&done);
        if (|failed)
            $fatal(1, "[debug_dbgen_sources] FAIL scenarios=%02b",
                   failed);
        $display("[debug_dbgen_sources] PASS");
        $finish;
    end

    initial begin
        repeat (CYCLE_LIMIT) @(posedge CLK);
        $fatal(1,
               "[debug_dbgen_sources] TIMEOUT done=%02b failed=%02b",
               done, failed);
    end
endmodule
