// DBG-006/JTAG-003 system-speed scan-chain-1 regression.
//
// Follow the ARM7TDMI debugger sequence used for an at-speed memory access:
// scan NOP/0, NOP/1, then LDR/0; issue RESTART; wait for automatic re-entry.
// The LDR must not execute before RESTART, must run only under CLKEN with
// DBGACK temporarily low, must survive a mid-transfer stall while IRQ is
// masked, and must report bit 33 HIGH on the first capture after re-entry.

`timescale 1ns/1ps

module arm7tdmis_debug_system_speed_tb
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_debug_pkg::*;
    import arm7tdmis_jtag_tb_pkg::*;
;

    localparam int CYCLE_LIMIT = 2600;
    localparam logic [31:0] DEBUG_NOP = 32'hE1A0_0000;
    localparam logic [31:0] SYSTEM_LDR = 32'hE590_4000; // LDR r4,[r0]

    logic CLK = 1'b0;
    initial forever #5 CLK = ~CLK;

    logic nRESET = 1'b0;
    logic CLKEN = 1'b0;
    logic nIRQ = 1'b1;
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
        .nIRQ,
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
        .ABORT,
        .inject_abort     (1'b0)
    );

    int unsigned errors = 0;

    task automatic fail(input string description);
        $display("[debug_system_speed] FAIL: %s", description);
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

    task automatic inject(
        input logic [31:0] instruction,
        input logic        break_bit
    );
        logic [37:0] ignored;
        shift_dr(33, chain1_serial_in(instruction, break_bit), ignored);
        if (&{1'b0, ignored})
            fail("unreachable injection sentinel");
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

    task automatic capture_reentry_cause(output logic cause);
        logic [37:0] captured;
        select_chain1();
        shift_dr(33, chain1_serial_in(DEBUG_NOP, 1'b0), captured);
        cause = captured[0];
        if (&{1'b0, captured[37:1]})
            fail("unreachable capture sentinel");
    endtask

    initial begin : run_test
        logic [31:0] normal_r13;
        logic [31:0] stalled_addr;
        logic [31:0] stalled_wdata;
        logic        stalled_write;
        logic [1:0]  stalled_size;
        logic [1:0]  stalled_prot;
        logic [1:0]  stalled_trans;
        logic        stalled_lock;
        logic        reentry_cause;
        bit          saw_dbgack_low;
        bit          saw_sync_idle;
        bit          saw_target_access;
        bit          pre_restart_access;
        bit          reentered;

        $dumpfile("debug_system_speed.fst");
        $dumpvars(0, arm7tdmis_debug_system_speed_tb);
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

        // Establish the target address at debug speed.
        inject(32'hE3A0_0C01, 1'b0); // MOV r0,#0x100
        wait_for_inject_idle("debug-speed MOV did not retire");
        if (u_dut.u_core.u_regfile.regs[0] !== 32'h0000_0100)
            fail("debug-speed MOV did not establish r0");

        // Exact ARM7TDMI system-speed pipeline sequence.
        inject(DEBUG_NOP, 1'b0);
        wait_for_inject_idle("first setup NOP did not retire");
        inject(DEBUG_NOP, 1'b1);
        wait_for_inject_idle("bit-33 setup NOP did not retire");
        inject(SYSTEM_LDR, 1'b0);

        // The final instruction is only staged; RESTART is the event that
        // transfers control back to CLKEN and permits it to execute.
        pre_restart_access = 1'b0;
        repeat (24) begin
            @(posedge CLK);
            #1;
            if ((TRANS == 2'(TRANS_N) || TRANS == 2'(TRANS_S))
                && PROT[0] && !WRITE && (ADDR == 32'h0000_0100))
                pre_restart_access = 1'b1;
        end
        if (pre_restart_access)
            fail("system-speed LDR accessed memory before RESTART");
        if (u_dut.u_core.u_regfile.regs[4] !== 32'h0000_0000)
            fail("system-speed LDR executed before RESTART");
        if (!DBGACK)
            fail("DBGACK dropped before RESTART");

        // A pending IRQ must remain masked throughout the at-speed access.
        nIRQ = 1'b0;
        load_ir(4'(IR_RESTART));

        saw_dbgack_low = 1'b0;
        saw_sync_idle = 1'b0;
        saw_target_access = 1'b0;
        for (int i = 0; i < 160; i++) begin
            @(posedge CLK);
            #1;
            if (!DBGACK)
                saw_dbgack_low = 1'b1;
            if (saw_dbgack_low && (TRANS == 2'(TRANS_I)))
                saw_sync_idle = 1'b1;
            if ((TRANS == 2'(TRANS_N) || TRANS == 2'(TRANS_S))
                && PROT[0] && !WRITE && (ADDR == 32'h0000_0100)) begin
                saw_target_access = 1'b1;
                if (!saw_sync_idle)
                    fail("system access began without an internal sync cycle");
                if (DBGACK)
                    fail("DBGACK stayed high during system-speed access");

                @(negedge CLK);
                stalled_addr  = ADDR;
                stalled_wdata = WDATA;
                stalled_write = WRITE;
                stalled_size  = SIZE;
                stalled_prot  = PROT;
                stalled_trans = TRANS;
                stalled_lock  = LOCK;
                CLKEN = 1'b0;
                repeat (7) begin
                    @(posedge CLK);
                    #1;
                    if ({ADDR, WDATA, WRITE, SIZE, PROT, TRANS, LOCK}
                        !== {stalled_addr, stalled_wdata, stalled_write,
                            stalled_size, stalled_prot, stalled_trans,
                            stalled_lock})
                        fail("system-speed bus changed while CLKEN was low");
                    if (DBGACK)
                        fail("system-speed access re-halted during CLKEN stall");
                end
                @(negedge CLK);
                CLKEN = 1'b1;
                break;
            end
        end
        if (!saw_dbgack_low)
            fail("RESTART never dropped DBGACK for system-speed access");
        if (!saw_target_access)
            fail("RESTART never issued the staged system-speed LDR");

        reentered = 1'b0;
        for (int i = 0; i < 160; i++) begin
            @(posedge CLK);
            #1;
            if (DBGACK && u_dut.u_ice.core_halt
                && (TRANS == 2'(TRANS_I))) begin
                reentered = 1'b1;
                break;
            end
        end
        if (!reentered)
            fail("system-speed LDR did not automatically re-enter debug");
        if (u_dut.u_core.u_regfile.regs[4] !== 32'hCAFE_BABE)
            fail("system-speed LDR result was not committed");
        if (u_dut.u_core.u_psr.cpsr_q[4:0] !== 5'h13)
            fail("pending IRQ was taken during system-speed debug access");
        if (u_dut.u_core.u_regfile.regs[13] !== normal_r13)
            fail("normal program instruction retired during system access");

        if (reentered) begin
            capture_reentry_cause(reentry_cause);
            if (reentry_cause !== 1'b1)
                fail("system-speed re-entry did not scan out bit 33 HIGH");
        end

        if (errors != 0)
            $fatal(1, "[debug_system_speed] FAIL (%0d errors)", errors);
        $display("[debug_system_speed] PASS");
        $finish;
    end

    initial begin
        repeat (CYCLE_LIMIT) @(posedge CLK);
        $fatal(1, "[debug_system_speed] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI,
        DBGnEXEC, DBGINSTRVALID, DBGRNG, DBGCOMMTX, DBGCOMMRX, DBGnTDOEN,
        DMORE};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
