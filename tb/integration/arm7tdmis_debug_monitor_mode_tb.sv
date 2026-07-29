// CP-009/DBG-001/DBG-005/JTAG-005 monitor-mode integration regression.
//
// Three independent cores are configured only through the public TAP and
// scan chain 2:
//   0. an instruction breakpoint must cause a Prefetch Abort;
//   1. a data watchpoint must cause a Data Abort;
//   2. a data watchpoint coincident with external ABORT must take the real
//      Data Abort and leave CP14 DbgAbt clear.
//
// Monitor mode never enters debug state. External DBGBREAK is unsupported
// and must be ignored, while comparator RANGE outputs remain observable.
// Each abort handler reads CP14 c2 so the DbgAbt checks use an architectural
// observation rather than a hierarchical status-register oracle.

`timescale 1ns/1ps

/* verilator lint_off DECLFILENAME */
module arm7tdmis_debug_monitor_mode_scenario #(
    parameter int unsigned SCENARIO = 0
) (
    input  logic CLK,
    output logic done,
    output logic failed
);
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_debug_pkg::*;
    import arm7tdmis_jtag_tb_pkg::*;

    localparam int unsigned BREAKPOINT_SCENARIO = 0;
    localparam int unsigned WATCHPOINT_SCENARIO = 1;
    localparam int unsigned EXTERNAL_ABORT_SCENARIO = 2;

    logic nRESET = 1'b0;
    logic CLKEN = 1'b0;
    logic ABORT;
    logic DBGBREAK = 1'b0;
    logic DBGTCKEN = 1'b0;
    logic DBGTMS = 1'b1;
    logic DBGTDI = 1'b0;
    logic DBGnTRST = 1'b0;

    logic [31:0] ADDR, WDATA, RDATA;
    logic WRITE;
    logic [1:0] SIZE, PROT, TRANS;
    logic LOCK;
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
        .DBGBREAK,
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

    logic inject_external_abort;
    arm7tdmis_memory #(
        .WORDS    (128),
        .INIT_HEX ("../tb/programs/debug_monitor_mode_test.hex")
    ) u_mem (
        .CLK,
        .CLKEN,
        .nRESET,
        .CFGBIGEND        (1'b0),
        .ADDR, .WRITE, .SIZE, .PROT, .LOCK, .TRANS, .WDATA, .RDATA,
        .ABORT,
        .inject_abort     (inject_external_abort)
    );

    assign inject_external_abort =
        (SCENARIO == EXTERNAL_ABORT_SCENARIO)
        && u_mem.is_active_q
        && u_mem.addr_q == 32'h0000_0100;

    logic [37:0] scan_ignored;

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
        input  int unsigned width,
        input  logic [37:0] scan_in,
        output logic [37:0] scan_out
    );
        scan_out = '0;
        tck(1'b1, 1'b0);
        tck(1'b0, 1'b0);
        tck(1'b0, 1'b0);
        for (int i = 0; i < width; i++) begin
            scan_out[i] = DBGTDO;
            tck(i == (width - 1), scan_in[i]);
        end
        tck(1'b1, 1'b0);
        tck(1'b0, 1'b0);
    endtask

    task automatic select_chain2;
        load_ir(4'(IR_SCAN_N));
        shift_dr(4, 38'd2, scan_ignored);
        load_ir(4'(IR_INTEST));
    endtask

    task automatic chain2_access(
        input  logic        write,
        input  logic [4:0]  addr,
        input  logic [31:0] data,
        output logic [37:0] response
    );
        logic [37:0] serial_response;
        shift_dr(38, chain2_serial_in(write, addr, data),
                 serial_response);
        response = chain2_parallel_out(serial_response);
    endtask

    task automatic write_ice(
        input logic [4:0] addr,
        input logic [31:0] data
    );
        chain2_access(1'b1, addr, data, scan_ignored);
    endtask

    task automatic read_ice(
        input  logic [4:0] addr,
        output logic [31:0] data
    );
        logic [37:0] response;
        chain2_access(1'b0, addr, 32'h0, scan_ignored);
        chain2_access(1'b0, addr, 32'h0, response);
        if (response[37:32] !== {1'b0, addr}) begin
            $display("[debug_monitor/%0d] FAIL read header expected %02x got %02x",
                     SCENARIO, {1'b0, addr}, response[37:32]);
            failed = 1'b1;
        end
        data = response[31:0];
    endtask

    task automatic program_wp0;
        logic [31:0] watched_address;
        logic [31:0] control_value;
        watched_address = (SCENARIO == BREAKPOINT_SCENARIO)
                        ? 32'h0000_0028 : 32'h0000_0100;
        control_value = (SCENARIO == BREAKPOINT_SCENARIO)
                      ? 32'h0000_0114 : 32'h0000_011C;
        write_ice(5'h08, watched_address);
        write_ice(5'h09, (SCENARIO == BREAKPOINT_SCENARIO)
                         ? 32'h0000_0003 : 32'h0000_0000);
        write_ice(5'h0A, 32'h0000_0000);
        write_ice(5'h0B, 32'hFFFF_FFFF);
        write_ice(5'h0C, control_value);
        write_ice(5'h0D, 32'h0000_00E0);
    endtask

    logic range_seen;
    logic dbgack_seen;
    always_ff @(posedge CLK) begin
        if (!nRESET) begin
            range_seen  <= 1'b0;
            dbgack_seen <= 1'b0;
        end else begin
            if (DBGRNG[0])
                range_seen <= 1'b1;
            if (DBGACK)
                dbgack_seen <= 1'b1;
        end
    end

    initial begin : run
        logic [31:0] control_readback;
        logic [31:0] expected_loaded_value;
        logic [31:0] expected_dbgabt;
        bit handler_seen;

        done   = 1'b0;
        failed = 1'b0;

        repeat (4) @(posedge CLK);
        nRESET = 1'b1;
        repeat (2) @(posedge CLK);
        DBGnTRST = 1'b1;
        tck(1'b0, 1'b0);
        select_chain2();

        // Follow the mandatory monitor reprogramming sequence. Reserved
        // control bit 3 is deliberately written HIGH and must read as zero.
        write_ice(5'h00, 32'h0000_0020);
        read_ice(5'h00, control_readback);
        if (control_readback !== 32'h0000_0020) begin
            $display("[debug_monitor/%0d] FAIL disable poll read %08x",
                     SCENARIO, control_readback);
            failed = 1'b1;
        end

        write_ice(5'h00, 32'h0000_0038);
        read_ice(5'h00, control_readback);
        if (control_readback !== 32'h0000_0030) begin
            $display("[debug_monitor/%0d] FAIL monitor control RAZ read %08x",
                     SCENARIO, control_readback);
            failed = 1'b1;
        end

        program_wp0();
        write_ice(5'h00, 32'h0000_0010);
        read_ice(5'h00, control_readback);
        if (control_readback !== 32'h0000_0010) begin
            $display("[debug_monitor/%0d] FAIL re-enable read %08x",
                     SCENARIO, control_readback);
            failed = 1'b1;
        end

        // The program's sole data word is deliberately nonzero so the
        // generated DABT must suppress an otherwise visible LDR writeback.
        u_mem.mem[64] = 32'hFEED_BEEF;

        // External DBGBREAK is unsupported in monitor mode. Hold it long
        // enough to pass the input synchronization path while execution
        // begins; it must neither halt the core nor generate an abort.
        CLKEN = 1'b1;
        DBGBREAK = 1'b1;
        repeat (4) @(posedge CLK);
        DBGBREAK = 1'b0;

        handler_seen = 1'b0;
        for (int i = 0; i < 320; i++) begin
            @(posedge CLK);
            if (u_dut.u_core.u_regfile.regs[10]
                == ((SCENARIO == BREAKPOINT_SCENARIO)
                    ? 32'h0000_000A : 32'h0000_000D)) begin
                handler_seen = 1'b1;
                break;
            end
        end

        if (!handler_seen) begin
            $display("[debug_monitor/%0d] FAIL expected abort handler not reached",
                     SCENARIO);
            failed = 1'b1;
        end
        if (!range_seen) begin
            $display("[debug_monitor/%0d] FAIL comparator RANGE never observed",
                     SCENARIO);
            failed = 1'b1;
        end
        if (dbgack_seen) begin
            $display("[debug_monitor/%0d] FAIL monitor mode asserted DBGACK",
                     SCENARIO);
            failed = 1'b1;
        end

        expected_dbgabt = (SCENARIO == EXTERNAL_ABORT_SCENARIO)
                        ? 32'h0 : 32'h1;
        if (u_dut.u_core.u_regfile.regs[8] !== expected_dbgabt) begin
            $display("[debug_monitor/%0d] FAIL CP14 DbgAbt expected %08x got %08x",
                     SCENARIO, expected_dbgabt,
                     u_dut.u_core.u_regfile.regs[8]);
            failed = 1'b1;
        end

        expected_loaded_value = (SCENARIO == BREAKPOINT_SCENARIO)
                              ? 32'hFEED_BEEF : 32'h0;
        if (u_dut.u_core.u_regfile.regs[1] !== expected_loaded_value) begin
            $display("[debug_monitor/%0d] FAIL LDR result expected %08x got %08x",
                     SCENARIO, expected_loaded_value,
                     u_dut.u_core.u_regfile.regs[1]);
            failed = 1'b1;
        end
        if (u_dut.u_core.u_regfile.regs[2] !== 32'h0
            || u_dut.u_core.u_regfile.regs[3] !== 32'h0) begin
            $display("[debug_monitor/%0d] FAIL post-fault flow r2/r3=%08x/%08x",
                     SCENARIO,
                     u_dut.u_core.u_regfile.regs[2],
                     u_dut.u_core.u_regfile.regs[3]);
            failed = 1'b1;
        end
        if (u_dut.u_core.cpsr.m !== 5'b10111
            || u_dut.u_core.u_regfile.regs[28] !== 32'h0000_002C) begin
            $display("[debug_monitor/%0d] FAIL abort mode/LR=%05b/%08x",
                     SCENARIO, u_dut.u_core.cpsr.m,
                     u_dut.u_core.u_regfile.regs[28]);
            failed = 1'b1;
        end

        done = 1'b1;
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, ADDR, WRITE, SIZE, PROT, LOCK, TRANS, WDATA,
        CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI, DBGnEXEC,
        DBGINSTRVALID, DBGRNG[1], DBGCOMMTX, DBGCOMMRX, DBGnTDOEN, DMORE,
        scan_ignored};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
/* verilator lint_on DECLFILENAME */

module arm7tdmis_debug_monitor_mode_tb;
    localparam int CYCLE_LIMIT = 2200;

    logic CLK;
    initial begin
        CLK = 1'b0;
        forever #5 CLK = ~CLK;
    end

    logic [2:0] done;
    logic [2:0] failed;

    arm7tdmis_debug_monitor_mode_scenario #(.SCENARIO(0)) u_breakpoint (
        .CLK, .done(done[0]), .failed(failed[0])
    );
    arm7tdmis_debug_monitor_mode_scenario #(.SCENARIO(1)) u_watchpoint (
        .CLK, .done(done[1]), .failed(failed[1])
    );
    arm7tdmis_debug_monitor_mode_scenario #(.SCENARIO(2)) u_external_abort (
        .CLK, .done(done[2]), .failed(failed[2])
    );

    initial begin
        $dumpfile("debug_monitor_mode.fst");
        $dumpvars(0, arm7tdmis_debug_monitor_mode_tb);
        wait (&done);
        if (|failed)
            $fatal(1, "[debug_monitor_mode] FAIL scenarios=%03b", failed);
        $display("[debug_monitor_mode] PASS");
        $finish;
    end

    initial begin
        repeat (CYCLE_LIMIT) @(posedge CLK);
        $fatal(1, "[debug_monitor_mode] TIMEOUT done=%03b failed=%03b",
               done, failed);
    end
endmodule
