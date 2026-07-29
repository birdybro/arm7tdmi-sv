// BUS-010: Rev-4 DMORE address-phase contract.
//
// TRM §1.5.5 defines DMORE HIGH when the next data memory access is
// followed by a sequential data memory access. Like ADDR/TRANS, this is an
// address-class prediction: for a three-word LDM/STM the first two data
// addresses carry DMORE=1 and the final address carries DMORE=0.
//
// Eight reset-isolated rows cover LDM/STM, single and three-beat transfers,
// first/middle/last indications, CLKEN stalls, and accepted first/middle
// response aborts. The abort rows also prove that r4p3's completing block
// sequence continues to advertise each remaining address exactly once.

`timescale 1ns/1ps

module arm7tdmis_dmore_matrix_tb
    import arm7tdmis_bus_pkg::*;
;

    localparam logic [31:0] DATA_BASE = 32'h0000_0100;
    localparam int ROW_COUNT = 8;

    logic CLK = 1'b0;
    initial forever #5 CLK = ~CLK;

    logic nRESET = 1'b0;
    logic CLKEN = 1'b1;
    logic inject_abort = 1'b0;

    logic [31:0] ADDR, WDATA, RDATA;
    logic WRITE;
    logic [1:0] SIZE, PROT, TRANS;
    logic LOCK, ABORT, DMORE;
    logic CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI;
    logic DBGACK, DBGnEXEC, DBGINSTRVALID;
    logic [1:0] DBGRNG;
    logic DBGCOMMTX, DBGCOMMRX, DBGTDO, DBGnTDOEN;

    arm7tdmis_top u_dut (
        .CLK, .CLKEN, .nRESET,
        .CFGBIGEND(1'b0), .nIRQ(1'b1), .nFIQ(1'b1), .ABORT,
        .ADDR, .WRITE, .SIZE, .PROT, .LOCK, .TRANS, .WDATA, .RDATA,
        .CPnMREQ, .CPSEQ, .CPnTRANS, .CPnOPC, .CPTBIT, .CPnI,
        .CPA(1'b1), .CPB(1'b1),
        .DBGEN(1'b0), .DBGRQ(1'b0), .DBGBREAK(1'b0),
        .DBGACK, .DBGnEXEC, .DBGINSTRVALID, .DBGEXT(2'b00),
        .DBGRNG, .DBGCOMMTX, .DBGCOMMRX,
        .DBGTCKEN(1'b0), .DBGTMS(1'b0), .DBGTDI(1'b0),
        .DBGTDO, .DBGnTRST(1'b1), .DBGnTDOEN, .DMORE
    );

    arm7tdmis_memory #(.WORDS(256)) u_mem (
        .CLK, .CLKEN, .nRESET, .CFGBIGEND(1'b0),
        .ADDR, .WRITE, .SIZE, .PROT, .LOCK, .TRANS, .WDATA, .RDATA,
        .ABORT, .inject_abort
    );

    int unsigned errors = 0;

    task automatic fail(input int row, input string description);
        $display("[dmore_matrix] FAIL row %0d: %s", row, description);
        errors++;
    endtask

    task automatic setup_row(
        input int row,
        input bit is_load,
        input int unsigned register_count
    );
        logic [15:0] register_list;
        logic [31:0] block_opcode;

        register_list = (register_count == 1) ? 16'h0002 : 16'h000E;
        block_opcode = (is_load ? 32'hE8B0_0000 : 32'hE8A0_0000)
                     | 32'(register_list);

        for (int word = 0; word < 256; word++)
            u_mem.mem[word] = 32'hEAFF_FFFE;

        u_mem.mem[0]  = 32'hEA00_0006;       // reset: B 0x20
        u_mem.mem[4]  = 32'hE3A0_7000 | 32'(row); // DABT marker
        u_mem.mem[5]  = 32'hEAFF_FFFE;
        u_mem.mem[8]  = 32'hE59F_0058;       // r0 <- DATA_BASE
        u_mem.mem[9]  = 32'hE3A0_1011;
        u_mem.mem[10] = 32'hE3A0_2022;
        u_mem.mem[11] = 32'hE3A0_3033;
        u_mem.mem[12] = block_opcode;
        u_mem.mem[13] = 32'hE3A0_7000 | 32'(row); // normal marker
        u_mem.mem[14] = 32'hEAFF_FFFE;
        u_mem.mem[32] = DATA_BASE;
        u_mem.mem[64] = 32'h1111_0001;
        u_mem.mem[65] = 32'h2222_0002;
        u_mem.mem[66] = 32'h3333_0003;
    endtask

    task automatic run_row(
        input int row,
        input bit is_load,
        input int unsigned register_count,
        input int stall_phase,
        input int abort_response
    );
        int unsigned address_phase;
        bit stalled;
        bit abort_driven;
        bit clear_abort;
        bit completed;
        logic [72:0] held_bus;

        @(negedge CLK);
        nRESET = 1'b0;
        CLKEN = 1'b1;
        inject_abort = 1'b0;
        repeat (4) @(posedge CLK);
        setup_row(row, is_load, register_count);
        @(negedge CLK);
        nRESET = 1'b1;

        address_phase = 0;
        stalled = 1'b0;
        abort_driven = 1'b0;
        clear_abort = 1'b0;
        completed = 1'b0;

        for (int cycle = 0; cycle < 300; cycle++) begin
            @(negedge CLK);

            if (clear_abort) begin
                inject_abort = 1'b0;
                clear_abort = 1'b0;
            end
            if (!abort_driven && (abort_response >= 0)
                && (u_mem.trans_q inside {TRANS_N, TRANS_S})
                && (u_mem.addr_q
                    == (DATA_BASE + 32'(4 * abort_response)))) begin
                inject_abort = 1'b1;
                abort_driven = 1'b1;
                clear_abort = 1'b1;
            end

            if (CLKEN && (TRANS inside {TRANS_N, TRANS_S})
                && PROT[PROT_BIT_DATA]
                && (ADDR >= DATA_BASE)
                && (ADDR < (DATA_BASE + 32'(4 * register_count)))) begin
                if (address_phase >= register_count) begin
                    fail(row, "presented too many block data addresses");
                end else begin
                    if (ADDR !== (DATA_BASE + 32'(4 * address_phase)))
                        fail(row, $sformatf(
                            "phase %0d address expected %08x got %08x",
                            address_phase,
                            DATA_BASE + 32'(4 * address_phase), ADDR));
                    if (TRANS !== ((address_phase == 0)
                                 ? 2'(TRANS_N) : 2'(TRANS_S)))
                        fail(row, $sformatf(
                            "phase %0d TRANS expected %02b got %02b",
                            address_phase,
                            (address_phase == 0) ? TRANS_N : TRANS_S,
                            TRANS));
                    if (WRITE !== !is_load || SIZE !== 2'(SIZE_WORD))
                        fail(row, $sformatf(
                            "phase %0d WRITE/SIZE=%0b/%02b",
                            address_phase, WRITE, SIZE));
                    if (DMORE !== ((address_phase + 1) < register_count))
                        fail(row, $sformatf(
                            "phase %0d DMORE expected %0b got %0b",
                            address_phase,
                            (address_phase + 1) < register_count, DMORE));

                    if (!stalled && (int'(address_phase) == stall_phase)) begin
                        held_bus = {
                            ADDR, WDATA, WRITE, SIZE, PROT, LOCK, TRANS, DMORE
                        };
                        CLKEN = 1'b0;
                        repeat (4) begin
                            @(posedge CLK);
                            #1;
                            if ({ADDR, WDATA, WRITE, SIZE, PROT,
                                 LOCK, TRANS, DMORE} !== held_bus)
                                fail(row, "bus/DMORE changed during CLKEN stall");
                        end
                        @(negedge CLK);
                        CLKEN = 1'b1;
                        stalled = 1'b1;
                    end
                    address_phase++;
                end
            end

            if (u_dut.u_core.u_regfile.regs[7] == 32'(row)) begin
                completed = 1'b1;
                break;
            end
        end

        if (!completed)
            fail(row, "normal/abort completion marker did not retire");
        if (address_phase != register_count)
            fail(row, $sformatf(
                "expected %0d address phases, observed %0d",
                register_count, address_phase));
        if ((stall_phase >= 0) && !stalled)
            fail(row, "requested CLKEN stall phase was not reached");
        if ((abort_response >= 0) && !abort_driven)
            fail(row, "requested response abort was not driven");
        if (DMORE !== 1'b0)
            fail(row, "DMORE remained asserted after block completion");
    endtask

    initial begin
        run_row(1, 1'b1, 1, -1, -1); // single LDM
        run_row(2, 1'b0, 1, -1, -1); // single STM
        run_row(3, 1'b1, 3, -1, -1); // LDM first/middle/last
        run_row(4, 1'b0, 3, -1, -1); // STM first/middle/last
        run_row(5, 1'b1, 3,  1, -1); // stalled LDM middle address
        run_row(6, 1'b0, 3,  0, -1); // stalled STM first address
        run_row(7, 1'b1, 3, -1,  0); // LDM first response abort
        run_row(8, 1'b0, 3, -1,  1); // STM middle response abort

        if (errors != 0)
            $fatal(1, "[dmore_matrix] FAIL (%0d errors)", errors);
        $display("[dmore_matrix] PASS (%0d reset-isolated rows)", ROW_COUNT);
        $finish;
    end

    initial begin
        repeat (ROW_COUNT * 400) @(posedge CLK);
        $fatal(1, "[dmore_matrix] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT,
        CPnI, DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG, DBGCOMMTX,
        DBGCOMMRX, DBGTDO, DBGnTDOEN};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
