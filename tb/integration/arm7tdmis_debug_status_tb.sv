// DBG-002 public-interface regression for the EmbeddedICE-RT Debug Status
// register. TRM §5.25 defines bit 3 as the live core TRANS[1] signal, not
// the privilege qualifier PROT[1].
//
// The test reads status through the real TAP and 38-bit scan chain 2 in two
// deliberately discriminating states:
//   1. a CLKEN-stalled active memory request, where TRANS[1] is HIGH;
//   2. debug halt, where TRANS is I (00) but PROT[1] remains privileged.
//
// Both reads must report the public TRANS[1] value and the full scan response
// must carry the requested EmbeddedICE-RT register address.

`timescale 1ns/1ps

module arm7tdmis_debug_status_tb
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_debug_pkg::*;
    import arm7tdmis_jtag_tb_pkg::*;
;

    localparam int CYCLE_LIMIT = 1200;

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
    logic ABORT;
    logic DBGRQ = 1'b0;
    logic DBGTCKEN = 1'b0;
    logic DBGTMS = 1'b1;
    logic DBGTDI = 1'b0;
    logic DBGnTRST = 1'b0;

    logic [31:0] ADDR;
    logic        WRITE;
    logic [1:0]  SIZE;
    logic [1:0]  PROT;
    logic        LOCK;
    logic [1:0]  TRANS;
    logic [31:0] WDATA, RDATA;
    logic        CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI;
    logic        DBGACK, DBGnEXEC, DBGINSTRVALID;
    logic [1:0]  DBGRNG;
    logic        DBGCOMMTX, DBGCOMMRX, DBGTDO, DBGnTDOEN, DMORE;

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
        .WORDS    (128),
        .INIT_HEX ("../tb/programs/debug_status_test.hex")
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

    // All transfers begin and end in Run-Test/Idle.
    task automatic load_ir(input logic [3:0] instruction);
        tck(1'b1, 1'b0); // RTI -> Select-DR
        tck(1'b1, 1'b0); // Select-DR -> Select-IR
        tck(1'b0, 1'b0); // Select-IR -> Capture-IR
        tck(1'b0, 1'b0); // Capture-IR -> Shift-IR
        for (int i = 0; i < 4; i++)
            tck(i == 3, instruction[i]);
        tck(1'b1, 1'b0); // Exit1-IR -> Update-IR
        tck(1'b0, 1'b0); // Update-IR -> RTI
    endtask

    task automatic shift_dr(
        input  int unsigned width,
        input  logic [37:0] scan_in,
        output logic [37:0] scan_out
    );
        scan_out = '0;
        tck(1'b1, 1'b0); // RTI -> Select-DR
        tck(1'b0, 1'b0); // Select-DR -> Capture-DR
        tck(1'b0, 1'b0); // Capture-DR -> Shift-DR
        for (int i = 0; i < width; i++) begin
            scan_out[i] = DBGTDO;
            tck(i == (width - 1), scan_in[i]);
        end
        tck(1'b1, 1'b0); // Exit1-DR -> Update-DR
        tck(1'b0, 1'b0); // Update-DR -> RTI
    endtask

    task automatic select_chain2;
        load_ir(4'(IR_SCAN_N));
        shift_dr(4, 38'd2, ignored_scan);
        load_ir(4'(IR_INTEST));
    endtask

    task automatic chain2_request(
        input  logic [4:0] addr,
        output logic [37:0] scan_result
    );
        logic [37:0] serial_result;
        shift_dr(38, chain2_serial_in(1'b0, addr, 32'h0),
                 serial_result);
        scan_result = chain2_parallel_out(serial_result);
    endtask

    task automatic read_debug_status(output logic [37:0] response);
        chain2_request(5'h01, ignored_scan);
        chain2_request(5'h01, response);
    endtask

    int unsigned errors = 0;
    logic [37:0] active_status;
    logic [37:0] halted_status;
    bit found_active;
    bit found_halt;

    initial begin : run_test
        $dumpfile("debug_status.fst");
        $dumpvars(0, arm7tdmis_debug_status_tb);

        repeat (2) @(posedge CLK);
        DBGnTRST = 1'b1;
        tck(1'b0, 1'b0); // TLR -> RTI
        select_chain2();

        // Run until the address phase presents a real memory request, then
        // freeze that phase with CLKEN exactly as an external wait state does.
        CLKEN = 1'b1;
        found_active = 1'b0;
        for (int i = 0; i < 80; i++) begin
            @(negedge CLK);
            if (TRANS[1]) begin
                CLKEN = 1'b0;
                found_active = 1'b1;
                break;
            end
        end
        if (!found_active) begin
            $display("[debug_status] FAIL no active memory transaction observed");
            errors = errors + 1;
        end else begin
            read_debug_status(active_status);
            if (active_status[37:32] !== {1'b0, 5'h01}
                || active_status[4:0] !== {CPTBIT, 1'b1, 1'b1, 1'b0, 1'b0}) begin
                $display("[debug_status] FAIL active response header/status=%02x/%02x",
                         active_status[37:32], active_status[4:0]);
                errors = errors + 1;
            end
        end

        // Let the core finish the stalled cycle and enter halt on DBGRQ.
        CLKEN = 1'b1;
        DBGRQ = 1'b1;
        found_halt = 1'b0;
        for (int i = 0; i < 100; i++) begin
            @(posedge CLK);
            if (DBGACK) begin
                found_halt = 1'b1;
                break;
            end
        end
        DBGRQ = 1'b0;
        repeat (4) @(posedge CLK); // clear synchronized DBGRQ status

        if (!found_halt) begin
            $display("[debug_status] FAIL DBGRQ did not enter debug halt");
            errors = errors + 1;
        end else begin
            if (TRANS !== 2'(TRANS_I) || PROT[1] !== 1'b1) begin
                $display("[debug_status] FAIL discriminating halt state TRANS/PROT=%02b/%02b",
                         TRANS, PROT);
                errors = errors + 1;
            end
            read_debug_status(halted_status);
            if (halted_status[37:32] !== {1'b0, 5'h01}
                || halted_status[4:0] !== {CPTBIT, 1'b0, 1'b0, 1'b0, 1'b1}) begin
                $display("[debug_status] FAIL halted response header/status=%02x/%02x (TRANS=%02b PROT=%02b)",
                         halted_status[37:32], halted_status[4:0],
                         TRANS, PROT);
                errors = errors + 1;
            end
        end

        if (errors != 0)
            $fatal(1, "[debug_status] FAIL (%0d errors)", errors);
        $display("[debug_status] PASS");
        $finish;
    end

    initial begin
        repeat (CYCLE_LIMIT) @(posedge CLK);
        $fatal(1, "[debug_status] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, ADDR, WRITE, SIZE, LOCK, WDATA, CPnMREQ, CPSEQ,
        CPnTRANS, CPnOPC, CPnI, DBGnEXEC, DBGINSTRVALID, DBGRNG,
        DBGCOMMTX, DBGCOMMRX, DBGnTDOEN, DMORE, ignored_scan,
        active_status[31:5], halted_status[31:5]};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
