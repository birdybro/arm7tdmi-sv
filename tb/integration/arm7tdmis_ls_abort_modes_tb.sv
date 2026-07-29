// EXC-006 regression: an aborting single LDR/STR retains every requested
// base modification, suppresses the load destination and subsequent
// instruction, and does not commit an aborted store. One resettable DUT
// runs the complete word-transfer P/U/W/L matrix:
//   LDR/STR x pre/post x up/down x no-WB/WB-or-translated.

`timescale 1ns/1ps

module arm7tdmis_ls_abort_modes_tb
    import arm7tdmis_bus_pkg::*;
;

    localparam int    CYCLE_LIMIT = 2400;
    localparam string INIT_HEX =
        "../tb/programs/ls_abort_modes_test.hex";

    logic CLK;
    initial begin
        CLK = 1'b0;
        forever #5 CLK = ~CLK;
    end

    logic nRESET;
    logic CFGBIGEND = 1'b0;
    logic CLKEN     = 1'b1;
    logic nIRQ      = 1'b1;
    logic nFIQ      = 1'b1;
    logic inject_abort;
    logic ABORT;

    logic [31:0] ADDR;
    logic        WRITE;
    logic [1:0]  SIZE;
    logic [1:0]  PROT;
    logic        LOCK;
    logic [1:0]  TRANS;
    logic [31:0] WDATA;
    logic [31:0] RDATA;

    logic CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI;
    logic DBGACK, DBGnEXEC, DBGINSTRVALID;
    logic [1:0] DBGRNG;
    logic DBGCOMMTX, DBGCOMMRX, DBGTDO, DBGnTDOEN, DMORE;

    arm7tdmis_top u_dut (
        .CLK(CLK), .CLKEN(CLKEN), .nRESET(nRESET),
        .CFGBIGEND(CFGBIGEND), .nIRQ(nIRQ), .nFIQ(nFIQ),
        .ABORT(ABORT),
        .ADDR(ADDR), .WRITE(WRITE), .SIZE(SIZE), .PROT(PROT),
        .LOCK(LOCK), .TRANS(TRANS), .WDATA(WDATA), .RDATA(RDATA),
        .CPnMREQ(CPnMREQ), .CPSEQ(CPSEQ), .CPnTRANS(CPnTRANS),
        .CPnOPC(CPnOPC), .CPTBIT(CPTBIT), .CPnI(CPnI),
        .CPA(1'b1), .CPB(1'b1),
        .DBGEN(1'b0), .DBGRQ(1'b0), .DBGBREAK(1'b0),
        .DBGACK(DBGACK), .DBGnEXEC(DBGnEXEC),
        .DBGINSTRVALID(DBGINSTRVALID), .DBGEXT(2'b00),
        .DBGRNG(DBGRNG), .DBGCOMMTX(DBGCOMMTX),
        .DBGCOMMRX(DBGCOMMRX), .DBGTCKEN(1'b0),
        .DBGTMS(1'b0), .DBGTDI(1'b0), .DBGTDO(DBGTDO),
        .DBGnTRST(1'b1), .DBGnTDOEN(DBGnTDOEN), .DMORE(DMORE)
    );

    arm7tdmis_memory #(
        .WORDS(4096),
        .INIT_HEX(INIT_HEX)
    ) u_mem (
        .CLK(CLK), .CLKEN(CLKEN), .nRESET(nRESET),
        .CFGBIGEND(CFGBIGEND),
        .ADDR(ADDR), .WRITE(WRITE), .SIZE(SIZE), .PROT(PROT),
        .LOCK(LOCK), .TRANS(TRANS), .WDATA(WDATA), .RDATA(RDATA),
        .ABORT(ABORT), .inject_abort(inject_abort)
    );

    // S_DDATA is the response cycle for the one transfer under test.
    assign inject_abort = (u_dut.u_core.state_q == 5'd1);

    function automatic logic [31:0] ls_opcode(
        input logic load,
        input logic pre,
        input logic up,
        input logic writeback
    );
        return {4'hE, 2'b01, 1'b0, pre, up, 1'b0, writeback, load,
                4'd4, 4'd1, 12'd4};
    endfunction

    int unsigned errors = 0;
    int unsigned cases_run = 0;

    task automatic run_case(
        input logic load,
        input logic pre,
        input logic up,
        input logic writeback
    );
        logic [31:0] expected_base;
        logic        modifies_base;
        string       kind;
        string       index_kind;
        string       direction;
        string       wb_kind;

        kind         = load ? "LDR" : "STR";
        index_kind   = pre ? "pre" : "post";
        direction    = up ? "up" : "down";
        wb_kind      = pre ? (writeback ? "wb" : "no-wb")
                           : (writeback ? "translated" : "normal");
        modifies_base = !pre || writeback;
        expected_base = modifies_base
                      ? (up ? 32'h00000104 : 32'h000000FC)
                      : 32'h00000100;

        // Reset between rows so every case begins from the same complete
        // architectural and memory state. Patch only the instruction slot.
        @(negedge CLK);
        nRESET = 1'b0;
        repeat (4) @(posedge CLK);
        u_mem.mem[11] = ls_opcode(load, pre, up, writeback);
        u_mem.mem[64] = 32'hCAFE_BABE;
        @(negedge CLK);
        nRESET = 1'b1;

        repeat (105) @(posedge CLK);
        cases_run = cases_run + 1;

        if (u_dut.u_core.u_regfile.regs[4] !== expected_base) begin
            $display("[ls_abort_modes] FAIL %s %s %s %s: r4 expected %08x got %08x",
                     kind, index_kind, direction, wb_kind, expected_base,
                     u_dut.u_core.u_regfile.regs[4]);
            errors = errors + 1;
        end
        if (u_dut.u_core.u_regfile.regs[1] !== 32'h00000055) begin
            $display("[ls_abort_modes] FAIL %s %s %s %s: r1 changed to %08x",
                     kind, index_kind, direction, wb_kind,
                     u_dut.u_core.u_regfile.regs[1]);
            errors = errors + 1;
        end
        if (u_mem.mem[64] !== 32'hCAFE_BABE) begin
            $display("[ls_abort_modes] FAIL %s %s %s %s: aborted store changed memory to %08x",
                     kind, index_kind, direction, wb_kind, u_mem.mem[64]);
            errors = errors + 1;
        end
        if (u_dut.u_core.u_regfile.regs[8] !== 32'h0
            || u_dut.u_core.u_regfile.regs[9] !== 32'h000000EE) begin
            $display("[ls_abort_modes] FAIL %s %s %s %s: flow markers r8=%08x r9=%08x",
                     kind, index_kind, direction, wb_kind,
                     u_dut.u_core.u_regfile.regs[8],
                     u_dut.u_core.u_regfile.regs[9]);
            errors = errors + 1;
        end
        if (u_dut.u_core.u_regfile.regs[28] !== 32'h00000034
            || u_dut.u_core.cpsr.m !== 5'b10111
            || u_dut.u_core.pc_q !== 32'h00000054) begin
            $display("[ls_abort_modes] FAIL %s %s %s %s: lr=%08x mode=%05b pc=%08x",
                     kind, index_kind, direction, wb_kind,
                     u_dut.u_core.u_regfile.regs[28],
                     u_dut.u_core.cpsr.m, u_dut.u_core.pc_q);
            errors = errors + 1;
        end
    endtask

    initial begin
        nRESET = 1'b0;
        $dumpfile("ls_abort_modes.fst");
        $dumpvars(0, arm7tdmis_ls_abort_modes_tb);

        for (int load = 0; load < 2; load++) begin
            for (int pre = 0; pre < 2; pre++) begin
                for (int up = 0; up < 2; up++) begin
                    for (int wb = 0; wb < 2; wb++)
                        run_case(load[0], pre[0], up[0], wb[0]);
                end
            end
        end

        if (cases_run != 16 || errors != 0)
            $fatal(1, "[ls_abort_modes] FAIL (%0d cases, %0d errors)",
                   cases_run, errors);
        $display("[ls_abort_modes] PASS (all 16 P/U/W/L abort cases)");
        $finish;
    end

    initial begin
        repeat (CYCLE_LIMIT) @(posedge CLK);
        $fatal(1, "[ls_abort_modes] TIMEOUT after %0d cycles", CYCLE_LIMIT);
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT,
        CPnI, DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG, DBGCOMMTX,
        DBGCOMMRX, DBGTDO, DBGnTDOEN, DMORE};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
