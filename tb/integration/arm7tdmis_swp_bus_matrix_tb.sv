// ISA-012 / EXC-007 / BUS-009 SWP/SWPB atomic bus-contract matrix.
//
// For both word and byte swaps, cover ordinary completion, independent
// CLKEN stalls of the read and write response phases, read and write Data
// Aborts, reset cancellation in either response phase, and DBGRQ arriving
// between the locked read and write.  Accepted transfers must remain an
// uninterrupted read/write pair at one address with LOCK asserted.

`timescale 1ns/1ps

module arm7tdmis_swp_bus_matrix_tb
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_types_pkg::*;
;

    localparam int MODE_NORMAL      = 0;
    localparam int MODE_STALL_READ  = 1;
    localparam int MODE_STALL_WRITE = 2;
    localparam int MODE_ABORT_READ  = 3;
    localparam int MODE_ABORT_WRITE = 4;
    localparam int MODE_RESET_READ  = 5;
    localparam int MODE_RESET_WRITE = 6;
    localparam int MODE_DBGRQ_READ   = 7;
    localparam int MODE_COUNT        = 8;
    localparam int CASE_COUNT        = 2 * MODE_COUNT;

    localparam logic [31:0] TEST_PC = 32'h0000_002C;
    localparam logic [31:0] DATA_ADDR = 32'h0000_0200;
    localparam logic [31:0] OLD_WORD = 32'h1234_5678;
    localparam logic [31:0] STORE_WORD = 32'hA5A5_C3D4;

    logic CLK;
    initial begin
        CLK = 1'b0;
        forever #5 CLK = ~CLK;
    end

    logic CLKEN = 1'b1;
    logic nRESET = 1'b0;
    logic DBGRQ = 1'b0;
    logic DBGnTRST = 1'b1;
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
        .CLK(CLK), .CLKEN(CLKEN), .nRESET(nRESET),
        .CFGBIGEND(1'b0), .nIRQ(1'b1), .nFIQ(1'b1), .ABORT(ABORT),
        .ADDR(ADDR), .WRITE(WRITE), .SIZE(SIZE), .PROT(PROT),
        .LOCK(LOCK), .TRANS(TRANS), .WDATA(WDATA), .RDATA(RDATA),
        .CPnMREQ(CPnMREQ), .CPSEQ(CPSEQ), .CPnTRANS(CPnTRANS),
        .CPnOPC(CPnOPC), .CPTBIT(CPTBIT), .CPnI(CPnI),
        .CPA(1'b1), .CPB(1'b1),
        .DBGEN(1'b1), .DBGRQ(DBGRQ), .DBGBREAK(1'b0),
        .DBGACK(DBGACK), .DBGnEXEC(DBGnEXEC),
        .DBGINSTRVALID(DBGINSTRVALID), .DBGEXT(2'b00),
        .DBGRNG(DBGRNG), .DBGCOMMTX(DBGCOMMTX),
        .DBGCOMMRX(DBGCOMMRX), .DBGTCKEN(1'b0),
        .DBGTMS(1'b0), .DBGTDI(1'b0), .DBGTDO(DBGTDO),
        .DBGnTRST(DBGnTRST), .DBGnTDOEN(DBGnTDOEN), .DMORE(DMORE)
    );

    logic inject_abort;
    arm7tdmis_memory #(
        .WORDS(256)
    ) u_mem (
        .CLK(CLK), .CLKEN(CLKEN), .nRESET(nRESET),
        .CFGBIGEND(1'b0),
        .ADDR(ADDR), .WRITE(WRITE), .SIZE(SIZE), .PROT(PROT),
        .LOCK(LOCK), .TRANS(TRANS), .WDATA(WDATA), .RDATA(RDATA),
        .ABORT(ABORT), .inject_abort(inject_abort)
    );

    int current_case;
    int current_mode;
    logic current_byte;
    string current_label;
    logic monitor_active;
    int accepted_data_cycles;
    int accepted_reads;
    int accepted_writes;
    logic seen_abort;

    assign inject_abort =
           ((current_mode == MODE_ABORT_READ)
            && (u_dut.u_core.state_q == 4'd3))
        || ((current_mode == MODE_ABORT_WRITE)
            && (u_dut.u_core.state_q == 4'd4));

    function automatic string mode_name(input int mode);
        case (mode)
            MODE_NORMAL:      return "normal";
            MODE_STALL_READ:  return "stall-read";
            MODE_STALL_WRITE: return "stall-write";
            MODE_ABORT_READ:  return "abort-read";
            MODE_ABORT_WRITE: return "abort-write";
            MODE_RESET_READ:  return "reset-read";
            MODE_RESET_WRITE: return "reset-write";
            MODE_DBGRQ_READ:   return "dbgrq-read";
            default:          return "unknown";
        endcase
    endfunction

    function automatic logic [31:0] swp_opcode(input logic byte_access);
        return byte_access ? 32'hE144_1092 : 32'hE104_1092;
    endfunction

    task automatic fail(input string detail);
        $fatal(1, "[swp_bus_matrix] FAIL case %0d (%s): %s",
               current_case, current_label, detail);
    endtask

    always_ff @(posedge CLK) begin
        if (!nRESET || !monitor_active) begin
            accepted_data_cycles <= 0;
            accepted_reads       <= 0;
            accepted_writes      <= 0;
            seen_abort           <= 1'b0;
        end else begin
            if (ABORT && CLKEN)
                seen_abort <= 1'b1;

            // Table 7-15's final merged I-S prefetch retains data-class
            // PROT while LOCK is already released. Count only the locked
            // pair as SWP data transfers; the unlocked S is checked by the
            // Table 7 phase matrix.
            if (CLKEN && (TRANS inside {TRANS_N, TRANS_S}) && LOCK) begin
                if (ADDR !== DATA_ADDR)
                    fail($sformatf("data address expected %08x got %08x",
                                   DATA_ADDR, ADDR));
                if (SIZE !== (current_byte
                            ? 2'(SIZE_BYTE) : 2'(SIZE_WORD)))
                    fail($sformatf("SIZE expected %02b got %02b",
                                   current_byte
                                   ? 2'(SIZE_BYTE) : 2'(SIZE_WORD),
                                   SIZE));
                if (!PROT[PROT_BIT_PRIV])
                    fail("data transfer was not privileged");
                if (!LOCK)
                    fail("accepted swap transfer without LOCK");
                if (accepted_data_cycles == 0 && WRITE)
                    fail("first accepted transfer was not the read");
                if (accepted_data_cycles == 1 && !WRITE)
                    fail("second accepted transfer was not the write");
                if (accepted_data_cycles >= 2)
                    fail("issued more than two data transfers");

                accepted_data_cycles <= accepted_data_cycles + 1;
                if (WRITE)
                    accepted_writes <= accepted_writes + 1;
                else
                    accepted_reads <= accepted_reads + 1;
            end else if (CLKEN && (accepted_data_cycles == 1)
                         && !(current_mode inside {
                             MODE_ABORT_READ, MODE_RESET_READ})) begin
                // Ignoring disabled clocks, nothing may interleave between
                // the locked read and write address phases.
                fail("enabled non-data cycle interleaved locked pair");
            end
        end
    end

    task automatic setup_case(
        input int case_id,
        input int mode,
        input logic byte_access
    );
        CLKEN = 1'b1;
        DBGRQ = 1'b0;
        monitor_active = 1'b0;
        nRESET = 1'b0;
        DBGnTRST = 1'b0;
        #1;
        DBGnTRST = 1'b1;
        current_case = case_id;
        current_mode = mode;
        current_byte = byte_access;
        current_label = $sformatf("%s %s",
            byte_access ? "SWPB" : "SWP", mode_name(mode));

        repeat (4) @(posedge CLK);
        for (int word = 0; word < 256; word++)
            u_mem.mem[word] = 32'hEAFF_FFFE;

        u_mem.mem[0]  = 32'hEA00_0006; // B 0x20
        u_mem.mem[1]  = 32'hEA00_003D; // B 0x100
        u_mem.mem[4]  = 32'hEA00_003A; // DABT vector: B 0x100
        u_mem.mem[8]  = 32'hE3A0_4C02; // MOV r4,#0x200
        u_mem.mem[9]  = 32'hE59F_2094; // LDR r2,[pc,#0x94] -> 0xc0
        u_mem.mem[10] = 32'hE3A0_1055; // MOV r1,#0x55
        u_mem.mem[11] = swp_opcode(byte_access);
        u_mem.mem[12] = 32'hE3A0_7000 | 32'(case_id);
        u_mem.mem[13] = 32'hEAFF_FFFE;
        u_mem.mem[48] = STORE_WORD;
        u_mem.mem[64] = 32'hE3A0_6000 | 32'(case_id);
        u_mem.mem[65] = 32'hEAFF_FFFE;
        u_mem.mem[128] = OLD_WORD;

        @(negedge CLK);
        nRESET = 1'b1;

        // Start the scoreboard in the S_EXEC address phase so it includes
        // the locked read without counting the setup LDR.
        for (int timeout = 0; timeout < 100; timeout++) begin
            @(negedge CLK);
            if ((u_dut.u_core.state_q == 4'd0)
                && (u_dut.u_core.de_q.pc == TEST_PC)) begin
                monitor_active = 1'b1;
                return;
            end
        end
        fail("never reached swap instruction");
    endtask

    task automatic wait_for_state(input logic [3:0] target);
        for (int timeout = 0; timeout < 30; timeout++) begin
            @(negedge CLK);
            if (u_dut.u_core.state_q == target)
                return;
        end
        fail($sformatf("never reached state %0d", target));
    endtask

    task automatic stall_state(input logic [3:0] target);
        logic [71:0] held_bus;
        logic [31:0] held_rdata;

        wait_for_state(target);
        held_bus = {ADDR, WDATA, WRITE, SIZE, PROT, LOCK, TRANS};
        held_rdata = RDATA;
        CLKEN = 1'b0;
        repeat (4) begin
            @(posedge CLK);
            #1;
            if ({ADDR, WDATA, WRITE, SIZE, PROT, LOCK, TRANS} !== held_bus)
                fail("address/control/data outputs changed during stall");
            if (RDATA !== held_rdata)
                fail("RDATA changed during stall");
            if (u_dut.u_core.state_q !== target)
                fail("execute substate advanced during stall");
        end
        @(negedge CLK);
        CLKEN = 1'b1;
    endtask

    task automatic pulse_dbgrq_during_read;
        wait_for_state(4'd3); // S_SWP_RDATA
        DBGRQ = 1'b1;
        @(posedge CLK);
        @(negedge CLK);
        DBGRQ = 1'b0;
    endtask

    task automatic cancel_with_reset(input logic [3:0] target);
        wait_for_state(target);
        nRESET = 1'b0;
        #1;
        if (LOCK !== LOCK_FREE || TRANS !== 2'(TRANS_I))
            fail("reset did not release LOCK and force an I cycle");
        repeat (3) @(posedge CLK);
    endtask

    task automatic wait_after_operation(input int cycles);
        repeat (cycles) @(posedge CLK);
    endtask

    task automatic check_completed;
        logic [31:0] expected_loaded;
        logic [31:0] expected_memory;

        expected_loaded = current_byte ? 32'h0000_0078 : OLD_WORD;
        expected_memory = current_byte
                        ? 32'h1234_56D4 : STORE_WORD;

        if (accepted_data_cycles != 2
            || accepted_reads != 1 || accepted_writes != 1)
            fail($sformatf("accepted data/read/write counts %0d/%0d/%0d",
                           accepted_data_cycles,
                           accepted_reads, accepted_writes));
        if (u_dut.u_core.u_regfile.regs[1] !== expected_loaded)
            fail($sformatf("Rd expected %08x got %08x",
                           expected_loaded,
                           u_dut.u_core.u_regfile.regs[1]));
        if (u_mem.mem[128] !== expected_memory)
            fail($sformatf("memory expected %08x got %08x",
                           expected_memory, u_mem.mem[128]));
        if (LOCK !== LOCK_FREE)
            fail("LOCK remained asserted after completion");
    endtask

    task automatic check_abort(input logic read_abort);
        int expected_transfers;

        expected_transfers = read_abort ? 1 : 2;
        if (!seen_abort)
            fail("ABORT was not sampled");
        if (accepted_data_cycles != expected_transfers
            || accepted_reads != 1
            || accepted_writes != (read_abort ? 0 : 1))
            fail($sformatf("abort data/read/write counts %0d/%0d/%0d",
                           accepted_data_cycles,
                           accepted_reads, accepted_writes));
        if (u_mem.mem[128] !== OLD_WORD)
            fail("aborted swap changed memory");
        if (u_dut.u_core.u_regfile.regs[1] !== 32'h0000_0055)
            fail("aborted swap changed Rd");
        if (u_dut.u_core.u_regfile.regs[7] !== 32'h0)
            fail("aborted swap executed successor");
        if (u_dut.u_core.u_regfile.regs[6] !== 32'(current_case)
            || u_dut.u_core.cpsr.m !== 5'(MODE_ABORT)
            || u_dut.u_core.u_regfile.regs[28] !== (TEST_PC + 32'd8))
            fail($sformatf(
                "handler state r6=%08x/%08x mode=%05b/%05b lr=%08x/%08x",
                u_dut.u_core.u_regfile.regs[6], 32'(current_case),
                u_dut.u_core.cpsr.m, 5'(MODE_ABORT),
                u_dut.u_core.u_regfile.regs[28], TEST_PC + 32'd8));
        if (LOCK !== LOCK_FREE)
            fail("aborted swap left LOCK asserted");
    endtask

    task automatic run_case(
        input int case_id,
        input int mode,
        input logic byte_access
    );
        setup_case(case_id, mode, byte_access);

        unique case (mode)
            MODE_STALL_READ:  stall_state(4'd3);
            MODE_STALL_WRITE: stall_state(4'd4);
            MODE_RESET_READ: begin
                cancel_with_reset(4'd3);
                if (u_mem.mem[128] !== OLD_WORD)
                    fail("read-phase reset changed memory");
                monitor_active = 1'b0;
                return;
            end
            MODE_RESET_WRITE: begin
                cancel_with_reset(4'd4);
                if (u_mem.mem[128] !== OLD_WORD)
                    fail("write-phase reset committed memory");
                monitor_active = 1'b0;
                return;
            end
            MODE_DBGRQ_READ: pulse_dbgrq_during_read();
            default: ;
        endcase

        if (mode == MODE_DBGRQ_READ) begin
            for (int timeout = 0; timeout < 100; timeout++) begin
                @(posedge CLK);
                if (DBGACK) begin
                    check_completed();
                    if (u_dut.u_core.u_regfile.regs[7] !== 32'h0)
                        fail("DBGRQ allowed successor to execute");
                    monitor_active = 1'b0;
                    return;
                end
            end
            fail("DBGRQ did not enter halt mode");
        end

        wait_after_operation(100);
        if (mode == MODE_ABORT_READ)
            check_abort(1'b1);
        else if (mode == MODE_ABORT_WRITE)
            check_abort(1'b0);
        else begin
            check_completed();
            if (u_dut.u_core.u_regfile.regs[7] !== 32'(case_id))
                fail("completion marker missing");
        end
        monitor_active = 1'b0;
    endtask

    initial begin
        int case_id;

        case_id = 0;
        for (int byte_access = 0; byte_access < 2; byte_access++) begin
            for (int mode = 0; mode < MODE_COUNT; mode++) begin
                case_id++;
                run_case(case_id, mode, 1'(byte_access));
            end
        end

        $display("[swp_bus_matrix] PASS (%0d reset-per-case rows)",
                 CASE_COUNT);
        $finish;
    end

    initial begin
        #1000000;
        $fatal(1, "[swp_bus_matrix] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, WDATA, DMORE,
        CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI,
        DBGnEXEC, DBGINSTRVALID, DBGRNG,
        DBGCOMMTX, DBGCOMMRX, DBGTDO, DBGnTDOEN};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
