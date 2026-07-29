// DBG-001 EmbeddedICE-RT register-map regression.
//
// ARM7TDMI-S r4p3 TRM Table 5-1 defines only addresses 0x00, 0x01,
// 0x04, 0x05, 0x08-0x0D, and 0x10-0x15. In particular, address 0x02
// is reserved: r4p3 has no Vector Catch register. This test writes every
// reserved address through the public 38-bit JTAG chain, requires the
// implementation's deterministic RAZ/WI policy, then proves that the
// attempted address-0x02 write cannot stop ordinary vector-region fetches.

`timescale 1ns/1ps

module arm7tdmis_debug_reserved_regs_tb
    import arm7tdmis_debug_pkg::*;
    import arm7tdmis_jtag_tb_pkg::*;
;

    localparam int CYCLE_LIMIT = 3600;

    logic CLK = 1'b0;
    initial forever #5 CLK = ~CLK;

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
        .WORDS    (128),
        .INIT_HEX ("../tb/programs/debug_reserved_regs_test.hex")
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
        $display("[debug_reserved_regs] FAIL %s", description);
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

    function automatic bit mapped_register(input logic [4:0] address);
        return (address == 5'h00)
            || (address == 5'h01)
            || (address == 5'h04)
            || (address == 5'h05)
            || ((address >= 5'h08) && (address <= 5'h0D))
            || ((address >= 5'h10) && (address <= 5'h15));
    endfunction

    initial begin : run_test
        logic [31:0] value;
        bit program_completed;

        $dumpfile("debug_reserved_regs.fst");
        $dumpvars(0, arm7tdmis_debug_reserved_regs_tb);

        repeat (4) @(posedge CLK);
        nRESET = 1'b1;
        repeat (2) @(posedge CLK);
        DBGnTRST = 1'b1;
        tck(1'b0, 1'b0); // Test-Logic-Reset -> Run-Test/Idle
        select_chain2();

        // Keep the core frozen while every hole in the published register
        // map is attacked with a distinctive nonzero write.
        for (int address = 0; address < 32; address++) begin
            if (!mapped_register(5'(address))) begin
                write_ice(5'(address), 32'hD15A_FFFF ^ 32'(address));
                read_ice(5'(address), value);
                if (value !== 32'h0000_0000)
                    fail($sformatf(
                        "reserved address %02x read back %08x, expected RAZ",
                        address, value));
            end
        end

        // Address 0x02 was historically misimplemented as Vector Catch.
        // Its attempted write must neither create a breakpoint tag nor
        // inhibit ordinary execution through addresses 0x00-0x1C.
        CLKEN = 1'b1;
        program_completed = 1'b0;
        for (int i = 0; i < 160; i++) begin
            @(posedge CLK);
            #1;
            if (DBGACK) begin
                fail("reserved address 0x02 write caused debug entry");
                break;
            end
            if (u_dut.u_core.u_regfile.regs[0] == 32'h0000_0011
                && u_dut.u_core.u_regfile.regs[1] == 32'h0000_0022
                && u_dut.u_core.u_regfile.regs[2] == 32'h0000_0033
                && u_dut.u_core.u_regfile.regs[3] == 32'h0000_0044) begin
                program_completed = 1'b1;
                break;
            end
        end
        if (!program_completed)
            fail("vector-region program did not complete");

        if (errors != 0)
            $fatal(1, "[debug_reserved_regs] FAIL (%0d errors)", errors);
        $display("[debug_reserved_regs] PASS");
        $finish;
    end

    initial begin
        repeat (CYCLE_LIMIT) @(posedge CLK);
        $fatal(1, "[debug_reserved_regs] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, ADDR, WRITE, SIZE, PROT, LOCK, TRANS, WDATA,
        CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI, DBGnEXEC,
        DBGINSTRVALID, DBGRNG, DBGCOMMTX, DBGCOMMRX, DBGnTDOEN, DMORE};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
