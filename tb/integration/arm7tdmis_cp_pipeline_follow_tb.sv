// CP-004 regression for the external coprocessor pipeline-follow pins.
//
// The model below follows TRM §4.3 literally:
//   * load an ARM opcode when CPnOPC/CPnMREQ/CPTBIT were all LOW in the
//     preceding cycle;
//   * advance the follower when those signals are all LOW now;
//   * make no follower state change while CLKEN is LOW.
//
// The program includes a condition-failed CDP, two back-to-back accepted
// CDPs, a branch-flushed CDP, and ARM->Thumb->ARM interworking. Directed
// CLKEN stalls stretch one CDP and one Thumb fetch.

`timescale 1ns/1ps

module arm7tdmis_cp_pipeline_follow_tb
    import arm7tdmis_bus_pkg::*;
;

    localparam int CYCLE_LIMIT = 360;
    localparam logic [31:0] COND_CDP  = 32'h0E00_0400;
    localparam logic [31:0] READY_CDP0 = 32'hEE00_0400;
    localparam logic [31:0] READY_CDP1 = 32'hEE12_1443;
    localparam logic [31:0] FLUSHED_CDP = 32'hEE24_3465;

    logic CLK;
    initial begin
        CLK = 1'b0;
        forever #5 CLK = ~CLK;
    end

    logic CLKEN;
    logic nRESET;
    initial begin
        CLKEN  = 1'b1;
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
        .CLKEN,
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
        .INIT_HEX ("../tb/programs/cp_pipeline_follow_test.hex")
    ) u_mem (
        .CLK,
        .CLKEN,
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

    // CP4 accepts both live CDPs immediately. Outside CPnI-low it drives
    // the mandatory absent/default high/high levels.
    always_comb begin
        CPA = CPnI;
        CPB = CPnI;
    end

    wire arm_opcode_cycle = !CPnMREQ && !CPnOPC && !CPTBIT;

    // Literal §4.3 external follower. These are intentionally driven
    // only from public pins and RDATA, not from DUT pipeline hierarchy.
    logic        previous_arm_opcode_q;
    logic [31:0] follower_fetch_q;
    logic [31:0] follower_decode_q;
    logic        follower_fetch_valid_q;
    logic        follower_decode_valid_q;

    always_ff @(posedge CLK) begin
        if (!nRESET) begin
            previous_arm_opcode_q  <= 1'b0;
            follower_fetch_q       <= 32'h0;
            follower_decode_q      <= 32'h0;
            follower_fetch_valid_q <= 1'b0;
            follower_decode_valid_q <= 1'b0;
        end else if (CLKEN) begin
            previous_arm_opcode_q <= arm_opcode_cycle;

            if (arm_opcode_cycle) begin
                follower_decode_q        <= follower_fetch_q;
                follower_decode_valid_q  <= follower_fetch_valid_q;
            end

            if (previous_arm_opcode_q) begin
                follower_fetch_q       <= RDATA;
                follower_fetch_valid_q <= 1'b1;
            end else if (arm_opcode_cycle) begin
                follower_fetch_valid_q <= 1'b0;
            end
        end
    end

    // Stretch the first accepted CDP for two clocks, then a Thumb opcode
    // fetch for two clocks. Driving CLKEN at a falling edge avoids a
    // race with the core's rising-edge sampling.
    initial begin
        wait (nRESET);
        @(negedge CLK);
        while (!(!CPnI && u_dut.u_core.de_q.pc == 32'h0000_0030))
            @(negedge CLK);
        #1;
        CLKEN = 1'b0;
        repeat (2) @(posedge CLK);
        @(negedge CLK);
        #1;
        CLKEN = 1'b1;

        @(negedge CLK);
        while (!(CPTBIT && !CPnMREQ && !CPnOPC))
            @(negedge CLK);
        #1;
        CLKEN = 1'b0;
        repeat (2) @(posedge CLK);
        @(negedge CLK);
        #1;
        CLKEN = 1'b1;
    end

    int unsigned errors;
    int unsigned runtime_errors_q;
    int unsigned arm_fetch_samples;
    int unsigned thumb_fetch_samples;
    int unsigned stalled_samples;
    int unsigned cp_completion_samples;
    int unsigned follower_cond_samples;
    int unsigned follower_live_samples;
    int unsigned follower_flushed_samples;

    logic [5:0] held_cp_pins_q;
    logic       held_valid_q;

    wire map_error_w = CPnMREQ !== !TRANS[1]
                     || CPSEQ !== TRANS[0]
                     || CPnOPC !== PROT[PROT_BIT_DATA]
                     || CPnTRANS !==
                        (u_dut.u_core.cpsr.m != 5'b10000)
                     || CPTBIT !== u_dut.u_core.cpsr.t;
    wire stall_error_w = !CLKEN && held_valid_q
                       && ({CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI}
                           !== held_cp_pins_q);
    wire follower_is_live_cdp_w = follower_decode_q == READY_CDP0
                                || follower_decode_q == READY_CDP1;
    wire cp_execute_error_w = !CPnI && CLKEN
                            && (!follower_decode_valid_q
                                || !follower_is_live_cdp_w);
    wire cond_execute_error_w = follower_decode_valid_q
                              && follower_decode_q == COND_CDP
                              && !CPnI;
    wire flush_execute_error_w = follower_decode_valid_q
                               && follower_decode_q == FLUSHED_CDP
                               && !CPnI;

    // Check after the rising-edge nonblocking updates have settled.
    always @(negedge CLK) begin
        if (!nRESET) begin
            runtime_errors_q          <= 0;
            arm_fetch_samples         <= 0;
            thumb_fetch_samples       <= 0;
            stalled_samples           <= 0;
            cp_completion_samples     <= 0;
            follower_cond_samples     <= 0;
            follower_live_samples     <= 0;
            follower_flushed_samples  <= 0;
            held_cp_pins_q            <= '0;
            held_valid_q              <= 1'b0;
        end else begin
            runtime_errors_q <= runtime_errors_q + map_error_w
                              + stall_error_w + cp_execute_error_w
                              + cond_execute_error_w
                              + flush_execute_error_w;

            if (map_error_w) begin
                $display("[cp_pipeline_follow] FAIL map TRANS/PROT/mode/T=%02b/%02b/%05b/%b pins=%b%b%b%b%b",
                         TRANS, PROT, u_dut.u_core.cpsr.m,
                         u_dut.u_core.cpsr.t, CPnMREQ, CPSEQ,
                         CPnTRANS, CPnOPC, CPTBIT);
            end

            if (!CLKEN) begin
                stalled_samples <= stalled_samples + 1;
                if (stall_error_w) begin
                    $display("[cp_pipeline_follow] FAIL pins changed during CLKEN stall: %b -> %b",
                             held_cp_pins_q,
                             {CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI});
                end
            end
            held_cp_pins_q <=
                {CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI};
            held_valid_q <= 1'b1;

            if (!CPnMREQ && !CPnOPC) begin
                if (CPTBIT)
                    thumb_fetch_samples <= thumb_fetch_samples + 1;
                else
                    arm_fetch_samples <= arm_fetch_samples + 1;
            end

            if (!CPnI && CLKEN) begin
                cp_completion_samples <= cp_completion_samples + 1;
                if (cp_execute_error_w) begin
                    $display("[cp_pipeline_follow] FAIL CPnI follower decode=%08x valid=%b",
                             follower_decode_q, follower_decode_valid_q);
                end
            end

            if (follower_decode_valid_q) begin
                unique case (follower_decode_q)
                    COND_CDP: begin
                        follower_cond_samples <=
                            follower_cond_samples + 1;
                        if (cond_execute_error_w)
                            $display("[cp_pipeline_follow] FAIL condition-failed follower asserted CPnI");
                    end
                    READY_CDP0, READY_CDP1:
                        follower_live_samples <=
                            follower_live_samples + 1;
                    FLUSHED_CDP: begin
                        follower_flushed_samples <=
                            follower_flushed_samples + 1;
                        if (flush_execute_error_w)
                            $display("[cp_pipeline_follow] FAIL flushed follower asserted CPnI");
                    end
                    default: ;
                endcase
            end
        end
    end

    initial begin
        $dumpfile("cp_pipeline_follow.fst");
        $dumpvars(0, arm7tdmis_cp_pipeline_follow_tb);

        wait (nRESET);
        repeat (300) @(posedge CLK);
        #1;
        errors = runtime_errors_q;

        if (arm_fetch_samples == 0 || thumb_fetch_samples == 0
            || stalled_samples != 4) begin
            $display("[cp_pipeline_follow] FAIL ARM/Thumb/stall coverage=%0d/%0d/%0d",
                     arm_fetch_samples, thumb_fetch_samples,
                     stalled_samples);
            errors = errors + 1;
        end
        if (cp_completion_samples != 2
            || follower_cond_samples == 0
            || follower_live_samples < 2
            || follower_flushed_samples == 0) begin
            $display("[cp_pipeline_follow] FAIL CP/follower coverage=%0d cond=%0d live=%0d flushed=%0d",
                     cp_completion_samples, follower_cond_samples,
                     follower_live_samples, follower_flushed_samples);
            errors = errors + 1;
        end
        if (u_dut.u_core.u_regfile.regs[3] !== 32'h0000_00AA
            || u_dut.u_core.u_regfile.regs[5] !== 32'h0000_0055
            || u_dut.u_core.u_regfile.regs[7] !== 32'h0
            || u_dut.u_core.cpsr.t !== 1'b0) begin
            $display("[cp_pipeline_follow] FAIL flow r3/r5/r7/T=%08x/%08x/%08x/%b",
                     u_dut.u_core.u_regfile.regs[3],
                     u_dut.u_core.u_regfile.regs[5],
                     u_dut.u_core.u_regfile.regs[7],
                     u_dut.u_core.cpsr.t);
            errors = errors + 1;
        end

        if (errors != 0)
            $fatal(1, "[cp_pipeline_follow] FAIL (%0d errors)", errors);
        $display("[cp_pipeline_follow] PASS");
        $finish;
    end

    initial begin
        repeat (CYCLE_LIMIT) @(posedge CLK);
        $fatal(1, "[cp_pipeline_follow] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, ADDR, WRITE, SIZE, LOCK, WDATA, DBGACK,
        DBGnEXEC, DBGINSTRVALID, DBGRNG, DBGCOMMTX, DBGCOMMRX, DBGTDO,
        DBGnTDOEN, DMORE};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
