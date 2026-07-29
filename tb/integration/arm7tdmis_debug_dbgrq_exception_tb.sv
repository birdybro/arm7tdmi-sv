// DBG-001 / ARM7TDMI-S erratum [3] DBGRQ-with-exception regression.
//
// The official r4p3 errata conditions name Undefined, a bounced
// coprocessor instruction, Prefetch Abort, and Data Abort. A one-cycle
// synchronous DBGRQ coincident with each must retain the exception,
// commit its mode/LR/SPSR, fetch the first vector word, and only then
// assert DBGACK. Repeat the matrix with Debug Control[1]'s scan-created
// request. Load and store Data Aborts are separate scenarios.

`timescale 1ns/1ps

/* verilator lint_off DECLFILENAME */
module arm7tdmis_debug_dbgrq_exception_scenario #(
    parameter int unsigned SCENARIO = 0,
    parameter bit SCAN_REQUEST = 1'b0
) (
    input  logic CLK,
    output logic done,
    output logic failed
);
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_types_pkg::*;
    import arm7tdmis_debug_pkg::*;
    import arm7tdmis_jtag_tb_pkg::*;

    localparam int unsigned UNDEF_SCENARIO = 0;
    localparam int unsigned CP_SCENARIO    = 1;
    localparam int unsigned PABT_SCENARIO  = 2;
    localparam int unsigned LDR_SCENARIO   = 3;
    localparam int unsigned STR_SCENARIO   = 4;

    localparam logic [31:0] TRIGGER_PC = 32'h0000_0028;
    localparam logic [31:0] DATA_ADDR  = 32'h0000_0100;
    localparam logic [31:0] TRIGGER_INSTR =
        (SCENARIO == UNDEF_SCENARIO) ? 32'hE600_0010
      : (SCENARIO == CP_SCENARIO)    ? 32'hEE00_0700
      : (SCENARIO == PABT_SCENARIO)  ? 32'hE3A0_2022
      : (SCENARIO == LDR_SCENARIO)   ? 32'hE590_1000
                                     : 32'hE580_1000;
    localparam logic [31:0] EXCEPTION_VECTOR =
        ((SCENARIO == UNDEF_SCENARIO) || (SCENARIO == CP_SCENARIO))
        ? 32'h0000_0004
        : (SCENARIO == PABT_SCENARIO) ? 32'h0000_000C
                                      : 32'h0000_0010;
    localparam logic [4:0] EXPECTED_MODE =
        ((SCENARIO == UNDEF_SCENARIO) || (SCENARIO == CP_SCENARIO))
        ? 5'(MODE_UNDEFINED) : 5'(MODE_ABORT);
    localparam logic [31:0] EXPECTED_LR =
        ((SCENARIO == LDR_SCENARIO) || (SCENARIO == STR_SCENARIO))
        ? 32'h0000_0030 : 32'h0000_002C;

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

    logic inject_abort;
    arm7tdmis_memory #(
        .WORDS    (128),
        .INIT_HEX ("../tb/programs/debug_dbgrq_exception_test.hex")
    ) u_mem (
        .CLK,
        .CLKEN             (1'b1),
        .nRESET,
        .CFGBIGEND         (1'b0),
        .ADDR, .WRITE, .SIZE, .PROT, .LOCK, .TRANS, .WDATA, .RDATA,
        .ABORT,
        .inject_abort
    );

    wire trigger_exec = u_dut.u_core.executing
                      && (u_dut.u_core.de_q.pc == TRIGGER_PC);
    wire data_response = u_mem.is_active_q
                       && (u_mem.addr_q == DATA_ADDR);
    wire pabt_response = u_mem.is_active_q
                       && (u_mem.addr_q == TRIGGER_PC);

    always_comb begin
        inject_abort = 1'b0;
        DBGRQ        = 1'b0;
        if (SCENARIO == PABT_SCENARIO) begin
            inject_abort = pabt_response;
            DBGRQ        = !SCAN_REQUEST && trigger_exec;
        end else if ((SCENARIO == LDR_SCENARIO)
                     || (SCENARIO == STR_SCENARIO)) begin
            inject_abort = data_response;
            DBGRQ        = !SCAN_REQUEST && data_response;
        end else begin
            DBGRQ = !SCAN_REQUEST && trigger_exec;
        end
    end

    logic vector_seen;
    logic request_seen;
    always_ff @(posedge CLK) begin
        if (!nRESET) begin
            vector_seen  <= 1'b0;
            request_seen <= 1'b0;
        end else begin
            if (DBGRQ || u_dut.u_ice.ice_dbgrq_force_q)
                request_seen <= 1'b1;
            if (TRANS[1] && !PROT[0] && (ADDR == EXCEPTION_VECTOR))
                vector_seen <= 1'b1;
        end
    end

    task automatic fail(input string description);
        $display("[debug_dbgrq_exception/%0d/%s] FAIL %s",
                 SCENARIO, SCAN_REQUEST ? "scan" : "pin", description);
        failed = 1'b1;
    endtask

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

    // Commit force-DBGRQ without visiting Run-Test/Idle, then park in
    // Test-Logic-Reset. One later TCK edge enters RTI and opens the
    // force-request latch while the exception is being processed.
    task automatic arm_scan_request;
        logic [37:0] serial_in;
        select_chain2();
        serial_in = chain2_serial_in(1'b1, 5'h00, 32'h0000_0002);
        tck(1'b1, 1'b0);
        tck(1'b0, 1'b0);
        tck(1'b0, 1'b0);
        for (int i = 0; i < 38; i++)
            tck(i == 37, serial_in[i]);
        tck(1'b1, 1'b0); // Exit1-DR -> Update-DR
        tck(1'b1, 1'b0); // Update-DR -> Select-DR, commit
        tck(1'b1, 1'b0); // Select-DR -> Select-IR
        tck(1'b1, 1'b0); // Select-IR -> Test-Logic-Reset
    endtask

    initial begin : run
        bit halted;
        logic [4:0] lr_index;
        logic [2:0] spsr_index;

        done   = 1'b0;
        failed = 1'b0;

        @(posedge CLK);
        u_mem.mem[10] = TRIGGER_INSTR;
        u_mem.mem[64] = 32'hCAFE_BABE;

        repeat (3) @(posedge CLK);
        DBGnTRST = 1'b1;
        if (SCAN_REQUEST) begin
            tck(1'b0, 1'b0);
            arm_scan_request();
        end
        nRESET   = 1'b1;

        if (SCAN_REQUEST) fork
            begin : release_scan_request
                bit trigger_seen;
                trigger_seen = 1'b0;
                for (int i = 0; i < 180; i++) begin
                    @(negedge CLK);
                    if (((SCENARIO == LDR_SCENARIO)
                         || (SCENARIO == STR_SCENARIO))
                        ? data_response : trigger_exec) begin
                        trigger_seen = 1'b1;
                        break;
                    end
                end
                if (!trigger_seen) begin
                    fail("scan-request release condition was not observed");
                end else begin
                    // TLR -> RTI on the exception-taking edge. The force
                    // latch samples the programmed bit on the next CLK.
                    DBGTMS   = 1'b0;
                    DBGTDI   = 1'b0;
                    DBGTCKEN = 1'b1;
                    @(posedge CLK);
                    #1;
                    DBGTCKEN = 1'b0;
                end
            end
        join_none

        halted = 1'b0;
        for (int i = 0; i < 260; i++) begin
            @(posedge CLK);
            #1;
            if (DBGACK) begin
                halted = 1'b1;
                break;
            end
        end

        if (!halted)
            fail("debug request never entered debug state");
        if (!request_seen)
            fail("coincident debug request was never generated");
        if (!vector_seen)
            fail("exception vector was not fetched before DBGACK");
        if (u_dut.u_core.cpsr.m !== EXPECTED_MODE)
            fail($sformatf("mode expected %05b got %05b",
                           EXPECTED_MODE, u_dut.u_core.cpsr.m));
        if (TRANS !== 2'(TRANS_I))
            fail($sformatf("halted TRANS expected I got %02b", TRANS));
        if (u_dut.u_core.u_regfile.regs[8] !== 32'h0000_0000)
            fail("first vector instruction executed before debug halt");
        if (u_dut.u_core.u_regfile.regs[9] !== 32'h0000_0000)
            fail("instruction after exception source executed");

        lr_index = (EXPECTED_MODE == 5'(MODE_UNDEFINED)) ? 30 : 28;
        spsr_index = (EXPECTED_MODE == 5'(MODE_UNDEFINED)) ? 4 : 3;
        if (u_dut.u_core.u_regfile.regs[lr_index] !== EXPECTED_LR)
            fail($sformatf("exception LR expected %08x got %08x",
                           EXPECTED_LR,
                           u_dut.u_core.u_regfile.regs[lr_index]));
        if (u_dut.u_core.u_psr.spsr_q[spsr_index] !== 32'h0000_00D3)
            fail($sformatf("exception SPSR expected 000000d3 got %08x",
                           u_dut.u_core.u_psr.spsr_q[spsr_index]));

        if (SCENARIO == PABT_SCENARIO
            && u_dut.u_core.u_regfile.regs[2] !== 32'h0000_0000)
            fail("Prefetch-aborted instruction executed");
        if (SCENARIO == LDR_SCENARIO
            && u_dut.u_core.u_regfile.regs[1] !== 32'h0000_0055)
            fail("aborted LDR overwrote its destination");
        if (SCENARIO == STR_SCENARIO
            && u_mem.mem[64] !== 32'hCAFE_BABE)
            fail("aborted STR modified memory");

        done = 1'b1;
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, WRITE, SIZE, LOCK, WDATA, CPnMREQ, CPSEQ,
        CPnTRANS, CPnOPC, CPTBIT, CPnI, DBGnEXEC, DBGINSTRVALID, DBGRNG,
        DBGCOMMTX, DBGCOMMRX, DBGnTDOEN, DMORE, ignored_scan};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
/* verilator lint_on DECLFILENAME */

module arm7tdmis_debug_dbgrq_exception_tb;
    localparam int CYCLE_LIMIT = 1200;

    logic CLK = 1'b0;
    initial forever #5 CLK = ~CLK;

    logic [9:0] done;
    logic [9:0] failed;

    arm7tdmis_debug_dbgrq_exception_scenario #(
        .SCENARIO(0), .SCAN_REQUEST(1'b0)
    ) u_pin_undef (
        .CLK, .done(done[0]), .failed(failed[0])
    );
    arm7tdmis_debug_dbgrq_exception_scenario #(
        .SCENARIO(1), .SCAN_REQUEST(1'b0)
    ) u_pin_cp (
        .CLK, .done(done[1]), .failed(failed[1])
    );
    arm7tdmis_debug_dbgrq_exception_scenario #(
        .SCENARIO(2), .SCAN_REQUEST(1'b0)
    ) u_pin_pabt (
        .CLK, .done(done[2]), .failed(failed[2])
    );
    arm7tdmis_debug_dbgrq_exception_scenario #(
        .SCENARIO(3), .SCAN_REQUEST(1'b0)
    ) u_pin_ldr (
        .CLK, .done(done[3]), .failed(failed[3])
    );
    arm7tdmis_debug_dbgrq_exception_scenario #(
        .SCENARIO(4), .SCAN_REQUEST(1'b0)
    ) u_pin_str (
        .CLK, .done(done[4]), .failed(failed[4])
    );
    arm7tdmis_debug_dbgrq_exception_scenario #(
        .SCENARIO(0), .SCAN_REQUEST(1'b1)
    ) u_scan_undef (
        .CLK, .done(done[5]), .failed(failed[5])
    );
    arm7tdmis_debug_dbgrq_exception_scenario #(
        .SCENARIO(1), .SCAN_REQUEST(1'b1)
    ) u_scan_cp (
        .CLK, .done(done[6]), .failed(failed[6])
    );
    arm7tdmis_debug_dbgrq_exception_scenario #(
        .SCENARIO(2), .SCAN_REQUEST(1'b1)
    ) u_scan_pabt (
        .CLK, .done(done[7]), .failed(failed[7])
    );
    arm7tdmis_debug_dbgrq_exception_scenario #(
        .SCENARIO(3), .SCAN_REQUEST(1'b1)
    ) u_scan_ldr (
        .CLK, .done(done[8]), .failed(failed[8])
    );
    arm7tdmis_debug_dbgrq_exception_scenario #(
        .SCENARIO(4), .SCAN_REQUEST(1'b1)
    ) u_scan_str (
        .CLK, .done(done[9]), .failed(failed[9])
    );

    initial begin
        $dumpfile("debug_dbgrq_exception.fst");
        $dumpvars(0, arm7tdmis_debug_dbgrq_exception_tb);
        wait (&done);
        if (|failed)
            $fatal(1, "[debug_dbgrq_exception] FAIL scenarios=%010b",
                   failed);
        $display("[debug_dbgrq_exception] PASS");
        $finish;
    end

    initial begin
        repeat (CYCLE_LIMIT) @(posedge CLK);
        $fatal(1,
               "[debug_dbgrq_exception] TIMEOUT done=%010b failed=%010b",
               done, failed);
    end
endmodule
