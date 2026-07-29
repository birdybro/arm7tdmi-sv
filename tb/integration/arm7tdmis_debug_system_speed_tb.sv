// DBG-006/JTAG-003/JTAG-005 system-speed scan-chain-1 regression.
//
// Follow the ARM7TDMI debugger sequence used for an at-speed memory access:
// scan NOP/0, NOP/1, then LDR/0; issue RESTART; wait for automatic re-entry.
// The LDR must not execute before RESTART, must run only under CLKEN with
// DBGACK temporarily low, must survive a mid-transfer stall while IRQ is
// masked, and must report bit 33 HIGH on the first capture after re-entry.
//
// Then reproduce OpenOCD's complete word-memory path through public JTAG:
// load r0/r1-r4 at debug speed, run STMIA r0!,{r1-r4} at system speed,
// restore r0, run LDMIA r0!,{r5-r8} at system speed, and scan r0/r5-r8
// back at debug speed. This proves debugger-visible writes and reads rather
// than accepting an internal register or memory-array observation alone.

`timescale 1ns/1ps

module arm7tdmis_debug_system_speed_tb
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_debug_pkg::*;
    import arm7tdmis_jtag_tb_pkg::*;
;

    localparam int CYCLE_LIMIT = 2600;
    localparam logic [31:0] DEBUG_NOP = 32'hE1A0_0000;
    localparam logic [31:0] SYSTEM_LDR = 32'hE590_4000; // LDR r4,[r0]
    localparam logic [31:0] DEBUG_LDM_R0_R4 = 32'hE890_001F;
    localparam logic [31:0] DEBUG_LDM_R0    = 32'hE890_0001;
    localparam logic [31:0] DEBUG_STM_R0_R8 = 32'hE880_01E1;
    localparam logic [31:0] SYSTEM_STM_R1_R4 = 32'hE8A0_001E;
    localparam logic [31:0] SYSTEM_LDM_R5_R8 = 32'hE8B0_01E0;
    localparam logic [31:0] ROUNDTRIP_BASE   = 32'h0000_0120;
    localparam logic [31:0] ROUNDTRIP_END    = 32'h0000_0130;
    localparam logic [31:0] ROUNDTRIP_WORD1  = 32'h1122_3344;
    localparam logic [31:0] ROUNDTRIP_WORD2  = 32'h5566_7788;
    localparam logic [31:0] ROUNDTRIP_WORD3  = 32'h99AA_BBCC;
    localparam logic [31:0] ROUNDTRIP_WORD4  = 32'hDDEE_F00D;

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

    task automatic capture_data(output logic [31:0] data);
        logic [37:0] captured;
        shift_dr(33, chain1_serial_in(32'h0, 1'b0), captured);
        data = chain1_parallel_data(captured);
    endtask

    initial begin : run_test
        logic [31:0] normal_r13;
        logic [31:0] scanned_data;
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
        int unsigned roundtrip_beats;

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

        // OpenOCD arm7_9_write_memory() word path. Load the base and four
        // source registers through the debug-speed scan data bus.
        wait_for_inject_idle("post-capture NOP did not retire");
        inject(DEBUG_LDM_R0_R4, 1'b0);
        inject(DEBUG_NOP, 1'b0);
        inject(DEBUG_NOP, 1'b0);
        inject(ROUNDTRIP_BASE, 1'b0);
        inject(ROUNDTRIP_WORD1, 1'b0);
        inject(ROUNDTRIP_WORD2, 1'b0);
        inject(ROUNDTRIP_WORD3, 1'b0);
        inject(ROUNDTRIP_WORD4, 1'b0);
        inject(DEBUG_NOP, 1'b0);
        wait_for_inject_idle("debug-speed write-register tail did not retire");

        // OpenOCD arm7tdmi_store_word_regs(): NOP/0, NOP/1, then
        // STMIA r0!,{r1-r4}/0. The W bit keeps this instruction on the
        // external system-speed path rather than the scan-data adapter.
        inject(DEBUG_NOP, 1'b0);
        wait_for_inject_idle("word-write setup NOP did not retire");
        inject(DEBUG_NOP, 1'b1);
        wait_for_inject_idle("word-write bit-33 NOP did not retire");
        inject(SYSTEM_STM_R1_R4, 1'b0);
        load_ir(4'(IR_RESTART));

        roundtrip_beats = 0;
        reentered = 1'b0;
        for (int i = 0; i < 300; i++) begin
            @(posedge CLK);
            #1;
            if (CLKEN && ((TRANS == 2'(TRANS_N))
                       || (TRANS == 2'(TRANS_S)))
                && (ADDR >= ROUNDTRIP_BASE) && (ADDR < ROUNDTRIP_END)) begin
                if (!WRITE)
                    fail("word-memory write issued a read transfer");
                if (ADDR !== (ROUNDTRIP_BASE + 32'(roundtrip_beats * 4)))
                    fail($sformatf(
                        "word-memory write address %0d expected %08x got %08x",
                        roundtrip_beats,
                        ROUNDTRIP_BASE + 32'(roundtrip_beats * 4), ADDR));
                roundtrip_beats = roundtrip_beats + 1;
            end
            if (DBGACK && u_dut.u_ice.core_halt
                && (TRANS == 2'(TRANS_I))) begin
                reentered = 1'b1;
                break;
            end
        end
        if (!reentered)
            fail("system-speed STM did not automatically re-enter debug");
        if (roundtrip_beats != 4)
            fail($sformatf(
                "system-speed STM expected 4 external beats, saw %0d",
                roundtrip_beats));

        if (reentered) begin
            capture_reentry_cause(reentry_cause);
            if (reentry_cause !== 1'b1)
                fail("system-speed STM re-entry did not report bit 33 HIGH");
        end

        // Restore r0 through OpenOCD's debug-speed register-write path.
        wait_for_inject_idle("post-STM capture NOP did not retire");
        inject(DEBUG_LDM_R0, 1'b0);
        inject(DEBUG_NOP, 1'b0);
        inject(DEBUG_NOP, 1'b0);
        inject(ROUNDTRIP_BASE, 1'b0);
        inject(DEBUG_NOP, 1'b0);
        wait_for_inject_idle("debug-speed base restore tail did not retire");

        // OpenOCD arm7tdmi_load_word_regs(): read the same four words into
        // r5-r8 at system speed, with architectural base writeback.
        inject(DEBUG_NOP, 1'b0);
        wait_for_inject_idle("word-read setup NOP did not retire");
        inject(DEBUG_NOP, 1'b1);
        wait_for_inject_idle("word-read bit-33 NOP did not retire");
        inject(SYSTEM_LDM_R5_R8, 1'b0);
        load_ir(4'(IR_RESTART));

        roundtrip_beats = 0;
        reentered = 1'b0;
        for (int i = 0; i < 300; i++) begin
            @(posedge CLK);
            #1;
            if (CLKEN && ((TRANS == 2'(TRANS_N))
                       || (TRANS == 2'(TRANS_S)))
                && (ADDR >= ROUNDTRIP_BASE) && (ADDR < ROUNDTRIP_END)) begin
                if (WRITE)
                    fail("word-memory read issued a write transfer");
                if (ADDR !== (ROUNDTRIP_BASE + 32'(roundtrip_beats * 4)))
                    fail($sformatf(
                        "word-memory read address %0d expected %08x got %08x",
                        roundtrip_beats,
                        ROUNDTRIP_BASE + 32'(roundtrip_beats * 4), ADDR));
                roundtrip_beats = roundtrip_beats + 1;
            end
            if (DBGACK && u_dut.u_ice.core_halt
                && (TRANS == 2'(TRANS_I))) begin
                reentered = 1'b1;
                break;
            end
        end
        if (!reentered)
            fail("system-speed LDM did not automatically re-enter debug");
        if (roundtrip_beats != 4)
            fail($sformatf(
                "system-speed LDM expected 4 external beats, saw %0d",
                roundtrip_beats));

        if (reentered) begin
            capture_reentry_cause(reentry_cause);
            if (reentry_cause !== 1'b1)
                fail("system-speed LDM re-entry did not report bit 33 HIGH");
        end
        wait_for_inject_idle("post-LDM capture NOP did not retire");

        // OpenOCD read_core_regs_target_buffer(): scan r0 then r5-r8.
        // This is the only oracle for the loaded data, so the test cannot
        // pass from an internal memory-array or register-file observation.
        inject(DEBUG_STM_R0_R8, 1'b0);
        inject(DEBUG_NOP, 1'b0);
        inject(DEBUG_NOP, 1'b0);
        capture_data(scanned_data);
        if (scanned_data !== ROUNDTRIP_END)
            fail($sformatf(
                "system-speed base writeback expected %08x, scanned %08x",
                ROUNDTRIP_END, scanned_data));
        capture_data(scanned_data);
        if (scanned_data !== ROUNDTRIP_WORD1)
            fail($sformatf(
                "word 0 expected %08x, scanned %08x",
                ROUNDTRIP_WORD1, scanned_data));
        capture_data(scanned_data);
        if (scanned_data !== ROUNDTRIP_WORD2)
            fail($sformatf(
                "word 1 expected %08x, scanned %08x",
                ROUNDTRIP_WORD2, scanned_data));
        capture_data(scanned_data);
        if (scanned_data !== ROUNDTRIP_WORD3)
            fail($sformatf(
                "word 2 expected %08x, scanned %08x",
                ROUNDTRIP_WORD3, scanned_data));
        capture_data(scanned_data);
        if (scanned_data !== ROUNDTRIP_WORD4)
            fail($sformatf(
                "word 3 expected %08x, scanned %08x",
                ROUNDTRIP_WORD4, scanned_data));

        if (u_dut.u_core.u_regfile.regs[13] !== normal_r13)
            fail("normal program instruction retired during memory round trip");
        if (!DBGACK)
            fail("debug memory round trip unexpectedly left debug state");

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
