// EXC-009 reset matrix.
//
// Reach every non-Execute state in the core's complete multicycle
// FSM through an architectural instruction and public handshakes. Freeze
// CLKEN in that state, assert nRESET asynchronously, hold it for at least
// two full clocks, and prove reset dominates the stopped core. Every row
// then checks the two-flop synchronous release and the first accepted
// post-reset fetch at address zero.

`timescale 1ns/1ps

module arm7tdmis_reset_multicycle_matrix_tb
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_psr_pkg::*;
;

    localparam int CYCLE_LIMIT = 5000;

    logic CLK;
    initial begin
        CLK = 1'b0;
        forever #5 CLK = ~CLK;
    end

    logic nRESET;
    logic CLKEN;
    logic nFIQ;
    logic inject_abort;
    logic CPA;
    logic CPB;
    logic [31:0] ADDR;
    logic [31:0] WDATA;
    logic [31:0] RDATA;
    logic WRITE;
    logic [1:0] SIZE;
    logic [1:0] PROT;
    logic [1:0] TRANS;
    logic LOCK;
    logic ABORT;
    logic CPnMREQ;
    logic CPSEQ;
    logic CPnTRANS;
    logic CPnOPC;
    logic CPTBIT;
    logic CPnI;
    logic DBGACK;
    logic DBGnEXEC;
    logic DBGINSTRVALID;
    logic [1:0] DBGRNG;
    logic DBGCOMMTX;
    logic DBGCOMMRX;
    logic DBGTDO;
    logic DBGnTDOEN;
    logic DMORE;

    arm7tdmis_top u_dut (
        .CLK,
        .CLKEN,
        .nRESET,
        .CFGBIGEND        (1'b0),
        .nIRQ             (1'b1),
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
        .CPnMREQ,
        .CPSEQ,
        .CPnTRANS,
        .CPnOPC,
        .CPTBIT,
        .CPnI,
        .CPA,
        .CPB,
        .DBGEN            (1'b0),
        .DBGRQ            (1'b0),
        .DBGBREAK         (1'b0),
        .DBGACK,
        .DBGnEXEC,
        .DBGINSTRVALID,
        .DBGEXT           (2'b00),
        .DBGRNG,
        .DBGCOMMTX,
        .DBGCOMMRX,
        .DBGTCKEN         (1'b0),
        .DBGTMS           (1'b0),
        .DBGTDI           (1'b0),
        .DBGTDO,
        .DBGnTRST         (1'b1),
        .DBGnTDOEN,
        .DMORE
    );

    arm7tdmis_memory #(
        .WORDS (256)
    ) u_mem (
        .CLK,
        .CLKEN,
        .nRESET,
        .CFGBIGEND        (1'b0),
        .ADDR,
        .WRITE,
        .SIZE,
        .PROT,
        .LOCK,
        .TRANS,
        .WDATA,
        .RDATA,
        .ABORT,
        .inject_abort
    );

    int unsigned errors;
    int unsigned cases_run;

    function automatic string state_name(input int target);
        unique case (target)
            1:  return "S_DDATA";
            2:  return "S_BLOCK_DATA";
            3:  return "S_SWP_RDATA";
            4:  return "S_SWP_WDATA";
            5:  return "S_MULL_HI";
            6:  return "S_MUL_BUSY";
            7:  return "S_MULL_ACC";
            8:  return "S_BLOCK_WB";
            9:  return "S_DP_SHIFT";
            10: return "S_LOAD_WB";
            11: return "S_SWP_WB";
            12: return "S_CP_WAIT";
            13: return "S_CP_MCR_DATA";
            14: return "S_CP_MRC_DATA";
            15: return "S_CP_MRC_WB";
            16: return "S_UNDEF_WAIT";
            default: return "UNKNOWN";
        endcase
    endfunction

    function automatic logic [31:0] target_opcode(input int target);
        unique case (target)
            1:         return 32'hE580_3000; // STR r3,[r0]
            10:        return 32'hE590_3000; // LDR r3,[r0]
            2, 8:      return 32'hE8B0_000E; // LDMIA r0!,{r1-r3}
            3, 4, 11:  return 32'hE100_3091; // SWP r3,r1,[r0]
            5:         return 32'hE0C4_3291; // UMULL r3,r4,r1,r2
            6:         return 32'hE003_0291; // MUL r3,r1,r2
            7:         return 32'hE0E4_3291; // UMLAL r3,r4,r1,r2
            9:         return 32'hE1A0_3211; // MOV r3,r1,LSL r2
            12:        return 32'hEE00_0400; // CDP p4,0,c0,c0,c0,0
            13:        return 32'hEE01_0412; // MCR p4,0,r0,c1,c2,0
            14, 15:    return 32'hEE11_1412; // MRC p4,0,r1,c1,c2,0
            16:        return 32'hE7F0_00F0; // reserved Undefined
            default:   return 32'hE1A0_0000;
        endcase
    endfunction

    task automatic fail(input int target, input string description);
        $display("[reset_multicycle_matrix/%s] FAIL: %s",
                 state_name(target), description);
        errors = errors + 1;
    endtask

    task automatic prepare_program(input int target);
        for (int word = 0; word < 256; word++)
            u_mem.mem[word] = 32'hEAFF_FFFE;

        u_mem.mem[0]  = 32'hEA00_0006; // B 0x20
        u_mem.mem[8]  = 32'hE3A0_0C01; // MOV r0,#0x100
        u_mem.mem[9]  = 32'hE3A0_1003; // MOV r1,#3
        u_mem.mem[10] = 32'hE3A0_2004; // MOV r2,#4
        u_mem.mem[11] = target_opcode(target);
        u_mem.mem[12] = 32'hEAFF_FFFE;
        u_mem.mem[64] = 32'hCAFE_BABE;
        u_mem.mem[65] = 32'h1122_3344;
        u_mem.mem[66] = 32'h5566_7788;

        if (target == 12) begin
            CPA = 1'b0;
            CPB = 1'b1;
        end else if (target >= 13) begin
            CPA = 1'b0;
            CPB = 1'b0;
        end else begin
            CPA = 1'b1;
            CPB = 1'b1;
        end
    endtask

    task automatic check_reset_bus(input int target);
        if (ADDR !== 32'h0000_0000
            || WRITE !== WRITE_READ
            || SIZE !== 2'(SIZE_WORD)
            || PROT !== 2'(PROT_OPC_PRIV)
            || LOCK !== LOCK_FREE
            || TRANS !== 2'(TRANS_I)
            || WDATA !== 32'h0000_0000
            || DMORE !== 1'b0)
            fail(target, $sformatf(
                "reset bus addr=%08x wr=%b size=%b prot=%b lock=%b trans=%b wdata=%08x dmore=%b",
                ADDR, WRITE, SIZE, PROT, LOCK, TRANS, WDATA, DMORE));

        if (CPnMREQ !== 1'b1
            || CPSEQ !== 1'b0
            || CPnTRANS !== 1'b1
            || CPnOPC !== 1'b0
            || CPTBIT !== 1'b0
            || CPnI !== 1'b1
            || DBGINSTRVALID !== 1'b0
            || DBGnEXEC !== 1'b1
            || DBGACK !== 1'b0)
            fail(target, $sformatf(
                "reset sideband mreq=%b seq=%b trans=%b opc=%b t=%b ni=%b iv=%b ne=%b ack=%b",
                CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI,
                DBGINSTRVALID, DBGnEXEC, DBGACK));
    endtask

    task automatic check_reset_state(input int target);
        if (u_dut.u_core.state_q !== 5'd0
            || u_dut.u_core.fetch_pc_q !== 32'h0000_0000
            || u_dut.u_core.inflight_pc_q !== 32'h0000_0000
            || u_dut.u_core.inflight_valid_q !== 1'b0
            || u_dut.u_core.fd_q !== '0
            || u_dut.u_core.de_q !== '0
            || u_dut.u_core.pc_q !== 32'h0000_0000)
            fail(target, $sformatf(
                "pipeline state=%0d fetch=%08x inflight=%08x/%b pc=%08x",
                u_dut.u_core.state_q, u_dut.u_core.fetch_pc_q,
                u_dut.u_core.inflight_pc_q,
                u_dut.u_core.inflight_valid_q, u_dut.u_core.pc_q));

        if (u_dut.u_core.u_psr.cpsr_q !== 32'(PSR_RESET_VALUE))
            fail(target, $sformatf("CPSR expected %08x got %08x",
                 32'(PSR_RESET_VALUE), u_dut.u_core.u_psr.cpsr_q));

        for (int reg_index = 0; reg_index < 31; reg_index++) begin
            if (u_dut.u_core.u_regfile.regs[reg_index] !== 32'h0)
                fail(target, $sformatf(
                    "GPR flat slot %0d not reset: %08x", reg_index,
                    u_dut.u_core.u_regfile.regs[reg_index]));
        end
        for (int bank = 0; bank < 5; bank++) begin
            if (u_dut.u_core.u_psr.spsr_q[bank] !== 32'h0)
                fail(target, $sformatf(
                    "SPSR bank %0d not reset: %08x", bank,
                    u_dut.u_core.u_psr.spsr_q[bank]));
        end

        if ({
            u_dut.u_core.ls_data_addr_q,
            u_dut.u_core.ls_store_data_q,
            u_dut.u_core.ls_rd_q,
            u_dut.u_core.ls_byte_q,
            u_dut.u_core.ls_halfword_q,
            u_dut.u_core.ls_signed_q,
            u_dut.u_core.ls_load_q,
            u_dut.u_core.ls_addr_lo_q,
            u_dut.u_core.memory_instr_pc_q,
            u_dut.u_core.block_pc_refill_first_q,
            u_dut.u_core.block_remaining_q,
            u_dut.u_core.block_curr_addr_q,
            u_dut.u_core.block_curr_reg_q,
            u_dut.u_core.block_load_q,
            u_dut.u_core.block_first_beat_q,
            u_dut.u_core.block_user_mode_q,
            u_dut.u_core.block_has_pc_q,
            u_dut.u_core.block_thumb_ldm_base_in_list_q,
            u_dut.u_core.block_writeback_q,
            u_dut.u_core.block_writeback_addr_q,
            u_dut.u_core.block_base_value_q,
            u_dut.u_core.block_rn_q,
            u_dut.u_core.block_mode_q,
            u_dut.u_core.swp_addr_q,
            u_dut.u_core.swp_store_q,
            u_dut.u_core.swp_loaded_q,
            u_dut.u_core.swp_rd_q,
            u_dut.u_core.swp_byte_q,
            u_dut.u_core.swp_addr_lo_q,
            u_dut.u_core.mull_rdhi_q,
            u_dut.u_core.mull_result_hi_q,
            u_dut.u_core.mul_busy_remaining_q,
            u_dut.u_core.mull_active_q,
            u_dut.u_core.acc_lo_q,
            u_dut.u_core.mull_accumulate_active_q,
            u_dut.u_core.mull_rdlo_q,
            u_dut.u_core.mull_op_a_q,
            u_dut.u_core.mull_op_b_q,
            u_dut.u_core.mull_signed_q,
            u_dut.u_core.mull_s_q,
            u_dut.u_core.dp_shift_rd_q,
            u_dut.u_core.dp_shift_result_q,
            u_dut.u_core.dp_shift_flags_q,
            u_dut.u_core.dp_shift_writes_q,
            u_dut.u_core.dp_shift_flags_we_q,
            u_dut.u_core.dp_shift_writes_pc_q,
            u_dut.u_core.dp_shift_restore_q,
            u_dut.u_core.load_value_q,
            u_dut.u_core.cp_instr_pc_q,
            u_dut.u_core.cp_mcr_data_q,
            u_dut.u_core.cp_mrc_data_q,
            u_dut.u_core.cp_mrc_rd_q,
            u_dut.u_core.cp_wait_is_mcr_q,
            u_dut.u_core.cp_wait_is_mrc_q,
            u_dut.u_core.cp_wait_is_ldc_q,
            u_dut.u_core.cp_wait_is_stc_q,
            u_dut.u_core.cp_ls_addr_q,
            u_dut.u_core.cp_ls_writeback_value_q,
            u_dut.u_core.cp_ls_rn_q,
            u_dut.u_core.cp_ls_writeback_q,
            u_dut.u_core.cp_ls_first_q,
            u_dut.u_core.cp_ls_response_q,
            u_dut.u_core.undef_instr_pc_q,
            u_dut.u_core.undef_instr_thumb_q
        } !== '0)
            fail(target, "one or more multicycle payload latches survived");

        if ({
            u_dut.u_core.breakpoint_response_valid_q,
            u_dut.u_core.breakpoint_response_data_q,
            u_dut.u_core.breakpoint_response_abort_q,
            u_dut.u_core.breakpoint_response_tag_q,
            u_dut.u_core.dbg_inject_started_q,
            u_dut.u_core.dec_is_unimplemented_q,
            u_dut.u_core.data_abort_q,
            u_dut.u_core.external_data_abort_q,
            u_dut.u_core.debug_data_abort_q,
            u_dut.u_core.fiq_after_dabt_q,
            u_dut.u_core.debug_irq_pending_q,
            u_dut.u_core.debug_fiq_pending_q,
            u_dut.u_core.debug_exception_refill_q,
            u_dut.u_core.dbg_exception_vector_pc,
            u_dut.u_core.dbg_pc_redirect_pending,
            u_dut.u_core.dbg_pc_redirect_pc
        } !== '0)
            fail(target, "one or more pipeline/exception/debug latches survived");

        if (u_dut.u_core.bus_history_valid_q !== 1'b0
            || u_dut.u_core.bus_history_addr_q !== 32'h0
            || u_dut.u_core.bus_history_write_q !== WRITE_READ
            || u_dut.u_core.bus_history_size_q !== 2'(SIZE_WORD)
            || u_dut.u_core.bus_history_prot_q !== 2'(PROT_OPC_PRIV)
            || u_dut.u_core.bus_history_lock_q !== LOCK_FREE
            || u_dut.u_core.bus_history_trans_q !== 2'(TRANS_I))
            fail(target, "bus-history state did not reset");

        if (u_mem.addr_q !== 32'h0
            || u_mem.write_q !== WRITE_READ
            || u_mem.size_q !== 2'(SIZE_WORD)
            || u_mem.trans_q !== 2'(TRANS_I)
            || ABORT !== 1'b0)
            fail(target, "memory response pipeline did not reset");
    endtask

    task automatic run_case(input int target);
        bit reached;

        prepare_program(target);

        // The caller leaves a valid, CLKEN-low external reset asserted.
        @(negedge CLK);
        nRESET = 1'b1;

        // Asynchronous assertion, two-flop synchronous release.
        @(posedge CLK);
        #1;
        if (u_dut.core_nreset !== 1'b0)
            fail(target, "internal reset released after only one edge");
        @(posedge CLK);
        #1;
        if (u_dut.core_nreset !== 1'b1)
            fail(target, "internal reset did not release on edge two");
        check_reset_state(target);

        // The first enabled request after each release is the reset vector.
        @(negedge CLK);
        CLKEN = 1'b1;
        #1;
        if (ADDR !== 32'h0000_0000
            || TRANS !== 2'(TRANS_N)
            || WRITE !== WRITE_READ
            || SIZE !== 2'(SIZE_WORD)
            || PROT !== 2'(PROT_OPC_PRIV))
            fail(target, $sformatf(
                "first fetch addr=%08x trans=%b wr=%b size=%b prot=%b",
                ADDR, TRANS, WRITE, SIZE, PROT));
        @(posedge CLK);
        #1;
        if (!u_dut.u_core.inflight_valid_q
            || u_dut.u_core.inflight_pc_q !== 32'h0000_0000
            || u_dut.u_core.fetch_pc_q !== 32'h0000_0004)
            fail(target, "first fetch was not accepted exactly once");

        reached = 1'b0;
        for (int cycle = 0; cycle < 180; cycle++) begin
            @(posedge CLK);
            #1;
            if (u_dut.u_core.state_q == 5'(target)) begin
                reached = 1'b1;
                break;
            end
        end
        if (!reached)
            fail(target, "target multicycle state was not reached");

        // Stop in the selected state, then assert reset away from an edge.
        // The S_DDATA row deliberately keeps CLKEN active long enough to
        // present a live STR Data Abort together with FIQ. Reset must
        // dominate both before their common sampling edge.
        @(negedge CLK);
        if (target != 1)
            CLKEN = 1'b0;
        #1;
        if (u_dut.u_core.state_q !== 5'(target))
            fail(target, $sformatf(
                "CLKEN freeze lost target state (got %0d)",
                u_dut.u_core.state_q));
        if (target == 1) begin
            nFIQ        = 1'b0;
            inject_abort = 1'b1;
            #1;
            if (!ABORT
                || !u_dut.u_core.data_abort_now
                || !u_dut.u_core.dabt_fires)
                fail(target, "DABT+FIQ reset-priority collision was not live");
        end
        nRESET = 1'b0;
        #1;
        if (u_dut.core_nreset !== 1'b0)
            fail(target, "external assertion did not clear reset synchronizer asynchronously");
        if (u_dut.u_core.any_exc_fires
            || u_dut.u_core.data_abort_now
            || u_dut.u_core.dbg_exception_entry)
            fail(target, "exception event remained asserted under reset");
        check_reset_bus(target);
        CLKEN       = 1'b0;
        nFIQ        = 1'b1;
        inject_abort = 1'b0;

        // Architectural/control flops reset on the first clock regardless
        // of CLKEN. Keep nRESET low for three complete clocks, exceeding
        // the TRM's minimum two-cycle external contract.
        @(posedge CLK);
        #1;
        check_reset_state(target);
        check_reset_bus(target);
        repeat (2) @(posedge CLK);
        #1;
        check_reset_state(target);
        check_reset_bus(target);

        cases_run = cases_run + 1;
    endtask

    initial begin
        errors    = 0;
        cases_run = 0;
        nRESET    = 1'b0;
        CLKEN     = 1'b0;
        nFIQ      = 1'b1;
        inject_abort = 1'b0;
        CPA       = 1'b1;
        CPB       = 1'b1;

        $dumpfile("reset_multicycle_matrix.fst");
        $dumpvars(0, arm7tdmis_reset_multicycle_matrix_tb);

        repeat (4) @(posedge CLK);
        for (int target = 1; target <= 16; target++)
            run_case(target);

        if (cases_run != 16 || errors != 0)
            $fatal(1,
                "[reset_multicycle_matrix] FAIL (%0d rows, %0d errors)",
                cases_run, errors);
        $display("[reset_multicycle_matrix] PASS (all 16 non-Execute states)");
        $finish;
    end

    initial begin
        repeat (CYCLE_LIMIT) @(posedge CLK);
        $fatal(1, "[reset_multicycle_matrix] TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, DBGRNG, DBGCOMMTX, DBGCOMMRX, DBGTDO,
        DBGnTDOEN};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
