// CP-005 regression for external CDP handshaking.
//
// TRM §§4.4, 7.14 require an accepted-ready CDP to complete on an N
// cycle, an accepted-busy CDP to hold CPnI LOW through idempotent I
// cycles and complete exactly once when CPB falls, and an absent CDP to
// take Undefined. A condition-failed CDP must never assert CPnI.

`timescale 1ns/1ps

module arm7tdmis_cp_cdp_protocol_tb
    import arm7tdmis_bus_pkg::*;
;

    localparam int CYCLE_LIMIT = 360;
    localparam logic [31:0] READY_PC = 32'h0000_0024;
    localparam logic [31:0] BUSY_PC  = 32'h0000_0028;
    localparam logic [31:0] ABSENT_PC = 32'h0000_002C;
    localparam logic [31:0] COND_FAIL_PC = 32'h0000_0034;

    logic CLK;
    initial begin
        CLK = 1'b0;
        forever #5 CLK = ~CLK;
    end

    logic nRESET;
    initial begin
        nRESET = 1'b0;
        repeat (4) @(posedge CLK);
        nRESET = 1'b1;
    end

    logic [31:0] ADDR;
    logic        WRITE;
    logic [1:0]  SIZE;
    logic [1:0]  PROT;
    logic        LOCK;
    logic [1:0]  TRANS;
    logic [31:0] WDATA, RDATA;
    logic        ABORT;

    logic CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI;
    logic CPA, CPB;
    logic DBGACK, DBGnEXEC, DBGINSTRVALID;
    logic [1:0] DBGRNG;
    logic DBGCOMMTX, DBGCOMMRX, DBGTDO, DBGnTDOEN, DMORE;

    arm7tdmis_top u_dut (
        .CLK,
        .CLKEN             (1'b1),
        .nRESET,
        .CFGBIGEND         (1'b0),
        .nIRQ              (1'b1),
        .nFIQ              (1'b1),
        .ABORT,
        .ADDR, .WRITE, .SIZE, .PROT, .LOCK, .TRANS, .WDATA, .RDATA,
        .CPnMREQ, .CPSEQ, .CPnTRANS, .CPnOPC, .CPTBIT, .CPnI, .CPA, .CPB,
        .DBGEN             (1'b0),
        .DBGRQ             (1'b0),
        .DBGBREAK          (1'b0),
        .DBGACK,
        .DBGnEXEC,
        .DBGINSTRVALID,
        .DBGEXT            (2'b00),
        .DBGRNG,
        .DBGCOMMTX,
        .DBGCOMMRX,
        .DBGTCKEN          (1'b0),
        .DBGTMS            (1'b0),
        .DBGTDI            (1'b0),
        .DBGTDO,
        .DBGnTRST          (1'b1),
        .DBGnTDOEN,
        .DMORE
    );

    arm7tdmis_memory #(
        .WORDS    (256),
        .INIT_HEX ("../tb/programs/cp_cdp_protocol_test.hex")
    ) u_mem (
        .CLK,
        .CLKEN       (1'b1),
        .nRESET,
        .CFGBIGEND   (1'b0),
        .ADDR,
        .WRITE,
        .SIZE,
        .PROT,
        .LOCK,
        .TRANS,
        .WDATA,
        .RDATA,
        .ABORT,
        .inject_abort(1'b0)
    );

    // de_q advances as the core enters S_CP_WAIT, so use the latched
    // coprocessor PC during that state to keep the same response driven.
    wire [31:0] request_pc = (u_dut.u_core.state_q == 5'd12)
                           ? u_dut.u_core.cp_instr_pc_q
                           : u_dut.u_core.de_q.pc;

    logic [2:0] busy_remaining_q;

    always_comb begin
        CPA = 1'b1;
        CPB = 1'b1;
        if (!CPnI) begin
            unique case (request_pc)
                READY_PC: begin
                    CPA = 1'b0;
                    CPB = 1'b0;
                end
                BUSY_PC: begin
                    CPA = 1'b0;
                    CPB = (busy_remaining_q != 0);
                end
                default: begin
                    CPA = 1'b1;
                    CPB = 1'b1;
                end
            endcase
        end
    end

    int unsigned protocol_errors_q;
    int unsigned ready_completions_q;
    int unsigned busy_samples_q;
    int unsigned busy_completions_q;
    int unsigned absent_samples_q;
    int unsigned cond_fail_samples_q;
    int unsigned cpni_low_samples_q;

    always_ff @(posedge CLK) begin
        if (!nRESET) begin
            busy_remaining_q    <= 3;
            protocol_errors_q   <= 0;
            ready_completions_q <= 0;
            busy_samples_q      <= 0;
            busy_completions_q  <= 0;
            absent_samples_q    <= 0;
            cond_fail_samples_q <= 0;
            cpni_low_samples_q  <= 0;
        end else begin
            if (!CPnI)
                cpni_low_samples_q <= cpni_low_samples_q + 1;

            if (!CPnI && request_pc == READY_PC) begin
                ready_completions_q <= ready_completions_q + 1;
                if (CPA !== 1'b0 || CPB !== 1'b0
                    || TRANS !== 2'(TRANS_N)
                    || ADDR !== READY_PC + 32'd8
                    || WRITE || PROT[0] || SIZE !== 2'(SIZE_WORD)) begin
                    $display("[cp_cdp_protocol] FAIL ready A/T/W/S/P/CPA/CPB=%08x/%02b/%b/%02b/%b/%b/%b",
                             ADDR, TRANS, WRITE, SIZE, PROT[0], CPA, CPB);
                    protocol_errors_q <= protocol_errors_q + 1;
                end
            end

            if (!CPnI && request_pc == BUSY_PC) begin
                if (CPA !== 1'b0) begin
                    $display("[cp_cdp_protocol] FAIL busy request reported absent");
                    protocol_errors_q <= protocol_errors_q + 1;
                end
                if (CPB) begin
                    busy_samples_q <= busy_samples_q + 1;
                    if (TRANS !== 2'(TRANS_I)
                        || ADDR !== BUSY_PC + 32'd8
                        || WRITE
                        || (PROT[0] !==
                            (u_dut.u_core.state_q == 5'd12))) begin
                        $display("[cp_cdp_protocol] FAIL busy A/T/W/P=%08x/%02b/%b/%b",
                                 ADDR, TRANS, WRITE, PROT[0]);
                        protocol_errors_q <= protocol_errors_q + 1;
                    end
                    if (busy_remaining_q != 0)
                        busy_remaining_q <= busy_remaining_q - 1'b1;
                end else begin
                    busy_completions_q <= busy_completions_q + 1;
                    if (TRANS !== 2'(TRANS_N)
                        || ADDR !== BUSY_PC + 32'd8
                        || WRITE || !PROT[0]) begin
                        $display("[cp_cdp_protocol] FAIL busy-complete A/T/W/P=%08x/%02b/%b/%b",
                                 ADDR, TRANS, WRITE, PROT[0]);
                        protocol_errors_q <= protocol_errors_q + 1;
                    end
                end
            end

            if (!CPnI && request_pc == ABSENT_PC) begin
                absent_samples_q <= absent_samples_q + 1;
                if (CPA !== 1'b1 || CPB !== 1'b1) begin
                    $display("[cp_cdp_protocol] FAIL absent CPA/CPB=%b/%b",
                             CPA, CPB);
                    protocol_errors_q <= protocol_errors_q + 1;
                end
            end

            if (u_dut.u_core.state_q == 5'd0
                && u_dut.u_core.de_q.valid
                && u_dut.u_core.de_q.pc == COND_FAIL_PC) begin
                cond_fail_samples_q <= cond_fail_samples_q + 1;
                if (!CPnI) begin
                    $display("[cp_cdp_protocol] FAIL condition-failed CDP asserted CPnI");
                    protocol_errors_q <= protocol_errors_q + 1;
                end
            end
        end
    end

    int unsigned errors;

    initial begin
        $dumpfile("cp_cdp_protocol.fst");
        $dumpvars(0, arm7tdmis_cp_cdp_protocol_tb);
        errors = 0;

        wait (nRESET);
        repeat (280) @(posedge CLK);
        #1;

        errors = protocol_errors_q;
        if (ready_completions_q != 1) begin
            $display("[cp_cdp_protocol] FAIL ready completion count=%0d",
                     ready_completions_q);
            errors = errors + 1;
        end
        if (busy_samples_q != 3 || busy_completions_q != 1) begin
            $display("[cp_cdp_protocol] FAIL busy samples/completions=%0d/%0d",
                     busy_samples_q, busy_completions_q);
            errors = errors + 1;
        end
        if (absent_samples_q != 1 || cond_fail_samples_q != 1) begin
            $display("[cp_cdp_protocol] FAIL absent/cond-fail samples=%0d/%0d",
                     absent_samples_q, cond_fail_samples_q);
            errors = errors + 1;
        end
        if (cpni_low_samples_q != 6) begin
            $display("[cp_cdp_protocol] FAIL total CPnI-low samples=%0d",
                     cpni_low_samples_q);
            errors = errors + 1;
        end
        if (u_dut.u_core.u_regfile.regs[12] !== 32'd1
            || u_dut.u_core.u_regfile.regs[1] !== 32'h0000_0055
            || u_dut.u_core.u_regfile.regs[30] !== ABSENT_PC + 32'd4
            || u_dut.u_core.cpsr.m !== 5'b10011) begin
            $display("[cp_cdp_protocol] FAIL flow r12/r1/lr_und/mode=%08x/%08x/%08x/%05b",
                     u_dut.u_core.u_regfile.regs[12],
                     u_dut.u_core.u_regfile.regs[1],
                     u_dut.u_core.u_regfile.regs[30],
                     u_dut.u_core.cpsr.m);
            errors = errors + 1;
        end

        if (errors != 0)
            $fatal(1, "[cp_cdp_protocol] FAIL (%0d errors)", errors);
        $display("[cp_cdp_protocol] PASS");
        $finish;
    end

    initial begin
        repeat (CYCLE_LIMIT) @(posedge CLK);
        $fatal(1, "[cp_cdp_protocol] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT,
        DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG, DBGCOMMTX, DBGCOMMRX,
        DBGTDO, DBGnTDOEN, DMORE, LOCK, WDATA};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
