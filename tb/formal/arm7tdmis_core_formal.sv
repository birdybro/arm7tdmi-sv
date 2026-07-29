// VAL-007/VAL-008 formal harness for the actual pipeline and architectural
// state. All stimulus is arbitrary except for the documented raw-interface
// legality and bounded fairness assumptions below.

module arm7tdmis_core_formal
    import arm7tdmis_types_pkg::*, arm7tdmis_psr_pkg::*,
           arm7tdmis_bus_pkg::*, arm7tdmis_instr_pkg::*;
(
    input logic        CLK,
    input logic        CLKEN,
    input logic        CFGBIGEND,
    input logic        nIRQ,
    input logic        nFIQ,
    input logic        ABORT,
    input logic [31:0] RDATA,
    input logic        CPA,
    input logic        CPB
);
    logic [7:0] f_cycle = 8'd0;
    logic       f_past_valid = 1'b0;
    wire        nRESET = (f_cycle != 8'd0);

    logic [31:0] ADDR;
    logic        WRITE;
    logic [1:0]  SIZE;
    logic [1:0]  PROT;
    logic        LOCK;
    logic [1:0]  TRANS;
    logic [31:0] WDATA;
    logic        DMORE;
    logic        CPnMREQ;
    logic        CPSEQ;
    logic        CPnTRANS;
    logic        CPnOPC;
    logic        CPTBIT;
    logic        CPnI;
    logic        DBGnEXEC;
    logic        DBGINSTRVALID;
    logic        core_dcc_we;
    logic        core_dcc_re;
    logic [31:0] core_dcc_wdata;
    logic        core_dbgabt_we;
    logic        core_dbgabt_wdata;
    logic        dbg_inject_accept;
    logic        dbg_inject_retire;
    logic [31:0] dbg_reg_rdata;
    logic        dbg_halt_boundary;
    logic        dbg_breakpoint_execute;
    logic        dbg_abort_taken;
    logic        dbg_exception_pending;
    logic        dbg_breakpoint_interrupt_pending;
    logic        dbg_exception_entry;
    logic        dbg_exception_vector_ready;
    logic [31:0] dbg_exception_vector_pc;
    logic        dbg_pc_redirect_pending;
    logic [31:0] dbg_pc_redirect_pc;
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

    arm7tdmis_core_pipelined dut (
        .CLK,
        .CLKEN,
        .nRESET,
        .CFGBIGEND,
        .nIRQ,
        .nFIQ,
        .ABORT,
        .ADDR,
        .WRITE,
        .SIZE,
        .PROT,
        .LOCK,
        .TRANS,
        .WDATA,
        .RDATA,
        .DMORE,
        .CPnMREQ,
        .CPSEQ,
        .CPnTRANS,
        .CPnOPC,
        .CPTBIT,
        .CPnI,
        .CPA,
        .CPB,
        .DBGnEXEC,
        .DBGINSTRVALID,
        .core_dcc_we,
        .core_dcc_re,
        .core_dcc_wdata,
        .core_dcc_control (32'h0000_0000),
        .core_dcc_rdata   (32'h0000_0000),
        .core_dbgabt_we,
        .core_dbgabt_wdata,
        .core_dbgabt_rdata(32'h0000_0000),
        .dbg_inject_we    (1'b0),
        .dbg_inject_instr (32'h0000_0000),
        .dbg_inject_active(1'b0),
        .dbg_inject_accept,
        .dbg_inject_retire,
        .dbg_reg_we       (1'b0),
        .dbg_reg_addr     (4'h0),
        .dbg_reg_wdata    (32'h0000_0000),
        .dbg_reg_force_user(1'b0),
        .dbg_reg_rdata,
        .dbg_halt_req     (1'b0),
        .dbg_halted       (1'b0),
        .dbg_breakpoint_fetch(1'b0),
        .dbg_monitor_mode (1'b0),
        .dbg_watchpoint_abort(1'b0),
        .dbg_watchpoint_halt(1'b0),
        .dbg_halt_boundary,
        .dbg_breakpoint_execute,
        .dbg_abort_taken,
        .dbg_exception_pending,
        .dbg_breakpoint_interrupt_pending,
        .dbg_exception_entry,
        .dbg_exception_vector_ready,
        .dbg_exception_vector_pc,
        .dbg_pc_redirect_pending,
        .dbg_pc_redirect_pc,
        .VER_RETIRE_VALID,
        .VER_RETIRE_PC,
        .VER_RETIRE_OPCODE,
        .VER_RETIRE_THUMB,
        .VER_RETIRE_CONDITION_PASS,
        .VER_RETIRE_INJECTED,
        .VER_RETIRE_EXCEPTION_VALID,
        .VER_RETIRE_EXCEPTION,
        .VER_RETIRE_GPRS,
        .VER_RETIRE_CPSR,
        .VER_RETIRE_SPSRS
    );

    logic [2:0] clken_wait_q;
    logic [2:0] cp_wait_q;
    logic [5:0] busy_watchdog_q;
    always_ff @(posedge CLK) begin
        f_past_valid <= 1'b1;
        if (!f_past_valid)
            f_cycle <= 8'd0;
        else if (f_cycle != 8'hff)
            f_cycle <= f_cycle + 8'd1;

        if (!nRESET || CLKEN)
            clken_wait_q <= 3'd0;
        else
            clken_wait_q <= clken_wait_q + 3'd1;
        assume (clken_wait_q < 3'd4);

        if (!nRESET || (dut.state_q != 5'd12) || (CPA == 1'b0))
            cp_wait_q <= 3'd0;
        else if (CLKEN)
            cp_wait_q <= cp_wait_q + 3'd1;
        assume (cp_wait_q < 3'd4);
        assume ({CPA, CPB} != 2'b10);
        assume (!ABORT
                || (TRANS == 2'(TRANS_N))
                || (TRANS == 2'(TRANS_S)));

        if (!nRESET || (dut.state_q == 5'd0))
            busy_watchdog_q <= 6'd0;
        else if (CLKEN)
            busy_watchdog_q <= busy_watchdog_q + 6'd1;

        if (nRESET) begin
            assert (busy_watchdog_q < 6'd32);
            assert (
                dut.dabt_fires + dut.fiq_fires + dut.irq_fires
                + dut.pabt_fires + dut.undef_fires + dut.swi_fires
                <= 3'd1
            );
            if (((TRANS == 2'(TRANS_N)) || (TRANS == 2'(TRANS_S)))
                && !PROT[PROT_BIT_DATA]) begin
                assert ((SIZE != 2'(SIZE_WORD)) || (ADDR[1:0] == 2'b00));
                assert ((SIZE != 2'(SIZE_HALFWORD)) || (ADDR[0] == 1'b0));
            end
            if (dut.data_abort_q || dut.data_abort_now) begin
                assert (!dut.ddata_writes_rd);
                assert (!dut.block_writes_ldm);
                assert (!dut.swp_writes_rd);
            end
        end

        if (f_past_valid && $past(nRESET)) begin
            if (!$past(CLKEN)) begin
                assert ({
                    VER_RETIRE_GPRS, VER_RETIRE_CPSR, VER_RETIRE_SPSRS
                } == $past({
                    VER_RETIRE_GPRS, VER_RETIRE_CPSR, VER_RETIRE_SPSRS
                }));
                assert (dut.state_q == $past(dut.state_q));
            end
            if (!$past(CLKEN) && !CLKEN) begin
                assert ({
                    ADDR, WRITE, SIZE, PROT, LOCK, TRANS, WDATA, DMORE
                } == $past({
                    ADDR, WRITE, SIZE, PROT, LOCK, TRANS, WDATA, DMORE
                }));
            end
            if (VER_RETIRE_VALID && !VER_RETIRE_CONDITION_PASS
                && !VER_RETIRE_EXCEPTION_VALID) begin
                assert (VER_RETIRE_GPRS == $past(VER_RETIRE_GPRS));
                assert (VER_RETIRE_CPSR == $past(VER_RETIRE_CPSR));
                assert (VER_RETIRE_SPSRS == $past(VER_RETIRE_SPSRS));
            end
            if ($past(dut.state_q == 5'd3 && CLKEN && ABORT)) begin
                assert (dut.state_q == 5'd0);
                assert (!LOCK);
                assert (!WRITE);
            end
            if ($past(LOCK && CLKEN))
                assert (dut.state_q == 5'd3);
            if (dut.state_q == 5'd3 && !(CLKEN && ABORT)) begin
                assert (LOCK);
                assert (WRITE);
            end
            if (dut.state_q == 5'd3 && CLKEN && ABORT) begin
                assert (!LOCK);
                assert (!WRITE);
            end
        end
    end

`ifdef FORMAL_COVER
    `define COVER_STATE(NAME, VALUE) \
        cover_state_``NAME: cover property \
            (@(posedge CLK) nRESET && dut.state_q == VALUE);
    `define COVER_TRANSITION(FROM_NAME, FROM_VALUE, TO_NAME, TO_VALUE) \
        cover_transition_``FROM_NAME``_to_``TO_NAME: cover property \
            (@(posedge CLK) nRESET && f_past_valid \
             && $past(CLKEN && dut.state_q == FROM_VALUE) \
             && dut.state_q == TO_VALUE);

    `COVER_STATE(S_EXEC, 5'd0)
    `COVER_STATE(S_DDATA, 5'd1)
    `COVER_STATE(S_BLOCK_DATA, 5'd2)
    `COVER_STATE(S_SWP_RDATA, 5'd3)
    `COVER_STATE(S_SWP_WDATA, 5'd4)
    `COVER_STATE(S_MULL_HI, 5'd5)
    `COVER_STATE(S_MUL_BUSY, 5'd6)
    `COVER_STATE(S_MULL_ACC, 5'd7)
    `COVER_STATE(S_BLOCK_WB, 5'd8)
    `COVER_STATE(S_DP_SHIFT, 5'd9)
    `COVER_STATE(S_LOAD_WB, 5'd10)
    `COVER_STATE(S_SWP_WB, 5'd11)
    `COVER_STATE(S_CP_WAIT, 5'd12)
    `COVER_STATE(S_CP_MCR_DATA, 5'd13)
    `COVER_STATE(S_CP_MRC_DATA, 5'd14)
    `COVER_STATE(S_CP_MRC_WB, 5'd15)
    `COVER_STATE(S_UNDEF_WAIT, 5'd16)

    `COVER_TRANSITION(S_EXEC, 5'd0, S_EXEC, 5'd0)
    `COVER_TRANSITION(S_EXEC, 5'd0, S_DDATA, 5'd1)
    `COVER_TRANSITION(S_EXEC, 5'd0, S_BLOCK_DATA, 5'd2)
    `COVER_TRANSITION(S_EXEC, 5'd0, S_SWP_RDATA, 5'd3)
    `COVER_TRANSITION(S_EXEC, 5'd0, S_MUL_BUSY, 5'd6)
    `COVER_TRANSITION(S_EXEC, 5'd0, S_MULL_ACC, 5'd7)
    `COVER_TRANSITION(S_EXEC, 5'd0, S_DP_SHIFT, 5'd9)
    `COVER_TRANSITION(S_EXEC, 5'd0, S_CP_WAIT, 5'd12)
    `COVER_TRANSITION(S_EXEC, 5'd0, S_CP_MCR_DATA, 5'd13)
    `COVER_TRANSITION(S_EXEC, 5'd0, S_CP_MRC_DATA, 5'd14)
    `COVER_TRANSITION(S_EXEC, 5'd0, S_UNDEF_WAIT, 5'd16)
    `COVER_TRANSITION(S_DDATA, 5'd1, S_EXEC, 5'd0)
    `COVER_TRANSITION(S_DDATA, 5'd1, S_LOAD_WB, 5'd10)
    `COVER_TRANSITION(S_LOAD_WB, 5'd10, S_EXEC, 5'd0)
    `COVER_TRANSITION(S_BLOCK_DATA, 5'd2, S_BLOCK_DATA, 5'd2)
    `COVER_TRANSITION(S_BLOCK_DATA, 5'd2, S_BLOCK_WB, 5'd8)
    `COVER_TRANSITION(S_BLOCK_DATA, 5'd2, S_EXEC, 5'd0)
    `COVER_TRANSITION(S_BLOCK_WB, 5'd8, S_BLOCK_WB, 5'd8)
    `COVER_TRANSITION(S_BLOCK_WB, 5'd8, S_EXEC, 5'd0)
    `COVER_TRANSITION(S_SWP_RDATA, 5'd3, S_EXEC, 5'd0)
    `COVER_TRANSITION(S_SWP_RDATA, 5'd3, S_SWP_WDATA, 5'd4)
    `COVER_TRANSITION(S_SWP_WDATA, 5'd4, S_SWP_WB, 5'd11)
    `COVER_TRANSITION(S_SWP_WB, 5'd11, S_EXEC, 5'd0)
    `COVER_TRANSITION(S_MUL_BUSY, 5'd6, S_MUL_BUSY, 5'd6)
    `COVER_TRANSITION(S_MUL_BUSY, 5'd6, S_MULL_HI, 5'd5)
    `COVER_TRANSITION(S_MUL_BUSY, 5'd6, S_EXEC, 5'd0)
    `COVER_TRANSITION(S_MULL_ACC, 5'd7, S_MUL_BUSY, 5'd6)
    `COVER_TRANSITION(S_MULL_HI, 5'd5, S_EXEC, 5'd0)
    `COVER_TRANSITION(S_DP_SHIFT, 5'd9, S_EXEC, 5'd0)
    `COVER_TRANSITION(S_CP_WAIT, 5'd12, S_CP_WAIT, 5'd12)
    `COVER_TRANSITION(S_CP_WAIT, 5'd12, S_CP_MCR_DATA, 5'd13)
    `COVER_TRANSITION(S_CP_WAIT, 5'd12, S_CP_MRC_DATA, 5'd14)
    `COVER_TRANSITION(S_CP_WAIT, 5'd12, S_EXEC, 5'd0)
    `COVER_TRANSITION(S_CP_MCR_DATA, 5'd13, S_CP_MCR_DATA, 5'd13)
    `COVER_TRANSITION(S_CP_MCR_DATA, 5'd13, S_CP_MRC_WB, 5'd15)
    `COVER_TRANSITION(S_CP_MCR_DATA, 5'd13, S_EXEC, 5'd0)
    `COVER_TRANSITION(S_CP_MRC_DATA, 5'd14, S_CP_MRC_DATA, 5'd14)
    `COVER_TRANSITION(S_CP_MRC_DATA, 5'd14, S_CP_MRC_WB, 5'd15)
    `COVER_TRANSITION(S_CP_MRC_WB, 5'd15, S_EXEC, 5'd0)
    `COVER_TRANSITION(S_UNDEF_WAIT, 5'd16, S_EXEC, 5'd0)

    cover_exception_entry_reset: cover property
        (@(posedge CLK) !nRESET);
    cover_exception_entry_undefined: cover property
        (@(posedge CLK) nRESET && dut.any_exc_fires && dut.undef_fires);
    cover_exception_entry_swi: cover property
        (@(posedge CLK) nRESET && dut.any_exc_fires && dut.swi_fires);
    cover_exception_entry_prefetch_abort: cover property
        (@(posedge CLK) nRESET && dut.any_exc_fires && dut.pabt_fires);
    cover_exception_entry_data_abort: cover property
        (@(posedge CLK) nRESET && dut.any_exc_fires && dut.dabt_fires);
    cover_exception_entry_irq: cover property
        (@(posedge CLK) nRESET && dut.any_exc_fires && dut.irq_fires);
    cover_exception_entry_fiq: cover property
        (@(posedge CLK) nRESET && dut.any_exc_fires && dut.fiq_fires);

    cover_exception_return_undefined: cover property
        (@(posedge CLK) nRESET && dut.cpsr_restore_now
         && dut.cpsr.m == 5'(MODE_UNDEFINED));
    cover_exception_return_swi: cover property
        (@(posedge CLK) nRESET && dut.cpsr_restore_now
         && dut.cpsr.m == 5'(MODE_SUPERVISOR));
    cover_exception_return_prefetch_abort: cover property
        (@(posedge CLK) nRESET && dut.cpsr_restore_now
         && dut.cpsr.m == 5'(MODE_ABORT));
    cover_exception_return_data_abort: cover property
        (@(posedge CLK) nRESET && dut.cpsr_restore_now
         && dut.cpsr.m == 5'(MODE_ABORT));
    cover_exception_return_irq: cover property
        (@(posedge CLK) nRESET && dut.cpsr_restore_now
         && dut.cpsr.m == 5'(MODE_IRQ));
    cover_exception_return_fiq: cover property
        (@(posedge CLK) nRESET && dut.cpsr_restore_now
         && dut.cpsr.m == 5'(MODE_FIQ));
`endif
endmodule
