// DBG-001/DBG-004/DBG-007 watchpoint completion and exception regression.
//
// TRM §§5.3.2, 5.18.3, and 5.19 require:
//   * an STM watchpoint to wait for every store and base writeback;
//   * a watchpointed access that Data Aborts to enter debug in Abort mode,
//     after fetching the Data Abort vector;
//   * an IRQ or FIQ sampled with a watchpoint to be remembered, enter its
//     exception mode, and fetch its vector before debug entry; and
//   * a simultaneous DBGRQ not to erase the watchpoint entry cause.
//
// Five independent cores make each collision a fresh reset-state event.

`timescale 1ns/1ps

/* verilator lint_off DECLFILENAME */
module arm7tdmis_debug_watchpoint_priority_scenario #(
    parameter int unsigned SCENARIO = 0
) (
    input  logic CLK,
    output logic done,
    output logic failed
);
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_types_pkg::*;
    import arm7tdmis_debug_pkg::*;
    import arm7tdmis_jtag_tb_pkg::*;

    localparam int unsigned STM_SCENARIO   = 0;
    localparam int unsigned DABT_SCENARIO  = 1;
    localparam int unsigned IRQ_SCENARIO   = 2;
    localparam int unsigned DBGRQ_SCENARIO = 3;
    localparam int unsigned FIQ_SCENARIO   = 4;

    localparam logic [31:0] STM_INSTR = 32'hE8A0_000E;
    localparam logic [31:0] DEBUG_STM_PC = 32'hE880_8000;
    localparam logic [31:0] DEBUG_NOP    = 32'hE1A0_8008;
    localparam logic [31:0] WATCH_ADDR =
        (SCENARIO == STM_SCENARIO) ? 32'h0000_0104
                                   : 32'h0000_0100;
    localparam logic [31:0] EXCEPTION_VECTOR =
        (SCENARIO == DABT_SCENARIO) ? 32'h0000_0010
      : (SCENARIO == IRQ_SCENARIO)  ? 32'h0000_0018
      : (SCENARIO == FIQ_SCENARIO)  ? 32'h0000_001C
                                    : 32'hFFFF_FFFF;

    logic nRESET = 1'b0;
    logic CLKEN = 1'b0;
    logic nIRQ, nFIQ;
    logic ABORT;
    logic DBGRQ;
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
        .nIRQ,
        .nFIQ,
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

    logic inject_abort;
    arm7tdmis_memory #(
        .WORDS    (128),
        .INIT_HEX ("../tb/programs/debug_watchpoint_priority_test.hex")
    ) u_mem (
        .CLK,
        .CLKEN,
        .nRESET,
        .CFGBIGEND        (1'b0),
        .ADDR, .WRITE, .SIZE, .PROT, .LOCK, .TRANS, .WDATA, .RDATA,
        .ABORT,
        .inject_abort
    );

    wire watched_response = u_mem.is_active_q
                          && (u_mem.addr_q == WATCH_ADDR);
    assign inject_abort = (SCENARIO == DABT_SCENARIO)
                        && watched_response;
    assign nIRQ = ((SCENARIO == IRQ_SCENARIO) && watched_response)
                ? 1'b0 : 1'b1;
    assign nFIQ = ((SCENARIO == FIQ_SCENARIO) && watched_response)
                ? 1'b0 : 1'b1;
    assign DBGRQ = ((SCENARIO == DBGRQ_SCENARIO) && watched_response)
                 ? 1'b1 : 1'b0;

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
        input  logic [37:0] scan_in
    );
        tck(1'b1, 1'b0);
        tck(1'b0, 1'b0);
        tck(1'b0, 1'b0);
        for (int i = 0; i < width; i++) begin
            scan_ignored[i] = DBGTDO;
            tck(i == (width - 1), scan_in[i]);
        end
        tck(1'b1, 1'b0);
        tck(1'b0, 1'b0);
    endtask

    task automatic select_chain2;
        load_ir(4'(IR_SCAN_N));
        shift_dr(4, 38'd2);
        load_ir(4'(IR_INTEST));
    endtask

    task automatic select_chain1;
        load_ir(4'(IR_SCAN_N));
        shift_dr(4, 38'd1);
        load_ir(4'(IR_INTEST));
    endtask

    task automatic write_ice(
        input logic [4:0] addr,
        input logic [31:0] data
    );
        shift_dr(38, chain2_serial_in(1'b1, addr, data));
    endtask

    task automatic clock_out(input logic [31:0] data);
        shift_dr(SCAN_CHAIN1_WIDTH, chain1_serial_in(data, 1'b0));
    endtask

    task automatic clock_data_in(output logic [31:0] data);
        shift_dr(SCAN_CHAIN1_WIDTH, chain1_serial_in(32'h0, 1'b0));
        data = chain1_parallel_data(scan_ignored);
    endtask

    logic range_seen;
    logic vector_fetch_seen;
    always_ff @(posedge CLK) begin
        if (!nRESET) begin
            range_seen        <= 1'b0;
            vector_fetch_seen <= 1'b0;
        end else begin
            if (DBGRNG[0])
                range_seen <= 1'b1;
            if (TRANS[1] && !PROT[0] && (ADDR == EXCEPTION_VECTOR))
                vector_fetch_seen <= 1'b1;
        end
    end

    task automatic fail(input string description);
        $display("[debug_watchpoint_priority/%0d] FAIL %s",
                 SCENARIO, description);
        failed = 1'b1;
    endtask

    task automatic check_reg(
        input int unsigned index,
        input logic [31:0] expected,
        input string description
    );
        if (u_dut.u_core.u_regfile.regs[index] !== expected)
            fail($sformatf("%s r%0d expected %08x got %08x",
                           description, index, expected,
                           u_dut.u_core.u_regfile.regs[index]));
    endtask

    initial begin : run
        bit halted;
        logic [31:0] scanned_r15;
        logic [31:0] corrected_pc;

        done   = 1'b0;
        failed = 1'b0;

        // Replace the default LDR with a three-beat writeback STM in the
        // completion scenario. The patch occurs while reset and CLKEN hold.
        @(posedge CLK);
        if (SCENARIO == STM_SCENARIO)
            u_mem.mem[13] = STM_INSTR;

        repeat (3) @(posedge CLK);
        nRESET = 1'b1;
        repeat (2) @(posedge CLK);
        DBGnTRST = 1'b1;
        tck(1'b0, 1'b0);
        select_chain2();

        // Exact address and privileged data-word access. Ignore data and
        // RANGE/CHAIN/EXTERN. ENABLE remains unmaskable in control bit 8.
        write_ice(5'h08, WATCH_ADDR);
        write_ice(5'h09, 32'h0000_0000);
        write_ice(5'h0A, 32'h0000_0000);
        write_ice(5'h0B, 32'hFFFF_FFFF);
        write_ice(5'h0C, (SCENARIO == STM_SCENARIO)
                         ? 32'h0000_011D : 32'h0000_011C);
        write_ice(5'h0D, 32'h0000_00E0);

        u_mem.mem[64] = 32'hFEED_BEEF;
        u_mem.mem[65] = 32'hAAAA_AAAA;
        u_mem.mem[66] = 32'hBBBB_BBBB;

        CLKEN = 1'b1;
        halted = 1'b0;
        for (int i = 0; i < 320; i++) begin
            @(posedge CLK);
            #1;
            if (DBGACK) begin
                halted = 1'b1;
                break;
            end
        end

        if (!halted)
            fail("watchpoint never entered debug state");
        if (!range_seen)
            fail("watchpoint comparator never matched");
        if (!u_dut.u_ice.entry_watchpoint_q)
            fail("watchpoint entry cause was not retained");
        if (TRANS !== 2'(TRANS_I))
            fail($sformatf("halted bus TRANS=%02b instead of internal",
                           TRANS));
        check_reg(9, 32'h0000_0000,
                  "instruction following watched access retired");

        unique case (SCENARIO)
            STM_SCENARIO: begin
                check_reg(0, 32'h0000_010C,
                          "STM base writeback did not complete");
                if (u_mem.mem[64] !== 32'h0000_0011
                    || u_mem.mem[65] !== 32'h0000_0022
                    || u_mem.mem[66] !== 32'h0000_0033)
                    fail($sformatf("STM writes incomplete %08x/%08x/%08x",
                                   u_mem.mem[64], u_mem.mem[65],
                                   u_mem.mem[66]));
            end
            DABT_SCENARIO: begin
                if (!vector_fetch_seen)
                    fail("Data Abort vector was not fetched before DBGACK");
                if (u_dut.u_core.cpsr.m !== 5'(MODE_ABORT))
                    fail($sformatf("Data Abort collision halted in mode %05b",
                                   u_dut.u_core.cpsr.m));
                check_reg(4, 32'h0000_0000,
                          "aborted LDR destination was committed");
                check_reg(10, 32'h0000_0000,
                          "Data Abort vector instruction executed");
                check_reg(28, 32'h0000_003C,
                          "Data Abort link register");
                if (u_dut.u_core.u_psr.spsr_q[3] !== 32'h0000_0013)
                    fail($sformatf("SPSR_abt expected 00000013 got %08x",
                                   u_dut.u_core.u_psr.spsr_q[3]));
            end
            IRQ_SCENARIO: begin
                if (!vector_fetch_seen)
                    fail("IRQ vector was not fetched before DBGACK");
                if (u_dut.u_core.cpsr.m !== 5'(MODE_IRQ))
                    fail($sformatf("IRQ collision halted in mode %05b",
                                   u_dut.u_core.cpsr.m));
                check_reg(4, 32'hFEED_BEEF,
                          "watchpointed LDR did not complete before IRQ");
                check_reg(11, 32'h0000_0000,
                          "IRQ vector instruction executed");
                check_reg(24, 32'h0000_003C,
                          "IRQ link register");
                if (u_dut.u_core.u_psr.spsr_q[1] !== 32'h0000_0013)
                    fail($sformatf("SPSR_irq expected 00000013 got %08x",
                                   u_dut.u_core.u_psr.spsr_q[1]));
            end
            FIQ_SCENARIO: begin
                if (!vector_fetch_seen)
                    fail("FIQ vector was not fetched before DBGACK");
                if (u_dut.u_core.cpsr.m !== 5'(MODE_FIQ))
                    fail($sformatf("FIQ collision halted in mode %05b",
                                   u_dut.u_core.cpsr.m));
                check_reg(4, 32'hFEED_BEEF,
                          "watchpointed LDR did not complete before FIQ");
                check_reg(12, 32'h0000_0000,
                          "FIQ vector instruction executed");
                check_reg(22, 32'h0000_003C,
                          "FIQ link register");
                if (u_dut.u_core.u_psr.spsr_q[0] !== 32'h0000_0013)
                    fail($sformatf("SPSR_fiq expected 00000013 got %08x",
                                   u_dut.u_core.u_psr.spsr_q[0]));
            end
            default: begin
                check_reg(4, 32'hFEED_BEEF,
                          "simultaneous-DBGRQ LDR did not complete");
                if (u_dut.u_core.cpsr.m !== 5'(MODE_SUPERVISOR))
                    fail($sformatf("simultaneous DBGRQ changed mode to %05b",
                                   u_dut.u_core.cpsr.m));
            end
        endcase

        // TRM §§5.18.3 and 5.18.6: watchpoint entry that overlaps an
        // exception advances the PC by three addresses, not the four used
        // for a normal break/watch. Reproduce the public scan-chain STM
        // capture and the debugger's two corrections. The result must be
        // the exception vector that was fetched immediately before DBGACK.
        if ((SCENARIO == DABT_SCENARIO)
            || (SCENARIO == IRQ_SCENARIO)
            || (SCENARIO == FIQ_SCENARIO)) begin
            select_chain1();
            clock_out(DEBUG_STM_PC);
            clock_out(DEBUG_NOP);
            clock_out(DEBUG_NOP);
            clock_data_in(scanned_r15);
            corrected_pc = scanned_r15 - 32'd12 - 32'd8;
            if (corrected_pc !== EXCEPTION_VECTOR)
                fail($sformatf(
                    "exception PC correction expected %08x, got %08x (scanned r15=%08x)",
                    EXCEPTION_VECTOR, corrected_pc, scanned_r15));
        end

        done = 1'b1;
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, ADDR, WRITE, SIZE, PROT, LOCK, WDATA,
        CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI, DBGnEXEC,
        DBGINSTRVALID, DBGRNG[1], DBGCOMMTX, DBGCOMMRX, DBGnTDOEN, DMORE,
        scan_ignored};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
/* verilator lint_on DECLFILENAME */

module arm7tdmis_debug_watchpoint_priority_tb;
    localparam int CYCLE_LIMIT = 2400;

    logic CLK = 1'b0;
    initial forever #5 CLK = ~CLK;

    logic [4:0] done;
    logic [4:0] failed;

    arm7tdmis_debug_watchpoint_priority_scenario #(.SCENARIO(0)) u_stm (
        .CLK, .done(done[0]), .failed(failed[0])
    );
    arm7tdmis_debug_watchpoint_priority_scenario #(.SCENARIO(1)) u_dabt (
        .CLK, .done(done[1]), .failed(failed[1])
    );
    arm7tdmis_debug_watchpoint_priority_scenario #(.SCENARIO(2)) u_irq (
        .CLK, .done(done[2]), .failed(failed[2])
    );
    arm7tdmis_debug_watchpoint_priority_scenario #(.SCENARIO(3)) u_dbgrq (
        .CLK, .done(done[3]), .failed(failed[3])
    );
    arm7tdmis_debug_watchpoint_priority_scenario #(.SCENARIO(4)) u_fiq (
        .CLK, .done(done[4]), .failed(failed[4])
    );

    initial begin
        $dumpfile("debug_watchpoint_priority.fst");
        $dumpvars(0, arm7tdmis_debug_watchpoint_priority_tb);
        wait (&done);
        if (|failed)
            $fatal(1, "[debug_watchpoint_priority] FAIL scenarios=%05b",
                   failed);
        $display("[debug_watchpoint_priority] PASS");
        $finish;
    end

    initial begin
        repeat (CYCLE_LIMIT) @(posedge CLK);
        $fatal(1,
               "[debug_watchpoint_priority] TIMEOUT done=%05b failed=%05b",
               done, failed);
    end
endmodule
