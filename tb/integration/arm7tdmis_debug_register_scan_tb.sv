// JTAG-005 end-to-end core-register scan regression.
//
// Reproduce the public ARM7TDMI sequence used by OpenOCD:
//   write: LDMIA r0,{registers}; NOP; NOP; one scanned data word/register
//   read : STMIA r0,{registers}; NOP; NOP; one captured data word/register
// Debug-speed block transfers use scan chain 1 as the data bus and must not
// issue an external memory transaction.

`timescale 1ns/1ps

module arm7tdmis_debug_register_scan_tb
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_debug_pkg::*;
    import arm7tdmis_jtag_tb_pkg::*;
;

    localparam int CYCLE_LIMIT = 7000;
    localparam logic [15:0] REGISTER_MASK = 16'h7FFF; // r0-r14
    localparam logic [31:0] DEBUG_LDM =
        32'hE890_0000 | 32'(REGISTER_MASK);
    localparam logic [31:0] DEBUG_STM =
        32'hE880_0000 | 32'(REGISTER_MASK);
    localparam logic [31:0] DEBUG_NOP = 32'hE1A0_8008;
    localparam logic [31:0] DEBUG_MRS_CPSR = 32'hE10F_0000;
    localparam logic [31:0] DEBUG_MRS_SPSR = 32'hE14F_0000;
    localparam logic [31:0] DEBUG_STR_R0_PC = 32'hE58F_0000;
    localparam logic [31:0] CPSR_TEST_VALUE = 32'hA000_00D3;
    localparam logic [31:0] SPSR_TEST_VALUE = 32'h5000_0012;

    logic CLK = 1'b0;
    initial forever #5 CLK = ~CLK;

    logic nRESET = 1'b0;
    logic CLKEN = 1'b0;
    logic DBGRQ = 1'b1;
    logic ABORT;
    logic DBGTCKEN = 1'b0;
    logic DBGTMS = 1'b1;
    logic DBGTDI = 1'b0;
    logic DBGnTRST = 1'b0;
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
        .INIT_HEX ("../tb/programs/debug_register_scan_test.hex")
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
        .inject_abort     (1'b0)
    );

    logic [31:0] expected [0:15];
    int unsigned errors = 0;
    int unsigned external_debug_transfers;
    logic monitor_debug_bus = 1'b0;

    always @(posedge CLK) begin
        if (!nRESET)
            external_debug_transfers <= 0;
        else if (monitor_debug_bus && CLKEN
            && ((TRANS == 2'(TRANS_N)) || (TRANS == 2'(TRANS_S))))
            external_debug_transfers <= external_debug_transfers + 1;
    end

    task automatic fail(input string description);
        $display("[debug_register_scan] FAIL: %s", description);
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
        input  int unsigned width,
        input  logic [37:0] serial_in,
        output logic [37:0] serial_out
    );
        serial_out = '0;
        tck(1'b1, 1'b0);
        tck(1'b0, 1'b0);
        tck(1'b0, 1'b0);
        for (int i = 0; i < width; i++) begin
            serial_out[i] = DBGTDO;
            tck(i == (width - 1), serial_in[i]);
        end
        tck(1'b1, 1'b0);
        tck(1'b0, 1'b0);
    endtask

    task automatic select_chain1;
        logic [37:0] ignored;
        load_ir(4'(IR_SCAN_N));
        shift_dr(4, 38'd1, ignored);
        if (&{1'b0, ignored})
            fail("unreachable SCAN_N sentinel");
        load_ir(4'(IR_INTEST));
    endtask

    task automatic clock_out(input logic [31:0] data);
        logic [37:0] ignored;
        shift_dr(SCAN_CHAIN1_WIDTH, chain1_serial_in(data, 1'b0),
                 ignored);
        if (&{1'b0, ignored})
            fail("unreachable clock-out sentinel");
    endtask

    task automatic clock_data_in(output logic [31:0] data);
        logic [37:0] captured;
        shift_dr(SCAN_CHAIN1_WIDTH, chain1_serial_in(32'h0, 1'b0),
                 captured);
        data = chain1_parallel_data(captured);
    endtask

    function automatic logic [31:0] msr_immediate(
        input logic [7:0] immediate,
        input logic [3:0] rotate,
        input logic [3:0] field_mask,
        input logic       spsr
    );
        logic [31:0] instruction;
        instruction = 32'hE320_F000;
        instruction[22]    = spsr;
        instruction[19:16] = field_mask;
        instruction[11:8]  = rotate;
        instruction[7:0]   = immediate;
        return instruction;
    endfunction

    task automatic write_xpsr(
        input logic [31:0] value,
        input logic        spsr
    );
        // Exact OpenOCD arm7tdmi_write_xpsr() scan schedule.
        clock_out(msr_immediate(value[7:0],   4'h0, 4'h1, spsr));
        clock_out(msr_immediate(value[15:8],  4'hC, 4'h2, spsr));
        clock_out(msr_immediate(value[23:16], 4'h8, 4'h4, spsr));
        clock_out(DEBUG_NOP);
        clock_out(msr_immediate(value[31:24], 4'h4, 4'h8, spsr));
        repeat (5)
            clock_out(DEBUG_NOP);
    endtask

    task automatic read_xpsr(
        input  logic        spsr,
        output logic [31:0] value
    );
        // Exact OpenOCD arm7tdmi_read_xpsr() scan schedule.
        clock_out(spsr ? DEBUG_MRS_SPSR : DEBUG_MRS_CPSR);
        clock_out(DEBUG_STR_R0_PC);
        clock_out(DEBUG_NOP);
        clock_out(DEBUG_NOP);
        clock_data_in(value);
    endtask

    initial begin : run_test
        logic [31:0] observed;

        $dumpfile("debug_register_scan.fst");
        $dumpvars(0, arm7tdmis_debug_register_scan_tb);

        for (int i = 0; i < 16; i++)
            expected[i] = 32'h5100_0000 + (32'(i) * 32'h0001_0101);

        repeat (4) @(posedge CLK);
        nRESET = 1'b1;
        repeat (2) @(posedge CLK);
        DBGnTRST = 1'b1;
        CLKEN = 1'b1;

        for (int i = 0; i < 120; i++) begin
            @(posedge CLK);
            #1;
            if (DBGACK)
                break;
        end
        if (!DBGACK)
            fail("DBGRQ did not enter debug state");
        DBGRQ = 1'b0;

        tck(1'b0, 1'b0);
        select_chain1();
        monitor_debug_bus = 1'b1;

        // OpenOCD arm7tdmi_write_core_regs(), restricted only to r0-r14
        // so PC return-address handling can be checked independently.
        clock_out(DEBUG_LDM);
        clock_out(DEBUG_NOP);
        clock_out(DEBUG_NOP);
        for (int reg_index = 0; reg_index <= 14; reg_index++)
            clock_out(expected[reg_index]);
        clock_out(DEBUG_NOP);

        // Read the same bank exclusively through scan chain 1.
        clock_out(DEBUG_STM);
        clock_out(DEBUG_NOP);
        clock_out(DEBUG_NOP);
        for (int reg_index = 0; reg_index <= 14; reg_index++) begin
            clock_data_in(observed);
            if (observed !== expected[reg_index])
                fail($sformatf(
                    "r%0d expected %08x, scanned %08x",
                    reg_index, expected[reg_index], observed));
        end

        // OpenOCD-compatible CPSR/SPSR write and readback. These are
        // legal debug-speed instructions and their STR data phase belongs
        // on scan chain 1, never on the external memory interface.
        write_xpsr(CPSR_TEST_VALUE, 1'b0);
        read_xpsr(1'b0, observed);
        if (observed !== CPSR_TEST_VALUE)
            fail($sformatf(
                "CPSR expected %08x, scanned %08x",
                CPSR_TEST_VALUE, observed));

        write_xpsr(SPSR_TEST_VALUE, 1'b1);
        read_xpsr(1'b1, observed);
        if (observed !== SPSR_TEST_VALUE)
            fail($sformatf(
                "SPSR expected %08x, scanned %08x",
                SPSR_TEST_VALUE, observed));
        read_xpsr(1'b0, observed);
        if (observed !== CPSR_TEST_VALUE)
            fail($sformatf(
                "SPSR traffic changed CPSR to %08x", observed));

        monitor_debug_bus = 1'b0;
        if (external_debug_transfers != 0)
            fail($sformatf(
                "debug-speed register transfer leaked %0d external accesses",
                external_debug_transfers));
        if (!DBGACK)
            fail("register scan unexpectedly left debug state");

        if (errors != 0)
            $fatal(1, "[debug_register_scan] FAIL (%0d errors)", errors);
        $display("[debug_register_scan] PASS");
        $finish;
    end

    initial begin
        repeat (CYCLE_LIMIT) @(posedge CLK);
        $fatal(1, "[debug_register_scan] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, ADDR, WDATA, WRITE, SIZE, PROT, LOCK,
        CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI,
        DBGnEXEC, DBGINSTRVALID, DBGRNG, DBGCOMMTX, DBGCOMMRX,
        DBGnTDOEN, DMORE};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
