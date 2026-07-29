// VER-009 contract test.
//
// Scoreboards must be able to observe architectural completion without
// reaching into u_core, its pipeline registers, the regfile, or the PSR
// implementation.  This program crosses ARM/Thumb state, a failed condition,
// store/load multicycle paths, a PC redirect, and synchronous exception entry.
// Every instruction is expected exactly once with a post-event banked-state
// snapshot.

`timescale 1ns/1ps

module arm7tdmis_retire_interface_tb
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_types_pkg::*;
;

    localparam int EXPECTED_EVENTS = 11;

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

    logic         VER_RETIRE_VALID;
    logic [31:0]  VER_RETIRE_PC;
    logic [31:0]  VER_RETIRE_OPCODE;
    logic         VER_RETIRE_THUMB;
    logic         VER_RETIRE_CONDITION_PASS;
    logic         VER_RETIRE_INJECTED;
    logic         VER_RETIRE_EXCEPTION_VALID;
    logic [2:0]   VER_RETIRE_EXCEPTION;
    logic [991:0] VER_RETIRE_GPRS;
    logic [31:0]  VER_RETIRE_CPSR;
    logic [159:0] VER_RETIRE_SPSRS;

    arm7tdmis_top u_dut (
        .CLK(CLK), .CLKEN(1'b1), .nRESET(nRESET),
        .CFGBIGEND(1'b0), .nIRQ(1'b1), .nFIQ(1'b1), .ABORT(ABORT),
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
        .DBGnTRST(1'b1), .DBGnTDOEN(DBGnTDOEN), .DMORE(DMORE),
        .VER_RETIRE_VALID(VER_RETIRE_VALID),
        .VER_RETIRE_PC(VER_RETIRE_PC),
        .VER_RETIRE_OPCODE(VER_RETIRE_OPCODE),
        .VER_RETIRE_THUMB(VER_RETIRE_THUMB),
        .VER_RETIRE_CONDITION_PASS(VER_RETIRE_CONDITION_PASS),
        .VER_RETIRE_INJECTED(VER_RETIRE_INJECTED),
        .VER_RETIRE_EXCEPTION_VALID(VER_RETIRE_EXCEPTION_VALID),
        .VER_RETIRE_EXCEPTION(VER_RETIRE_EXCEPTION),
        .VER_RETIRE_GPRS(VER_RETIRE_GPRS),
        .VER_RETIRE_CPSR(VER_RETIRE_CPSR),
        .VER_RETIRE_SPSRS(VER_RETIRE_SPSRS)
    );

    arm7tdmis_memory #(.WORDS(256)) u_mem (
        .CLK(CLK), .CLKEN(1'b1), .nRESET(nRESET),
        .CFGBIGEND(1'b0),
        .ADDR(ADDR), .WRITE(WRITE), .SIZE(SIZE), .PROT(PROT),
        .LOCK(LOCK), .TRANS(TRANS), .WDATA(WDATA), .RDATA(RDATA),
        .ABORT(ABORT), .inject_abort(1'b0)
    );

    logic [31:0] expected_pc     [0:EXPECTED_EVENTS-1];
    logic [31:0] expected_opcode [0:EXPECTED_EVENTS-1];
    logic        expected_thumb  [0:EXPECTED_EVENTS-1];
    logic        expected_cond   [0:EXPECTED_EVENTS-1];
    int unsigned event_count;

    function automatic logic [31:0] physical_gpr(input int index);
        return VER_RETIRE_GPRS[(index * 32) +: 32];
    endfunction

    function automatic logic [31:0] saved_psr(input int index);
        return VER_RETIRE_SPSRS[(index * 32) +: 32];
    endfunction

    task automatic fail(input string reason);
        $fatal(1, "[retire_interface] FAIL event %0d: %s",
               event_count, reason);
    endtask

    task automatic check_snapshot;
        unique case (event_count)
            1: if (physical_gpr(0) !== 32'd1)
                   fail("MOV r0 post-state missing");
            2: if (physical_gpr(0) !== 32'd1)
                   fail("condition-failed ADD changed r0");
            3: if (physical_gpr(2) !== 32'h80)
                   fail("MOV r2 post-state missing");
            4: if (physical_gpr(1) !== 32'd3)
                   fail("ADD r1 post-state missing");
            5: if (physical_gpr(1) !== 32'd3)
                   fail("store event corrupted source register");
            6: if (physical_gpr(3) !== 32'd3)
                   fail("load result absent from retirement snapshot");
            7: if (physical_gpr(4) !== 32'h41)
                   fail("interworking target register missing");
            9: if (physical_gpr(5) !== 32'd7)
                   fail("Thumb MOV result absent from snapshot");
            10: begin
                if (physical_gpr(26) !== 32'h44)
                    fail("SWI did not expose SVC r14 link");
                if (VER_RETIRE_CPSR[4:0] !== 5'(MODE_SUPERVISOR)
                    || VER_RETIRE_CPSR[5] !== 1'b0)
                    fail("SWI post-state CPSR is not ARM Supervisor");
                if (saved_psr(2)[5] !== 1'b1
                    || saved_psr(2)[4:0] !== 5'(MODE_SUPERVISOR))
                    fail("SWI did not expose pre-entry Thumb SPSR_svc");
            end
            default: ;
        endcase
    endtask

    always @(posedge CLK) begin
        #1;
        if (VER_RETIRE_VALID) begin
            if (event_count >= EXPECTED_EVENTS)
                fail("ghost retirement after expected program");
            if (VER_RETIRE_PC !== expected_pc[event_count])
                fail($sformatf("PC expected %08x got %08x",
                               expected_pc[event_count], VER_RETIRE_PC));
            if (VER_RETIRE_OPCODE !== expected_opcode[event_count])
                fail($sformatf("opcode expected %08x got %08x",
                               expected_opcode[event_count],
                               VER_RETIRE_OPCODE));
            if (VER_RETIRE_THUMB !== expected_thumb[event_count])
                fail("instruction-state tag mismatch");
            if (VER_RETIRE_CONDITION_PASS !== expected_cond[event_count])
                fail("condition result mismatch");
            if (VER_RETIRE_INJECTED)
                fail("normal program event tagged as debug injection");
            if (VER_RETIRE_EXCEPTION_VALID
                !== (event_count == EXPECTED_EVENTS-1))
                fail("exception-valid pulse mismatch");
            if (VER_RETIRE_EXCEPTION_VALID
                && VER_RETIRE_EXCEPTION !== 3'(EXC_SWI))
                fail("wrong exception cause");

            check_snapshot();
            event_count <= event_count + 1;
            if ((event_count + 1) == EXPECTED_EVENTS) begin
                $display("[retire_interface] PASS (%0d events)",
                         event_count + 1);
                $finish;
            end
        end else if (VER_RETIRE_EXCEPTION_VALID) begin
            fail("exception event lacked an instruction disposition");
        end
    end

    initial begin
        event_count = 0;
        for (int word = 0; word < 256; word++)
            u_mem.mem[word] = 32'hEAFF_FFFE;

        u_mem.mem[0]  = 32'hEA00_0006; // 0x00: B 0x20
        u_mem.mem[2]  = 32'hEA00_003C; // 0x08: SWI handler B 0x100
        u_mem.mem[8]  = 32'hE3A0_0001; // 0x20: MOV   r0,#1
        u_mem.mem[9]  = 32'h0280_0001; // 0x24: ADDEQ r0,r0,#1 (fails)
        u_mem.mem[10] = 32'hE3A0_2080; // 0x28: MOV   r2,#0x80
        u_mem.mem[11] = 32'hE280_1002; // 0x2c: ADD   r1,r0,#2
        u_mem.mem[12] = 32'hE582_1000; // 0x30: STR   r1,[r2]
        u_mem.mem[13] = 32'hE592_3000; // 0x34: LDR   r3,[r2]
        u_mem.mem[14] = 32'hE3A0_4041; // 0x38: MOV   r4,#0x41
        u_mem.mem[15] = 32'hE12F_FF14; // 0x3c: BX    r4
        u_mem.mem[16] = 32'hDF00_2507; // 0x40: MOVS r5,#7; SWI #0

        expected_pc[0]      = 32'h00;
        expected_opcode[0]  = 32'hEA00_0006;
        expected_thumb[0]   = 1'b0;
        expected_cond[0]    = 1'b1;
        expected_pc[1]      = 32'h20;
        expected_opcode[1]  = 32'hE3A0_0001;
        expected_thumb[1]   = 1'b0;
        expected_cond[1]    = 1'b1;
        expected_pc[2]      = 32'h24;
        expected_opcode[2]  = 32'h0280_0001;
        expected_thumb[2]   = 1'b0;
        expected_cond[2]    = 1'b0;
        expected_pc[3]      = 32'h28;
        expected_opcode[3]  = 32'hE3A0_2080;
        expected_thumb[3]   = 1'b0;
        expected_cond[3]    = 1'b1;
        expected_pc[4]      = 32'h2c;
        expected_opcode[4]  = 32'hE280_1002;
        expected_thumb[4]   = 1'b0;
        expected_cond[4]    = 1'b1;
        expected_pc[5]      = 32'h30;
        expected_opcode[5]  = 32'hE582_1000;
        expected_thumb[5]   = 1'b0;
        expected_cond[5]    = 1'b1;
        expected_pc[6]      = 32'h34;
        expected_opcode[6]  = 32'hE592_3000;
        expected_thumb[6]   = 1'b0;
        expected_cond[6]    = 1'b1;
        expected_pc[7]      = 32'h38;
        expected_opcode[7]  = 32'hE3A0_4041;
        expected_thumb[7]   = 1'b0;
        expected_cond[7]    = 1'b1;
        expected_pc[8]      = 32'h3c;
        expected_opcode[8]  = 32'hE12F_FF14;
        expected_thumb[8]   = 1'b0;
        expected_cond[8]    = 1'b1;
        expected_pc[9]      = 32'h40;
        expected_opcode[9]  = 32'h0000_2507;
        expected_thumb[9]   = 1'b1;
        expected_cond[9]    = 1'b1;
        expected_pc[10]     = 32'h42;
        expected_opcode[10] = 32'h0000_DF00;
        expected_thumb[10]  = 1'b1;
        expected_cond[10]   = 1'b1;

        repeat (4) @(posedge CLK);
        nRESET = 1'b1;
    end

    initial begin
        repeat (220) @(posedge CLK);
        $fatal(1, "[retire_interface] TIMEOUT after %0d/%0d events",
               event_count, EXPECTED_EVENTS);
    end

    // The contract test consumes only architectural retirement outputs.
    // Drain unrelated pin-level status so -Wall remains a zero-warning gate.
    wire _unused_pin_status = &{1'b0,
        CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI,
        DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG,
        DBGCOMMTX, DBGCOMMRX, DBGTDO, DBGnTDOEN, DMORE,
        VER_RETIRE_CPSR[31:6]};

endmodule
