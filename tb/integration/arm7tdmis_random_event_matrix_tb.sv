// VAL-005 constrained-random external-event closure.
//
// Every seed runs a reset-isolated CLKEN hold against all 16 normalized
// decoder classes, then injects each asynchronous/synchronous boundary event
// at an LFSR-selected legal cycle. ABORT is constrained to a live opcode,
// data-read, or data-write response. Coprocessor responses are constrained to
// the three legal {CPA,CPB} pairs. Required bins are closed independently for
// every seed rather than accumulated across a lucky campaign.

`timescale 1ns/1ps

module arm7tdmis_random_event_matrix_tb
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_instr_pkg::*;
    import arm7tdmis_types_pkg::*;
;

    // Random choices intentionally consume only the low bits needed by each
    // bounded decision.
    /* verilator lint_off UNUSEDSIGNAL */

    localparam int INSTR_CLASS_COUNT = 16;
    localparam logic [15:0] REQUIRED_CLASS_MASK = 16'hffff;

    localparam int EVENT_ABORT_OPCODE = 0;
    localparam int EVENT_ABORT_READ   = 1;
    localparam int EVENT_ABORT_WRITE  = 2;
    localparam int EVENT_IRQ          = 3;
    localparam int EVENT_FIQ          = 4;
    localparam int EVENT_RESET        = 5;
    localparam int EVENT_DBGRQ        = 6;
    localparam int EVENT_CP_READY     = 7;
    localparam int EVENT_CP_BUSY      = 8;
    localparam int EVENT_CP_ABSENT    = 9;
    localparam logic [9:0] REQUIRED_EVENT_MASK = 10'h3ff;

    localparam logic [31:0] TEST_PC = 32'h0000_0040;
    localparam logic [31:0] DATA_ADDRESS = 32'h0000_0100;
    localparam int MAX_WAIT_CYCLES = 400;

    logic CLK;
    initial begin
        CLK = 1'b0;
        forever #5 CLK = ~CLK;
    end

    logic nRESET = 1'b0;
    logic CLKEN = 1'b1;
    logic nIRQ = 1'b1;
    logic nFIQ = 1'b1;
    logic inject_abort = 1'b0;
    logic DBGEN = 1'b0;
    logic DBGRQ = 1'b0;
    logic CPA = 1'b1;
    logic CPB = 1'b1;

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
        .CLK, .CLKEN, .nRESET, .CFGBIGEND(1'b0),
        .nIRQ, .nFIQ, .ABORT,
        .ADDR, .WRITE, .SIZE, .PROT, .LOCK, .TRANS, .WDATA, .RDATA,
        .CPnMREQ, .CPSEQ, .CPnTRANS, .CPnOPC, .CPTBIT, .CPnI,
        .CPA, .CPB,
        .DBGEN, .DBGRQ, .DBGBREAK(1'b0),
        .DBGACK, .DBGnEXEC, .DBGINSTRVALID, .DBGEXT(2'b00), .DBGRNG,
        .DBGCOMMTX, .DBGCOMMRX,
        .DBGTCKEN(1'b0), .DBGTMS(1'b0), .DBGTDI(1'b0),
        .DBGTDO, .DBGnTRST(1'b1), .DBGnTDOEN, .DMORE
    );

    arm7tdmis_memory #(
        .WORDS(256)
    ) u_mem (
        .CLK, .CLKEN, .nRESET, .CFGBIGEND(1'b0),
        .ADDR, .WRITE, .SIZE, .PROT, .LOCK, .TRANS, .WDATA, .RDATA,
        .ABORT, .inject_abort
    );

    int unsigned seed;
    logic [31:0] lfsr;
    int unsigned decision_count = 0;
    int unsigned consecutive_stalls = 0;
    logic [15:0] class_mask = '0;
    logic [15:0] class_stall_mask = '0;
    logic [9:0] event_mask = '0;

    int unsigned prefetch_abort_count;
    int unsigned data_abort_count;
    int unsigned irq_count;
    int unsigned fiq_count;
    int unsigned undef_count;

    always @(posedge CLK) begin
        if (!nRESET) begin
            prefetch_abort_count <= 0;
            data_abort_count <= 0;
            irq_count <= 0;
            fiq_count <= 0;
            undef_count <= 0;
        end else if (CLKEN) begin
            if (u_dut.u_core.pabt_fires)
                prefetch_abort_count <= prefetch_abort_count + 1;
            if (u_dut.u_core.dabt_fires)
                data_abort_count <= data_abort_count + 1;
            if (u_dut.u_core.irq_fires)
                irq_count <= irq_count + 1;
            if (u_dut.u_core.fiq_fires)
                fiq_count <= fiq_count + 1;
            if (u_dut.u_core.undef_fires)
                undef_count <= undef_count + 1;
        end
    end

    // This is both an executable assertion and an easy-to-audit statement
    // of the constrained ABORT generator's legality rule.
    always_comb begin
        if (ABORT && !u_mem.is_active_q)
            $fatal(1, "[random_events] ABORT outside an active response");
    end

    function automatic logic [31:0] class_opcode(input int class_index);
        unique case (class_index)
            0:  return 32'hE7F0_00F0; // INSTR_UNDEF
            1:  return 32'hE1A0_3001; // INSTR_DP: MOV r3,r1
            2:  return 32'hE128_F000; // INSTR_MSR: MSR CPSR_f,r0
            3:  return 32'hE10F_3000; // INSTR_MRS: MRS r3,CPSR
            4:  return 32'hE003_0291; // INSTR_MUL
            5:  return 32'hE084_3291; // INSTR_MULL
            6:  return 32'hEA00_0000; // INSTR_BRANCH
            7:  return 32'hE12F_FF11; // INSTR_BX: BX r1
            8:  return 32'hE590_3000; // INSTR_LDR_STR
            9:  return 32'hE1D0_30B0; // INSTR_LDRH_STRH
            10: return 32'hE890_0006; // INSTR_LDM_STM
            11: return 32'hE100_3092; // INSTR_SWP
            12: return 32'hEF00_0000; // INSTR_SWI
            13: return 32'hEE00_0000; // INSTR_CDP
            14: return 32'hEE00_0010; // INSTR_MCR_MRC
            15: return 32'hED90_0000; // INSTR_LDC_STC
            default: return 32'hxxxx_xxxx;
        endcase
    endfunction

    task automatic fail(input string reason);
        $fatal(1, "[random_events] FAIL seed=%0d: %s", seed, reason);
    endtask

    task automatic random_word(output logic [31:0] value);
        logic feedback;
        feedback = lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0];
        lfsr = {lfsr[30:0], feedback};
        if (lfsr == 0)
            lfsr = 32'h1;
        value = lfsr;
        decision_count++;
    endtask

    task automatic random_clken_edge;
        logic [31:0] choice;
        @(negedge CLK);
        random_word(choice);
        if (consecutive_stalls >= 3 || choice[1:0] != 0) begin
            CLKEN = 1'b1;
            consecutive_stalls = 0;
        end else begin
            CLKEN = 1'b0;
            consecutive_stalls++;
        end
        @(posedge CLK);
        #1;
    endtask

    task automatic drive_cp_response(input coproc_handshake_e response);
        unique case (response)
            CP_PRESENT_READY: begin
                CPA = 1'b0;
                CPB = 1'b0;
            end
            CP_PRESENT_BUSY: begin
                CPA = 1'b0;
                CPB = 1'b1;
            end
            CP_ABSENT: begin
                CPA = 1'b1;
                CPB = 1'b1;
            end
            default: fail("attempted illegal {CPA,CPB} response");
        endcase
    endtask

    task automatic setup_common_program(input logic [31:0] opcode);
        for (int word = 0; word < 256; word++)
            u_mem.mem[word] = 32'hEAFF_FFFE;
        u_mem.mem[0] = 32'hEA00_0006;  // reset -> 0x20
        u_mem.mem[8] = 32'hE3A0_0C01;  // r0 = DATA_ADDRESS
        u_mem.mem[9] = 32'hE3A0_1048;  // r1 = 0x48 (legal BX target)
        u_mem.mem[10] = 32'hE3A0_2004; // r2 = 4
        u_mem.mem[11] = 32'hE3A0_3005; // r3 = 5
        u_mem.mem[12] = 32'hE3A0_4006; // r4 = 6
        u_mem.mem[13] = 32'hE1A0_0000;
        u_mem.mem[14] = 32'hE1A0_0000;
        u_mem.mem[15] = 32'hE1A0_0000;
        u_mem.mem[16] = opcode;
        u_mem.mem[17] = 32'hEAFF_FFFD; // 0x44 -> 0x40
        u_mem.mem[18] = 32'hEAFF_FFFE;
        u_mem.mem[DATA_ADDRESS >> 2] = 32'h1122_3344;
    endtask

    task automatic begin_case(input logic [31:0] opcode);
        @(negedge CLK);
        nRESET = 1'b0;
        CLKEN = 1'b1;
        nIRQ = 1'b1;
        nFIQ = 1'b1;
        inject_abort = 1'b0;
        DBGEN = 1'b0;
        DBGRQ = 1'b0;
        drive_cp_response(CP_PRESENT_READY);
        consecutive_stalls = 0;
        repeat (4) @(posedge CLK);
        setup_common_program(opcode);
        @(negedge CLK);
        nRESET = 1'b1;
    endtask

    task automatic wait_target_execute(input int expected_class);
        int cycles;
        cycles = 0;
        while (!(u_dut.u_core.state_q == 5'd0
                 && u_dut.u_core.de_q.valid
                 && u_dut.u_core.de_q.pc == TEST_PC)) begin
            random_clken_edge();
            cycles++;
            if (cycles > MAX_WAIT_CYCLES)
                fail($sformatf(
                    "class %0d did not reach Execute", expected_class
                ));
        end
        if (u_dut.u_core.de_q.dec.instr_class
            !== instr_class_e'(expected_class))
            fail($sformatf(
                "opcode %08x decoded as %0d, expected class %0d",
                u_dut.u_core.de_q.instr,
                u_dut.u_core.de_q.dec.instr_class,
                expected_class
            ));
    endtask

    task automatic stall_current_class(input int class_index);
        logic [31:0] choice;
        logic [114:0] original_outputs;
        logic [114:0] held_outputs;
        logic [4:0] frozen_state;
        logic [31:0] frozen_pc;
        logic [31:0] frozen_cpsr;
        logic frozen_valid;
        logic [31:0] frozen_de_pc;
        logic [31:0] frozen_de_instr;
        int hold_cycles;

        random_word(choice);
        hold_cycles = 2 + int'(choice[1:0]);
        @(negedge CLK);
        original_outputs = {
            ADDR, WDATA, RDATA, WRITE, SIZE, PROT, LOCK, TRANS,
            ABORT, DMORE, CPnMREQ, CPSEQ, CPnTRANS, CPnOPC,
            CPTBIT, CPnI, DBGACK, DBGnEXEC, DBGINSTRVALID
        };
        frozen_state = u_dut.u_core.state_q;
        frozen_pc = u_dut.u_core.pc_q;
        frozen_cpsr = u_dut.u_core.cpsr;
        frozen_valid = u_dut.u_core.de_q.valid;
        frozen_de_pc = u_dut.u_core.de_q.pc;
        frozen_de_instr = u_dut.u_core.de_q.instr;
        CLKEN = 1'b0;

        @(posedge CLK);
        #1;
        held_outputs = {
            ADDR, WDATA, RDATA, WRITE, SIZE, PROT, LOCK, TRANS,
            ABORT, DMORE, CPnMREQ, CPSEQ, CPnTRANS, CPnOPC,
            CPTBIT, CPnI, DBGACK, DBGnEXEC, DBGINSTRVALID
        };
        if (u_dut.u_core.state_q !== frozen_state
            || u_dut.u_core.pc_q !== frozen_pc
            || u_dut.u_core.cpsr !== frozen_cpsr
            || u_dut.u_core.de_q.valid !== frozen_valid
            || u_dut.u_core.de_q.pc !== frozen_de_pc
            || u_dut.u_core.de_q.instr !== frozen_de_instr)
            fail($sformatf("class %0d advanced on stopped edge", class_index));

        repeat (hold_cycles - 1) begin
            @(posedge CLK);
            #1;
            if ({
                    ADDR, WDATA, RDATA, WRITE, SIZE, PROT, LOCK, TRANS,
                    ABORT, DMORE, CPnMREQ, CPSEQ, CPnTRANS, CPnOPC,
                    CPTBIT, CPnI, DBGACK, DBGnEXEC, DBGINSTRVALID
                } !== held_outputs)
                fail($sformatf(
                    "class %0d changed pins during CLKEN hold", class_index
                ));
            if (u_dut.u_core.state_q !== frozen_state
                || u_dut.u_core.pc_q !== frozen_pc
                || u_dut.u_core.cpsr !== frozen_cpsr
                || u_dut.u_core.de_q.valid !== frozen_valid
                || u_dut.u_core.de_q.pc !== frozen_de_pc
                || u_dut.u_core.de_q.instr !== frozen_de_instr)
                fail($sformatf(
                    "class %0d changed state during CLKEN hold", class_index
                ));
        end

        @(negedge CLK);
        CLKEN = 1'b1;
        #1;
        if ({
                ADDR, WDATA, RDATA, WRITE, SIZE, PROT, LOCK, TRANS,
                ABORT, DMORE, CPnMREQ, CPSEQ, CPnTRANS, CPnOPC,
                CPTBIT, CPnI, DBGACK, DBGnEXEC, DBGINSTRVALID
            } !== original_outputs)
            fail($sformatf(
                "class %0d pins did not restore after CLKEN hold",
                class_index
            ));
        class_mask[class_index] = 1'b1;
        class_stall_mask[class_index] = 1'b1;
    endtask

    task automatic run_class_stalls;
        for (int class_index = 0;
             class_index < INSTR_CLASS_COUNT;
             class_index++) begin
            begin_case(class_opcode(class_index));
            wait_target_execute(class_index);
            stall_current_class(class_index);
        end
    endtask

    task automatic wait_abort_response(
        input logic [31:0] address,
        input logic expected_write
    );
        logic [31:0] choice;
        int matches_to_skip;
        int cycles;

        random_word(choice);
        matches_to_skip = int'(choice[2:0]);
        cycles = 0;
        while (1) begin
            random_clken_edge();
            cycles++;
            if (u_mem.is_active_q
                && u_mem.addr_q == address
                && u_mem.write_q == expected_write) begin
                if (matches_to_skip == 0)
                    return;
                matches_to_skip--;
            end
            if (cycles > MAX_WAIT_CYCLES)
                fail($sformatf(
                    "response %08x/%0d was not observed", address,
                    expected_write
                ));
        end
    endtask

    task automatic inject_one_abort(
        input logic [31:0] address,
        input logic expected_write,
        input int event_index,
        input bit prefetch
    );
        int before_count;
        int cycles;

        begin_case(
            prefetch ? 32'hE1A0_3001
                     : expected_write ? 32'hE580_3000
                                      : 32'hE590_3000
        );
        before_count = prefetch ? prefetch_abort_count : data_abort_count;
        wait_abort_response(address, expected_write);
        @(negedge CLK);
        CLKEN = 1'b1;
        inject_abort = 1'b1;
        #1;
        if (!ABORT || !u_mem.is_active_q)
            fail("legal ABORT injection was not presented to the core");
        @(posedge CLK);
        #1;
        @(negedge CLK);
        inject_abort = 1'b0;

        cycles = 0;
        while ((prefetch ? prefetch_abort_count : data_abort_count)
               == before_count) begin
            random_clken_edge();
            cycles++;
            if (cycles > MAX_WAIT_CYCLES)
                fail(prefetch
                     ? "prefetch ABORT did not take Prefetch Abort"
                     : "data ABORT did not take Data Abort");
        end
        if (u_dut.u_core.cpsr.m != 5'(MODE_ABORT))
            fail("ABORT did not enter Abort mode");
        event_mask[event_index] = 1'b1;
    endtask

    task automatic setup_interrupt_program;
        setup_common_program(32'hE1A0_0000);
        u_mem.mem[16] = 32'hE10F_0000; // MRS r0,CPSR
        u_mem.mem[17] = 32'hE3C0_00C0; // clear I and F
        u_mem.mem[18] = 32'hE121_F000; // MSR CPSR_c,r0
        u_mem.mem[19] = 32'hE1A0_0000;
        u_mem.mem[20] = 32'hEAFF_FFFE; // 0x50 loop
    endtask

    task automatic begin_interrupt_case;
        @(negedge CLK);
        nRESET = 1'b0;
        CLKEN = 1'b1;
        nIRQ = 1'b1;
        nFIQ = 1'b1;
        inject_abort = 1'b0;
        DBGEN = 1'b0;
        DBGRQ = 1'b0;
        drive_cp_response(CP_PRESENT_READY);
        consecutive_stalls = 0;
        repeat (4) @(posedge CLK);
        setup_interrupt_program();
        @(negedge CLK);
        nRESET = 1'b1;
    endtask

    task automatic run_interrupt(input bit fiq);
        logic [31:0] choice;
        int delay_cycles;
        int before_count;
        int cycles;

        begin_interrupt_case();
        cycles = 0;
        while (u_dut.u_core.cpsr.i || u_dut.u_core.cpsr.f) begin
            random_clken_edge();
            cycles++;
            if (cycles > MAX_WAIT_CYCLES)
                fail("interrupt masks were not cleared");
        end

        random_word(choice);
        delay_cycles = int'(choice[3:0]);
        repeat (delay_cycles)
            random_clken_edge();
        before_count = fiq ? fiq_count : irq_count;

        @(negedge CLK);
        CLKEN = 1'b1;
        if (fiq)
            nFIQ = 1'b0;
        else
            nIRQ = 1'b0;
        @(posedge CLK);
        #1;

        cycles = 0;
        while ((fiq ? fiq_count : irq_count) == before_count) begin
            random_clken_edge();
            cycles++;
            if (cycles > MAX_WAIT_CYCLES)
                fail(fiq ? "FIQ was not taken" : "IRQ was not taken");
        end
        @(negedge CLK);
        nIRQ = 1'b1;
        nFIQ = 1'b1;
        if (u_dut.u_core.cpsr.m
            != (fiq ? 5'(MODE_FIQ) : 5'(MODE_IRQ)))
            fail(fiq ? "FIQ mode entry mismatch" : "IRQ mode entry mismatch");
        event_mask[fiq ? EVENT_FIQ : EVENT_IRQ] = 1'b1;
    endtask

    task automatic run_random_reset;
        logic [31:0] choice;
        int reset_cycles;
        int class_index;

        random_word(choice);
        class_index = int'(choice[3:0]);
        begin_case(class_opcode(class_index));
        wait_target_execute(class_index);
        random_word(choice);
        reset_cycles = 1 + int'(choice[1:0]);
        @(negedge CLK);
        CLKEN = choice[4];
        nRESET = 1'b0;
        repeat (reset_cycles) @(posedge CLK);
        #1;
        if (u_dut.u_core.cpsr.m !== 5'(MODE_SUPERVISOR)
            || !u_dut.u_core.cpsr.i
            || !u_dut.u_core.cpsr.f
            || u_dut.u_core.cpsr.t
            || TRANS !== 2'(TRANS_I)
            || LOCK
            || DMORE)
            fail("reset did not clear architectural and bus state");
        event_mask[EVENT_RESET] = 1'b1;
    endtask

    task automatic run_dbgrq;
        logic [31:0] choice;
        int delay_cycles;
        int cycles;

        begin_case(32'hE1A0_0000);
        DBGEN = 1'b1;
        wait_target_execute(int'(INSTR_DP));
        random_word(choice);
        delay_cycles = int'(choice[3:0]);
        repeat (delay_cycles)
            random_clken_edge();
        @(negedge CLK);
        CLKEN = 1'b1;
        DBGRQ = 1'b1;
        @(posedge CLK);
        #1;

        cycles = 0;
        while (!DBGACK) begin
            random_clken_edge();
            cycles++;
            if (cycles > MAX_WAIT_CYCLES)
                fail("DBGRQ did not enter debug halt");
        end
        @(negedge CLK);
        DBGRQ = 1'b0;
        if (!DBGACK)
            fail("debug acknowledge was not held at the halt boundary");
        event_mask[EVENT_DBGRQ] = 1'b1;
    endtask

    task automatic run_cp_response(input coproc_handshake_e response);
        logic [31:0] choice;
        int busy_cycles;
        int before_undef;
        int cycles;

        begin_case(32'hEE00_0000); // CDP p0,0,c0,c0,c0
        drive_cp_response(response);
        before_undef = undef_count;
        wait_target_execute(int'(INSTR_CDP));
        @(negedge CLK);
        if (CPnI)
            fail("CDP did not assert CPnI");

        unique case (response)
            CP_PRESENT_READY: begin
                if (CPA || CPB)
                    fail("ready coprocessor pair was not 00");
                @(posedge CLK);
                #1;
                event_mask[EVENT_CP_READY] = 1'b1;
            end
            CP_PRESENT_BUSY: begin
                if (CPA || !CPB)
                    fail("busy coprocessor pair was not 01");
                random_word(choice);
                busy_cycles = 1 + int'(choice[2:0]);
                @(posedge CLK);
                #1;
                while (busy_cycles > 0) begin
                    random_clken_edge();
                    if (CLKEN)
                        busy_cycles--;
                    if (CPnI)
                        fail("CPnI released during legal busy wait");
                end
                @(negedge CLK);
                CLKEN = 1'b1;
                drive_cp_response(CP_PRESENT_READY);
                @(posedge CLK);
                #1;
                event_mask[EVENT_CP_BUSY] = 1'b1;
            end
            CP_ABSENT: begin
                if (!CPA || !CPB)
                    fail("absent coprocessor pair was not 11");
                @(posedge CLK);
                #1;
                cycles = 0;
                while (undef_count == before_undef) begin
                    random_clken_edge();
                    cycles++;
                    if (cycles > MAX_WAIT_CYCLES)
                        fail("absent coprocessor did not take Undefined");
                end
                event_mask[EVENT_CP_ABSENT] = 1'b1;
            end
            default: fail("illegal coprocessor scenario");
        endcase
    endtask

    task automatic finish_minimum_random_decisions;
        begin_case(32'hE1A0_0000);
        while (decision_count < 256)
            random_clken_edge();
    endtask

    initial begin
        if (!$value$plusargs("SEED=%d", seed))
            fail("missing +SEED");
        lfsr = seed ^ 32'h9e37_79b9;
        if (lfsr == 0)
            lfsr = 32'h1;

        run_class_stalls();
        inject_one_abort(
            TEST_PC, 1'b0, EVENT_ABORT_OPCODE, 1'b1
        );
        inject_one_abort(
            DATA_ADDRESS, 1'b0, EVENT_ABORT_READ, 1'b0
        );
        inject_one_abort(
            DATA_ADDRESS, 1'b1, EVENT_ABORT_WRITE, 1'b0
        );
        run_interrupt(1'b0);
        run_interrupt(1'b1);
        run_random_reset();
        run_dbgrq();
        run_cp_response(CP_PRESENT_READY);
        run_cp_response(CP_PRESENT_BUSY);
        run_cp_response(CP_ABSENT);
        finish_minimum_random_decisions();

        if (class_mask !== REQUIRED_CLASS_MASK)
            fail($sformatf("missing class bins: %04x", ~class_mask));
        if (class_stall_mask !== REQUIRED_CLASS_MASK)
            fail($sformatf(
                "missing class-stall bins: %04x", ~class_stall_mask
            ));
        if (event_mask !== REQUIRED_EVENT_MASK)
            fail($sformatf("missing event bins: %03x", ~event_mask));
        if (decision_count < 256)
            fail("random decision floor was not met");

        $display(
            "[random_events] PASS seed=%0d classes=%04x stalls=%04x events=%04x decisions=%0d",
            seed, class_mask, class_stall_mask, event_mask, decision_count
        );
        $finish;
    end

    initial begin
        repeat (20000) @(posedge CLK);
        fail("TIMEOUT");
    end

    wire _unused = &{
        1'b0, SIZE, PROT, WDATA, CPnMREQ, CPSEQ, CPnTRANS, CPnOPC,
        CPTBIT, DBGnEXEC, DBGINSTRVALID, DBGRNG, DBGCOMMTX, DBGCOMMRX,
        DBGTDO, DBGnTDOEN
    };
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
