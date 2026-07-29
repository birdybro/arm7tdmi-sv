// ISA-016 unaligned LDR-to-PC data-address policy.
//
// ARMv4T requires the data address of LDR pc to be word aligned; otherwise
// the result is UNPREDICTABLE. This implementation deterministically applies
// the ordinary ARM7 LDR rotation first and then the pre-v5 LDR-to-PC
// alignment rule. Eight reset-per-case rows cover every address suffix and
// both endian modes. The aligned rows are controls; the other six freeze
// project behavior, not an ARM software guarantee.

`timescale 1ns/1ps

module arm7tdmis_ldr_pc_unaligned_policy_tb
    import arm7tdmis_bus_pkg::*;
;

    localparam int CASE_COUNT = 8;
    localparam logic [31:0] TARGET = 32'h0000_0180;

    logic CLK;
    initial begin
        CLK = 1'b0;
        forever #5 CLK = ~CLK;
    end

    logic nRESET = 1'b0;
    logic cfg_bigend = 1'b0;
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
        .CLK, .CLKEN(1'b1), .nRESET, .CFGBIGEND(cfg_bigend),
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
        .WORDS(128)
    ) u_mem (
        .CLK, .CLKEN(1'b1), .nRESET, .CFGBIGEND(cfg_bigend),
        .ADDR, .WRITE, .SIZE, .PROT, .LOCK, .TRANS, .WDATA, .RDATA,
        .ABORT, .inject_abort(1'b0)
    );

    int unsigned errors;

    function automatic logic [31:0] inverse_rotate_target(
        input logic [1:0] low
    );
        unique case (low)
            2'd0: return TARGET;
            2'd1: return {TARGET[23:0], TARGET[31:24]};
            2'd2: return {TARGET[15:0], TARGET[31:16]};
            default: return {TARGET[7:0], TARGET[31:8]};
        endcase
    endfunction

    task automatic fail(
        input int    case_id,
        input string message
    );
        $display("[ldr_pc_unaligned_policy] FAIL case %0d: %s",
                 case_id, message);
        errors++;
    endtask

    task automatic setup_case(
        input  int          case_id,
        output logic [31:0] data_address
    );
        logic [1:0] low;

        low = 2'((case_id - 1) % 4);
        cfg_bigend = case_id > 4;
        data_address = 32'h0000_0100 | 32'(low);

        for (int word = 0; word < 128; word++)
            u_mem.mem[word] = 32'hEAFF_FFFE;

        u_mem.mem[0]  = 32'hEA00_0006; // reset: B 0x20
        u_mem.mem[8]  = 32'hE59F_0058; // r0 <- data address
        u_mem.mem[9]  = 32'hE590_F000; // LDR pc,[r0]
        u_mem.mem[10] = 32'hE3A0_50EE; // flushed successor
        u_mem.mem[32] = data_address;
        u_mem.mem[64] = inverse_rotate_target(low);
        u_mem.mem[TARGET >> 2] =
            32'hE3A0_7000 | 32'(case_id);
        u_mem.mem[(TARGET >> 2) + 1] = 32'hEAFF_FFFE;
    endtask

    task automatic run_case(input int case_id);
        logic [31:0] data_address;
        int unsigned data_cycles;
        logic target_fetch_seen;

        @(negedge CLK);
        nRESET = 1'b0;
        repeat (4) @(posedge CLK);
        setup_case(case_id, data_address);
        @(negedge CLK);
        nRESET = 1'b1;

        data_cycles = 0;
        target_fetch_seen = 1'b0;
        repeat (120) begin
            @(negedge CLK);
            if ((TRANS inside {TRANS_N, TRANS_S})
                && PROT[PROT_BIT_DATA]
                && ADDR == data_address) begin
                data_cycles++;
                if (WRITE || SIZE !== 2'(SIZE_WORD))
                    fail(case_id, "LDR pc data cycle pins are wrong");
            end
            if ((TRANS inside {TRANS_N, TRANS_S})
                && !WRITE && !PROT[PROT_BIT_DATA]
                && ADDR == TARGET) begin
                target_fetch_seen = 1'b1;
                if (SIZE !== 2'(SIZE_WORD))
                    fail(case_id, "target fetch is not an ARM word");
            end
        end

        if (data_cycles != 1)
            fail(case_id, $sformatf(
                "expected one raw data address, got %0d", data_cycles));
        if (!target_fetch_seen)
            fail(case_id, "aligned target fetch was not observed");
        if (u_dut.u_core.u_regfile.regs[7] !== 32'(case_id))
            fail(case_id, "target marker did not retire");
        if (u_dut.u_core.u_regfile.regs[5] !== 32'h0000_0000)
            fail(case_id, "sequential successor executed");
        if (u_dut.u_core.cpsr.t)
            fail(case_id, "LDR pc changed to Thumb state");
    endtask

    initial begin
        errors = 0;
        for (int case_id = 1; case_id <= CASE_COUNT; case_id++)
            run_case(case_id);

        if (errors != 0)
            $fatal(1, "[ldr_pc_unaligned_policy] FAIL (%0d errors)",
                   errors);
        $display("[ldr_pc_unaligned_policy] PASS (%0d reset-per-case rows)",
                 CASE_COUNT);
        $finish;
    end

    initial begin
        repeat (CASE_COUNT * 160) @(posedge CLK);
        $fatal(1, "[ldr_pc_unaligned_policy] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, LOCK, WDATA, ABORT, CPnMREQ, CPSEQ,
        CPnTRANS, CPnOPC, CPTBIT, CPnI, DBGACK, DBGnEXEC,
        DBGINSTRVALID, DBGRNG, DBGCOMMTX, DBGCOMMRX, DBGTDO,
        DBGnTDOEN, DMORE};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
