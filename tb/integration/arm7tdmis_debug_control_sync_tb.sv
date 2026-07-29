// DBG-001 Debug Control, Debug Status, and synchronous DBGRQ regression.
//
// ARM7TDMI-S Appendix B requires DBGRQ to be synchronized outside the soft
// macrocell and sampled as a synchronous CLK input. TRM §5.24.2 separately
// requires force-DBGRQ (Debug Control bit 1) to remain behind a latch that
// opens only in TAP Run-Test/Idle. Figure 5-17 requires Debug Status bit 0
// to report internal DBGACKI, not the force-DBGACK-modified output pin.

`timescale 1ns/1ps

module arm7tdmis_debug_control_sync_tb
    import arm7tdmis_debug_pkg::*;
    import arm7tdmis_jtag_tb_pkg::*;
;

    localparam int CYCLE_LIMIT = 2600;
    localparam logic [31:0] REQUEST_PC = 32'h0000_0024;

    logic CLK = 1'b0;
    initial forever #5 CLK = ~CLK;

    logic nRESET = 1'b0;
    logic CLKEN = 1'b0;
    logic DBGRQ = 1'b0;
    logic DBGTCKEN = 1'b0;
    logic DBGTMS = 1'b1;
    logic DBGTDI = 1'b0;
    logic DBGnTRST = 1'b0;

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
        .INIT_HEX ("../tb/programs/debug_control_sync_test.hex")
    ) u_mem (
        .CLK,
        .CLKEN,
        .nRESET,
        .CFGBIGEND        (1'b0),
        .ADDR, .WRITE, .SIZE, .PROT, .LOCK, .TRANS, .WDATA, .RDATA,
        .ABORT,
        .inject_abort     (1'b0)
    );

    int unsigned errors = 0;

    task automatic fail(input string description);
        $display("[debug_control_sync] FAIL %s", description);
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
        input  logic [37:0] scan_in,
        output logic [37:0] scan_out
    );
        scan_out = '0;
        tck(1'b1, 1'b0);
        tck(1'b0, 1'b0);
        tck(1'b0, 1'b0);
        for (int i = 0; i < width; i++) begin
            scan_out[i] = DBGTDO;
            tck(i == (width - 1), scan_in[i]);
        end
        tck(1'b1, 1'b0);
        tck(1'b0, 1'b0);
    endtask

    task automatic select_chain2;
        logic [37:0] ignored;
        load_ir(4'(IR_SCAN_N));
        shift_dr(4, 38'd2, ignored);
        if (&{1'b0, ignored})
            fail("unreachable SCAN_N sentinel");
        load_ir(4'(IR_INTEST));
    endtask

    task automatic write_ice(
        input logic [4:0] address,
        input logic [31:0] data
    );
        logic [37:0] ignored;
        shift_dr(38, chain2_serial_in(1'b1, address, data), ignored);
        if (&{1'b0, ignored})
            fail("unreachable chain-2 write sentinel");
    endtask

    task automatic read_ice(
        input  logic [4:0] address,
        output logic [31:0] data
    );
        logic [37:0] ignored;
        logic [37:0] response;
        shift_dr(38, chain2_serial_in(1'b0, address, 32'h0), ignored);
        shift_dr(38, chain2_serial_in(1'b0, address, 32'h0), response);
        if (&{1'b0, ignored})
            fail("unreachable chain-2 read sentinel");
        response = chain2_parallel_out(response);
        if (response[37:32] !== {1'b0, address})
            fail($sformatf("read header for %02x was %02x",
                           address, response[37:32]));
        data = response[31:0];
    endtask

    // Commit a chain-2 write at Update-DR, then leave Update-DR for
    // Select-DR-Scan instead of Run-Test/Idle.
    task automatic write_ice_without_idle(
        input logic [4:0] address,
        input logic [31:0] data
    );
        logic [37:0] serial_in;
        serial_in = chain2_serial_in(1'b1, address, data);
        tck(1'b1, 1'b0);
        tck(1'b0, 1'b0);
        tck(1'b0, 1'b0);
        for (int i = 0; i < 38; i++)
            tck(i == 37, serial_in[i]);
        tck(1'b1, 1'b0); // Exit1-DR -> Update-DR
        tck(1'b1, 1'b0); // Update-DR -> Select-DR-Scan, commit write
    endtask

    task automatic reset_scenario;
        CLKEN = 1'b0;
        DBGRQ = 1'b0;
        DBGTCKEN = 1'b0;
        DBGTMS = 1'b1;
        DBGTDI = 1'b0;
        nRESET = 1'b0;
        DBGnTRST = 1'b0;
        repeat (4) @(posedge CLK);
        nRESET = 1'b1;
        repeat (2) @(posedge CLK);
        DBGnTRST = 1'b1;
        tck(1'b0, 1'b0); // Test-Logic-Reset -> Run-Test/Idle
    endtask

    task automatic wait_for_halt(input string description);
        for (int i = 0; i < 40; i++) begin
            @(posedge CLK);
            #1;
            if (DBGACK)
                return;
        end
        fail(description);
    endtask

    initial begin : run_test
        logic found_request_pc;
        logic [31:0] value;

        $dumpfile("debug_control_sync.fst");
        $dumpvars(0, arm7tdmis_debug_control_sync_tb);

        // A one-enabled-cycle external DBGRQ must be consumed on that edge,
        // after the current instruction but before younger instructions.
        reset_scenario();
        CLKEN = 1'b1;
        found_request_pc = 1'b0;
        for (int i = 0; i < 80; i++) begin
            @(negedge CLK);
            if (u_dut.u_core.de_q.valid
                && (u_dut.u_core.de_q.pc == REQUEST_PC)) begin
                DBGRQ = 1'b1;
                found_request_pc = 1'b1;
                break;
            end
        end
        if (!found_request_pc)
            fail("external DBGRQ trigger instruction was not observed");
        @(negedge CLK);
        DBGRQ = 1'b0;
        wait_for_halt("one-cycle synchronous DBGRQ did not halt");
        if (u_dut.u_core.u_regfile.regs[0] !== 32'h1
            || u_dut.u_core.u_regfile.regs[1] !== 32'h2
            || u_dut.u_core.u_regfile.regs[2] !== 32'h0
            || u_dut.u_core.u_regfile.regs[3] !== 32'h0)
            fail($sformatf("DBGRQ boundary registers r0-r3=%08x/%08x/%08x/%08x",
                           u_dut.u_core.u_regfile.regs[0],
                           u_dut.u_core.u_regfile.regs[1],
                           u_dut.u_core.u_regfile.regs[2],
                           u_dut.u_core.u_regfile.regs[3]));

        // A scan-written force-DBGRQ must remain latent while the TAP
        // deliberately avoids Run-Test/Idle.
        reset_scenario();
        select_chain2();
        write_ice_without_idle(5'h00, 32'h0000_0002);
        CLKEN = 1'b1;
        repeat (8) @(posedge CLK);
        #1;
        if (DBGACK)
            fail("force-DBGRQ applied before Run-Test/Idle");

        // Navigate Select-DR -> Select-IR -> Test-Logic-Reset -> RTI.
        tck(1'b1, 1'b0);
        tck(1'b1, 1'b0);
        tck(1'b0, 1'b0);
        wait_for_halt("force-DBGRQ did not apply in Run-Test/Idle");

        // Forced external DBGACK must not feed back into Debug Status[0].
        // INTDIS must likewise appear through the live IFEN status bit.
        reset_scenario();
        select_chain2();
        write_ice(5'h00, 32'h0000_0001);
        CLKEN = 1'b1;
        #1;
        if (!DBGACK)
            fail("Debug Control bit 0 did not force the DBGACK pin");
        read_ice(5'h01, value);
        if (value[0] !== 1'b0)
            fail("Debug Status[0] reported forced pin DBGACK, not DBGACKI");
        if (value[2] !== 1'b1)
            fail("Debug Status[2] did not report enabled IFEN");

        write_ice(5'h00, 32'h0000_0005);
        read_ice(5'h01, value);
        if (value[2] !== 1'b0)
            fail("INTDIS did not force Debug Status IFEN LOW");
        if (value[0] !== 1'b0)
            fail("forced DBGACK changed internal status while running");

        // Bit 3 and every upper bit are RAZ without disturbing bit 0.
        write_ice(5'h00, 32'hFFFF_FFF9);
        read_ice(5'h00, value);
        if (value !== 32'h0000_0031)
            fail($sformatf("Debug Control width/RAZ expected 00000031 got %08x",
                           value));

        if (errors != 0)
            $fatal(1, "[debug_control_sync] FAIL (%0d errors)", errors);
        $display("[debug_control_sync] PASS");
        $finish;
    end

    initial begin
        repeat (CYCLE_LIMIT) @(posedge CLK);
        $fatal(1, "[debug_control_sync] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, ADDR, WRITE, SIZE, PROT, LOCK, TRANS, WDATA,
        CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI, DBGnEXEC,
        DBGINSTRVALID, DBGRNG, DBGCOMMTX, DBGCOMMRX, DBGnTDOEN, DMORE};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
