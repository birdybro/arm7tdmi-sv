// ERR-001 / ARM7TDMI-S erratum [5] corrected-behavior regression.
//
// Each official example of a non-branching multicycle predecessor is
// followed by two independently breakpointed instructions:
//   register-controlled shift, multiply, load, and store.
// The predecessor must finish, each breakpoint must halt before its own
// effect, and two disable/RESTART operations must resume at the exact PCs.

`timescale 1ns/1ps

/* verilator lint_off DECLFILENAME */
module arm7tdmis_debug_multicycle_breakpoints_scenario #(
    parameter int unsigned KIND = 0
) (
    input  logic CLK,
    output logic done,
    output logic failed
);
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_debug_pkg::*;
    import arm7tdmis_jtag_tb_pkg::*;

    localparam int unsigned KIND_SHIFT = 0;
    localparam int unsigned KIND_MUL   = 1;
    localparam int unsigned KIND_LOAD  = 2;
    localparam int unsigned KIND_STORE = 3;
    localparam logic [31:0] TEST_OPCODE =
        (KIND == KIND_SHIFT) ? 32'hE1A0_3211 // MOV r3,r1,LSL r2
      : (KIND == KIND_MUL)   ? 32'hE003_0291 // MUL r3,r1,r2
      : (KIND == KIND_LOAD)  ? 32'hE590_3000 // LDR r3,[r0]
                              : 32'hE580_3000;// STR r3,[r0]

    logic nRESET = 1'b0;
    logic CLKEN = 1'b0;
    logic DBGTCKEN = 1'b0;
    logic DBGTMS = 1'b1;
    logic DBGTDI = 1'b0;
    logic DBGnTRST = 1'b0;

    logic [31:0] ADDR, WDATA, RDATA;
    logic WRITE, LOCK, ABORT;
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

    arm7tdmis_memory #(
        .WORDS (128)
    ) u_mem (
        .CLK,
        .CLKEN,
        .nRESET,
        .CFGBIGEND        (1'b0),
        .ADDR, .WRITE, .SIZE, .PROT, .LOCK, .TRANS, .WDATA, .RDATA,
        .ABORT,
        .inject_abort     (1'b0)
    );

    initial begin : initialize_program
        for (int i = 0; i < 128; i++)
            u_mem.mem[i] = 32'hE1A0_0000;
        u_mem.mem[0]  = 32'hEA00_0006; // Reset: B 0x20
        u_mem.mem[8]  = 32'hE3A0_0C01; // MOV r0,#0x100
        u_mem.mem[9]  = 32'hE3A0_1003; // MOV r1,#3
        u_mem.mem[10] = 32'hE3A0_2002; // MOV r2,#2
        u_mem.mem[11] = 32'hE3A0_3033; // MOV r3,#0x33
        u_mem.mem[12] = TEST_OPCODE;   // 0x30 multicycle predecessor
        u_mem.mem[13] = 32'hE284_4001; // 0x34 breakpoint 1
        u_mem.mem[14] = 32'hE285_5001; // 0x38 breakpoint 2
        u_mem.mem[15] = 32'hE3A0_6066; // completion marker
        u_mem.mem[16] = 32'hEAFF_FFFE;
        u_mem.mem[64] = 32'hCAFE_BABE;
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

    task automatic program_breakpoint(
        input bit wp1,
        input logic [31:0] address
    );
        logic [4:0] base;
        base = wp1 ? 5'h10 : 5'h08;
        write_ice(base + 5'd0, address);
        write_ice(base + 5'd1, 32'h0000_0003);
        write_ice(base + 5'd2, 32'h0000_0000);
        write_ice(base + 5'd3, 32'hFFFF_FFFF);
        write_ice(base + 5'd4, 32'h0000_0114);
        write_ice(base + 5'd5, 32'h0000_00E0);
    endtask

    bit multicycle_seen;
    bit wp0_seen;
    bit wp1_seen;
    always_ff @(posedge CLK) begin
        if (!nRESET) begin
            multicycle_seen <= 1'b0;
            wp0_seen        <= 1'b0;
            wp1_seen        <= 1'b0;
        end else begin
            if ((KIND == KIND_SHIFT && u_dut.u_core.state_q == 5'd9)
                || (KIND == KIND_MUL && u_dut.u_core.state_q == 5'd6)
                || (KIND == KIND_LOAD
                    && u_dut.u_core.state_q inside {5'd1, 5'd10})
                || (KIND == KIND_STORE && u_dut.u_core.state_q == 5'd1))
                multicycle_seen <= 1'b1;
            if (DBGRNG[0])
                wp0_seen <= 1'b1;
            if (DBGRNG[1])
                wp1_seen <= 1'b1;
        end
    end

    int unsigned errors;
    string kind_name;
    task automatic fail(input string description);
        $display("[debug_multicycle_breakpoints/%s] FAIL %s",
                 kind_name, description);
        errors++;
    endtask

    initial begin : run_test
        bit first_halt;
        bit second_halt;
        bit completed;
        logic [31:0] expected_r3;

        done   = 1'b0;
        failed = 1'b0;
        errors = 0;
        kind_name = (KIND == KIND_SHIFT) ? "shift"
                  : (KIND == KIND_MUL) ? "multiply"
                  : (KIND == KIND_LOAD) ? "load" : "store";
        expected_r3 = (KIND == KIND_SHIFT) ? 32'd12
                    : (KIND == KIND_MUL) ? 32'd6
                    : (KIND == KIND_LOAD) ? 32'hCAFE_BABE
                                          : 32'h0000_0033;

        repeat (4) @(posedge CLK);
        nRESET = 1'b1;
        repeat (2) @(posedge CLK);
        DBGnTRST = 1'b1;
        tck(1'b0, 1'b0);
        select_chain2();
        program_breakpoint(1'b0, 32'h0000_0034);
        program_breakpoint(1'b1, 32'h0000_0038);

        CLKEN = 1'b1;
        first_halt = 1'b0;
        for (int i = 0; i < 260; i++) begin
            @(posedge CLK);
            #1;
            if (DBGACK) begin
                first_halt = 1'b1;
                break;
            end
        end
        if (!first_halt || u_dut.u_core.de_q.pc !== 32'h0000_0034)
            fail($sformatf("first halt/PC=%0b/%08x",
                           first_halt, u_dut.u_core.de_q.pc));
        if (!multicycle_seen)
            fail("predecessor did not enter its multicycle state");
        if (!wp0_seen)
            fail("first breakpoint comparator never matched");
        if (u_dut.u_core.u_regfile.regs[3] !== expected_r3)
            fail($sformatf("predecessor result expected %08x got %08x",
                           expected_r3,
                           u_dut.u_core.u_regfile.regs[3]));
        if (KIND == KIND_STORE && u_mem.mem[64] !== 32'h0000_0033)
            fail("multicycle store did not complete before breakpoint");
        if (u_dut.u_core.u_regfile.regs[4] !== 32'h0
            || u_dut.u_core.u_regfile.regs[5] !== 32'h0)
            fail("breakpointed instruction executed before first halt");

        write_ice(5'h0C, 32'h0000_0014);
        load_ir(4'(IR_RESTART));
        second_halt = 1'b0;
        for (int i = 0; i < 180; i++) begin
            @(posedge CLK);
            #1;
            if (DBGACK) begin
                second_halt = 1'b1;
                break;
            end
        end
        if (!second_halt || u_dut.u_core.de_q.pc !== 32'h0000_0038)
            fail($sformatf("second halt/PC=%0b/%08x",
                           second_halt, u_dut.u_core.de_q.pc));
        if (!wp1_seen)
            fail("second breakpoint comparator never matched");
        if (u_dut.u_core.u_regfile.regs[4] !== 32'h1
            || u_dut.u_core.u_regfile.regs[5] !== 32'h0)
            fail($sformatf("first/second effects=%08x/%08x expected 1/0",
                           u_dut.u_core.u_regfile.regs[4],
                           u_dut.u_core.u_regfile.regs[5]));

        write_ice(5'h14, 32'h0000_0014);
        load_ir(4'(IR_RESTART));
        completed = 1'b0;
        for (int i = 0; i < 140; i++) begin
            @(posedge CLK);
            if (u_dut.u_core.u_regfile.regs[6] == 32'h66) begin
                completed = 1'b1;
                break;
            end
        end
        if (!completed)
            fail("second RESTART did not reach completion marker");
        if (u_dut.u_core.u_regfile.regs[4] !== 32'h1
            || u_dut.u_core.u_regfile.regs[5] !== 32'h1)
            fail($sformatf("final breakpoint effects=%08x/%08x expected 1/1",
                           u_dut.u_core.u_regfile.regs[4],
                           u_dut.u_core.u_regfile.regs[5]));

        failed = (errors != 0);
        done   = 1'b1;
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, ADDR, WRITE, SIZE, PROT, LOCK, TRANS, WDATA,
        CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI, DBGnEXEC,
        DBGINSTRVALID, DBGCOMMTX, DBGCOMMRX, DBGnTDOEN, DMORE,
        ignored_scan};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
/* verilator lint_on DECLFILENAME */

module arm7tdmis_debug_multicycle_breakpoints_tb;
    logic CLK;
    logic [3:0] done;
    logic [3:0] failed;

    initial begin
        CLK = 1'b0;
        forever #5 CLK = ~CLK;
    end

    arm7tdmis_debug_multicycle_breakpoints_scenario #(
        .KIND (0)
    ) u_shift (.CLK, .done(done[0]), .failed(failed[0]));
    arm7tdmis_debug_multicycle_breakpoints_scenario #(
        .KIND (1)
    ) u_multiply (.CLK, .done(done[1]), .failed(failed[1]));
    arm7tdmis_debug_multicycle_breakpoints_scenario #(
        .KIND (2)
    ) u_load (.CLK, .done(done[2]), .failed(failed[2]));
    arm7tdmis_debug_multicycle_breakpoints_scenario #(
        .KIND (3)
    ) u_store (.CLK, .done(done[3]), .failed(failed[3]));

    initial begin
        $dumpfile("debug_multicycle_breakpoints.fst");
        $dumpvars(0, arm7tdmis_debug_multicycle_breakpoints_tb);
        wait (&done);
        if (|failed)
            $fatal(1, "[debug_multicycle_breakpoints] FAIL scenarios=%04b",
                   failed);
        $display("[debug_multicycle_breakpoints] PASS");
        $finish;
    end

    initial begin
        repeat (2800) @(posedge CLK);
        $fatal(1, "[debug_multicycle_breakpoints] TIMEOUT");
    end
endmodule
