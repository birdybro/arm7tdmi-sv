// DBG-008 public-JTAG regression for TRM §5.18.5.
//
// A debugger-issued system-speed LDR receives an external Data Abort. The
// core must establish ordinary Abort mode/SPSR state and suppress the load
// destination before DBGACK returns. The first chain-1 capture must identify
// an at-speed re-entry. A pending level IRQ stays masked throughout the
// access and halt, then vectors after the debugger enables IRQ and performs
// a real exit. A forced ABORT during halted I-cycles is separately ignored.

`timescale 1ns/1ps

module arm7tdmis_debug_system_speed_abort_tb
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_debug_pkg::*;
    import arm7tdmis_jtag_tb_pkg::*;
;

    localparam int CYCLE_LIMIT = 4500;
    localparam logic [31:0] DEBUG_NOP = 32'hE1A0_0000;
    localparam logic [31:0] DEBUG_MRS_CPSR = 32'hE10F_0000;
    localparam logic [31:0] DEBUG_MRS_SPSR = 32'hE14F_0000;
    localparam logic [31:0] DEBUG_STR_R0_PC = 32'hE58F_0000;
    localparam logic [31:0] SYSTEM_LDR_R4 = 32'hE590_4000;
    localparam logic [31:0] ACCESS_ADDR = 32'h0000_0100;
    localparam logic [31:0] R4_SENTINEL = 32'h0000_0055;

    logic CLK = 1'b0;
    initial forever #5 CLK = ~CLK;

    logic nRESET = 1'b0;
    logic CLKEN = 1'b0;
    logic nIRQ = 1'b1;
    logic nFIQ = 1'b1;
    logic DBGRQ = 1'b1;
    logic forced_abort = 1'b0;
    logic inject_abort = 1'b0;
    logic memory_abort;
    wire ABORT = memory_abort | forced_abort;
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
        .nIRQ,
        .nFIQ,
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
        .INIT_HEX ("../tb/programs/debug_system_speed_test.hex")
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
        .ABORT            (memory_abort),
        .inject_abort
    );

    int unsigned errors = 0;

    task automatic fail(input string description);
        $display("[debug_system_speed_abort] FAIL: %s", description);
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
            fail("unreachable SCAN_N capture sentinel");
        load_ir(4'(IR_INTEST));
    endtask

    task automatic inject(
        input logic [31:0] instruction,
        input logic        break_bit
    );
        logic [37:0] ignored;
        shift_dr(33, chain1_serial_in(instruction, break_bit), ignored);
        if (&{1'b0, ignored})
            fail("unreachable injection capture sentinel");
    endtask

    task automatic capture_data(output logic [31:0] data);
        logic [37:0] captured;
        shift_dr(33, chain1_serial_in(32'h0, 1'b0), captured);
        data = chain1_parallel_data(captured);
    endtask

    task automatic wait_for_inject_idle(input string description);
        for (int i = 0; i < 120; i++) begin
            @(posedge CLK);
            #1;
            if (!u_dut.u_ice.dbg_inject_active)
                return;
        end
        fail(description);
    endtask

    task automatic write_debug_r0_r4(
        input logic [31:0] r0_value,
        input logic [31:0] r4_value
    );
        inject(32'hE890_0011, 1'b0); // LDMIA r0,{r0,r4}, no writeback
        inject(DEBUG_NOP, 1'b0);
        inject(DEBUG_NOP, 1'b0);
        inject(r0_value, 1'b0);
        inject(r4_value, 1'b0);
        inject(DEBUG_NOP, 1'b0);
        wait_for_inject_idle("debug register setup did not retire");
    endtask

    task automatic read_debug_r4(output logic [31:0] value);
        inject(32'hE880_0010, 1'b0); // STMIA r0,{r4}, no writeback
        inject(DEBUG_NOP, 1'b0);
        inject(DEBUG_NOP, 1'b0);
        capture_data(value);
    endtask

    task automatic read_xpsr(
        input  logic        spsr,
        output logic [31:0] value
    );
        inject(spsr ? DEBUG_MRS_SPSR : DEBUG_MRS_CPSR, 1'b0);
        inject(DEBUG_STR_R0_PC, 1'b0);
        inject(DEBUG_NOP, 1'b0);
        inject(DEBUG_NOP, 1'b0);
        capture_data(value);
    endtask

    task automatic capture_reentry_cause(output logic cause);
        logic [37:0] captured;
        select_chain1();
        shift_dr(33, chain1_serial_in(DEBUG_NOP, 1'b0), captured);
        cause = captured[0];
        if (&{1'b0, captured[37:1]})
            fail("unreachable re-entry capture sentinel");
        wait_for_inject_idle("re-entry capture NOP did not retire");
    endtask

    initial begin : run_test
        logic [31:0] cpsr_before;
        logic [31:0] cpsr_after;
        logic [31:0] spsr_after;
        logic [31:0] r4_after;
        logic        reentry_cause;
        logic [31:0] normal_r13;
        bit          saw_target;
        bit          saw_abort_response;
        bit          saw_dbgack_low;
        bit          reentered;
        bit          saw_irq_vector;

        $dumpfile("debug_system_speed_abort.fst");
        $dumpvars(0, arm7tdmis_debug_system_speed_abort_tb);
        u_mem.mem[64] = 32'hCAFE_BABE;

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
        normal_r13 = u_dut.u_core.u_regfile.regs[13];

        tck(1'b0, 1'b0);
        select_chain1();
        read_xpsr(1'b0, cpsr_before);
        if (cpsr_before[4:0] !== 5'h13)
            fail($sformatf(
                "initial debug mode expected Supervisor, got %02x",
                cpsr_before[4:0]));

        // §5.3.4: ABORT is ignored while debug state forces I-cycles.
        @(negedge CLK);
        forced_abort = 1'b1;
        repeat (3) begin
            @(posedge CLK);
            #1;
            if (!DBGACK || TRANS !== 2'(TRANS_I))
                fail("halted ABORT disturbed debug I-cycle isolation");
        end
        @(negedge CLK);
        forced_abort = 1'b0;
        read_xpsr(1'b0, cpsr_after);
        if (cpsr_after !== cpsr_before)
            fail("halted ABORT changed CPSR");

        write_debug_r0_r4(ACCESS_ADDR, R4_SENTINEL);

        // Exact NOP/0, NOP/1, memory/0 system-speed staging sequence.
        inject(DEBUG_NOP, 1'b0);
        wait_for_inject_idle("first at-speed setup NOP did not retire");
        inject(DEBUG_NOP, 1'b1);
        wait_for_inject_idle("bit-33 setup NOP did not retire");
        inject(SYSTEM_LDR_R4, 1'b0);
        load_ir(4'(IR_RESTART));

        saw_target = 1'b0;
        saw_abort_response = 1'b0;
        saw_dbgack_low = 1'b0;
        reentered = 1'b0;
        for (int i = 0; i < 240; i++) begin
            @(posedge CLK);
            #1;
            if (!DBGACK)
                saw_dbgack_low = 1'b1;
            if (!saw_target
                && (TRANS == 2'(TRANS_N) || TRANS == 2'(TRANS_S))
                && PROT[0] && !WRITE && ADDR == ACCESS_ADDR) begin
                saw_target = 1'b1;
                @(negedge CLK);
                inject_abort = 1'b1;
                nIRQ = 1'b0;
                // The behavioral memory asserts ABORT after latching the
                // address. Hold it through the following complete S_DDATA
                // response edge, not merely until it becomes visible.
                @(posedge CLK);
                #1;
                if (!ABORT)
                    fail("memory did not assert ABORT after address capture");
                if (!DBGACK)
                    saw_dbgack_low = 1'b1;
                @(posedge CLK);
                #1;
                // ABORT was sampled on this edge. The memory pipeline can
                // now advance to the following inactive phase and drop it.
                if (!DBGACK)
                    saw_dbgack_low = 1'b1;
                saw_abort_response = 1'b1;
                @(negedge CLK);
                inject_abort = 1'b0;
            end
            if (saw_dbgack_low && DBGACK) begin
                reentered = 1'b1;
                if (u_dut.u_core.u_psr.cpsr_q[4:0] !== 5'h17)
                    fail("DBGACK returned before Abort mode was established");
                break;
            end
        end
        if (!saw_target)
            fail("staged LDR never issued its system data access");
        if (!saw_abort_response)
            fail("system data response did not carry ABORT");
        if (!saw_dbgack_low)
            fail("DBGACK never dropped for the system-speed instruction");
        if (!reentered)
            fail("aborted system-speed instruction did not re-enter debug");
        if (TRANS !== 2'(TRANS_I))
            fail("aborted system-speed re-entry did not isolate the bus");
        if (u_dut.u_core.u_regfile.regs[13] !== normal_r13)
            fail("a normal program instruction retired during the aborted access");

        capture_reentry_cause(reentry_cause);
        if (reentry_cause !== 1'b1)
            fail("aborted system-speed re-entry did not report bit 33 HIGH");

        read_xpsr(1'b0, cpsr_after);
        read_xpsr(1'b1, spsr_after);
        if (!cpsr_after[7] || cpsr_after[5]
            || cpsr_after[4:0] !== 5'h17)
            fail($sformatf(
                "aborted access CPSR expected ARM/IRQ-masked Abort, got %08x",
                cpsr_after));
        if (spsr_after !== cpsr_before)
            fail($sformatf(
                "SPSR_abt expected %08x, got %08x",
                cpsr_before, spsr_after));
        read_debug_r4(r4_after);
        if (r4_after !== R4_SENTINEL)
            fail($sformatf(
                "aborted LDR changed r4 from %08x to %08x",
                R4_SENTINEL, r4_after));
        if (!DBGACK || u_dut.u_core.u_psr.cpsr_q[4:0] !== 5'h17)
            fail("held IRQ escaped masking before real debug exit");

        // Keep Abort mode, but enable IRQ. It is still hidden by IFEN while
        // halted; the held level must become visible on the real RESTART.
        inject(32'hE321_F017, 1'b0); // MSR CPSR_c,#MODE_ABORT
        wait_for_inject_idle("CPSR IRQ-enable instruction did not retire");
        if (u_dut.u_core.u_psr.cpsr_q[7]
            || u_dut.u_core.u_psr.cpsr_q[4:0] !== 5'h17)
            fail("debugger did not enable IRQ while retaining Abort mode");
        load_ir(4'(IR_RESTART));

        saw_irq_vector = 1'b0;
        for (int i = 0; i < 160; i++) begin
            @(posedge CLK);
            #1;
            if (TRANS == 2'(TRANS_N) && !PROT[0]
                && ADDR == 32'h0000_0018)
                saw_irq_vector = 1'b1;
            if (saw_irq_vector
                && u_dut.u_core.u_psr.cpsr_q[4:0] == 5'h12)
                break;
        end
        if (!saw_irq_vector)
            fail("pending IRQ was lost across aborted system-speed debug");
        if (u_dut.u_core.u_psr.cpsr_q[4:0] !== 5'h12)
            fail("pending IRQ did not enter IRQ mode after real debug exit");

        if (errors != 0)
            $fatal(1, "[debug_system_speed_abort] FAIL (%0d errors)", errors);
        $display("[debug_system_speed_abort] PASS");
        $finish;
    end

    initial begin
        repeat (CYCLE_LIMIT) @(posedge CLK);
        $fatal(1, "[debug_system_speed_abort] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, WDATA, SIZE, LOCK, CPnMREQ, CPSEQ, CPnTRANS,
        CPnOPC, CPTBIT, CPnI, DBGnEXEC, DBGINSTRVALID, DBGRNG, DBGCOMMTX,
        DBGCOMMRX, DBGnTDOEN, DMORE, nFIQ};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
