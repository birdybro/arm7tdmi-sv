// DBG-001 / TRM §5.19.1 breakpoint-with-Prefetch-Abort priority.
//
// WP0 marks the opcode fetch at 0x80 while the memory returns ABORT for
// that same response. The Prefetch Abort must win and the breakpoint must
// be disregarded: no debug entry occurs, the faulting instruction has no
// effect, and the PABT handler runs in Abort mode.

`timescale 1ns/1ps

module arm7tdmis_debug_breakpoint_pabt_tb
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_types_pkg::*;
    import arm7tdmis_debug_pkg::*;
    import arm7tdmis_jtag_tb_pkg::*;
;
    localparam int CYCLE_LIMIT = 1400;
    localparam logic [31:0] FAULT_ADDR = 32'h0000_0080;

    logic CLK = 1'b0;
    initial forever #5 CLK = ~CLK;

    logic nRESET = 1'b0;
    logic CLKEN = 1'b0;
    logic DBGTCKEN = 1'b0;
    logic DBGTMS = 1'b1;
    logic DBGTDI = 1'b0;
    logic DBGnTRST = 1'b0;

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
        .nIRQ             (1'b1),
        .nFIQ             (1'b1),
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

    logic inject_abort;
    arm7tdmis_memory #(
        .WORDS    (128),
        .INIT_HEX ("../tb/programs/debug_breakpoint_pabt_test.hex")
    ) u_mem (
        .CLK,
        .CLKEN,
        .nRESET,
        .CFGBIGEND        (1'b0),
        .ADDR, .WRITE, .SIZE, .PROT, .LOCK, .TRANS, .WDATA, .RDATA,
        .ABORT,
        .inject_abort
    );

    assign inject_abort = u_mem.is_active_q
                        && !u_mem.write_q
                        && !u_mem.PROT[0]
                        && (u_mem.addr_q == FAULT_ADDR);

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

    int unsigned errors = 0;
    logic breakpoint_seen;
    logic vector_seen;
    logic debug_seen;

    task automatic fail(input string description);
        $display("[debug_breakpoint_pabt] FAIL %s", description);
        errors = errors + 1;
    endtask

    always_ff @(posedge CLK) begin
        if (!nRESET) begin
            breakpoint_seen <= 1'b0;
            vector_seen     <= 1'b0;
            debug_seen      <= 1'b0;
        end else begin
            if (DBGRNG[0])
                breakpoint_seen <= 1'b1;
            if (TRANS[1] && !PROT[0] && (ADDR == 32'h0000_000C))
                vector_seen <= 1'b1;
            if (DBGACK)
                debug_seen <= 1'b1;
        end
    end

    initial begin : run_test
        bit handler_seen;

        $dumpfile("debug_breakpoint_pabt.fst");
        $dumpvars(0, arm7tdmis_debug_breakpoint_pabt_tb);

        repeat (4) @(posedge CLK);
        nRESET = 1'b1;
        repeat (2) @(posedge CLK);
        DBGnTRST = 1'b1;
        tck(1'b0, 1'b0);

        load_ir(4'(IR_SCAN_N));
        shift_dr(4, 38'd2);
        load_ir(4'(IR_INTEST));

        // Exact privileged ARM opcode fetch at 0x80. Ignore data and
        // RANGE/CHAIN/EXTERN while keeping ENABLE unmasked in bit 8.
        write_ice(5'h08, FAULT_ADDR);
        write_ice(5'h09, 32'h0000_0003);
        write_ice(5'h0A, 32'h0000_0000);
        write_ice(5'h0B, 32'hFFFF_FFFF);
        write_ice(5'h0C, 32'h0000_0114);
        write_ice(5'h0D, 32'h0000_00E0);

        CLKEN = 1'b1;
        handler_seen = 1'b0;
        for (int i = 0; i < 260; i++) begin
            @(posedge CLK);
            #1;
            if (u_dut.u_core.u_regfile.regs[7] == 32'h0000_00AB) begin
                handler_seen = 1'b1;
                break;
            end
            if (DBGACK)
                break;
        end

        // Keep observing after handler entry so a delayed or transient
        // debug acknowledge cannot masquerade as correct abort handling.
        repeat (16) @(posedge CLK);
        #1;

        if (!breakpoint_seen)
            fail("breakpoint comparator never matched faulting fetch");
        if (!vector_seen)
            fail("Prefetch Abort vector was not fetched");
        if (!handler_seen)
            fail("Prefetch Abort handler did not execute");
        if (debug_seen)
            fail("breakpoint entered debug despite coincident Prefetch Abort");
        if (u_dut.u_core.cpsr.m !== 5'(MODE_ABORT))
            fail($sformatf("handler mode expected Abort got %05b",
                           u_dut.u_core.cpsr.m));
        if (u_dut.u_core.u_regfile.regs[28] !== 32'h0000_0084)
            fail($sformatf("LR_abt expected 00000084 got %08x",
                           u_dut.u_core.u_regfile.regs[28]));
        if (u_dut.u_core.u_regfile.regs[1] !== 32'h0000_0000)
            fail("faulting breakpointed instruction executed");
        if (u_dut.u_core.u_regfile.regs[2] !== 32'h0000_0000)
            fail("instruction after faulting fetch executed");

        if (errors != 0)
            $fatal(1, "[debug_breakpoint_pabt] FAIL (%0d errors)", errors);
        $display("[debug_breakpoint_pabt] PASS");
        $finish;
    end

    initial begin
        repeat (CYCLE_LIMIT) @(posedge CLK);
        $fatal(1, "[debug_breakpoint_pabt] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, WRITE, SIZE, LOCK, WDATA, CPnMREQ, CPSEQ,
        CPnTRANS, CPnOPC, CPTBIT, CPnI, DBGnEXEC, DBGINSTRVALID,
        DBGRNG[1], DBGCOMMTX, DBGCOMMRX, DBGnTDOEN, DMORE, ignored_scan};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
