// ERR-001 / ARM7TDMI-S erratum [1] corrected-behavior regression.
//
// A single EmbeddedICE-RT comparator must recognize consecutive matches:
//   0. ARM B pc+8 fetches its breakpointed target twice;
//   1. Thumb B pc+4 fetches its breakpointed target twice;
//   2. an address-ignored opcode comparator sees the same software-
//      breakpoint pattern two instructions after a branch and at its target.
//
// The discarded first match must not enter debug.  The architecturally
// executed target must halt before its effect, then execute exactly once
// after the comparator is disabled and RESTART is scanned.

`timescale 1ns/1ps

/* verilator lint_off DECLFILENAME */
module arm7tdmis_debug_consecutive_breakpoints_scenario #(
    parameter int unsigned SCENARIO = 0
) (
    input  logic CLK,
    output logic done,
    output logic failed
);
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_debug_pkg::*;
    import arm7tdmis_jtag_tb_pkg::*;

    localparam int unsigned ARM_TARGET   = 0;
    localparam int unsigned THUMB_TARGET = 1;
    localparam int unsigned SOFT_PATTERN = 2;
    localparam logic [31:0] SOFT_OPCODE = 32'hE7F1_23F4;

    logic nRESET = 1'b0;
    logic CLKEN = 1'b0;
    logic DBGTCKEN = 1'b0;
    logic DBGTMS = 1'b1;
    logic DBGTDI = 1'b0;
    logic DBGnTRST = 1'b0;

    logic [31:0] ADDR, WDATA, RDATA;
    logic WRITE, LOCK;
    logic [1:0] SIZE, PROT, TRANS;
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
        .ABORT            (1'b0),
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

    logic [31:0] mem [0:31];
    logic [31:0] mem_addr_q;
    logic        mem_active_q;

    always_ff @(posedge CLK) begin
        if (!nRESET) begin
            mem_addr_q   <= 32'h0;
            mem_active_q <= 1'b0;
        end else if (CLKEN) begin
            mem_addr_q   <= ADDR;
            mem_active_q <= TRANS inside {2'(TRANS_N), 2'(TRANS_S)};
        end
    end
    assign RDATA = mem_active_q ? mem[mem_addr_q[6:2]] : 32'h0;

    initial begin : initialize_program
        for (int i = 0; i < 32; i++)
            mem[i] = 32'hE1A0_0000; // ARM NOP
        mem[0] = 32'hEA00_0006;     // Reset: B 0x20

        unique case (SCENARIO)
            ARM_TARGET: begin
                mem[8]  = 32'hEA00_0000; // 0x20 B 0x28 (pc+8)
                mem[9]  = 32'hE3A0_7007; // discarded
                mem[10] = 32'hE281_1001; // target: ADD r1,r1,#1
                mem[11] = 32'hE3A0_2022; // completion marker
                mem[12] = 32'hEAFF_FFFE;
            end
            THUMB_TARGET: begin
                mem[8]  = 32'hE3A0_0041; // MOV r0,#0x41
                mem[9]  = 32'hE12F_FF10; // BX r0
                mem[16] = 32'h2707_E000; // 0x40 B 0x44; discarded MOVS
                mem[17] = 32'h2222_3101; // target ADDS r1,#1; MOVS r2,#0x22
                mem[18] = 32'hE7FE_E7FE;
            end
            default: begin
                mem[8]  = 32'hEA00_0002; // 0x20 B 0x30
                mem[9]  = 32'hE1A0_0000; // first shadow
                mem[10] = SOFT_OPCODE;   // second shadow: discarded match
                mem[11] = 32'hE1A0_0000;
                mem[12] = SOFT_OPCODE;   // target: executed match
                mem[13] = 32'hE3A0_2022; // completion marker
                mem[14] = 32'hEAFF_FFFE;
            end
        endcase
    end

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

    task automatic select_chain2;
        load_ir(4'(IR_SCAN_N));
        shift_dr(4, 38'd2);
        load_ir(4'(IR_INTEST));
    endtask

    task automatic write_ice(
        input logic [4:0] address,
        input logic [31:0] data
    );
        shift_dr(38, chain2_serial_in(1'b1, address, data));
    endtask

    task automatic program_comparator;
        logic [31:0] target;
        target = (SCENARIO == ARM_TARGET) ? 32'h0000_0028
               : (SCENARIO == THUMB_TARGET) ? 32'h0000_0044
                                             : 32'h0000_0000;
        write_ice(5'h08, target);
        write_ice(5'h09, (SCENARIO == SOFT_PATTERN) ? 32'hFFFF_FFFF
                          : (SCENARIO == THUMB_TARGET) ? 32'h0000_0001
                                                       : 32'h0000_0003);
        write_ice(5'h0A, (SCENARIO == SOFT_PATTERN)
                          ? SOFT_OPCODE : 32'h0000_0000);
        write_ice(5'h0B, (SCENARIO == SOFT_PATTERN)
                          ? 32'h0000_0000 : 32'hFFFF_FFFF);
        write_ice(5'h0C, (SCENARIO == THUMB_TARGET)
                          ? 32'h0000_0112 : 32'h0000_0114);
        write_ice(5'h0D, 32'h0000_00E0);
    endtask

    bit previous_match;
    bit consecutive_match;
    int unsigned match_count;
    always_ff @(posedge CLK) begin
        if (!nRESET) begin
            previous_match   <= 1'b0;
            consecutive_match <= 1'b0;
            match_count      <= 0;
        end else begin
            if (DBGRNG[0]) begin
                match_count <= match_count + 1;
                if (previous_match)
                    consecutive_match <= 1'b1;
            end
            previous_match <= DBGRNG[0];
        end
    end

    int unsigned errors;
    task automatic fail(input string description);
        $display("[debug_consecutive_breakpoints/%0d] FAIL %s",
                 SCENARIO, description);
        errors++;
    endtask

    initial begin : run_test
        bit halted;
        bit completed;
        logic [31:0] expected_pc;

        done   = 1'b0;
        failed = 1'b0;
        errors = 0;
        expected_pc = (SCENARIO == ARM_TARGET) ? 32'h0000_0028
                    : (SCENARIO == THUMB_TARGET) ? 32'h0000_0044
                                                  : 32'h0000_0030;

        repeat (4) @(posedge CLK);
        nRESET = 1'b1;
        repeat (2) @(posedge CLK);
        DBGnTRST = 1'b1;
        tck(1'b0, 1'b0);
        select_chain2();
        program_comparator();

        CLKEN = 1'b1;
        halted = 1'b0;
        for (int i = 0; i < 220; i++) begin
            @(posedge CLK);
            if (DBGACK) begin
                #1;
                halted = 1'b1;
                break;
            end
        end

        if (!halted)
            fail("architectural target did not enter debug");
        if (u_dut.u_core.de_q.pc !== expected_pc)
            fail($sformatf("halt PC=%08x expected=%08x",
                           u_dut.u_core.de_q.pc, expected_pc));
        if (u_dut.u_core.u_regfile.regs[1] !== 32'h0)
            fail("target executed before debug entry");
        if (u_dut.u_core.u_regfile.regs[2] !== 32'h0)
            fail("successor executed before debug entry");
        if (match_count < 2)
            fail($sformatf("comparator matched only %0d time(s)", match_count));
        if (!consecutive_match)
            fail("comparator did not report back-to-back matches");

        // A debugger restores a software breakpoint's original opcode.
        if (SCENARIO == SOFT_PATTERN)
            mem[12] = 32'hE281_1001; // ADD r1,r1,#1

        write_ice(5'h0C, 32'h0000_0014); // disable WP0
        load_ir(4'(IR_RESTART));

        completed = 1'b0;
        for (int i = 0; i < 140; i++) begin
            @(posedge CLK);
            if (u_dut.u_core.u_regfile.regs[2] == 32'h22) begin
                completed = 1'b1;
                break;
            end
        end
        if (!completed)
            fail($sformatf(
                "RESTART did not complete r1/r2/pc/fd/de=%08x/%08x/%08x/%08x/%08x",
                u_dut.u_core.u_regfile.regs[1],
                u_dut.u_core.u_regfile.regs[2],
                u_dut.u_core.fetch_pc_q, u_dut.u_core.fd_q.pc,
                u_dut.u_core.de_q.pc));
        if (u_dut.u_core.u_regfile.regs[1] !== 32'h1)
            fail($sformatf("target executed %0d times",
                           u_dut.u_core.u_regfile.regs[1]));

        failed = (errors != 0);
        done   = 1'b1;
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, mem_addr_q[31:7], mem_addr_q[1:0],
        WRITE, SIZE, PROT, LOCK, WDATA, CPnMREQ, CPSEQ,
        CPnTRANS, CPnOPC, CPTBIT, CPnI, DBGnEXEC, DBGINSTRVALID, DBGRNG[1],
        DBGCOMMTX, DBGCOMMRX, DBGnTDOEN, DMORE, ignored_scan};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
/* verilator lint_on DECLFILENAME */

module arm7tdmis_debug_consecutive_breakpoints_tb;
    logic CLK;
    logic [2:0] done;
    logic [2:0] failed;

    initial begin
        CLK = 1'b0;
        forever #5 CLK = ~CLK;
    end

    arm7tdmis_debug_consecutive_breakpoints_scenario #(
        .SCENARIO (0)
    ) u_arm (.CLK, .done(done[0]), .failed(failed[0]));

    arm7tdmis_debug_consecutive_breakpoints_scenario #(
        .SCENARIO (1)
    ) u_thumb (.CLK, .done(done[1]), .failed(failed[1]));

    arm7tdmis_debug_consecutive_breakpoints_scenario #(
        .SCENARIO (2)
    ) u_soft (.CLK, .done(done[2]), .failed(failed[2]));

    initial begin
        $dumpfile("debug_consecutive_breakpoints.fst");
        $dumpvars(0, arm7tdmis_debug_consecutive_breakpoints_tb);
        wait (&done);
        if (|failed)
            $fatal(1, "[debug_consecutive_breakpoints] FAIL scenarios=%03b",
                   failed);
        $display("[debug_consecutive_breakpoints] PASS");
        $finish;
    end

    initial begin
        repeat (1800) @(posedge CLK);
        $fatal(1, "[debug_consecutive_breakpoints] TIMEOUT");
    end
endmodule
