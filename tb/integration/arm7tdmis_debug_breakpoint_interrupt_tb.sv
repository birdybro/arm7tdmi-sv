// DBG-001 / TRM §5.19.2 breakpoint-with-interrupt regression.
//
// A one-cycle IRQ or FIQ coincident with a breakpoint reaching Execute
// must be remembered. Debug has priority over running the breakpointed
// instruction, but the core first enters the interrupt mode and fetches
// its vector. DBGACK then freezes the vector instruction before Execute.

`timescale 1ns/1ps

/* verilator lint_off DECLFILENAME */
module arm7tdmis_debug_breakpoint_interrupt_scenario #(
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
    localparam logic [31:0] VECTOR =
        FIQ_SCENARIO ? 32'h0000_001C : 32'h0000_0018;
    localparam logic [4:0] MODE =
        FIQ_SCENARIO ? 5'(MODE_FIQ) : 5'(MODE_IRQ);

    logic nRESET = 1'b0;
    logic CLKEN = 1'b0;
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
        .DBGEN            (1'b1),
        .DBGRQ            (1'b0),
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
        .WORDS    (128),
        .INIT_HEX ("../tb/programs/debug_breakpoint_interrupt_test.hex")
    ) u_mem (
        .CLK,
        .CLKEN,
        .nRESET,
        .CFGBIGEND        (1'b0),
        .ADDR, .WRITE, .SIZE, .PROT, .LOCK, .TRANS, .WDATA, .RDATA,
        .ABORT,
        .inject_abort     (1'b0)
    );

    wire breakpoint_execute = u_dut.ice_breakpoint_execute;
    assign nIRQ = (FIQ_SCENARIO || !breakpoint_execute) ? 1'b1 : 1'b0;
    assign nFIQ = (!FIQ_SCENARIO || !breakpoint_execute) ? 1'b1 : 1'b0;

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

    logic range_seen;
    logic request_seen;
    logic vector_seen;
    always_ff @(posedge CLK) begin
        if (!nRESET) begin
            range_seen   <= 1'b0;
            request_seen <= 1'b0;
            vector_seen  <= 1'b0;
        end else begin
            if (DBGRNG[0])
                range_seen <= 1'b1;
            if (!nIRQ || !nFIQ)
                request_seen <= 1'b1;
            if (TRANS[1] && !PROT[0] && (ADDR == VECTOR))
                vector_seen <= 1'b1;
        end
    end

    task automatic fail(input string description);
        $display("[debug_breakpoint_interrupt/%s] FAIL %s",
                 FIQ_SCENARIO ? "FIQ" : "IRQ", description);
        failed = 1'b1;
    endtask

    initial begin : run
        bit halted;
        logic [4:0] lr_index;
        logic [2:0] spsr_index;

        done   = 1'b0;
        failed = 1'b0;

        repeat (4) @(posedge CLK);
        nRESET = 1'b1;
        repeat (2) @(posedge CLK);
        DBGnTRST = 1'b1;
        tck(1'b0, 1'b0);

        load_ir(4'(IR_SCAN_N));
        shift_dr(4, 38'd2);
        load_ir(4'(IR_INTEST));

        // Exact privileged ARM opcode fetch at 0x28.
        write_ice(5'h08, BREAKPOINT_PC);
        write_ice(5'h09, 32'h0000_0003);
        write_ice(5'h0A, 32'h0000_0000);
        write_ice(5'h0B, 32'hFFFF_FFFF);
        write_ice(5'h0C, 32'h0000_0114);
        write_ice(5'h0D, 32'h0000_00E0);

        CLKEN = 1'b1;
        halted = 1'b0;
        for (int i = 0; i < 280; i++) begin
            @(posedge CLK);
            #1;
            if (DBGACK) begin
                halted = 1'b1;
                break;
            end
        end

        if (!halted)
            fail("breakpoint never entered debug state");
        if (!range_seen)
            fail("breakpoint comparator never matched");
        if (!request_seen)
            fail("coincident interrupt pulse was never generated");
        if (!vector_seen)
            fail("interrupt vector was not fetched before DBGACK");
        if (u_dut.u_core.cpsr.m !== MODE)
            fail($sformatf("mode expected %05b got %05b",
                           MODE, u_dut.u_core.cpsr.m));
        if (TRANS !== 2'(TRANS_I))
            fail($sformatf("halted TRANS expected I got %02b", TRANS));
        if (u_dut.u_core.u_regfile.regs[0] !== 32'h0000_0000)
            fail("breakpointed ADD executed");
        if (u_dut.u_core.u_regfile.regs[7] !== 32'h0000_0000)
            fail("first interrupt-vector instruction executed");
        if (u_dut.u_core.u_regfile.regs[9] !== 32'h0000_0000)
            fail("instruction after breakpoint executed");

        lr_index   = FIQ_SCENARIO ? 5'd22 : 5'd24;
        spsr_index = FIQ_SCENARIO ? 3'd0 : 3'd1;
        if (u_dut.u_core.u_regfile.regs[lr_index] !== 32'h0000_002C)
            fail($sformatf("interrupt LR expected 0000002c got %08x",
                           u_dut.u_core.u_regfile.regs[lr_index]));
        if (u_dut.u_core.u_psr.spsr_q[spsr_index] !== 32'h0000_0013)
            fail($sformatf("interrupt SPSR expected 00000013 got %08x",
                           u_dut.u_core.u_psr.spsr_q[spsr_index]));

        done = 1'b1;
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, WRITE, SIZE, LOCK, WDATA, CPnMREQ, CPSEQ,
        CPnTRANS, CPnOPC, CPTBIT, CPnI, DBGnEXEC, DBGINSTRVALID,
        DBGRNG[1], DBGCOMMTX, DBGCOMMRX, DBGnTDOEN, DMORE, ignored_scan};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
/* verilator lint_on DECLFILENAME */

module arm7tdmis_debug_breakpoint_interrupt_tb;
    localparam int CYCLE_LIMIT = 1500;

    logic CLK = 1'b0;
    initial forever #5 CLK = ~CLK;

    logic [1:0] done;
    logic [1:0] failed;

    arm7tdmis_debug_breakpoint_interrupt_scenario #(
        .FIQ_SCENARIO(1'b0)
    ) u_irq (
        .CLK, .done(done[0]), .failed(failed[0])
    );
    arm7tdmis_debug_breakpoint_interrupt_scenario #(
        .FIQ_SCENARIO(1'b1)
    ) u_fiq (
        .CLK, .done(done[1]), .failed(failed[1])
    );

    initial begin
        $dumpfile("debug_breakpoint_interrupt.fst");
        $dumpvars(0, arm7tdmis_debug_breakpoint_interrupt_tb);
        wait (&done);
        if (|failed)
            $fatal(1, "[debug_breakpoint_interrupt] FAIL scenarios=%02b",
                   failed);
        $display("[debug_breakpoint_interrupt] PASS");
        $finish;
    end

    initial begin
        repeat (CYCLE_LIMIT) @(posedge CLK);
        $fatal(1,
               "[debug_breakpoint_interrupt] TIMEOUT done=%02b failed=%02b",
               done, failed);
    end
endmodule
