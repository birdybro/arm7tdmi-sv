// DBG-006 allowed debug-speed instruction matrix.
//
// TRM §5.16.1 permits data-processing operations, all load/store families
// (including block transfers), and MRS/MSR in debug state. Maximum LDM/STM
// is covered separately by debug_inject_handshake; this bench covers the
// remaining execution classes through public scan chain 1:
//   * all 16 data-processing opcodes and register-controlled shift timing;
//   * word, byte, halfword, signed-byte, and signed-halfword transfers;
//   * SWP and SWPB locked transfers; and
//   * CPSR/SPSR MRS and register-form MSR.
// Every ordinary injected word must generate exactly one accepted/retired
// handshake. Memory operations are CLKEN-stalled before their response edge,
// and no queued normal instruction may retire between injections.

`timescale 1ns/1ps

module arm7tdmis_debug_inject_matrix_tb
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_debug_pkg::*;
    import arm7tdmis_jtag_tb_pkg::*;
;

    localparam int CYCLE_LIMIT = 6500;

    logic CLK = 1'b0;
    initial forever #5 CLK = ~CLK;

    logic nRESET = 1'b0;
    logic CLKEN = 1'b0;
    logic DBGRQ = 1'b1;
    logic ABORT;
    logic DBGTCKEN = 1'b0;
    logic DBGTMS = 1'b1;
    logic DBGTDI = 1'b0;
    logic DBGnTRST = 1'b0;

    logic [31:0] ADDR, WDATA, RDATA;
    logic WRITE;
    logic [1:0] SIZE, PROT, TRANS;
    logic LOCK;
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
        .WORDS    (256),
        .INIT_HEX ("../tb/programs/debug_inject_handshake_test.hex")
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
    int unsigned accept_count;
    int unsigned retire_count;
    logic [37:0] ignored_scan;

    always_ff @(posedge CLK) begin
        if (!nRESET) begin
            accept_count <= 0;
            retire_count <= 0;
        end else begin
            if (u_dut.dbg_inject_accept)
                accept_count <= accept_count + 1;
            if (u_dut.dbg_inject_retire)
                retire_count <= retire_count + 1;
        end
    end

    task automatic fail(input string description);
        $display("[debug_inject_matrix] FAIL %s", description);
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

    task automatic select_chain1;
        load_ir(4'(IR_SCAN_N));
        shift_dr(4, 38'd1);
        load_ir(4'(IR_INTEST));
    endtask

    task automatic scan_instruction(input logic [31:0] instruction);
        shift_dr(33, chain1_serial_in(instruction, 1'b0));
    endtask

    task automatic wait_for_refreeze(input string description);
        bit saw_release;
        bit refrozen;

        saw_release = !u_dut.u_ice.core_halt;
        refrozen = 1'b0;
        for (int i = 0; i < 180; i++) begin
            @(posedge CLK);
            #1;
            if (!u_dut.u_ice.core_halt)
                saw_release = 1'b1;
            if (saw_release && u_dut.u_ice.core_halt
                && !u_dut.u_ice.dbg_inject_active) begin
                refrozen = 1'b1;
                break;
            end
        end
        if (!saw_release)
            fail($sformatf("%s never released the core", description));
        if (!refrozen)
            fail($sformatf("%s never refroze", description));
        if (u_dut.u_core.state_q !== 4'd0)
            fail($sformatf("%s refroze outside S_EXEC", description));
    endtask

    task automatic check_one_handshake(
        input int unsigned accept_before,
        input int unsigned retire_before,
        input string description
    );
        if (accept_count != (accept_before + 1))
            fail($sformatf("%s accepts expected %0d got %0d",
                           description, accept_before + 1, accept_count));
        if (retire_count != (retire_before + 1))
            fail($sformatf("%s retires expected %0d got %0d",
                           description, retire_before + 1, retire_count));
    endtask

    task automatic inject_and_wait(
        input logic [31:0] instruction,
        input string description
    );
        int unsigned accept_before;
        int unsigned retire_before;

        accept_before = accept_count;
        retire_before = retire_count;
        scan_instruction(instruction);
        wait_for_refreeze(description);
        check_one_handshake(accept_before, retire_before, description);
    endtask

    task automatic inject_memory_stalled(
        input logic [31:0] instruction,
        input string description
    );
        int unsigned accept_before;
        int unsigned retire_before;
        logic [31:0] held_addr, held_wdata;
        logic held_write, held_lock;
        logic [1:0] held_size, held_prot, held_trans;
        bit transfer_seen;

        accept_before = accept_count;
        retire_before = retire_count;
        scan_instruction(instruction);

        // Stop before the active transfer's response edge. The address
        // phase has already been presented, but neither the core nor the
        // memory model may advance while CLKEN is LOW.
        transfer_seen = 1'b0;
        for (int i = 0; i < 100; i++) begin
            @(negedge CLK);
            if (!u_dut.u_ice.core_halt && TRANS[1] && PROT[0]) begin
                held_addr  = ADDR;
                held_wdata = WDATA;
                held_write = WRITE;
                held_size  = SIZE;
                held_prot  = PROT;
                held_trans = TRANS;
                held_lock  = LOCK;
                CLKEN = 1'b0;
                transfer_seen = 1'b1;
                break;
            end
        end
        if (!transfer_seen) begin
            fail($sformatf("%s never presented a data transfer",
                           description));
        end else begin
            repeat (5) begin
                @(posedge CLK);
                #1;
                if ({ADDR, WDATA, WRITE, SIZE, PROT, TRANS, LOCK}
                    !== {held_addr, held_wdata, held_write, held_size,
                        held_prot, held_trans, held_lock})
                    fail($sformatf("%s bus changed during CLKEN stall",
                                   description));
            end
            @(negedge CLK);
            CLKEN = 1'b1;
        end

        wait_for_refreeze(description);
        check_one_handshake(accept_before, retire_before, description);
    endtask

    task automatic inject_internal_stalled(
        input logic [31:0] instruction,
        input logic [3:0] expected_state,
        input string description
    );
        int unsigned accept_before;
        int unsigned retire_before;
        bit state_seen;

        accept_before = accept_count;
        retire_before = retire_count;
        scan_instruction(instruction);
        state_seen = 1'b0;
        for (int i = 0; i < 100; i++) begin
            @(posedge CLK);
            #1;
            if (u_dut.u_core.state_q == expected_state) begin
                state_seen = 1'b1;
                break;
            end
        end
        if (!state_seen) begin
            fail($sformatf("%s never reached state %0d",
                           description, expected_state));
        end else begin
            @(negedge CLK);
            CLKEN = 1'b0;
            repeat (5) begin
                @(posedge CLK);
                #1;
                if (u_dut.u_core.state_q != expected_state)
                    fail($sformatf("%s advanced during CLKEN stall",
                                   description));
            end
            @(negedge CLK);
            CLKEN = 1'b1;
        end
        wait_for_refreeze(description);
        check_one_handshake(accept_before, retire_before, description);
    endtask

    function automatic logic [31:0] expected_dp_result(
        input logic [3:0] opcode,
        input logic       carry
    );
        logic [31:0] a;
        logic [31:0] b;
        a = 32'h0000_0012;
        b = 32'h0000_0003;
        unique case (opcode)
            4'h0: return a & b;
            4'h1: return a ^ b;
            4'h2: return a - b;
            4'h3: return b - a;
            4'h4: return a + b;
            4'h5: return a + b + 32'(carry);
            4'h6: return a - b - 32'(!carry);
            4'h7: return b - a - 32'(!carry);
            4'hC: return a | b;
            4'hD: return b;
            4'hE: return a & ~b;
            4'hF: return ~b;
            default: return 32'h0;
        endcase
    endfunction

    initial begin : run_test
        logic [31:0] instruction;
        logic [31:0] expected;
        logic [31:0] destination_before;
        logic carry_before;
        logic [31:0] normal_r13_svc;

        $dumpfile("debug_inject_matrix.fst");
        $dumpvars(0, arm7tdmis_debug_inject_matrix_tb);

        repeat (4) @(posedge CLK);
        nRESET = 1'b1;
        repeat (2) @(posedge CLK);
        DBGnTRST = 1'b1;
        CLKEN = 1'b1;

        for (int i = 0; i < 120; i++) begin
            @(posedge CLK);
            #1;
            if (DBGACK)
                break;
        end
        if (!DBGACK)
            fail("DBGRQ did not enter debug state");
        DBGRQ = 1'b0;
        normal_r13_svc = u_dut.u_core.u_regfile.regs[25];

        tck(1'b0, 1'b0);
        select_chain1();

        // Common data-processing operands.
        inject_and_wait(32'hE3A0_1012, "MOV r1,#0x12");
        inject_and_wait(32'hE3E0_2000, "MVN r2,#0");

        for (int opcode = 0; opcode < 16; opcode++) begin
            instruction = 32'hE201_2003 | (32'(opcode) << 21);
            if ((opcode >= 8) && (opcode <= 11)) begin
                instruction[20] = 1'b1;
                instruction[15:12] = 4'h0;
            end
            carry_before = u_dut.u_core.cpsr.c;
            destination_before = u_dut.u_core.u_regfile.regs[2];
            expected = expected_dp_result(4'(opcode), carry_before);
            inject_and_wait(
                instruction, $sformatf("data-processing opcode %0h", opcode));
            if ((opcode >= 8) && (opcode <= 11)) begin
                if (u_dut.u_core.u_regfile.regs[2]
                    !== destination_before)
                    fail($sformatf(
                        "test opcode %0h wrote destination r2", opcode));
            end else if (u_dut.u_core.u_regfile.regs[2] !== expected) begin
                fail($sformatf(
                    "data-processing opcode %0h expected %08x got %08x",
                    opcode, expected,
                    u_dut.u_core.u_regfile.regs[2]));
            end
        end

        // Register-controlled shifts use the dedicated S_DP_SHIFT cycle.
        inject_and_wait(32'hE3A0_4002, "MOV r4,#2");
        inject_internal_stalled(
            32'hE1A0_2411, 4'd9, "MOV r2,r1,LSL r4");
        if (u_dut.u_core.u_regfile.regs[2] !== 32'h0000_0048)
            fail($sformatf("register shift expected 00000048 got %08x",
                           u_dut.u_core.u_regfile.regs[2]));

        // Single and extra load/store families.
        inject_and_wait(32'hE3A0_0C01, "MOV r0,#0x100");
        inject_and_wait(32'hE3A0_50A5, "MOV r5,#0xa5");

        u_mem.mem[64] = 32'h1122_3344;
        inject_memory_stalled(32'hE580_5000, "STR word");
        if (u_mem.mem[64] !== 32'h0000_00A5)
            fail($sformatf("STR word stored %08x", u_mem.mem[64]));

        u_mem.mem[64] = 32'hDEAD_BEEF;
        inject_memory_stalled(32'hE590_6000, "LDR word");
        if (u_dut.u_core.u_regfile.regs[6] !== 32'hDEAD_BEEF)
            fail($sformatf("LDR word returned %08x",
                           u_dut.u_core.u_regfile.regs[6]));

        u_mem.mem[65] = 32'h1122_3344;
        inject_memory_stalled(32'hE5C0_5004, "STRB");
        if (u_mem.mem[65] !== 32'h1122_33A5)
            fail($sformatf("STRB stored %08x", u_mem.mem[65]));
        inject_memory_stalled(32'hE5D0_7004, "LDRB");
        if (u_dut.u_core.u_regfile.regs[7] !== 32'h0000_00A5)
            fail($sformatf("LDRB returned %08x",
                           u_dut.u_core.u_regfile.regs[7]));

        inject_memory_stalled(32'hE1C0_50B6, "STRH");
        if (u_mem.mem[65] !== 32'h00A5_33A5)
            fail($sformatf("STRH stored %08x", u_mem.mem[65]));
        inject_memory_stalled(32'hE1D0_80B6, "LDRH");
        if (u_dut.u_core.u_regfile.regs[8] !== 32'h0000_00A5)
            fail($sformatf("LDRH returned %08x",
                           u_dut.u_core.u_regfile.regs[8]));

        u_mem.mem[66] = 32'h8001_00FE;
        inject_memory_stalled(32'hE1D0_90D8, "LDRSB");
        if (u_dut.u_core.u_regfile.regs[9] !== 32'hFFFF_FFFE)
            fail($sformatf("LDRSB returned %08x",
                           u_dut.u_core.u_regfile.regs[9]));
        inject_memory_stalled(32'hE1D0_A0FA, "LDRSH");
        if (u_dut.u_core.u_regfile.regs[10] !== 32'hFFFF_8001)
            fail($sformatf("LDRSH returned %08x",
                           u_dut.u_core.u_regfile.regs[10]));

        // Locked swap family.
        u_mem.mem[64] = 32'h1234_5678;
        inject_memory_stalled(32'hE100_B095, "SWP");
        if (u_dut.u_core.u_regfile.regs[11] !== 32'h1234_5678)
            fail($sformatf("SWP returned %08x",
                           u_dut.u_core.u_regfile.regs[11]));
        if (u_mem.mem[64] !== 32'h0000_00A5)
            fail($sformatf("SWP stored %08x", u_mem.mem[64]));

        u_mem.mem[64] = 32'h1122_3380;
        inject_memory_stalled(32'hE140_C095, "SWPB");
        if (u_dut.u_core.u_regfile.regs[12] !== 32'h0000_0080)
            fail($sformatf("SWPB returned %08x",
                           u_dut.u_core.u_regfile.regs[12]));
        if (u_mem.mem[64] !== 32'h1122_33A5)
            fail($sformatf("SWPB stored %08x", u_mem.mem[64]));

        // PSR transfers: preserve the control byte while exercising both
        // current and saved status registers.
        inject_and_wait(32'hE10F_6000, "MRS r6,CPSR");
        if (u_dut.u_core.u_regfile.regs[6][7:0] !== 8'hD3)
            fail($sformatf("initial CPSR control was %02x",
                           u_dut.u_core.u_regfile.regs[6][7:0]));
        inject_and_wait(32'hE3A0_520A, "MOV r5,#0xa0000000");
        inject_and_wait(32'hE128_F005, "MSR CPSR_f,r5");
        if ({u_dut.u_core.cpsr.n, u_dut.u_core.cpsr.z,
             u_dut.u_core.cpsr.c, u_dut.u_core.cpsr.v} !== 4'b1010)
            fail("MSR CPSR_f did not write NZCV=1010");
        inject_and_wait(32'hE10F_6000, "MRS updated CPSR");
        if (u_dut.u_core.u_regfile.regs[6][31:28] !== 4'hA)
            fail($sformatf("updated CPSR flags were %01x",
                           u_dut.u_core.u_regfile.regs[6][31:28]));

        inject_and_wait(32'hE168_F005, "MSR SPSR_f,r5");
        inject_and_wait(32'hE14F_7000, "MRS r7,SPSR");
        if (u_dut.u_core.u_regfile.regs[7][31:28] !== 4'hA)
            fail($sformatf("updated SPSR flags were %01x",
                           u_dut.u_core.u_regfile.regs[7][31:28]));

        if (u_dut.u_core.u_regfile.regs[25] !== normal_r13_svc)
            fail("queued normal ADD retired during instruction matrix");
        if (accept_count != retire_count)
            fail($sformatf("final handshake imbalance accepts=%0d retires=%0d",
                           accept_count, retire_count));
        if (!DBGACK || !u_dut.u_ice.core_halt)
            fail("matrix did not finish in debug halt");

        if (errors != 0)
            $fatal(1, "[debug_inject_matrix] FAIL (%0d errors)", errors);
        $display("[debug_inject_matrix] PASS (%0d instructions)",
                 retire_count);
        $finish;
    end

    initial begin
        repeat (CYCLE_LIMIT) @(posedge CLK);
        $fatal(1, "[debug_inject_matrix] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT,
        CPnI, DBGnEXEC, DBGINSTRVALID, DBGRNG, DBGCOMMTX, DBGCOMMRX,
        DBGnTDOEN, DMORE, ignored_scan};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
