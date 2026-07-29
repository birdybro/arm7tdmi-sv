// CP-006 / ISA-005 regression for the special r15 MCR/MRC semantics.
//
// ARM DDI 0100I MCR/MRC and the ARM7 family programmer's model require:
//   * MCR with Rd=r15 transfers the address of the instruction plus 12.
//   * MRC with Rd=r15 updates only CPSR.NZCV from data[31:28]; it neither
//     writes the PC nor changes any other CPSR field.

`timescale 1ns/1ps

module arm7tdmis_cp_reg_r15_tb
    import arm7tdmis_bus_pkg::*;
;

    localparam int CYCLE_LIMIT = 320;
    localparam logic [31:0] MRC_FLAGS = 32'hA5A5_5A5A;
    localparam logic [31:0] MCR_PC12  = 32'h0000_002C;

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
    logic WRITE;
    logic [1:0] SIZE;
    logic [1:0] PROT;
    logic LOCK;
    logic [1:0] TRANS;
    logic [31:0] WDATA;
    logic [31:0] RDATA;
    logic [31:0] mem_rdata;
    logic ABORT;

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

    logic cp_data_phase_q;
    logic mrc_drive_q;
    wire mem_write = WRITE && !cp_data_phase_q;

    arm7tdmis_memory #(
        .WORDS    (256),
        .INIT_HEX ("../tb/programs/cp_reg_r15_test.hex")
    ) u_mem (
        .CLK,
        .CLKEN       (1'b1),
        .nRESET,
        .CFGBIGEND   (1'b0),
        .ADDR,
        .WRITE       (mem_write),
        .SIZE,
        .PROT,
        .LOCK,
        .TRANS,
        .WDATA,
        .RDATA       (mem_rdata),
        .ABORT,
        .inject_abort(1'b0)
    );

    assign RDATA = mrc_drive_q ? MRC_FLAGS : mem_rdata;

    int unsigned errors;
    int unsigned protocol_errors;
    int unsigned accepted_count;
    logic request_accepted_q;
    logic transfer_pending_q;
    logic transfer_is_mrc_q;
    logic mrc_wb_pending_q;
    logic [31:0] mcr_captured_q;

    // A single synthetic CP4 accepts both requests immediately. Outside
    // CPnI-low request windows it advertises the standard absent levels.
    always_comb begin
        CPA = CPnI;
        CPB = CPnI;
    end

    always_ff @(posedge CLK) begin
        if (!nRESET) begin
            protocol_errors    <= 0;
            accepted_count     <= 0;
            request_accepted_q <= 1'b0;
            transfer_pending_q <= 1'b0;
            transfer_is_mrc_q  <= 1'b0;
            mrc_wb_pending_q   <= 1'b0;
            cp_data_phase_q    <= 1'b0;
            mrc_drive_q        <= 1'b0;
            mcr_captured_q     <= 32'h0;
        end else begin
            cp_data_phase_q <= 1'b0;
            mrc_drive_q     <= 1'b0;

            if (CPnI)
                request_accepted_q <= 1'b0;

            if (!CPnI && !CPA && !CPB && !request_accepted_q) begin
                request_accepted_q <= 1'b1;
                accepted_count     <= accepted_count + 1;
                transfer_pending_q <= 1'b1;
                transfer_is_mrc_q  <= (accepted_count == 1);
                cp_data_phase_q    <= 1'b1;
                mrc_drive_q        <= (accepted_count == 1);

                if (TRANS !== 2'(TRANS_C)) begin
                    $display("[cp_reg_r15] FAIL accepted phase T=%02b", TRANS);
                    protocol_errors <= protocol_errors + 1;
                end
            end

            if (transfer_pending_q) begin
                transfer_pending_q <= 1'b0;
                if (!transfer_is_mrc_q) begin
                    mcr_captured_q <= WDATA;
                    if (TRANS !== 2'(TRANS_N) || !WRITE || !PROT[0]) begin
                        $display("[cp_reg_r15] FAIL MCR data T/W/P=%02b/%b/%b",
                                 TRANS, WRITE, PROT[0]);
                        protocol_errors <= protocol_errors + 1;
                    end
                end else begin
                    mrc_wb_pending_q <= 1'b1;
                    if (TRANS !== 2'(TRANS_I) || WRITE || !PROT[0]) begin
                        $display("[cp_reg_r15] FAIL MRC data T/W/P=%02b/%b/%b",
                                 TRANS, WRITE, PROT[0]);
                        protocol_errors <= protocol_errors + 1;
                    end
                end
            end

            if (mrc_wb_pending_q) begin
                mrc_wb_pending_q <= 1'b0;
                if (TRANS !== 2'(TRANS_S)) begin
                    $display("[cp_reg_r15] FAIL MRC writeback T=%02b", TRANS);
                    protocol_errors <= protocol_errors + 1;
                end
            end
        end
    end

    initial begin
        $dumpfile("cp_reg_r15.fst");
        $dumpvars(0, arm7tdmis_cp_reg_r15_tb);
        errors = 0;

        wait (nRESET);
        repeat (240) @(posedge CLK);
        #1;
        errors = protocol_errors;

        if (accepted_count != 2) begin
            $display("[cp_reg_r15] FAIL accepted_count=%0d", accepted_count);
            errors = errors + 1;
        end
        if (mcr_captured_q !== MCR_PC12) begin
            $display("[cp_reg_r15] FAIL MCR pc expected %08x got %08x",
                     MCR_PC12, mcr_captured_q);
            errors = errors + 1;
        end
        if ({u_dut.u_core.cpsr.n, u_dut.u_core.cpsr.z,
             u_dut.u_core.cpsr.c, u_dut.u_core.cpsr.v}
            !== MRC_FLAGS[31:28]) begin
            $display("[cp_reg_r15] FAIL NZCV expected %x got %x",
                     MRC_FLAGS[31:28],
                     {u_dut.u_core.cpsr.n, u_dut.u_core.cpsr.z,
                      u_dut.u_core.cpsr.c, u_dut.u_core.cpsr.v});
            errors = errors + 1;
        end
        if (u_dut.u_core.u_regfile.regs[0] !== 32'h1
            || u_dut.u_core.u_regfile.regs[1] !== 32'h0
            || u_dut.u_core.u_regfile.regs[2] !== 32'h1
            || u_dut.u_core.u_regfile.regs[3] !== 32'h0) begin
            $display("[cp_reg_r15] FAIL conditional markers r0-r3=%08x/%08x/%08x/%08x",
                     u_dut.u_core.u_regfile.regs[0],
                     u_dut.u_core.u_regfile.regs[1],
                     u_dut.u_core.u_regfile.regs[2],
                     u_dut.u_core.u_regfile.regs[3]);
            errors = errors + 1;
        end
        if (u_dut.u_core.u_regfile.regs[4] !== 32'h44) begin
            $display("[cp_reg_r15] FAIL completion marker r4=%08x",
                     u_dut.u_core.u_regfile.regs[4]);
            errors = errors + 1;
        end
        if (u_dut.u_core.u_regfile.regs[10] !== 32'h0) begin
            $display("[cp_reg_r15] FAIL unexpected Undefined r10=%08x",
                     u_dut.u_core.u_regfile.regs[10]);
            errors = errors + 1;
        end

        if (errors != 0)
            $fatal(1, "[cp_reg_r15] FAIL (%0d errors)", errors);
        $display("[cp_reg_r15] PASS");
        $finish;
    end

    initial begin
        repeat (CYCLE_LIMIT) @(posedge CLK);
        $fatal(1, "[cp_reg_r15] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT,
        DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG, DBGCOMMTX, DBGCOMMRX,
        DBGTDO, DBGnTDOEN, DMORE, SIZE, LOCK};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
