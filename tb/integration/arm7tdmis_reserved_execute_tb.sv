// ISA-007 pin-level execution matrix for ARMv4T reserved encodings.
//
// Every row starts from reset, executes a representative reserved encoding,
// and requires precise Undefined entry.  The matrix covers each distinct
// Thumb reserved range, every ARM extension-space family that used to leak
// into an implemented class, and the repository's deterministic trap policy
// for ARMv4 cond=1111 (architecturally UNPREDICTABLE).

`timescale 1ns/1ps

module arm7tdmis_reserved_execute_tb
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_types_pkg::*;
;

    localparam int CASE_COUNT = 12;
    localparam logic [31:0] DATA_SENTINEL = 32'hCAFE_BABE;

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
        .DBGnTRST(1'b1), .DBGnTDOEN(DBGnTDOEN), .DMORE(DMORE)
    );

    arm7tdmis_memory #(
        .WORDS(128)
    ) u_mem (
        .CLK(CLK), .CLKEN(1'b1), .nRESET(nRESET),
        .CFGBIGEND(1'b0),
        .ADDR(ADDR), .WRITE(WRITE), .SIZE(SIZE), .PROT(PROT),
        .LOCK(LOCK), .TRANS(TRANS), .WDATA(WDATA), .RDATA(RDATA),
        .ABORT(ABORT), .inject_abort(1'b0)
    );

    int unsigned errors;

    task automatic fail(input int case_id, input string label);
        $display("[reserved_execute] FAIL case %0d: %s", case_id, label);
        errors++;
    endtask

    task automatic setup_case(
        input  int          case_id,
        output string       label,
        output logic [31:0] expected_lr,
        output logic [31:0] expected_spsr
    );
        logic [31:0] arm_opcode;
        logic [15:0] thumb_opcode;
        logic        thumb_case;

        for (int word = 0; word < 128; word++)
            u_mem.mem[word] = 32'hEAFF_FFFE;

        // Reset and Undefined vectors.
        u_mem.mem[0]  = 32'hEA00_0006; // B 0x20
        u_mem.mem[1]  = 32'hEA00_001D; // B 0x80
        u_mem.mem[32] = 32'hE3A0_7000 | 32'(case_id); // handler marker
        u_mem.mem[33] = 32'hEAFF_FFFE; // B .
        u_mem.mem[64] = DATA_SENTINEL;

        thumb_case   = (case_id >= 8);
        expected_lr  = thumb_case ? 32'h0000_0042 : 32'h0000_0030;
        expected_spsr = thumb_case ? 32'h0000_00F3 : 32'h0000_00D3;
        arm_opcode   = 32'hE7F0_00F0;
        thumb_opcode = 16'hDE00;

        unique case (case_id)
            1: begin
                label      = "ARM signed-byte store hole";
                arm_opcode = 32'hE1C3_20D0;
            end
            2: begin
                label      = "ARM signed-halfword store hole";
                arm_opcode = 32'hE1C3_20F0;
            end
            3: begin
                label      = "ARM multiply extension hole";
                arm_opcode = 32'hE040_0090;
            end
            4: begin
                label      = "ARM control extension hole";
                arm_opcode = 32'hE100_0010;
            end
            5: begin
                label      = "ARMv5 coprocessor extension";
                arm_opcode = 32'hEC40_0000;
            end
            6: begin
                label      = "ARM media extension";
                arm_opcode = 32'hE600_0010;
            end
            7: begin
                label      = "ARM cond=1111 BLX-immediate pattern";
                arm_opcode = 32'hFA00_0000;
            end
            8: begin
                label        = "Thumb B1xx reserved range";
                thumb_opcode = 16'hB100;
            end
            9: begin
                label        = "Thumb B6xx-BBxx reserved range";
                thumb_opcode = 16'hB600;
            end
            10: begin
                label        = "Thumb BExx-BFxx reserved range";
                thumb_opcode = 16'hBE00;
            end
            11: begin
                label        = "Thumb conditional branch cond=1110";
                thumb_opcode = 16'hDE00;
            end
            default: begin
                label        = "Thumb ARMv5T BLX-suffix range";
                thumb_opcode = 16'hE800;
            end
        endcase

        if (!thumb_case) begin
            u_mem.mem[8]  = 32'hE3A0_005A; // MOV r0,#0x5a
            u_mem.mem[9]  = 32'hE3A0_20A5; // MOV r2,#0xa5
            u_mem.mem[10] = 32'hE3A0_3C01; // MOV r3,#0x100
            u_mem.mem[11] = arm_opcode;    // reserved at 0x2c
            u_mem.mem[12] = 32'hE3A0_10A5; // must be flushed
            u_mem.mem[13] = 32'hEAFF_FFFE; // B .
        end else begin
            u_mem.mem[8]  = 32'hE3A0_005A; // MOV r0,#0x5a
            u_mem.mem[9]  = 32'hE59F_200C; // LDR r2,[pc,#0xc]
            u_mem.mem[10] = 32'hE12F_FF12; // BX r2
            u_mem.mem[14] = 32'h0000_0041;
            // Reserved at 0x40, followed by MOVS r1,#0xa5 at 0x42.
            u_mem.mem[16] = {16'h21A5, thumb_opcode};
            u_mem.mem[17] = 32'hE7FE_E7FE; // B . in either halfword
        end
    endtask

    task automatic run_case(input int case_id);
        string       label;
        logic [31:0] expected_lr;
        logic [31:0] expected_spsr;
        logic        cp_request_seen;

        @(negedge CLK);
        nRESET = 1'b0;
        repeat (4) @(posedge CLK);
        setup_case(case_id, label, expected_lr, expected_spsr);
        @(negedge CLK);
        nRESET = 1'b1;

        cp_request_seen = 1'b0;
        repeat (120) begin
            @(negedge CLK);
            if (!CPnI)
                cp_request_seen = 1'b1;
        end

        if (u_dut.u_core.cpsr.m !== 5'(MODE_UNDEFINED)
         || u_dut.u_core.cpsr.t !== 1'b0
         || u_dut.u_core.cpsr.i !== 1'b1)
            fail(case_id, $sformatf(
                "%s did not finish in ARM Undefined mode (m/T/I=%05b/%b/%b)",
                label, u_dut.u_core.cpsr.m, u_dut.u_core.cpsr.t,
                u_dut.u_core.cpsr.i));

        if (u_dut.u_core.u_regfile.regs[30] !== expected_lr)
            fail(case_id, $sformatf(
                "%s LR_und expected %08x got %08x", label, expected_lr,
                u_dut.u_core.u_regfile.regs[30]));

        if (u_dut.u_core.u_psr.spsr_q[4] !== expected_spsr)
            fail(case_id, $sformatf(
                "%s SPSR_und expected %08x got %08x", label, expected_spsr,
                u_dut.u_core.u_psr.spsr_q[4]));

        if (u_dut.u_core.u_regfile.regs[0] !== 32'h0000_005A)
            fail(case_id, $sformatf("%s changed pre-instruction r0", label));
        if (u_dut.u_core.u_regfile.regs[1] !== 32'h0000_0000)
            fail(case_id, $sformatf("%s executed the flushed successor", label));
        if (u_dut.u_core.u_regfile.regs[7] !== 32'(case_id))
            fail(case_id, $sformatf("%s handler marker missing", label));
        if (u_dut.u_core.pc_q !== 32'h0000_0084)
            fail(case_id, $sformatf(
                "%s handler loop PC expected 00000084 got %08x",
                label, u_dut.u_core.pc_q));
        if (u_mem.mem[64] !== DATA_SENTINEL)
            fail(case_id, $sformatf("%s caused a reserved-store side effect",
                                    label));
        if (cp_request_seen)
            fail(case_id, $sformatf(
                "%s leaked into the external coprocessor interface", label));
    endtask

    initial begin
        errors = 0;
        for (int case_id = 1; case_id <= CASE_COUNT; case_id++)
            run_case(case_id);

        if (errors != 0)
            $fatal(1, "[reserved_execute] FAIL (%0d errors)", errors);
        $display("[reserved_execute] PASS (%0d reset-per-case rows)",
                 CASE_COUNT);
        $finish;
    end

    initial begin
        #250000;
        $fatal(1, "[reserved_execute] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, ADDR, WRITE, SIZE, PROT, LOCK, TRANS, WDATA,
        CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT,
        DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG,
        DBGCOMMTX, DBGCOMMRX, DBGTDO, DBGnTDOEN, DMORE};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
