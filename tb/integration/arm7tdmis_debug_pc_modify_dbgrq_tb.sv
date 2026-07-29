// DBG-007 / ARM7TDMI-S erratum [13] synchronous-boundary regression.
//
// The r4p3 silicon defect requires DBGRQ to arrive asynchronously while a
// PC-modifying instruction is in flight. Appendix B instead defines the soft
// macrocell DBGRQ pin as synchronous to CLK. Exercise every synchronous
// boundary around MOV pc and LDR pc: a request before MOV executes must stop
// at MOV, while requests at or after either instruction's commit must expose
// the committed target through the public r15 scan formula.

`timescale 1ns/1ps

/* verilator lint_off DECLFILENAME */
module arm7tdmis_debug_pc_modify_dbgrq_scenario #(
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

    localparam int unsigned MOV_PRE_SCENARIO  = 0;
    localparam int unsigned MOV_EXEC_SCENARIO = 1;
    localparam int unsigned MOV_POST_SCENARIO = 2;
    localparam int unsigned LDR_EXEC_SCENARIO = 3;
    localparam int unsigned LDR_DATA_SCENARIO = 4;
    localparam int unsigned LDR_WB_SCENARIO   = 5;

    localparam logic [31:0] TRIGGER_PC = 32'h0000_0020;
    localparam logic [31:0] TARGET_PC  = 32'h0000_0080;
    localparam logic [31:0] DATA_ADDR  = 32'h0000_0100;
    localparam logic [31:0] DEBUG_STM_PC = 32'hE880_8000;
    localparam logic [31:0] DEBUG_NOP    = 32'hE1A0_0000;

    logic nRESET = 1'b0;
    logic DBGnTRST = 1'b0;
    logic DBGRQ;
    logic DBGTCKEN = 1'b0;
    logic DBGTMS = 1'b1;
    logic DBGTDI = 1'b0;

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
        .CLKEN             (1'b1),
        .nRESET,
        .CFGBIGEND         (1'b0),
        .nIRQ              (1'b1),
        .nFIQ              (1'b1),
        .ABORT,
        .ADDR, .WRITE, .SIZE, .PROT, .LOCK, .TRANS, .WDATA, .RDATA,
        .CPnMREQ, .CPSEQ, .CPnTRANS, .CPnOPC, .CPTBIT, .CPnI,
        .CPA               (1'b1),
        .CPB               (1'b1),
        .DBGEN             (1'b1),
        .DBGRQ,
        .DBGBREAK          (1'b0),
        .DBGACK,
        .DBGnEXEC,
        .DBGINSTRVALID,
        .DBGEXT            (2'b00),
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
        .INIT_HEX ("")
    ) u_mem (
        .CLK,
        .CLKEN             (1'b1),
        .nRESET,
        .CFGBIGEND         (1'b0),
        .ADDR, .WRITE, .SIZE, .PROT, .LOCK, .TRANS, .WDATA, .RDATA,
        .ABORT,
        .inject_abort      (1'b0)
    );

    wire mov_scenario = SCENARIO <= MOV_POST_SCENARIO;
    wire trigger_execute = u_dut.u_core.executing
                         && (u_dut.u_core.de_q.pc == TRIGGER_PC);
    wire trigger_in_decode = u_dut.u_core.fd_q.valid
                           && (u_dut.u_core.fd_q.pc == TRIGGER_PC)
                           && !trigger_execute;
    wire target_refill = u_dut.u_core.inflight_valid_q
                       && (u_dut.u_core.inflight_pc_q == TARGET_PC);
    wire ldr_data = (u_dut.u_core.state_q == 5'd1)
                  && (u_dut.u_core.memory_instr_pc_q == TRIGGER_PC);
    wire ldr_writeback = (u_dut.u_core.state_q == 5'd10)
                       && (u_dut.u_core.ls_rd_q == 4'd15);

    always_comb begin
        unique case (SCENARIO)
            MOV_PRE_SCENARIO:  DBGRQ = trigger_in_decode;
            MOV_EXEC_SCENARIO: DBGRQ = trigger_execute;
            MOV_POST_SCENARIO: DBGRQ = target_refill;
            LDR_EXEC_SCENARIO: DBGRQ = trigger_execute;
            LDR_DATA_SCENARIO: DBGRQ = ldr_data;
            LDR_WB_SCENARIO:   DBGRQ = ldr_writeback;
            default:           DBGRQ = 1'b0;
        endcase
    end

    logic request_seen;
    always_ff @(posedge CLK) begin
        if (!nRESET)
            request_seen <= 1'b0;
        else if (DBGRQ)
            request_seen <= 1'b1;
    end

    task automatic fail(input string description);
        $display("[debug_pc_modify_dbgrq/%0d] FAIL %s",
                 SCENARIO, description);
        failed = 1'b1;
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

    initial begin : run
        bit halted;
        logic [31:0] scanned_r15;
        logic [31:0] corrected_pc;
        logic [31:0] expected_pc;

        done   = 1'b0;
        failed = 1'b0;

        @(posedge CLK);
        for (int i = 0; i < 128; i++)
            u_mem.mem[i] = 32'hEAFF_FFFE;
        u_mem.mem[0]  = 32'hE3A0_0080; // MOV r0,#0x80
        u_mem.mem[1]  = 32'hE3A0_1C01; // MOV r1,#0x100
        u_mem.mem[2]  = 32'hEA00_0004; // B 0x20
        u_mem.mem[8]  = mov_scenario
                      ? 32'hE1A0_F000   // MOV pc,r0
                      : 32'hE591_F000;  // LDR pc,[r1]
        u_mem.mem[9]  = 32'hE3A0_6066; // fallthrough: MOV r6,#0x66
        u_mem.mem[32] = 32'hE3A0_5055; // target: MOV r5,#0x55
        u_mem.mem[64] = TARGET_PC;

        repeat (3) @(posedge CLK);
        DBGnTRST = 1'b1;
        nRESET   = 1'b1;

        halted = 1'b0;
        for (int i = 0; i < 240; i++) begin
            @(posedge CLK);
            #1;
            if (DBGACK) begin
                halted = 1'b1;
                break;
            end
        end

        if (!halted)
            fail("synchronous DBGRQ never entered debug state");
        if (!request_seen)
            fail("cycle-positioned DBGRQ was never generated");
        if (u_dut.u_core.cpsr.m !== 5'(MODE_SUPERVISOR))
            fail($sformatf("DBGRQ changed mode to %05b",
                           u_dut.u_core.cpsr.m));
        if (u_dut.u_core.u_regfile.regs[5] !== 32'h0000_0000)
            fail("target instruction executed before debug halt");
        if (u_dut.u_core.u_regfile.regs[6] !== 32'h0000_0000)
            fail("fallthrough instruction executed after PC modification");

        tck(1'b0, 1'b0);
        select_chain1();
        clock_out(DEBUG_STM_PC);
        clock_out(DEBUG_NOP);
        clock_out(DEBUG_NOP);
        clock_data_in(scanned_r15);

        expected_pc = (SCENARIO == MOV_PRE_SCENARIO)
                    ? TRIGGER_PC : TARGET_PC;
        corrected_pc = scanned_r15 - 32'd12 - 32'd8;
        if (corrected_pc !== expected_pc)
            fail($sformatf(
                "corrected PC expected %08x, got %08x (scanned r15=%08x)",
                expected_pc, corrected_pc, scanned_r15));

        done = 1'b1;
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, ADDR, WRITE, SIZE, PROT, LOCK, WDATA,
        CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI, DBGnEXEC,
        DBGINSTRVALID, DBGRNG, DBGCOMMTX, DBGCOMMRX, DBGnTDOEN, DMORE,
        DATA_ADDR};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
/* verilator lint_on DECLFILENAME */

module arm7tdmis_debug_pc_modify_dbgrq_tb;
    localparam int CYCLE_LIMIT = 2600;

    logic CLK = 1'b0;
    initial forever #5 CLK = ~CLK;

    logic [5:0] done;
    logic [5:0] failed;

    for (genvar i = 0; i < 6; i++) begin : g_scenario
        arm7tdmis_debug_pc_modify_dbgrq_scenario #(.SCENARIO(i)) u_scenario (
            .CLK,
            .done   (done[i]),
            .failed (failed[i])
        );
    end

    initial begin
        $dumpfile("debug_pc_modify_dbgrq.fst");
        $dumpvars(0, arm7tdmis_debug_pc_modify_dbgrq_tb);
        wait (&done);
        if (|failed)
            $fatal(1, "[debug_pc_modify_dbgrq] FAIL scenarios=%06b",
                   failed);
        $display("[debug_pc_modify_dbgrq] PASS");
        $finish;
    end

    initial begin
        repeat (CYCLE_LIMIT) @(posedge CLK);
        $fatal(1,
               "[debug_pc_modify_dbgrq] TIMEOUT done=%06b failed=%06b",
               done, failed);
    end
endmodule
