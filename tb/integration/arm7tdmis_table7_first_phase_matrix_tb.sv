// BUS-002/BUS-003/BUS-005: first Execute phase from TRM Tables 7-3--7-23.
//
// Section 7.1 is easy to misread: Data is the response in the numbered
// instruction cycle, while TRANS predicts the following bus cycle and the
// address-class outputs are already one bus cycle ahead.  Consequently the
// raw pins during an instruction's first Execute cycle contain the next
// row's address-class values and the current row's TRANS.  Examples:
//   * ordinary DP: pc+3i/S opcode
//   * shift(Rs):   pc+3i/I data (first half of a merged I-S)
//   * LDR/STR:     data-address/N data
//   * branch:      target/N opcode
// This reset-isolated matrix checks that first raw phase without conflating
// it with the pc+2i opcode response that is simultaneously on RDATA.

`timescale 1ns/1ps

module arm7tdmis_table7_first_phase_matrix_tb
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_instr_pkg::*;
    import arm7tdmis_types_pkg::*;
;

    localparam int ROW_COUNT = 17;
    localparam logic [31:0] TEST_PC = 32'h0000_0040;

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
    int unsigned errors = 0;

    arm7tdmis_top u_dut (
        .CLK, .CLKEN(1'b1), .nRESET, .CFGBIGEND(1'b0),
        .nIRQ(1'b1), .nFIQ(1'b1), .ABORT,
        .ADDR, .WRITE, .SIZE, .PROT, .LOCK, .TRANS, .WDATA, .RDATA,
        .CPnMREQ, .CPSEQ, .CPnTRANS, .CPnOPC, .CPTBIT, .CPnI,
        .CPA(1'b1), .CPB(1'b1),
        .DBGEN(1'b0), .DBGRQ(1'b0), .DBGBREAK(1'b0),
        .DBGACK, .DBGnEXEC, .DBGINSTRVALID, .DBGEXT(2'b00), .DBGRNG,
        .DBGCOMMTX, .DBGCOMMRX, .DBGTCKEN(1'b0), .DBGTMS(1'b0),
        .DBGTDI(1'b0), .DBGTDO, .DBGnTRST(1'b1), .DBGnTDOEN, .DMORE
    );

    arm7tdmis_memory #(
        .WORDS(256)
    ) u_mem (
        .CLK, .CLKEN(1'b1), .nRESET, .CFGBIGEND(1'b0),
        .ADDR, .WRITE, .SIZE, .PROT, .LOCK, .TRANS, .WDATA, .RDATA,
        .ABORT, .inject_abort(1'b0)
    );

    function automatic logic [31:0] row_opcode(input int row);
        unique case (row)
            0:  return 32'hE1A0_3001; // MOV r3,r1
            1:  return 32'hE1A0_3211; // MOV r3,r1,LSL r2
            2:  return 32'hE003_0291; // MUL r3,r1,r2
            3:  return 32'hE023_4291; // MLA r3,r1,r2,r4
            4:  return 32'hE084_3291; // UMULL r3,r4,r1,r2
            5:  return 32'hE590_3000; // LDR r3,[r0]
            6:  return 32'hE580_3000; // STR r3,[r0]
            7:  return 32'hE1D0_30B0; // LDRH r3,[r0]
            8:  return 32'hE1C0_30B0; // STRH r3,[r0]
            9:  return 32'hE8B0_0006; // LDMIA r0!,{r1,r2}
            10: return 32'hE8A0_0006; // STMIA r0!,{r1,r2}
            11: return 32'hE100_3091; // SWP r3,r1,[r0]
            12: return 32'hEA00_0002; // B 0x50
            13: return 32'hEF00_0000; // SWI 0
            14: return 32'hE7F0_00F0; // reserved Undefined
            15: return 32'h0590_3000; // LDREQ r3,[r0], Z=0
            16: return 32'hE10F_3000; // MRS r3,CPSR
            default: return 32'hExxx_xxxx;
        endcase
    endfunction

    function automatic logic [31:0] expected_addr(input int row);
        unique case (row)
            3: return TEST_PC + 32'd8; // MLA holds pc+2i for its extra I
            5, 6, 7, 8, 9, 10, 11: return 32'h0000_0100;
            12: return 32'h0000_0050;  // B destination
            13: return 32'h0000_0008;  // SWI vector
            14: return TEST_PC + 32'd8; // Undef recognition I cycle
            default: return TEST_PC + 32'd12;
        endcase
    endfunction

    function automatic logic [1:0] expected_trans(input int row);
        unique case (row)
            0, 15, 16: return 2'(TRANS_S);
            1, 2, 3, 4, 14: return 2'(TRANS_I);
            default: return 2'(TRANS_N);
        endcase
    endfunction

    function automatic logic [1:0] expected_prot(input int row);
        unique case (row)
            0, 12, 13, 14, 15, 16: return 2'(PROT_OPC_PRIV);
            default: return 2'(PROT_DAT_PRIV);
        endcase
    endfunction

    function automatic logic [1:0] expected_size(input int row);
        return row inside {7, 8} ? 2'(SIZE_HALFWORD) : 2'(SIZE_WORD);
    endfunction

    function automatic logic expected_lock(input int row);
        return row == 11 ? LOCK_LOCKED : LOCK_FREE;
    endfunction

    function automatic logic expected_write(input int row);
        unique case (row)
            6, 8, 10: return WRITE_WRITE;
            default: return WRITE_READ;
        endcase
    endfunction

    function automatic instr_class_e expected_class(input int row);
        unique case (row)
            0, 1: return INSTR_DP;
            2, 3: return INSTR_MUL;
            4: return INSTR_MULL;
            5, 6, 15: return INSTR_LDR_STR;
            7, 8: return INSTR_LDRH_STRH;
            9, 10: return INSTR_LDM_STM;
            11: return INSTR_SWP;
            12: return INSTR_BRANCH;
            13: return INSTR_SWI;
            14: return INSTR_UNDEF;
            16: return INSTR_MRS;
            default: return INSTR_UNDEF;
        endcase
    endfunction

    function automatic string row_name(input int row);
        unique case (row)
            0:  return "DP";
            1:  return "DP shift(Rs)";
            2:  return "MUL";
            3:  return "MLA";
            4:  return "UMULL";
            5:  return "LDR";
            6:  return "STR";
            7:  return "LDRH";
            8:  return "STRH";
            9:  return "LDM";
            10: return "STM";
            11: return "SWP";
            12: return "B";
            13: return "SWI";
            14: return "Undefined";
            15: return "failed LDR";
            16: return "MRS";
            default: return "invalid";
        endcase
    endfunction

    task automatic fail(input int row, input string reason);
        $display("[table7_first_phase_matrix] FAIL row %0d %s: %s",
                 row, row_name(row), reason);
        errors++;
    endtask

    task automatic setup_row(input int row);
        for (int word = 0; word < 256; word++)
            u_mem.mem[word] = 32'hEAFF_FFFE;

        u_mem.mem[0] = 32'hEA00_0006; // reset: B 0x20
        u_mem.mem[8] = 32'hE3A0_0C01; // r0 = 0x100
        u_mem.mem[9] = 32'hE3A0_1003; // r1 = 3
        u_mem.mem[10] = 32'hE3A0_2004; // r2 = 4
        u_mem.mem[11] = 32'hE3A0_3005; // r3 = 5
        u_mem.mem[12] = 32'hE3A0_4006; // r4 = 6
        u_mem.mem[13] = 32'hE1A0_0000;
        u_mem.mem[14] = 32'hE1A0_0000;
        u_mem.mem[15] = 32'hE1A0_0000;
        u_mem.mem[16] = row_opcode(row);
        u_mem.mem[17] = 32'hE1A0_0000;
        u_mem.mem[18] = 32'hEAFF_FFFE;
        u_mem.mem[DATA_ADDRESS_WORD] = 32'h1122_3344;
    endtask

    localparam int DATA_ADDRESS_WORD = 32'h0000_0100 >> 2;

    task automatic run_row(input int row);
        int unsigned wait_cycles;

        @(negedge CLK);
        nRESET = 1'b0;
        repeat (4) @(posedge CLK);
        setup_row(row);
        @(negedge CLK);
        nRESET = 1'b1;

        wait_cycles = 0;
        while (!(u_dut.u_core.state_q == 4'd0
                 && u_dut.u_core.de_q.valid
                 && u_dut.u_core.de_q.pc == TEST_PC)) begin
            @(negedge CLK);
            wait_cycles++;
            if (wait_cycles > 100)
                fail(row, "instruction never reached Execute");
        end

        if (u_dut.u_core.de_q.instr !== row_opcode(row)
            || u_dut.u_core.de_q.dec.instr_class !== expected_class(row))
            fail(row, "opcode did not reach the expected decode class");
        if (row == 15 && u_dut.u_core.condition_pass)
            fail(row, "condition-failed control row unexpectedly passed");
        if (row != 15 && !u_dut.u_core.condition_pass)
            fail(row, "executed row unexpectedly failed its condition");

        if (ADDR !== expected_addr(row)
            || WRITE !== expected_write(row)
            || SIZE !== expected_size(row)
            || PROT !== expected_prot(row)
            || LOCK !== expected_lock(row)
            || TRANS !== expected_trans(row))
            fail(row, $sformatf(
                "first phase A/W/S/P/L/T=%08x/%0b/%02b/%02b/%0b/%02b expected %08x/%0b/%02b/%02b/%0b/%02b",
                ADDR, WRITE, SIZE, PROT, LOCK, TRANS,
                expected_addr(row), expected_write(row),
                expected_size(row), expected_prot(row), expected_lock(row),
                expected_trans(row)));
    endtask

    initial begin
        for (int row = 0; row < ROW_COUNT; row++)
            run_row(row);
        if (errors != 0)
            $fatal(1, "[table7_first_phase_matrix] FAIL (%0d errors)",
                   errors);
        $display("[table7_first_phase_matrix] PASS (%0d reset-isolated rows)",
                 ROW_COUNT);
        $finish;
    end

    initial begin
        #150000;
        $fatal(1, "[table7_first_phase_matrix] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, WDATA, RDATA, ABORT, CPnMREQ, CPSEQ,
        CPnTRANS, CPnOPC, CPTBIT, CPnI, DBGACK, DBGnEXEC,
        DBGINSTRVALID, DBGRNG, DBGCOMMTX, DBGCOMMRX, DBGTDO,
        DBGnTDOEN, DMORE};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
