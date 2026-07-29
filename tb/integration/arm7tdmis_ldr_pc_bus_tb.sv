// BUS-003/BUS-008/BUS-011: ARM LDR-to-PC raw-bus timing.
//
// TRM Table 7-11 gives the destination-PC form five Execute cycles.  With
// §7.1's pipelining applied to the raw output pins, they are:
//   data-address/N, pc+12/I, target/N, target+4/S, target+8/S.
// The returned data in those cycles is respectively the discarded pc+8
// opcode, loaded PC value, no transfer, target opcode, and target+4 opcode.
// Each row repeats the complete proof in Supervisor and User mode so both
// PROT[1] values are covered. LDR-to-PC is not available in Thumb state.

`timescale 1ns/1ps

module arm7tdmis_ldr_pc_bus_tb
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_types_pkg::*;
;

    localparam int ROW_COUNT = 2;
    localparam logic [31:0] TEST_PC      = 32'h0000_0030;
    localparam logic [31:0] DATA_ADDRESS = 32'h0000_0100;
    localparam logic [31:0] TARGET       = 32'h0000_0180;

    logic CLK;
    initial begin
        CLK = 1'b0;
        forever #5 CLK = ~CLK;
    end

    logic nRESET = 1'b0;
    logic [31:0] ADDR;
    logic        WRITE;
    logic [1:0]  SIZE;
    logic [1:0]  PROT;
    logic        LOCK;
    logic [1:0]  TRANS;
    logic [31:0] WDATA;
    logic [31:0] RDATA;
    logic        ABORT;

    logic CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI;
    logic DBGACK, DBGnEXEC, DBGINSTRVALID;
    logic [1:0] DBGRNG;
    logic DBGCOMMTX, DBGCOMMRX, DBGTDO, DBGnTDOEN, DMORE;

    arm7tdmis_top u_dut (
        .CLK, .CLKEN(1'b1), .nRESET, .CFGBIGEND(1'b0),
        .nIRQ(1'b1), .nFIQ(1'b1), .ABORT,
        .ADDR, .WRITE, .SIZE, .PROT, .LOCK, .TRANS, .WDATA, .RDATA,
        .CPnMREQ, .CPSEQ, .CPnTRANS, .CPnOPC, .CPTBIT, .CPnI,
        .CPA(1'b1), .CPB(1'b1),
        .DBGEN(1'b0), .DBGRQ(1'b0), .DBGBREAK(1'b0),
        .DBGACK, .DBGnEXEC, .DBGINSTRVALID, .DBGEXT(2'b00), .DBGRNG,
        .DBGCOMMTX, .DBGCOMMRX, .DBGTCKEN(1'b0), .DBGTMS(1'b0),
        .DBGTDI(1'b0), .DBGTDO, .DBGnTRST(1'b1), .DBGnTDOEN, .DMORE
    );

    arm7tdmis_memory #(
        .WORDS(256)
    ) u_mem (
        .CLK, .CLKEN(1'b1), .nRESET, .CFGBIGEND(1'b0),
        .ADDR, .WRITE, .SIZE, .PROT, .LOCK, .TRANS, .WDATA, .RDATA,
        .ABORT, .inject_abort(1'b0)
    );

    function automatic logic [4:0] row_mode(input int row);
        return row == 0 ? 5'(MODE_SUPERVISOR) : 5'(MODE_USER);
    endfunction

    function automatic logic [1:0] opcode_prot(input int row);
        return row == 0 ? 2'(PROT_OPC_PRIV) : 2'(PROT_OPC_USR);
    endfunction

    function automatic logic [1:0] data_prot(input int row);
        return row == 0 ? 2'(PROT_DAT_PRIV) : 2'(PROT_DAT_USR);
    endfunction

    function automatic string row_name(input int row);
        return row == 0 ? "Supervisor" : "User";
    endfunction

    task automatic fail(input int row, input string reason);
        $fatal(1, "[ldr_pc_bus] FAIL %s: %s", row_name(row), reason);
    endtask

    task automatic check_bus(
        input int          row,
        input string       phase,
        input logic [31:0] observed_addr,
        input logic        observed_write,
        input logic [1:0]  observed_size,
        input logic [1:0]  observed_prot,
        input logic        observed_lock,
        input logic [1:0]  observed_trans,
        input logic [31:0] expected_addr,
        input logic [1:0]  expected_prot,
        input logic [1:0]  expected_trans
    );
        if (observed_addr !== expected_addr
            || observed_write !== WRITE_READ
            || observed_size !== 2'(SIZE_WORD)
            || observed_prot !== expected_prot
            || observed_lock !== LOCK_FREE
            || observed_trans !== expected_trans)
            fail(row, $sformatf(
                "%s A/W/S/P/L/T=%08x/%0b/%02b/%02b/%0b/%02b expected %08x/0/10/%02b/0/%02b",
                phase, observed_addr, observed_write, observed_size,
                observed_prot, observed_lock, observed_trans,
                expected_addr, expected_prot, expected_trans));
    endtask

    task automatic setup_row(input int row);
        logic [7:0] control;

        for (int word = 0; word < 256; word++)
            u_mem.mem[word] = 32'hEAFF_FFFE;

        control = {3'b110, row_mode(row)};
        u_mem.mem[0]  = 32'hEA00_0006; // reset: B 0x20
        u_mem.mem[8]  = 32'hE59F_0058; // r0 <- [0x80] = DATA_ADDRESS
        u_mem.mem[9]  = 32'hE321_F000 | 32'(control); // select source mode
        u_mem.mem[10] = 32'hE1A0_0000; // drain mode change
        u_mem.mem[11] = 32'hE1A0_0000;
        u_mem.mem[12] = 32'hE590_F000; // TEST_PC: LDR pc,[r0]
        u_mem.mem[13] = 32'hE3A0_5055; // discarded successor
        u_mem.mem[14] = 32'hEAFF_FFFE;
        u_mem.mem[32] = DATA_ADDRESS;
        u_mem.mem[DATA_ADDRESS >> 2] = TARGET;
        u_mem.mem[TARGET >> 2] = 32'hE3A0_7001; // target marker
        u_mem.mem[(TARGET >> 2) + 1] = 32'hEAFF_FFFE;
    endtask

    task automatic run_row(input int row);
        int unsigned wait_cycles;

        @(negedge CLK);
        nRESET = 1'b0;
        repeat (4) @(posedge CLK);
        setup_row(row);
        @(negedge CLK);
        nRESET = 1'b1;

        wait_cycles = 0;
        while (!(u_dut.u_core.state_q == 5'd0
                 && u_dut.u_core.de_q.valid
                 && u_dut.u_core.de_q.pc == TEST_PC)) begin
            @(negedge CLK);
            wait_cycles++;
            if (wait_cycles > 100)
                fail(row, "LDR pc never reached Execute");
        end

        if (u_dut.u_core.cpsr.m !== row_mode(row)
            || u_dut.u_core.cpsr.t)
            fail(row, "source mode/state setup is wrong");

        check_bus(row, "data request",
                  ADDR, WRITE, SIZE, PROT, LOCK, TRANS,
                  DATA_ADDRESS, data_prot(row), 2'(TRANS_N));
        if (RDATA !== u_mem.mem[(TEST_PC + 32'd8) >> 2])
            fail(row, "discarded pc+8 opcode response is wrong");

        @(negedge CLK);
        if (u_dut.u_core.state_q !== 5'd1)
            fail(row, "data response did not use S_DDATA");
        check_bus(row, "load-response I phase",
                  ADDR, WRITE, SIZE, PROT, LOCK, TRANS,
                  TEST_PC + 32'd12, data_prot(row), 2'(TRANS_I));
        if (RDATA !== TARGET)
            fail(row, $sformatf(
                "data response expected %08x got %08x", TARGET, RDATA));

        @(negedge CLK);
        if (u_dut.u_core.state_q !== 5'd10
            || !u_dut.u_core.flush)
            fail(row, "LDR pc did not redirect from S_LOAD_WB");
        check_bus(row, "first target request",
                  ADDR, WRITE, SIZE, PROT, LOCK, TRANS,
                  TARGET, opcode_prot(row), 2'(TRANS_N));
        if (u_dut.u_core.flush_target_pc !== TARGET)
            fail(row, "redirect target is wrong");

        @(negedge CLK);
        check_bus(row, "following target request",
                  ADDR, WRITE, SIZE, PROT, LOCK, TRANS,
                  TARGET + 32'd4, opcode_prot(row), 2'(TRANS_S));
        if (RDATA !== u_mem.mem[TARGET >> 2])
            fail(row, "target opcode response is wrong");

        @(negedge CLK);
        check_bus(row, "second following target request",
                  ADDR, WRITE, SIZE, PROT, LOCK, TRANS,
                  TARGET + 32'd8, opcode_prot(row), 2'(TRANS_S));
        if (RDATA !== u_mem.mem[(TARGET >> 2) + 1])
            fail(row, "target+4 opcode response is wrong");

        repeat (12) @(negedge CLK);
        if (u_dut.u_core.u_regfile.regs[7] !== 32'h0000_0001)
            fail(row, "target marker did not retire");
        if (u_dut.u_core.u_regfile.regs[5] !== 32'h0000_0000)
            fail(row, "discarded successor retired");
    endtask

    initial begin
        for (int row = 0; row < ROW_COUNT; row++)
            run_row(row);
        $display("[ldr_pc_bus] PASS (%0d mode rows)", ROW_COUNT);
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "[ldr_pc_bus] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, WDATA, ABORT, CPnMREQ, CPSEQ, CPnTRANS,
        CPnOPC, CPTBIT, CPnI, DBGACK, DBGnEXEC, DBGINSTRVALID,
        DBGRNG, DBGCOMMTX, DBGCOMMRX, DBGTDO, DBGnTDOEN, DMORE};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
