// DBG-006 debug-speed injection completion regression.
//
// Enter halt through DBGRQ, then inject single-cycle and maximum-length
// multicycle instructions through public scan chain 1. The matrix includes:
//   * a MOV;
//   * a 12-register writeback LDM, exceeding the old fixed window; and
//   * 16-register STMIB/LDMIB transfers, including r15.
// CLKEN stalls each block path in its data phase. Every scan update must
// execute exactly one injected instruction, wait for its real completion
// boundary, and re-freeze in S_EXEC. The r15 load is proven by resuming at
// the loaded target.

`timescale 1ns/1ps

module arm7tdmis_debug_inject_handshake_tb
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_debug_pkg::*;
    import arm7tdmis_jtag_tb_pkg::*;
;

    localparam int CYCLE_LIMIT = 3600;
    localparam logic [31:0] DEBUG_MOV_R0_100 = 32'hE3A0_0C01;
    localparam logic [31:0] DEBUG_SUB_R0_4   = 32'hE240_0004;
    localparam logic [31:0] DEBUG_STMIB_ALL  = 32'hE980_FFFF;
    localparam logic [31:0] DEBUG_LDMIB_ALL  = 32'hE990_FFFF;
    localparam logic [31:0] RESUME_PC        = 32'h0000_0300;

    logic CLK;
    initial begin
        CLK = 1'b0;
        forever #5 CLK = ~CLK;
    end

    logic nRESET;
    initial begin
        nRESET = 1'b0;
        repeat (4) @(posedge CLK);
        nRESET = 1'b1;
    end

    logic CLKEN = 1'b0;
    logic DBGRQ = 1'b1;
    logic ABORT;
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
        .INIT_HEX ("../tb/programs/debug_inject_handshake_test.hex")
    ) u_mem (
        .CLK,
        .CLKEN,
        .nRESET,
        .CFGBIGEND        (1'b0),
        .ADDR, .WRITE, .SIZE, .PROT, .LOCK, .TRANS, .WDATA, .RDATA,
        .ABORT,
        .inject_abort     (1'b0)
    );

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

    task automatic select_chain1;
        load_ir(4'(IR_SCAN_N));
        shift_dr(4, 38'd1);
        load_ir(4'(IR_INTEST));
    endtask

    task automatic inject_debug_speed(input logic [31:0] instruction);
        shift_dr(33, chain1_serial_in(instruction, 1'b0));
    endtask

    int unsigned errors = 0;
    logic [31:0] normal_r13;

    task automatic fail(input string description);
        $display("[debug_inject_handshake] FAIL %s", description);
        errors = errors + 1;
    endtask

    task automatic wait_for_refreeze(input string description);
        bit saw_running;
        bit refrozen;
        saw_running = !u_dut.u_ice.core_halt;
        refrozen = 1'b0;
        for (int i = 0; i < 160; i++) begin
            @(posedge CLK);
            #1;
            if (!u_dut.u_ice.core_halt)
                saw_running = 1'b1;
            if (saw_running && u_dut.u_ice.core_halt) begin
                refrozen = 1'b1;
                break;
            end
        end
        if (!saw_running)
            fail($sformatf("%s never released the core", description));
        if (!refrozen)
            fail($sformatf("%s never returned to debug halt", description));
    endtask

    task automatic stall_block_transfer(input string description);
        logic [31:0] stalled_addr;
        logic [31:0] stalled_wdata;
        logic        stalled_write;
        logic [1:0]  stalled_size;
        logic [1:0]  stalled_prot;
        logic [1:0]  stalled_trans;
        logic        stalled_lock;
        bit          block_started;

        block_started = 1'b0;
        for (int i = 0; i < 100; i++) begin
            @(posedge CLK);
            #1;
            if (u_dut.u_core.state_q == 4'd2) begin
                block_started = 1'b1;
                break;
            end
        end
        if (!block_started) begin
            fail($sformatf("%s never reached S_BLOCK_DATA", description));
            return;
        end

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
                    stalled_size, stalled_prot, stalled_trans, stalled_lock})
                fail($sformatf("%s bus changed with CLKEN LOW",
                               description));
        end
        @(negedge CLK);
        CLKEN = 1'b1;
    endtask

    initial begin : run_test
        logic [31:0] stm_expected [0:14];
        bit          target_executed;

        $dumpfile("debug_inject_handshake.fst");
        $dumpvars(0, arm7tdmis_debug_inject_handshake_tb);

        for (int i = 1; i <= 12; i++)
            u_mem.mem[64 + i - 1] = 32'h1000_0000 + 32'(i);
        u_mem.mem[RESUME_PC >> 2] = 32'hE3A0_505A;
        u_mem.mem[(RESUME_PC >> 2) + 1] = 32'hEAFF_FFFE;

        repeat (2) @(posedge CLK);
        DBGnTRST = 1'b1;
        CLKEN = 1'b1;

        for (int i = 0; i < 100; i++) begin
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

        // MOV r0,#0x100
        inject_debug_speed(DEBUG_MOV_R0_100);
        wait_for_refreeze("MOV injection");
        if (u_dut.u_core.u_regfile.regs[0] !== 32'h0000_0100)
            fail($sformatf("MOV result r0=%08x",
                           u_dut.u_core.u_regfile.regs[0]));
        if (u_dut.u_core.u_regfile.regs[13] !== normal_r13)
            fail("normal instruction retired during MOV injection");
        if (u_dut.u_core.state_q !== 4'd0)
            fail("MOV refroze outside S_EXEC");

        // LDMIA r0!,{r1-r12}; 12 beats exceed the old fixed window.
        inject_debug_speed(32'hE8B0_1FFE);
        stall_block_transfer("12-register LDM");

        wait_for_refreeze("LDM injection");
        if (u_dut.u_core.state_q !== 4'd0)
            fail($sformatf("LDM refroze in state %0d", u_dut.u_core.state_q));
        if (u_dut.u_core.u_regfile.regs[0] !== 32'h0000_0130)
            fail($sformatf("LDM writeback r0=%08x",
                           u_dut.u_core.u_regfile.regs[0]));
        for (int i = 1; i <= 12; i++) begin
            if (u_dut.u_core.u_regfile.regs[i] !==
                (32'h1000_0000 + 32'(i)))
                fail($sformatf("LDM r%0d expected %08x got %08x", i,
                               32'h1000_0000 + 32'(i),
                               u_dut.u_core.u_regfile.regs[i]));
        end
        if (u_dut.u_core.u_regfile.regs[13] !== normal_r13)
            fail("normal instruction retired during LDM injection");

        // Seed a base at 0xfc so increment-before starts at 0x100.
        inject_debug_speed(DEBUG_MOV_R0_100);
        wait_for_refreeze("STM base MOV");
        inject_debug_speed(DEBUG_SUB_R0_4);
        wait_for_refreeze("STM base SUB");
        for (int i = 0; i <= 12; i++)
            stm_expected[i] = u_dut.u_core.u_regfile.regs[i];
        stm_expected[13] = u_dut.u_core.u_regfile.regs[25];
        stm_expected[14] = u_dut.u_core.u_regfile.regs[26];
        for (int i = 0; i < 16; i++)
            u_mem.mem[64 + i] = 32'hDEAD_0000 + 32'(i);

        // STMIB r0,{r0-r15}: the non-writeback increment-before form is
        // fully defined even though the base appears in the register list.
        // P=1 also keeps this maximum transfer on the explicit instruction
        // handshake rather than the standard LDMIA/STMIA scan-data adapter.
        inject_debug_speed(DEBUG_STMIB_ALL);
        stall_block_transfer("16-register STM");
        wait_for_refreeze("16-register STM");
        if (u_dut.u_core.u_regfile.regs[0] !== 32'h0000_00FC)
            fail($sformatf("STM unexpectedly wrote back r0=%08x",
                           u_dut.u_core.u_regfile.regs[0]));
        for (int i = 0; i <= 14; i++) begin
            if (u_mem.mem[64 + i] !== stm_expected[i])
                fail($sformatf(
                    "STM beat r%0d expected %08x got %08x",
                    i, stm_expected[i], u_mem.mem[64 + i]));
        end
        if (u_mem.mem[79] === 32'hDEAD_000F)
            fail("STM did not issue the sixteenth r15 beat");

        // Replace all 16 words. The final r15 value is an executable target;
        // successful RESTART is the public proof that the final load beat
        // committed before the ICE refroze.
        for (int i = 0; i <= 14; i++)
            u_mem.mem[64 + i] = 32'h7000_0000 + 32'(i);
        u_mem.mem[79] = RESUME_PC;

        inject_debug_speed(DEBUG_LDMIB_ALL);
        stall_block_transfer("16-register LDM");
        wait_for_refreeze("16-register LDM");
        for (int i = 0; i <= 12; i++) begin
            if (u_dut.u_core.u_regfile.regs[i] !==
                (32'h7000_0000 + 32'(i)))
                fail($sformatf(
                    "LDM r%0d expected %08x got %08x",
                    i, 32'h7000_0000 + 32'(i),
                    u_dut.u_core.u_regfile.regs[i]));
        end
        if (u_dut.u_core.u_regfile.regs[25] !== 32'h7000_000D)
            fail($sformatf("LDM r13_svc expected 7000000d got %08x",
                           u_dut.u_core.u_regfile.regs[25]));
        if (u_dut.u_core.u_regfile.regs[26] !== 32'h7000_000E)
            fail($sformatf("LDM r14_svc expected 7000000e got %08x",
                           u_dut.u_core.u_regfile.regs[26]));
        if (u_dut.u_core.state_q !== 4'd0)
            fail("16-register LDM refroze outside S_EXEC");

        load_ir(4'(IR_RESTART));
        target_executed = 1'b0;
        for (int i = 0; i < 160; i++) begin
            @(posedge CLK);
            #1;
            if (u_dut.u_core.u_regfile.regs[5] == 32'h0000_005A) begin
                target_executed = 1'b1;
                break;
            end
        end
        if (!target_executed)
            fail("r15 load did not resume at the sixteenth word");
        if (DBGACK)
            fail("maximum LDM restart remained in debug state");

        if (errors != 0)
            $fatal(1, "[debug_inject_handshake] FAIL (%0d errors)", errors);
        $display("[debug_inject_handshake] PASS");
        $finish;
    end

    initial begin
        repeat (CYCLE_LIMIT) @(posedge CLK);
        $fatal(1, "[debug_inject_handshake] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI,
        DBGnEXEC, DBGINSTRVALID, DBGRNG, DBGCOMMTX, DBGCOMMRX, DBGnTDOEN,
        DMORE, ignored_scan};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
