// 3-stage Fetch/Decode/Execute pipeline (TASKS.md §16).
//
// Replaces the non-pipelined arm7tdmis_core.sv. Same port list, same execute
// substates (DADDR/DDATA/BLOCK_*/SWP_*) — what changes is that Fetch and
// Decode now run concurrently with Execute. In steady state three
// instructions are in flight per cycle:
//
//     cycle T:   F = pc=N+8, D = pc=N+4, E = pc=N
//     cycle T+1: F = pc=N+12, D = pc=N+8, E = pc=N+4
//     ...
//
// Throughput in steady state is 1S per ARM instruction (the TRM headline
// figure). E stalls F and D upstream whenever it's in a multi-cycle substate
// (memory access, multiply, SWP) — the bus is shared, so F can't prefetch
// during the data cycle anyway.
//
// Stage registers:
//   F→D  (fd_q):  raw instruction bits + the PC that produced them
//   D→E  (de_q):  decoded_t + raw instruction bits + the PC that produced it
// Each stage has a valid bit. On flush, valid bits clear and the pipeline
// refills from the new fetch_pc.
//
// PC accounting:
//   fetch_pc_q       — address driven onto ADDR for next fetch
//   inflight_pc_q    — PC whose instruction will arrive on RDATA next cycle
//   fd_q.pc          — PC of the instruction sitting in the F→D register
//   de_q.pc          — PC of the instruction sitting in the D→E register
//                       (this is the "PC of the currently-executing instr")
//   r15 read in E    — exposes de_q.pc + 8 (ARM) or de_q.pc + 4 (Thumb)
//                       per TRM §2.4 prefetch-offset rule. The regfile adds
//                       this offset internally; we just pass de_q.pc as pc_in.
//
// Phases (TASKS.md §16):
//   Phase 1: F stage                                    [done]
//   Phase 2: D stage                                    [done]
//   Phase 3: E stage migration                          [done]
//   Phase 4: Flush triggers + pipeline kill             [done — folded into E]
//   Phase 5: Stall propagation (e_busy)                 [done — folded into E]
//   Phase 6: Integration / swap at arm7tdmis_top        [pending]

module arm7tdmis_core_pipelined
    import arm7tdmis_types_pkg::*;
    import arm7tdmis_psr_pkg::*;
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_instr_pkg::*;
(
    input  logic        CLK,
    input  logic        CLKEN,
    input  logic        nRESET,        // synchronized
    input  logic        CFGBIGEND,
    input  logic        nIRQ,
    input  logic        nFIQ,
    input  logic        ABORT,

    // Memory bus
    output logic [31:0] ADDR,
    output logic        WRITE,
    output logic [1:0]  SIZE,
    output logic [1:0]  PROT,
    output logic        LOCK,
    output logic [1:0]  TRANS,
    output logic [31:0] WDATA,
    input  logic [31:0] RDATA,
    output logic        DMORE,

    // §19: Coprocessor handshake (pipeline-following + CPnI)
    output logic        CPnMREQ,
    output logic        CPSEQ,
    output logic        CPnTRANS,
    output logic        CPnOPC,
    output logic        CPTBIT,
    output logic        CPnI,
    input  logic        CPA,
    input  logic        CPB,

    // §24: ETM-facing pipeline-state outputs
    output logic        DBGnEXEC,
    output logic        DBGINSTRVALID,

    // §20: internal CP14 register interface.  c0 is the read-only DCC
    // control register, c1 is the split RX/TX data register, and c2 is the
    // read/write Debug Abort Status register.
    output logic        core_dcc_we,
    output logic        core_dcc_re,
    output logic [31:0] core_dcc_wdata,
    input  logic [31:0] core_dcc_control,
    input  logic [31:0] core_dcc_rdata,
    output logic        core_dbgabt_we,
    output logic        core_dbgabt_wdata,
    input  logic [31:0] core_dbgabt_rdata,

    // §22 scan-chain-1 instruction injection. When dbg_inject_we pulses
    // HIGH, the F-stage overrides fd_q with dbg_inject_instr (skipping
    // the normal RDATA latch path). Used while in debug-halt state to
    // run debugger-supplied instructions one at a time.
    input  logic        dbg_inject_we,
    input  logic [31:0] dbg_inject_instr,
    input  logic        dbg_inject_active,
    output logic        dbg_inject_accept,
    output logic        dbg_inject_retire,

    // Debug-speed block-transfer scan data port. This is separate from
    // instruction injection because a halted core uses scan chain 1,
    // rather than the external memory bus, for LDM/STM register data.
    input  logic        dbg_reg_we,
    input  logic [3:0]  dbg_reg_addr,
    input  logic [31:0] dbg_reg_wdata,
    input  logic        dbg_reg_force_user,
    output logic [31:0] dbg_reg_rdata,

    // §5.3 debug-state boundary. dbg_halt_req is the synchronized final
    // running request; dbg_halt_boundary is HIGH on an edge that legally
    // completes the current instruction; dbg_halted is the subsequent
    // frozen state.
    input  logic        dbg_halt_req,
    input  logic        dbg_halted,
    input  logic        dbg_breakpoint_fetch,
    input  logic        dbg_monitor_mode,
    input  logic        dbg_watchpoint_abort,
    input  logic        dbg_watchpoint_halt,
    output logic        dbg_halt_boundary,
    output logic        dbg_breakpoint_execute,
    output logic        dbg_abort_taken,
    output logic        dbg_exception_pending,
    output logic        dbg_breakpoint_interrupt_pending,
    output logic        dbg_exception_entry,
    output logic        dbg_exception_vector_ready,
    output logic [31:0] dbg_exception_vector_pc
);

    // =====================================================================
    // Pipeline register types
    // =====================================================================

    typedef struct packed {
        logic [31:0] instr;
        logic [31:0] pc;       // PC that produced `instr`
        logic        thumb;    // T-bit when the fetch was issued
        logic        pabort;   // §17: ABORT asserted during this fetch's data
                               //      cycle → prefetch abort when the instr
                               //      reaches execute. Named `pabort` not
                               //      `abort` because Verilator warns on the
                               //      C++ reserved word.
        logic        breakpoint;
        logic        injected;
        logic        valid;
    } fd_t;

    typedef struct packed {
        decoded_t    dec;
        logic [31:0] instr;   // raw instruction bits — needed for DP-imm raw imm8
        logic [31:0] pc;       // PC of this instruction
        logic        thumb;    // T-bit when fetched
        logic        pabort;   // §17: carried from fd_q
        logic        breakpoint;
        logic        injected;
        logic        valid;
    } de_t;

    // A breakpoint stops the core before the Execute edge, but the external
    // bus already carries the response for a younger in-flight opcode fetch.
    // Preserve that response while the rest of the core is clock-disabled;
    // otherwise restart would associate a later halted-bus value with the
    // old inflight_pc_q and skip or corrupt the younger instruction.
    logic        breakpoint_response_valid_q;
    logic [31:0] breakpoint_response_data_q;
    logic        breakpoint_response_abort_q;
    logic        breakpoint_response_tag_q;

    always_ff @(posedge CLK) begin
        if (!nRESET) begin
            breakpoint_response_valid_q <= 1'b0;
            breakpoint_response_data_q  <= 32'h0;
            breakpoint_response_abort_q <= 1'b0;
            breakpoint_response_tag_q   <= 1'b0;
        end else if (dbg_pc_write) begin
            // A scan-loaded resume PC invalidates the younger fetch response
            // saved when a breakpoint stopped the pipeline.
            breakpoint_response_valid_q <= 1'b0;
        end else if (!breakpoint_response_valid_q
                     && dbg_halted && dbg_breakpoint_execute) begin
            breakpoint_response_valid_q <= 1'b1;
            breakpoint_response_data_q  <= RDATA;
            breakpoint_response_abort_q <= ABORT;
            breakpoint_response_tag_q   <= dbg_breakpoint_fetch;
        end else if (CLKEN && breakpoint_response_valid_q) begin
            breakpoint_response_valid_q <= 1'b0;
        end
    end

    // =====================================================================
    // E-stage substate FSM — bus-pipelined per TRM §3.3 / §18
    // =====================================================================
    //
    // S_EXEC drives the first addr-class of any memory substate (LDR/STR
    // data addr, LDM/STM beat-1 addr, SWP read addr). The dedicated *_ADDR
    // substates the non-pipelined model used (S_DADDR, S_BLOCK_ADDR,
    // S_SWP_RADDR, S_SWP_WADDR) are gone — they fold into the previous
    // state's bus cycle since the address-class signals lead the data
    // signals by one bus cycle on a pipelined bus. Saves 1 cycle per
    // memory op and (n-1) cycles per n-register LDM/STM.
    //
    // Symmetrically, the *_DATA cycles drive the NEXT addr-class while
    // their data is on the bus, so an LDM iterates 1 cycle per beat
    // and LDR/STR's data cycle prefetches the next instruction for free.

    typedef enum logic [3:0] {
        S_EXEC       = 4'd0,
        S_DDATA      = 4'd1,    // LDR/STR data cycle
        S_BLOCK_DATA = 4'd2,    // LDM/STM beat iteration
        S_SWP_RDATA  = 4'd3,    // SWP read data + drive write addr
        S_SWP_WDATA  = 4'd4,    // SWP write data + drive next fetch
        S_MULL_HI    = 4'd5,    // §9d: 64-bit multiply RdHi writeback cycle
        S_MUL_BUSY   = 4'd6,    // §18: multiplier I cycles (early termination m)
        S_MULL_ACC   = 4'd7,    // UMLAL/SMLAL: read RdHi for accumulator,
                                 //              commit RdLo result
        S_BLOCK_WB   = 4'd8,    // LDM/STM Rn-writeback cycle (deferred from
                                 // S_EXEC so abort restart preserves Rn)
        S_DP_SHIFT   = 4'd9,    // §18: DP shift-by-reg I cycle (TRM 1S+1I)
        S_LOAD_WB    = 4'd10,   // §18: LDR/LDRB writeback I cycle (TRM 1S+1N+1I)
        S_SWP_WB     = 4'd11,   // §18: SWP Rd writeback I cycle (TRM 1S+2N+1I)
        S_CP_WAIT    = 4'd12,   // external CP accepted but busy
        S_CP_MCR_DATA = 4'd13,  // ARM register -> CP data phase
        S_CP_MRC_DATA = 4'd14,  // CP -> ARM register data phase
        S_CP_MRC_WB   = 4'd15   // MRC register writeback/fetch phase
    } state_e;

    state_e state_q;

    // External coprocessor register-transfer state survives the initial
    // S_EXEC edge, where Decode advances to the following instruction.
    logic [31:0] cp_instr_pc_q;
    logic [31:0] cp_mcr_data_q;
    logic [31:0] cp_mrc_data_q;
    logic [3:0]  cp_mrc_rd_q;
    logic        cp_wait_is_mcr_q;
    logic        cp_wait_is_mrc_q;
    logic        cp_wait_is_ldc_q;
    logic        cp_wait_is_stc_q;
    logic [31:0] cp_ls_addr_q;
    logic [31:0] cp_ls_writeback_value_q;
    logic [3:0]  cp_ls_rn_q;
    logic        cp_ls_writeback_q;
    logic        cp_ls_first_q;
    logic        cp_ls_response_q;

    // =====================================================================
    // F stage
    // =====================================================================

    logic [31:0] fetch_pc_q;
    logic [31:0] inflight_pc_q;
    logic        inflight_valid_q;
    fd_t         fd_q;

    // CPSR lives in u_psr below; F reads it live to size halfword vs word.
    psr_t        cpsr;

    wire [31:0]  fetch_step = cpsr.t ? 32'd2 : 32'd4;
    wire         dbg_pc_write = dbg_reg_we && (dbg_reg_addr == 4'd15);
    wire [31:0]  dbg_pc_aligned = cpsr.t
                                ? {dbg_reg_wdata[31:1], 1'b0}
                                : {dbg_reg_wdata[31:2], 2'b00};

    // E-stall (Phase 5): whenever E is in a memory substate, hold F and D.
    wire e_busy = (state_q != S_EXEC);

    // Flush triggers come from the E stage (Phase 4).
    logic        flush;
    logic [31:0] flush_target_pc;

    // F-stage advance control. issue_fetch fires whenever the bus is
    // driving a fetch this cycle — that is, in any cycle whose state_next
    // is S_EXEC. With the §18 bus overlap that includes the LAST cycle of
    // memory substates (S_DDATA, last S_BLOCK_DATA beat, S_SWP_WDATA,
    // S_MULL_HI, last S_MUL_BUSY cycle). Result arrives next cycle when
    // state_q == S_EXEC and latch_into_fd captures it.
    // LDC/STC's final N data address does not also fetch an opcode. The
    // normal S_EXEC cycle following it restarts instruction prefetch.
    wire cp_ls_data_state = ((state_q == S_CP_MCR_DATA) && cp_wait_is_stc_q)
                          || ((state_q == S_CP_MRC_DATA) && cp_wait_is_ldc_q);
    wire cp_ls_cleanup_state = (state_q == S_CP_MRC_WB)
                             && (cp_wait_is_ldc_q || cp_wait_is_stc_q);
    wire cp_mrc_wb_state = (state_q == S_CP_MRC_WB)
                         && !cp_ls_cleanup_state;
    wire cp_wait_debug_pending = (state_q == S_CP_WAIT) && dbg_halt_req;
    wire issue_fetch   = !dbg_inject_active
                       && !flush && (state_next == S_EXEC)
                       && !cp_ls_data_state
                       && !cp_wait_debug_pending;
    wire latch_into_fd = !dbg_inject_active
                       && !flush && !e_busy && inflight_valid_q;

    // D-stage advance — same shape; takes the decoded view of fd_q.
    de_t          de_q;

    // Halfword fetches are returned in their addressed external data lane.
    // Big-endian mode mirrors the lane selected by PC[1].
    wire [15:0]   thumb_instr_w = (fd_q.pc[1] ^ CFGBIGEND)
                                 ? fd_q.instr[31:16]
                                 : fd_q.instr[15:0];

    decoded_t     arm_dec_w;
    decoded_t     thumb_dec_w;
    decoded_t     dec_w;

    logic         arm_is_dataproc_w, arm_is_unimpl_w;
    logic         thumb_is_dataproc_w, thumb_is_unimpl_w;
    logic         dec_is_unimplemented_w;

    arm7tdmis_decoder u_arm_decoder (
        .instr            (fd_q.instr),
        .dec              (arm_dec_w),
        .is_dataproc      (arm_is_dataproc_w),
        .is_unimplemented (arm_is_unimpl_w)
    );

    arm7tdmis_thumb_decoder u_thumb_decoder (
        .thumb_instr      (thumb_instr_w),
        .dec              (thumb_dec_w),
        .is_dataproc      (thumb_is_dataproc_w),
        .is_unimplemented (thumb_is_unimpl_w)
    );

    assign dec_w                   = fd_q.thumb ? thumb_dec_w        : arm_dec_w;
    assign dec_is_unimplemented_w  = fd_q.thumb ? thumb_is_unimpl_w  : arm_is_unimpl_w;

    wire d_advance = fd_q.valid && !flush && !e_busy;

    // F stage update. Reset dominates CLKEN so a stopped core cannot miss
    // a complete reset pulse.
    always_ff @(posedge CLK) begin
        if (!nRESET) begin
            fetch_pc_q       <= 32'h0;
            inflight_pc_q    <= 32'h0;
            inflight_valid_q <= 1'b0;
            fd_q             <= '{instr:32'h0, pc:32'h0, thumb:1'b0,
                              pabort:1'b0, breakpoint:1'b0, injected:1'b0,
                              valid:1'b0};
        end else if (dbg_pc_write) begin
            // A debug-speed LDM of r15 restores the debugger-selected
            // resume address while the normal core enable is stopped.
            // Discard every pre-debug pipeline value so RESTART's first
            // active bus cycle fetches exactly this address.
            fetch_pc_q       <= dbg_pc_aligned;
            inflight_pc_q    <= dbg_pc_aligned;
            inflight_valid_q <= 1'b0;
            fd_q.valid       <= 1'b0;
        end else if (CLKEN) begin
            if (flush) begin
                if (early_flush_fetch) begin
                    // Capture the target as the inflight prefetch this
                    // cycle (ADDR=flush_target_pc, TRANS=N driven below).
                    // Memory latches it at this posedge → RDATA next cycle.
                    // Both the captured transfer size and the next
                    // prefetch increment use the destination state. This
                    // differs from live CPSR.T for BX and for an
                    // exception-returning data-processing PC write.
                    inflight_pc_q    <= flush_target_pc;
                    inflight_valid_q <= 1'b1;
                    fetch_pc_q       <= flush_target_pc
                                     + (early_flush_t ? 32'd2 : 32'd4);
                end else begin
                    fetch_pc_q       <= flush_target_pc;
                    inflight_valid_q <= 1'b0;
                end
                fd_q.valid       <= 1'b0;
            end else if (dbg_inject_we) begin
                // §22 scan-chain-1 injection: bypass the F-stage's
                // normal RDATA latch and force fd_q to the debugger-
                // supplied instruction. pc and thumb are set to the
                // current execution context so the decoder produces a
                // valid decoded_t (the exact pc doesn't matter for the
                // architecturally-allowed debug instructions — DP, L/S,
                // LDM/STM, MSR/MRS — none of which read r15 in a way
                // that would care about the spoofed value).
                fd_q.instr  <= dbg_inject_instr;
                fd_q.pc     <= de_q.pc;
                fd_q.thumb  <= cpsr.t;
                fd_q.pabort <= 1'b0;
                fd_q.breakpoint <= 1'b0;
                fd_q.injected <= 1'b1;
                fd_q.valid  <= 1'b1;
            end else begin
                if (issue_fetch) begin
                    fetch_pc_q       <= fetch_pc_q + fetch_step;
                    inflight_pc_q    <= fetch_pc_q;
                    inflight_valid_q <= 1'b1;
                end else begin
                    inflight_valid_q <= 1'b0;
                end

                if (latch_into_fd) begin
                    fd_q.instr <= breakpoint_response_valid_q
                                ? breakpoint_response_data_q : RDATA;
                    fd_q.pc    <= inflight_pc_q;
                    fd_q.thumb <= cpsr.t;
                    fd_q.pabort <= breakpoint_response_valid_q
                                 ? breakpoint_response_abort_q : ABORT;
                    fd_q.breakpoint <= breakpoint_response_valid_q
                                     ? breakpoint_response_tag_q
                                     : dbg_breakpoint_fetch;
                    fd_q.injected <= 1'b0;
                    fd_q.valid <= 1'b1;
                end else if (d_advance) begin
                    fd_q.valid <= 1'b0;
                end
            end
        end
    end

    // D stage update.
    always_ff @(posedge CLK) begin
        if (!nRESET) begin
            de_q <= '{dec:'0, instr:32'h0, pc:32'h0, thumb:1'b0,
                      pabort:1'b0, breakpoint:1'b0, injected:1'b0,
                      valid:1'b0};
        end else if (dbg_pc_write) begin
            de_q.valid <= 1'b0;
        end else if (CLKEN) begin
            if (dbg_inject_we) begin
                // Discard the normal instruction that occupied Execute at
                // debug entry. Only the scanned instruction may retire.
                de_q.valid <= 1'b0;
            end else if (flush) begin
                de_q.valid <= 1'b0;
            end else if (!e_busy) begin
                if (fd_q.valid) begin
                    de_q.dec   <= dec_w;
                    de_q.instr <= fd_q.instr;
                    de_q.pc    <= fd_q.pc;
                    de_q.thumb <= fd_q.thumb;
                    de_q.pabort <= fd_q.pabort;
                    de_q.breakpoint <= fd_q.breakpoint;
                    de_q.injected <= fd_q.injected;
                    de_q.valid <= 1'b1;
                end else begin
                    de_q.valid <= 1'b0;
                end
            end
        end
    end

    // =====================================================================
    // E stage — substates + datapath
    // =====================================================================

    // Convenience alias for execute logic (mirrors the old core's `dec`).
    wire decoded_t dec = de_q.dec;

    // Latches used during memory substates — same set as the non-pipelined
    // core. Snapshotted at end of S_EXEC because de_q.dec is held while in
    // a substate (D doesn't advance), but having them latched separately
    // keeps the substate logic clean.
    logic [31:0]  ls_data_addr_q;
    logic [31:0]  ls_store_data_q;
    logic [3:0]   ls_rd_q;
    logic         ls_byte_q;
    logic         ls_halfword_q;
    logic         ls_signed_q;
    logic         ls_load_q;
    logic [1:0]   ls_addr_lo_q;
    logic [31:0]  memory_instr_pc_q;

    logic [15:0]  block_remaining_q;
    logic [31:0]  block_curr_addr_q;
    logic [3:0]   block_curr_reg_q;
    logic         block_load_q;
    logic         block_first_beat_q;
    logic         block_user_mode_q;     // LDM/STM ^ — force user-bank regs
    logic         block_has_pc_q;        // r15 in this block's reg list?

    // §17 block-transfer writeback state. LDM defers Rn writeback until
    // all beats have completed (or the final abort boundary). STM commits
    // Rn in its setup cycle, before any data abort can be returned, as
    // required by the ARM7TDMI-S abort model. Latched values are retained
    // for the LDM paths and for block-transfer iteration.
    logic         block_writeback_q;
    logic [31:0]  block_writeback_addr_q;
    logic [31:0]  block_base_value_q;
    logic [3:0]   block_rn_q;

    // §18 DP shift-by-reg: TRM Table 7-3 says these take 1S+1I = 2 cycles
    // because reading Rs for the shift amount adds an internal cycle.
    // Defer commit to S_DP_SHIFT.
    logic [3:0]   dp_shift_rd_q;
    logic [31:0]  dp_shift_result_q;
    logic [3:0]   dp_shift_flags_q;   // {N, Z, C, V} of the ALU result
    logic         dp_shift_writes_q;
    logic         dp_shift_flags_we_q;
    logic         dp_shift_writes_pc_q;

    // §18 LDR/LDRB writeback I cycle. Holds the load value across S_DDATA
    // → S_LOAD_WB so the regfile commit happens at the architecturally
    // correct posedge. ls_rd_q already holds the destination.
    logic [31:0]  load_value_q;

    logic [31:0]  swp_addr_q;
    logic [31:0]  swp_store_q;
    logic [31:0]  swp_loaded_q;
    logic [3:0]   swp_rd_q;
    logic         swp_byte_q;
    logic [1:0]   swp_addr_lo_q;

    // §9d MULL latches — capture RdHi register address and the upper 32 bits
    // of the product at end of S_EXEC, so S_MULL_HI can commit them even
    // after de_q has moved on.
    logic [3:0]   mull_rdhi_q;
    logic [31:0]  mull_result_hi_q;

    // §18: multiplier internal-cycle accounting. Latched at end of S_EXEC
    // for MUL/MULL: m parameter from the multiplier (1..4 depending on Rs
    // significant-bit-count) drives mul_busy_remaining_q for S_MUL_BUSY
    // countdown; mull_active_q tells the FSM whether to land at S_MULL_HI
    // or back at S_EXEC after the busy cycles complete.
    logic [2:0]   mul_busy_remaining_q;
    logic         mull_active_q;

    // §9c UMLAL/SMLAL: 64-bit accumulator read across two cycles. S_EXEC
    // reads RdLo via port A (rf_ra_data) and latches it into acc_lo_q;
    // S_MULL_ACC reads RdHi via port A and feeds it as acc_hi to the
    // multiplier alongside the latched acc_lo_q. RdLo writeback commits
    // at end of S_MULL_ACC; RdHi writeback at S_MULL_HI as for UMULL/SMULL.
    //
    // de_q.dec advances at posedge ending S_EXEC (since !e_busy gating
    // lets D consume fd_q), so its rn/rd/rm/rs go stale during S_MULL_ACC.
    // We snapshot the operand values (Rm, Rs) and register destinations
    // (RdLo for the writeback) at S_EXEC end into per-MULL latches.
    logic [31:0]  acc_lo_q;
    logic         mull_accumulate_active_q;
    logic [3:0]   mull_rdlo_q;            // dec.rd at S_EXEC time
    logic [31:0]  mull_op_a_q;            // rf_rb_data (= Rm)  at S_EXEC time
    logic [31:0]  mull_op_b_q;            // rf_rc_data (= Rs) at S_EXEC time
    logic         mull_signed_q;          // dec.mul_signed at S_EXEC time
    logic         mull_s_q;               // dec.s_bit at S_EXEC time

    // ---- PSR + exception entry plumbing ----
    psr_t         spsr_value;
    logic         spsr_valid;
    logic         cpsr_write_en;
    logic [31:0]  cpsr_write_data;
    logic [3:0]   cpsr_write_mask;

    logic         cpsr_restore_now;
    logic         bx_set_t_en;
    logic         bx_set_t_value;
    logic         exc_enter_en;
    logic [2:0]   exc_target_spsr_idx;
    psr_t         exc_new_cpsr;

    arm7tdmis_psr u_psr (
        .CLK                 (CLK),
        .CLKEN               (CLKEN),
        .nRESET              (nRESET),
        .cpsr                (cpsr),
        .spsr                (spsr_value),
        .spsr_valid          (spsr_valid),
        .cpsr_write_en       (cpsr_write_en),
        .cpsr_write_data     (cpsr_write_data),
        .cpsr_write_mask     (cpsr_write_mask),
        .spsr_write_en       (msr_to_spsr),
        .spsr_write_data     (sh_result),
        .spsr_write_mask     (dec.msr_field_mask),
        .cpsr_restore_en     (cpsr_restore_now),
        .bx_set_t_en         (bx_set_t_en),
        .bx_set_t_value      (bx_set_t_value),
        .exc_enter_en        (exc_enter_en),
        .exc_target_spsr_idx (exc_target_spsr_idx),
        .exc_new_cpsr        (exc_new_cpsr)
    );

    // ---- Condition evaluator (on the in-flight decoded instr) ----
    logic condition_pass;
    logic cond_is_nv;

    arm7tdmis_condition u_cond (
        .cond           (dec.cond),
        .n_flag         (cpsr.n),
        .z_flag         (cpsr.z),
        .c_flag         (cpsr.c),
        .v_flag         (cpsr.v),
        .condition_pass (condition_pass),
        .cond_is_nv     (cond_is_nv)
    );

    // ---- Regfile reads ----
    logic [31:0] rf_ra_data, rf_rb_data, rf_rc_data;
    logic        rf_pc_written;
    logic [3:0]  rf_write_addr;
    logic [31:0] rf_write_data;
    logic        rf_write_en;

    // Both ordinary and extra load/store encodings name their store source
    // in Rd. The extra halfword/signed class otherwise falls through to
    // dec.rs (instruction bits 11:8), which is part of its split immediate
    // and can silently source the wrong register for STRH.
    wire instr_is_ls_decoder = (dec.instr_class == INSTR_LDR_STR)
                            || (dec.instr_class == INSTR_LDRH_STRH);
    wire block_active        = (state_q == S_BLOCK_DATA);
    // MCR reads dec.rd via port C (the source register goes to the
    // coprocessor). LDR/STR also uses port C for dec.rd as the store source.
    wire instr_mcr_decoder = (dec.instr_class == INSTR_MCR_MRC)
                          && !de_q.instr[20];
    wire [3:0] rc_addr_eff   = block_active        ? block_curr_reg_q
                             : instr_is_ls_decoder ? dec.rd
                             : instr_mcr_decoder   ? dec.rd
                                                   : dec.rs;

    wire instr_is_mul_decoder = (dec.instr_class == INSTR_MUL);
    // Port A read addr:
    //   • S_MULL_ACC for UMLAL/SMLAL : mull_rdhi_q (latched RdHi address;
    //                                  dec is already stale by this cycle).
    //   • MUL / MLA / UMLAL-S_EXEC   : dec.rd (= the accumulator slot for
    //                                  MUL/MLA, RdLo for UMLAL/SMLAL).
    //   • Everything else            : dec.rn (DP source, L/S base).
    wire instr_is_mull_accum_decoder = (dec.instr_class == INSTR_MULL) && dec.mul_accumulate;
    wire [3:0] ra_addr_eff    = (state_q == S_MULL_ACC)             ? mull_rdhi_q
                              : (instr_is_mul_decoder ||
                                 instr_is_mull_accum_decoder)        ? dec.rd
                              :                                        dec.rn;

    wire [4:0] regfile_mode_eff = any_exc_fires ? exc_mode_target : cpsr.m;

    // LDM/STM with S=1 forces the user-bank registers for r8-r14
    // regardless of the current mode (TRM §12.4). The variant with PC
    // in the list uses the *current* bank for r0-r14 (it's an exception
    // return, not a user-mode read), so block_has_pc_q gates this off.
    wire force_user_bank_eff = block_active && block_user_mode_q
                            && !block_has_pc_q;

    arm7tdmis_regfile u_regfile (
        .CLK             (CLK),
        .CLKEN           (CLKEN),
        .nRESET          (nRESET),
        .mode            (regfile_mode_eff),
        .t_bit           (de_q.thumb),
        .pc_in           (de_q.pc),
        .ra_addr         (ra_addr_eff),
        .rb_addr         (dec.rm),
        .rc_addr         (rc_addr_eff),
        .ra_data         (rf_ra_data),
        .rb_data         (rf_rb_data),
        .rc_data         (rf_rc_data),
        .wa_addr         (rf_write_addr),
        .wa_data         (rf_write_data),
        .wa_enable       (rf_write_en),
        .force_user_bank (force_user_bank_eff),
        .dbg_we          (dbg_reg_we),
        .dbg_addr        (dbg_reg_addr),
        .dbg_wdata       (dbg_reg_wdata),
        .dbg_force_user_bank(dbg_reg_force_user),
        .dbg_rdata       (dbg_reg_rdata),
        .pc_written      (rf_pc_written)
    );

    // ---- Shifter ----
    logic [31:0] sh_result;
    logic        sh_carry_out;

    // DP-imm shifter input. For ARM the raw imm8 lives at instr[7:0]; the
    // decoder feeds shifter_amount=2*rot4 so the shifter performs the
    // architectural rotate and produces the shifter-carry the S-bit
    // path needs. For Thumb the imm is encoded at different bit
    // positions per format (3 / 13 / etc.), and the Thumb decoder
    // already extracts it into dp_imm_value with shifter_amount=0
    // (Thumb has no rotate field). So for Thumb we feed the decoded
    // value directly — the shifter is then a no-op and carry_out =
    // carry_in, matching ARMv4T's Thumb DP semantics (Thumb doesn't
    // affect C from immediates).
    wire [31:0] op2_shifter_in     = dec.dp_use_imm
                                     ? (de_q.thumb ? dec.dp_imm_value
                                                   : {24'h0, de_q.instr[7:0]})
                                     : rf_rb_data;
    wire [7:0]  op2_shifter_amount = dec.shifter_use_rs
                                     ? rf_rc_data[7:0]
                                     : dec.shifter_amount;

    arm7tdmis_shifter u_shifter (
        .op        (dec.shifter_op),
        .amount    (op2_shifter_amount),
        .is_rrx    (dec.shifter_is_rrx),
        .in_data   (op2_shifter_in),
        .carry_in  (cpsr.c),
        .result    (sh_result),
        .carry_out (sh_carry_out)
    );

    // ---- ALU ----
    logic [31:0] alu_result;
    logic        alu_n, alu_z, alu_c, alu_v;
    logic [3:0]  alu_flag_we;

    wire [31:0] alu_op_b = dec.dp_use_raw_imm ? dec.dp_imm_value : sh_result;

    // §15.12 Thumb fmt12 PC-form (ADD Rd, PC, #imm8<<2): the architectural
    // semantics force the PC base to word alignment ("PC AND ~3"). The
    // regfile already adds the +4 Thumb pipeline offset for r15 reads, so
    // we just mask bits[1:0] here. For all other DP ops (and ARM in
    // general) dp_pc_align is 0 and op_a passes through unchanged.
    wire [31:0] alu_op_a = dec.dp_pc_align ? (rf_ra_data & 32'hFFFFFFFC)
                                            : rf_ra_data;

    arm7tdmis_alu u_alu (
        .op            (dec.alu_op),
        .op_a          (alu_op_a),
        .op_b          (alu_op_b),
        .cpsr_c        (cpsr.c),
        .shifter_carry (sh_carry_out),
        .result        (alu_result),
        .n_out         (alu_n),
        .z_out         (alu_z),
        .c_out         (alu_c),
        .v_out         (alu_v),
        .flag_we       (alu_flag_we)
    );

    // Merge the ALU's per-flag write enables before using the PSR's
    // byte-granular flags field. Logical/move/shift operations update NZC
    // but preserve V; any future disabled flag likewise retains its value.
    wire [3:0] alu_flags_merged = {
        alu_flag_we[3] ? alu_n : cpsr.n,
        alu_flag_we[2] ? alu_z : cpsr.z,
        alu_flag_we[1] ? alu_c : cpsr.c,
        alu_flag_we[0] ? alu_v : cpsr.v
    };

    // ---- Multiplier ----
    logic [31:0] mul_result_lo, mul_result_hi;
    logic        mul_n_out, mul_z_out;
    logic [3:0]  mul_flag_we;
    logic [2:0]  mul_cycle_count;

    // §9d: is_long=1 for MULL forms (UMULL/SMULL/UMLAL/SMLAL); is_signed=1
    // for SMULL/SMLAL (decoder sets dec.mul_signed accordingly). MUL/MLA
    // keep is_long=0 / is_signed=0. UMLAL/SMLAL use the dedicated
    // S_MULL_ACC cycle below to read the accumulator high half.
    wire instr_class_is_mull = (dec.instr_class == INSTR_MULL);

    // §9c UMLAL/SMLAL routing. In S_MULL_ACC: op_a/op_b come from
    // latches captured at S_EXEC (dec is stale by S_MULL_ACC because D
    // advanced de_q to the next instruction). acc_lo from acc_lo_q,
    // acc_hi from current port-A read (which is regs[mull_rdhi_q] —
    // see ra_addr_eff override). In all other states the legacy live-
    // wiring stands.
    wire [31:0] mul_op_a_in   = (state_q == S_MULL_ACC) ? mull_op_a_q : rf_rb_data;
    wire [31:0] mul_op_b_in   = (state_q == S_MULL_ACC) ? mull_op_b_q : rf_rc_data;
    wire [31:0] mul_acc_lo_in = (state_q == S_MULL_ACC) ? acc_lo_q    : rf_ra_data;
    wire [31:0] mul_acc_hi_in = (state_q == S_MULL_ACC) ? rf_ra_data  : 32'h0;
    wire        mul_is_long_in     = (state_q == S_MULL_ACC) ? 1'b1 : instr_class_is_mull;
    wire        mul_accumulate_in  = (state_q == S_MULL_ACC) ? 1'b1 : dec.mul_accumulate;
    wire        mul_is_signed_in   = (state_q == S_MULL_ACC) ? mull_signed_q : dec.mul_signed;

    arm7tdmis_multiplier u_mul (
        .is_signed   (mul_is_signed_in),
        .is_long     (mul_is_long_in),
        .accumulate  (mul_accumulate_in),
        .op_a        (mul_op_a_in),
        .op_b        (mul_op_b_in),
        .acc_lo      (mul_acc_lo_in),
        .acc_hi      (mul_acc_hi_in),
        .result_lo   (mul_result_lo),
        .result_hi   (mul_result_hi),
        .n_out       (mul_n_out),
        .z_out       (mul_z_out),
        .flag_we     (mul_flag_we),
        .cycle_count (mul_cycle_count)
    );

    // =====================================================================
    // Substate FSM transitions
    // =====================================================================

    function automatic logic [3:0] lowest_set_idx(input logic [15:0] mask);
        for (int i = 0; i < 16; i = i + 1) begin
            if (mask[i]) return i[3:0];
        end
        return 4'd0;
    endfunction

    wire instr_is_ls_any = (dec.instr_class == INSTR_LDR_STR)
                        || (dec.instr_class == INSTR_LDRH_STRH);
    wire ls_take_data_cycle = passes_cond && instr_is_ls_any;
    // ARM single-transfer P=0,W=1 is the translated T form. It performs
    // the access with User permissions while execution remains in the
    // current (typically privileged) processor mode.
    wire ls_is_translated = (dec.instr_class == INSTR_LDR_STR)
                          && !dec.ls_pre_index && dec.ls_writeback;

    // LDM ^ with PC in the register list is the CPSR-from-SPSR variant
    // (TRM §12.4): on the cycle r15 loads, CPSR atomically := SPSR-of-
    // current-mode. For this variant we must NOT force user-bank for the
    // other registers in the list (TRM: "if r15 in list, current bank
    // is used"). Plain LDM/STM ^ without PC just routes user-bank reads
    // via force_user_bank_eff. Distinction handled by latching
    // block_has_pc_q at S_EXEC and gating force_user_bank_eff with it.
    wire block_take_cycle = passes_cond
                          && (dec.instr_class == INSTR_LDM_STM)
                          && (dec.block_reg_list != 16'h0);

    function automatic logic [4:0] popcount16(input logic [15:0] mask);
        logic [4:0] sum;
        sum = 5'd0;
        for (int i = 0; i < 16; i = i + 1) sum = sum + {4'h0, mask[i]};
        return sum;
    endfunction

    wire [4:0]  block_reg_count    = popcount16(dec.block_reg_list);
    wire [31:0] block_reg_count_x4 = {25'h0, block_reg_count, 2'h0};

    logic [31:0] block_start_addr;
    always_comb begin
        unique case ({dec.block_pre_index, dec.block_up})
            2'b01:   block_start_addr = rf_ra_data;
            2'b11:   block_start_addr = rf_ra_data + 32'd4;
            2'b00:   block_start_addr = rf_ra_data - block_reg_count_x4 + 32'd4;
            2'b10:   block_start_addr = rf_ra_data - block_reg_count_x4;
            default: block_start_addr = rf_ra_data;
        endcase
    end

    wire [31:0] block_writeback_addr = dec.block_up
                                       ? (rf_ra_data + block_reg_count_x4)
                                       : (rf_ra_data - block_reg_count_x4);

    // Normal LDM Rn writeback fires in the dedicated S_BLOCK_WB cycle.
    // For an aborted LDM the final data cycle's register port is free
    // (all writes from the aborting beat onward are suppressed), so the
    // requested modified base is restored there before S_BLOCK_WB uses
    // the port to save LR_abt.
    wire block_does_writeback = (state_q == S_BLOCK_WB)
                             && block_writeback_q
                             && !data_abort_q;

    wire [15:0] block_after_curr = block_remaining_q & ~(16'h1 << block_curr_reg_q);
    wire        block_has_more   = (block_after_curr != 16'h0);
    wire block_ldm_abort_writeback = (state_q == S_BLOCK_DATA)
                                   && !block_has_more
                                   && block_load_q
                                   && block_writeback_q
                                   && (data_abort_q || data_abort_now);

    // §17/§18: STM modifies Rn in the setup cycle. This is before the
    // first data response, so an abort on any beat still leaves the
    // requested writeback visible. It also preserves STM's n+1 timing
    // because no separate writeback state is introduced.
    wire block_stm_early_writeback = (state_q == S_EXEC)
                                   && block_take_cycle
                                   && !dec.block_load
                                   && dec.block_writeback;

    wire swp_take_cycle = passes_cond && (dec.instr_class == INSTR_SWP);

    // §9d: UMULL/SMULL take an extra cycle in S_MULL_HI to write RdHi.
    wire mull_take_cycle = passes_cond && instr_class_is_mull
                        && !dec.mul_accumulate;

    // §9c UMLAL/SMLAL — the 64-bit accumulate forms take an extra cycle
    // (S_MULL_ACC) before S_MUL_BUSY to read RdHi via the regfile's
    // single port A; RdLo comes in during S_EXEC. The multiplier sees
    // both accumulator halves at S_MULL_ACC and produces the correct
    // result_lo (committed there) and result_hi (latched, committed in
    // S_MULL_HI).
    wire mull_accum_take_cycle = passes_cond && instr_class_is_mull
                              && dec.mul_accumulate;

    // §18: any MUL or MULL takes the S_MUL_BUSY internal-cycle detour
    // for m cycles where m is determined by the multiplier from Rs's
    // significant-bit-count (TRM §7.7). m ranges 1..4 → MUL completes
    // in 2..5 cycles, MULL completes in 3..6 cycles (or 4..7 for
    // accumulate forms with the extra S_MULL_ACC cycle).
    wire mul_take_busy = passes_cond
                      && (instr_is_mul || (instr_class_is_mull && !dec.mul_accumulate));

    // §18: DP shift-by-register (TRM Table 7-3 row 2) takes 1S+1I = 2
    // cycles. Detected combinationally; defers the commit to S_DP_SHIFT.
    wire dp_shift_take_cycle = passes_cond && instr_is_dp && dec.shifter_use_rs;

    // TRM §4.4.4: an unmasked IRQ/FIQ can abandon an accepted
    // coprocessor instruction only while it is still busy-waiting. Give
    // that interrupt priority over a coincident CPB-ready transition so
    // the coprocessor cannot commit after the exception has won.
    wire cp_wait_fiq_pending = (state_q == S_CP_WAIT)
                             && !nFIQ && !cpsr.f;
    wire cp_wait_irq_pending = (state_q == S_CP_WAIT)
                             && !nIRQ && !cpsr.i;
    wire cp_wait_interrupt_pending = cp_wait_fiq_pending
                                   || cp_wait_irq_pending;
    wire cp_wait_abandon_pending = cp_wait_interrupt_pending
                                 || cp_wait_debug_pending;

    // E-stage substate transitions. Single-cycle "execute" loops back to
    // S_EXEC; multi-cycle ops take the appropriate substate detour.
    // While in S_EXEC, an invalid de_q (bubble) still loops to S_EXEC —
    // the bus is idle that cycle.
    state_e state_next;
    always_comb begin
        unique case (state_q)
            S_EXEC:       state_next = ls_take_data_cycle    ? S_DDATA
                                     : block_take_cycle      ? S_BLOCK_DATA
                                     : swp_take_cycle        ? S_SWP_RDATA
                                     : mull_accum_take_cycle ? S_MULL_ACC
                                     : mul_take_busy         ? S_MUL_BUSY
                                     : dp_shift_take_cycle   ? S_DP_SHIFT
                                     : external_cp_busy      ? S_CP_WAIT
                                     : (external_cp_ready
                                        && external_cp_is_mcr)
                                                            ? S_CP_MCR_DATA
                                     : (external_cp_ready
                                        && external_cp_is_mrc)
                                                            ? S_CP_MRC_DATA
                                     : (external_cp_ready
                                        && external_cp_is_stc)
                                                            ? S_CP_MCR_DATA
                                     : (external_cp_ready
                                        && external_cp_is_ldc)
                                                            ? S_CP_MRC_DATA
                                                             : S_EXEC;
            S_DDATA:      state_next = ls_load_q ? S_LOAD_WB : S_EXEC;
            S_LOAD_WB:    state_next = S_EXEC;
            // STM (block_load_q=0) skips the S_BLOCK_WB cycle: TRM has no
            // I cycle for STM (Table 7-15: 1S+(n-1)S+1N = n+1 cycles).
            // LDM still goes through S_BLOCK_WB for the Rd writeback I
            // cycle (and Rn writeback when W=1).
            S_BLOCK_DATA: state_next = block_has_more ? S_BLOCK_DATA
                                     : (block_load_q  ? S_BLOCK_WB : S_EXEC);
            S_BLOCK_WB:   state_next = S_EXEC;
            // ARM7TDMI-S requires any SWP Data Abort to be signaled on
            // the read. A failed read terminates the locked sequence;
            // the write phase must never be issued.
            S_SWP_RDATA:  state_next = data_abort_now ? S_EXEC
                                                      : S_SWP_WDATA;
            S_SWP_WDATA:  state_next = S_SWP_WB;
            S_SWP_WB:     state_next = S_EXEC;
            S_MULL_HI:    state_next = S_EXEC;
            S_MUL_BUSY:   state_next = (mul_busy_remaining_q == 3'd1)
                                       ? (mull_active_q ? S_MULL_HI : S_EXEC)
                                       : S_MUL_BUSY;
            S_MULL_ACC:   state_next = S_MUL_BUSY;
            S_DP_SHIFT:   state_next = S_EXEC;
            S_CP_WAIT:    state_next = cp_wait_abandon_pending ? S_EXEC
                                     : !cp_wait_ready ? S_CP_WAIT
                                     : cp_wait_is_mcr_q ? S_CP_MCR_DATA
                                     : cp_wait_is_mrc_q ? S_CP_MRC_DATA
                                     : cp_wait_is_stc_q ? S_CP_MCR_DATA
                                     : cp_wait_is_ldc_q ? S_CP_MRC_DATA
                                                       : S_EXEC;
            S_CP_MCR_DATA: state_next = cp_wait_is_stc_q
                                      ? (cp_ls_final ? S_CP_MRC_WB
                                                     : S_CP_MCR_DATA)
                                      : S_EXEC;
            S_CP_MRC_DATA: state_next = cp_wait_is_ldc_q
                                      ? (cp_ls_final ? S_CP_MRC_WB
                                                     : S_CP_MRC_DATA)
                                      : S_CP_MRC_WB;
            S_CP_MRC_WB:   state_next = S_EXEC;
            default:      state_next = S_EXEC;
        endcase
    end

    // Every instruction class returns to S_EXEC only after its final
    // architectural effect: ordinary S_EXEC instructions complete in
    // place, while load/block/SWP/multiply/coprocessor substates return
    // only after their destination and base writebacks. ICE uses this
    // combinational indication on the same enabled edge as the commit.
    assign dbg_halt_boundary = (state_next == S_EXEC);

    // =====================================================================
    // Writeback / commit / flush computation (S_EXEC + memory substates)
    // =====================================================================

    // `executing` predicate — only valid de_q during S_EXEC writes back.
    wire executing = (state_q == S_EXEC) && de_q.valid && !dbg_inject_we;
    // TRM §5.19.1: an external Prefetch Abort on the breakpointed fetch
    // takes priority and disregards the breakpoint. Do not let ICE gate
    // off the very Execute edge on which the core must select PABT.
    assign dbg_breakpoint_execute = executing && de_q.breakpoint
                                  && !de_q.pabort;
    wire passes_cond = executing && condition_pass && !dec_is_unimplemented_q;

    // Explicit scan-chain instruction handshake. Acceptance is the edge
    // that replaces F and invalidates the pre-debug E instruction. The
    // started latch spans all multicycle substates until the final
    // architectural completion edge returns state_next to S_EXEC.
    logic dbg_inject_started_q;
    wire dbg_inject_starts = executing && de_q.injected;
    assign dbg_inject_accept = CLKEN && dbg_inject_we;
    assign dbg_inject_retire = CLKEN && dbg_inject_active
                             && (dbg_inject_started_q || dbg_inject_starts)
                             && (state_next == S_EXEC);

    always_ff @(posedge CLK) begin
        if (!nRESET) begin
            dbg_inject_started_q <= 1'b0;
        end else if (CLKEN) begin
            if (dbg_inject_we || dbg_inject_retire)
                dbg_inject_started_q <= 1'b0;
            else if (dbg_inject_starts)
                dbg_inject_started_q <= 1'b1;
        end
    end

    // We need the unimplemented bit latched alongside de_q.dec. Use a
    // small companion register driven from dec_is_unimplemented_w at the
    // same time we latch de_q.
    logic dec_is_unimplemented_q;
    always_ff @(posedge CLK) begin
        if (!nRESET)
            dec_is_unimplemented_q <= 1'b0;
        else if (CLKEN) begin
            if (flush)
                dec_is_unimplemented_q <= 1'b0;
            else if (!e_busy && fd_q.valid)
                dec_is_unimplemented_q <= dec_is_unimplemented_w;
        end
    end

    wire instr_is_dp     = (dec.instr_class == INSTR_DP);
    wire instr_is_branch = (dec.instr_class == INSTR_BRANCH);
    wire instr_is_bx     = (dec.instr_class == INSTR_BX);
    wire instr_is_swi    = (dec.instr_class == INSTR_SWI);
    wire instr_is_mul    = (dec.instr_class == INSTR_MUL);
    wire instr_is_msr    = (dec.instr_class == INSTR_MSR);
    wire instr_is_mrs    = (dec.instr_class == INSTR_MRS);
    wire instr_is_undef  = (dec.instr_class == INSTR_UNDEF);

    // §19/§20: coprocessor instructions. With no external coprocessor
    // present, CP instructions trap UNDEF except for the internal CP14
    // Debug Communications Channel. A bare ARM7TDMI-S has no internal
    // CP15; a system that needs one must claim p15 on this interface.
    wire instr_is_cp = (dec.instr_class == INSTR_CDP)
                    || (dec.instr_class == INSTR_MCR_MRC)
                    || (dec.instr_class == INSTR_LDC_STC);
    wire instr_is_cp14 = instr_is_cp && (dec.cp_num == 4'd14);
    wire instr_is_mrc  = (dec.instr_class == INSTR_MCR_MRC) && de_q.instr[20];
    wire instr_is_mcr  = (dec.instr_class == INSTR_MCR_MRC) && !de_q.instr[20];
    wire cp14_exact_fields = instr_is_cp14
                          && (dec.instr_class == INSTR_MCR_MRC)
                          && (de_q.instr[23:21] == 3'b000)
                          && (de_q.instr[7:5] == 3'b000)
                          && (de_q.instr[3:0] == 4'b0000);
    wire cp14_mrc_control = cp14_exact_fields && instr_is_mrc
                          && (de_q.instr[19:16] == 4'd0);
    wire cp14_mrc_data    = cp14_exact_fields && instr_is_mrc
                          && (de_q.instr[19:16] == 4'd1);
    wire cp14_mcr_data    = cp14_exact_fields && instr_is_mcr
                          && (de_q.instr[19:16] == 4'd1);
    wire cp14_mrc_dbgabt  = cp14_exact_fields && instr_is_mrc
                          && (de_q.instr[19:16] == 4'd2);
    wire cp14_mcr_dbgabt  = cp14_exact_fields && instr_is_mcr
                          && (de_q.instr[19:16] == 4'd2);
    wire cp14_supported   = cp14_mrc_control || cp14_mrc_data
                          || cp14_mcr_data || cp14_mrc_dbgabt
                          || cp14_mcr_dbgabt;
    wire external_cp_request = passes_cond && instr_is_cp && !instr_is_cp14;
    wire external_cp_ready   = external_cp_request && !CPA && !CPB;
    wire external_cp_busy    = external_cp_request && !CPA &&  CPB;
    wire external_cp_is_mcr  = external_cp_request && instr_is_mcr;
    wire external_cp_is_mrc  = external_cp_request && instr_is_mrc;
    wire external_cp_is_ldc  = external_cp_request
                             && (dec.instr_class == INSTR_LDC_STC)
                             && de_q.instr[20];
    wire external_cp_is_stc  = external_cp_request
                             && (dec.instr_class == INSTR_LDC_STC)
                             && !de_q.instr[20];
    wire cp_wait_ready       = (state_q == S_CP_WAIT) && !CPA && !CPB;
    wire cp_ls_final         = cp_ls_data_state && CPA && CPB;
    wire cp_undef_trap = executing && condition_pass && instr_is_cp
                      && (instr_is_cp14 ? !cp14_supported : CPA);

    // ARM Addressing Mode 5. offset8 is scaled by four; P selects the
    // adjusted address versus the original base, while W independently
    // requests the adjusted value be committed to Rn.
    wire [31:0] cp_ls_offset = {22'h0, de_q.instr[7:0], 2'b00};
    wire [31:0] cp_ls_adjusted_base = de_q.instr[23]
                                           ? (rf_ra_data + cp_ls_offset)
                                           : (rf_ra_data - cp_ls_offset);
    wire [31:0] cp_ls_start_addr = de_q.instr[24]
                                           ? cp_ls_adjusted_base
                                           : rf_ra_data;

    wire cp14_mrc_control_fires = passes_cond && cp14_mrc_control;
    wire cp14_mcr_data_fires    = passes_cond && cp14_mcr_data;
    wire cp14_mrc_data_fires    = passes_cond && cp14_mrc_data;
    wire cp14_mrc_dbgabt_fires  = passes_cond && cp14_mrc_dbgabt;
    wire cp14_mcr_dbgabt_fires  = passes_cond && cp14_mcr_dbgabt;
    wire cp14_mrc_fires         = cp14_mrc_control_fires
                                || cp14_mrc_data_fires
                                || cp14_mrc_dbgabt_fires;
    wire [31:0] cp14_mrc_value  = cp14_mrc_control_fires ? core_dcc_control
                                : cp14_mrc_data_fires    ? core_dcc_rdata
                                                        : core_dbgabt_rdata;
    wire [31:0] cp14_mcr_value  = (dec.rd == 4'd15)
                                ? (de_q.pc + 32'd12)
                                : rf_rc_data;

    // c1 has separate processor-facing directions. A read consumes RX;
    // a write fills TX. c2 is a one-bit software-visible status register.
    assign core_dcc_we        = cp14_mcr_data_fires;
    assign core_dcc_re        = cp14_mrc_data_fires;
    assign core_dcc_wdata     = cp14_mcr_value;
    assign core_dbgabt_we     = cp14_mcr_dbgabt_fires;
    assign core_dbgabt_wdata  = cp14_mcr_value[0];

    wire msr_fires   = passes_cond && instr_is_msr;
    wire mrs_fires   = passes_cond && instr_is_mrs;
    wire msr_to_cpsr = msr_fires && !dec.psr_use_spsr;
    wire msr_to_spsr = msr_fires &&  dec.psr_use_spsr;

    wire dp_writes_dest     = passes_cond && instr_is_dp && !dec.is_test_op;
    wire dp_writes_pc       = dp_writes_dest && (dec.rd == 4'd15);
    wire branch_link_writes = passes_cond && instr_is_branch && dec.branch_link;
    wire branch_writes_pc   = passes_cond && instr_is_branch;
    wire bx_writes_pc       = passes_cond && instr_is_bx;
    wire swi_pending   = passes_cond && instr_is_swi;
    wire undef_pending = executing
                       && ((condition_pass && instr_is_undef) || cond_is_nv
                           || cp_undef_trap);
    // A halt-mode watchpoint or DBGRQ has priority over an interrupt, but
    // §5.19.2 requires the core to remember the interrupt and enter debug
    // in that exception's mode. Retain a one-cycle request sampled during
    // a multicycle instruction, then take it on the following S_EXEC edge
    // after the watched instruction's final architectural writeback.
    logic debug_irq_pending_q;
    logic debug_fiq_pending_q;
    wire debug_halt_collision = dbg_watchpoint_halt || dbg_halt_req
                              || dbg_breakpoint_execute;
    wire debug_irq_pending_now = debug_halt_collision
                               && !nIRQ && !cpsr.i;
    wire debug_fiq_pending_now = debug_halt_collision
                               && !nFIQ && !cpsr.f;
    assign dbg_exception_pending = debug_irq_pending_q
                                 || debug_fiq_pending_q
                                 || debug_irq_pending_now
                                 || debug_fiq_pending_now;
    // Narrow combinational qualifier for the immediate breakpoint stop
    // gate. Keep this independent of data-watchpoint inputs so no
    // WDATA/comparator-to-core-halt feedback path is created.
    assign dbg_breakpoint_interrupt_pending =
        dbg_breakpoint_execute
        && ((!nIRQ && !cpsr.i) || (!nFIQ && !cpsr.f));

    wire irq_pending   = (executing && !nIRQ && !cpsr.i)
                       || cp_wait_irq_pending
                       || ((state_q == S_EXEC) && debug_irq_pending_q);
    wire fiq_pending   = (executing && !nFIQ && !cpsr.f)
                       || cp_wait_fiq_pending
                       || ((state_q == S_EXEC) && debug_fiq_pending_q);
    logic fiq_after_dabt_q;
    wire  fiq_interlock_fires = fiq_after_dabt_q
                              && (state_q == S_EXEC);

    // §17: the prefetch-abort metadata travels with the fetched
    // instruction. It remains a request even when that instruction also
    // decodes Undefined; the priority selector below chooses PABT.
    wire debug_pabt_pending = executing && de_q.breakpoint
                            && dbg_monitor_mode;
    wire pabt_pending = executing && (de_q.pabort || debug_pabt_pending);

    // TRM §2.9.10 fixed priority below Data Abort:
    // FIQ > IRQ > PABT > UNDEF > SWI. These are selected, one-hot events,
    // not merely overlapping requests. Data Abort is generated only in a
    // non-S_EXEC memory substate, so it is mutually exclusive here; the
    // DABT+FIQ interlock is handled separately at its abort boundary.
    wire fiq_fires   = fiq_pending || fiq_interlock_fires;
    wire irq_fires   = irq_pending && !fiq_pending;
    wire pabt_fires  = pabt_pending && !fiq_pending && !irq_pending;
    wire undef_fires = undef_pending && !fiq_pending && !irq_pending
                    && !pabt_pending;
    wire swi_fires   = swi_pending && !fiq_pending && !irq_pending
                    && !pabt_pending && !undef_pending;

    // §17/§31.6: data abort fires when ABORT is asserted during the active
    // response cycle of an LDR/STR/LDM/STM/SWP/LDC/STC. CP load/store
    // address phases are pipelined, so cp_ls_response_q distinguishes a
    // returned data response from the accepted instruction's preceding N
    // opcode cycle. Latched so the exception can be raised only after a
    // variable-length transfer reaches its coprocessor-selected final word.
    wire active_data_response = (state_q == S_DDATA)
                              || (state_q == S_BLOCK_DATA)
                              || (state_q == S_SWP_RDATA)
                              || (state_q == S_SWP_WDATA)
                              || (cp_ls_response_q
                                  && (cp_ls_data_state
                                      || cp_ls_cleanup_state));
    wire external_data_abort_now = CLKEN && ABORT
                                 && active_data_response;
    wire debug_data_abort_now = CLKEN && dbg_watchpoint_abort
                              && active_data_response;
    wire data_abort_now = external_data_abort_now || debug_data_abort_now;

    logic data_abort_q;
    logic external_data_abort_q;
    logic debug_data_abort_q;
    always_ff @(posedge CLK) begin
        if (!nRESET) begin
            data_abort_q          <= 1'b0;
            external_data_abort_q <= 1'b0;
            debug_data_abort_q    <= 1'b0;
        end else if (CLKEN) begin
            if (state_q == S_EXEC) begin
                // Clear on entering a new instruction.
                data_abort_q          <= 1'b0;
                external_data_abort_q <= 1'b0;
                debug_data_abort_q    <= 1'b0;
            end else begin
                if (data_abort_now)
                    data_abort_q <= 1'b1;
                if (external_data_abort_now)
                    external_data_abort_q <= 1'b1;
                if (debug_data_abort_now)
                    debug_data_abort_q <= 1'b1;
            end
        end
    end

    // Fire DABT at the end of the memory-substate sequence — i.e., on the
    // transition back to S_EXEC. This is the cycle where commits would
    // otherwise complete and the next instruction would normally enter.
    //
    // For single-beat LDR/STR the S_DDATA cycle IS the transition out
    // (state_next == S_EXEC), so data_abort_q hasn't been latched yet
    // (the latch fires at the posedge ending this cycle). Include
    // data_abort_now (the live signal) to catch that case; for multi-
    // beat LDM/STM the latch carries data_abort through to S_BLOCK_WB.
    wire dabt_fires = (data_abort_q || data_abort_now)
                   && (state_next == S_EXEC)
                   && (state_q != S_EXEC);
    wire external_dabt_cause = external_data_abort_q
                             || external_data_abort_now;
    wire debug_dabt_cause = debug_data_abort_q || debug_data_abort_now;
    wire debug_pabt_fires = pabt_fires && debug_pabt_pending
                          && !de_q.pabort;
    wire debug_dabt_fires = dabt_fires && debug_dabt_cause
                          && !external_dabt_cause;
    assign dbg_abort_taken = debug_pabt_fires || debug_dabt_fires;

    // TRM §2.9.10 DABT+FIQ interlock. DABT must save the interrupted
    // program first, without setting CPSR.F. The immediately following
    // boundary then enters FIQ from Abort mode even if nFIQ was only low
    // for the coincident enabled cycle. Returning from FIQ resumes the
    // untouched Data Abort vector.
    always_ff @(posedge CLK) begin
        if (!nRESET) begin
            fiq_after_dabt_q <= 1'b0;
        end else if (CLKEN) begin
            if (fiq_interlock_fires)
                fiq_after_dabt_q <= 1'b0;
            // Sample at the actual failed data response. Loads and LDMs
            // can spend later writeback/completion cycles before
            // dabt_fires, by which time a one-cycle nFIQ pulse is gone.
            else if (data_abort_now && !nFIQ && !cpsr.f)
                fiq_after_dabt_q <= 1'b1;
        end
    end

    wire any_exc_fires    = swi_fires || undef_fires || irq_fires || fiq_fires
                         || pabt_fires || dabt_fires;
    wire cp_wait_interrupt_fires = (state_q == S_CP_WAIT)
                                 && (irq_fires || fiq_fires);

    // TRM §2.9.8 exception-link table. Synchronous SWI/UNDEF links use
    // the source instruction width; IRQ/FIQ/PABT always use PC+4; DABT
    // uses the faulting transfer's PC+8. The latter comes from an issue-
    // time latch because Decode can already contain the next Thumb
    // halfword by the eventual abort writeback boundary.
    wire [31:0] exception_lr_value =
        fiq_interlock_fires ? 32'h0000_0014
      : dabt_fires          ? (memory_instr_pc_q + 32'd8)
      : cp_wait_interrupt_fires
                            ? (cp_instr_pc_q + 32'd4)
      : (swi_fires || undef_fires)
                            ? (de_q.pc + (de_q.thumb ? 32'd2 : 32'd4))
                            : (de_q.pc + 32'd4);

    always_ff @(posedge CLK) begin
        if (!nRESET) begin
            debug_irq_pending_q <= 1'b0;
            debug_fiq_pending_q <= 1'b0;
        end else if (CLKEN) begin
            if (irq_fires || fiq_fires) begin
                debug_irq_pending_q <= 1'b0;
                debug_fiq_pending_q <= 1'b0;
            end else begin
                if (debug_irq_pending_now)
                    debug_irq_pending_q <= 1'b1;
                if (debug_fiq_pending_now)
                    debug_fiq_pending_q <= 1'b1;
            end
        end
    end

    // Exception/watchpoint debug entry is delayed until the first vector
    // instruction has been fetched, but not executed (TRM §5.18.3). A
    // flush starts the refill; latch_into_fd marks the response edge that
    // captures that first vector instruction. ICE freezes the core after
    // this edge, before fd_q can advance into Execute.
    logic debug_exception_refill_q;
    assign dbg_exception_entry = any_exc_fires;
    assign dbg_exception_vector_ready = debug_exception_refill_q
                                      && latch_into_fd;
    always_ff @(posedge CLK) begin
        if (!nRESET)
            dbg_exception_vector_pc <= 32'h0000_0000;
        else if (CLKEN && dbg_exception_vector_ready)
            dbg_exception_vector_pc <= inflight_pc_q;
    end
    always_ff @(posedge CLK) begin
        if (!nRESET) begin
            debug_exception_refill_q <= 1'b0;
        end else if (CLKEN) begin
            if (any_exc_fires)
                debug_exception_refill_q <= 1'b1;
            else if (dbg_exception_vector_ready)
                debug_exception_refill_q <= 1'b0;
        end
    end

    // §9d: MUL/MLA write Rd at bits[19:16] (= dec.rn) in S_EXEC.
    // UMULL/SMULL write RdLo at bits[15:12] (= dec.rd) in S_EXEC and
    // RdHi at bits[19:16] (= dec.rn) in S_MULL_HI. Non-accumulating flag
    // updates happen in S_EXEC because both product halves are already
    // combinational. UMLAL/SMLAL defer N/Z until S_MULL_ACC, when both
    // accumulator halves are available and the final 64-bit sum exists.
    wire mul_writes_dest  = passes_cond && instr_is_mul;
    wire mull_writes_lo   = mull_take_cycle;
    wire mull_accum_writes_flags = (state_q == S_MULL_ACC) && mull_s_q;
    wire mul_writes_flags = ((mul_writes_dest || mull_take_cycle) && dec.s_bit)
                          || mull_accum_writes_flags;

    wire writes_pc_exec   = (dp_writes_pc && !dp_shift_take_cycle)
                          || ((state_q == S_DP_SHIFT) && dp_shift_writes_pc_q)
                          || branch_writes_pc || bx_writes_pc
                          || any_exc_fires;
    // For DP shift-by-reg, defer the destination + flag commit to
    // S_DP_SHIFT (TRM 1S+1I cycle accuracy). The flush trigger
    // writes_pc_exec also gates on this so the PC isn't redirected
    // a cycle too early.
    wire exec_writes_rf   = (dp_writes_dest && !dp_shift_take_cycle)
                         || branch_link_writes || any_exc_fires;
    wire writes_flags     = (passes_cond && instr_is_dp && dec.s_bit && !dp_shift_take_cycle)
                         || mul_writes_flags;

    // CPSR := SPSR-of-current-mode fires on:
    //   - DP to PC with S=1 (MOVS PC, LR family)
    //   - LDM ^ with PC in list, at the cycle r15 loads
    wire block_ldm_pc_restore = (state_q == S_BLOCK_DATA) && block_load_q
                             && (block_curr_reg_q == 4'd15)
                             && block_user_mode_q
                             && !data_abort_q && !data_abort_now;
    assign cpsr_restore_now = (dp_writes_pc && dec.s_bit) || block_ldm_pc_restore;
    assign bx_set_t_en      = bx_writes_pc;
    assign bx_set_t_value   = rf_rb_data[0];

    // Exception target tables
    logic [4:0]  exc_mode_target;
    logic [2:0]  exc_spsr_target;
    logic [31:0] exc_pc_target_addr;

    always_comb begin
        // Default: SWI (lowest-priority entry path).
        exc_mode_target    = 5'(MODE_SUPERVISOR);
        exc_spsr_target    = 3'd2;
        exc_pc_target_addr = 32'h0000_0008;
        // TRM §2.9.10: DABT > FIQ > IRQ > PABT > UNDEF > SWI.
        if (dabt_fires) begin
            exc_mode_target    = 5'(MODE_ABORT);
            exc_spsr_target    = 3'd3;
            exc_pc_target_addr = 32'h0000_0010;
        end else if (fiq_fires) begin
            exc_mode_target    = 5'(MODE_FIQ);
            exc_spsr_target    = 3'd0;
            exc_pc_target_addr = 32'h0000_001C;
        end else if (irq_fires) begin
            exc_mode_target    = 5'(MODE_IRQ);
            exc_spsr_target    = 3'd1;
            exc_pc_target_addr = 32'h0000_0018;
        end else if (pabt_fires) begin
            exc_mode_target    = 5'(MODE_ABORT);
            exc_spsr_target    = 3'd3;
            exc_pc_target_addr = 32'h0000_000C;
        end else if (undef_fires) begin
            exc_mode_target    = 5'(MODE_UNDEFINED);
            exc_spsr_target    = 3'd4;
            exc_pc_target_addr = 32'h0000_0004;
        end
    end

    psr_t exc_cpsr_built;
    always_comb begin
        exc_cpsr_built   = cpsr;
        exc_cpsr_built.m = exc_mode_target;
        exc_cpsr_built.i = 1'b1;
        exc_cpsr_built.t = 1'b0;
        if (fiq_fires) exc_cpsr_built.f = 1'b1;
    end
    assign exc_enter_en        = any_exc_fires;
    assign exc_target_spsr_idx = exc_spsr_target;
    assign exc_new_cpsr        = exc_cpsr_built;

    // PC targets per class.
    wire [31:0] dp_pc_target = alu_result;
    wire [31:0] branch_base  = dec.branch_use_rn_base
                              ? rf_ra_data
                              : de_q.pc + (de_q.thumb ? 32'd4 : 32'd8);
    wire [31:0] branch_pc_target = branch_base + dec.branch_offset;
    wire [31:0] bx_pc_target     = rf_rb_data[0]
                                  ? (rf_rb_data & 32'hFFFF_FFFE)
                                  : (rf_rb_data & 32'hFFFF_FFFC);

    wire [31:0] pc_target_exec = any_exc_fires   ? exc_pc_target_addr :
                                 instr_is_branch ? branch_pc_target :
                                 instr_is_bx     ? bx_pc_target     :
                                                   dp_pc_target;

    // L/S address generation
    wire [31:0] ls_offset_value =
        (dec.instr_class == INSTR_LDRH_STRH)
          ? (dec.hs_use_imm ? {24'h0, dec.hs_imm_offset} : rf_rb_data)
          : (dec.ls_use_imm ? {20'h0, dec.ls_imm_offset} : sh_result);

    wire [31:0] ls_rn_value      = (dec.rn == 4'd15)
                                   ? (rf_ra_data & 32'hFFFF_FFFC)
                                   : rf_ra_data;
    wire [31:0] ls_data_addr_calc = dec.ls_up
                                    ? (ls_rn_value + ls_offset_value)
                                    : (ls_rn_value - ls_offset_value);

    wire [31:0] ls_data_addr_used    = dec.ls_pre_index ? ls_data_addr_calc : rf_ra_data;
    wire        ls_writeback_in_exec = ls_take_data_cycle
                                     && (dec.ls_writeback || !dec.ls_pre_index);

    wire ls_effective_byte     = (dec.instr_class == INSTR_LDRH_STRH)
                                   ? !dec.hs_halfword
                                   : dec.ls_byte;
    wire ls_effective_halfword = (dec.instr_class == INSTR_LDRH_STRH)
                                   ? dec.hs_halfword
                                   : 1'b0;
    wire ls_effective_signed   = (dec.instr_class == INSTR_LDRH_STRH)
                                   ? dec.hs_signed
                                   : 1'b0;

    // Load-value extraction (these reference RDATA during S_DDATA — at
    // which point RDATA IS the load data, not a fetch result. Same as
    // the non-pipelined core.)
    wire [1:0]  load_byte_lane  = CFGBIGEND ? ~ls_addr_lo_q
                                            :  ls_addr_lo_q;
    wire [4:0]  load_byte_shift = {load_byte_lane, 3'b000};
    wire [7:0]  load_byte_raw   = 8'((RDATA >> load_byte_shift) & 32'h0000_00FF);
    wire [31:0] load_byte_val   = ls_signed_q
                                  ? {{24{load_byte_raw[7]}}, load_byte_raw}
                                  : {24'h0, load_byte_raw};

    wire        load_hw_high    = CFGBIGEND ? ~ls_addr_lo_q[1]
                                            :  ls_addr_lo_q[1];
    wire [15:0] load_hw_raw     = load_hw_high ? RDATA[31:16]
                                              : RDATA[15:0];
    wire [31:0] load_hw_val     = ls_signed_q
                                  ? {{16{load_hw_raw[15]}}, load_hw_raw}
                                  : {16'h0, load_hw_raw};

    wire [31:0] load_word_val   = RDATA;
    wire [31:0] load_value      = ls_halfword_q ? load_hw_val
                                : ls_byte_q    ? load_byte_val
                                                : load_word_val;

    // §17: writeback suppression on data abort. ddata_writes_rd suppressed
    // when the current data cycle aborted; block load writeback suppressed
    // similarly. SWP Rd commit also suppressed if any abort fired during
    // the locked read/write window.
    // §18: LDR/LDRB writeback fires in S_LOAD_WB (TRM 1S+1N+1I), not
    // S_DDATA. Suppressed on data abort.
    wire ddata_writes_rd  = (state_q == S_LOAD_WB) && !data_abort_q;
    wire block_writes_ldm = (state_q == S_BLOCK_DATA) && block_load_q
                          && !data_abort_q && !data_abort_now;
    wire swp_writes_rd    = (state_q == S_SWP_WB) && !data_abort_q;
    wire cp_ls_writes_base = cp_ls_data_state && cp_ls_first_q
                           && cp_ls_writeback_q;

    wire [1:0]  swp_byte_lane  = CFGBIGEND ? ~swp_addr_lo_q
                                           :  swp_addr_lo_q;
    wire [4:0]  swp_byte_shift = {swp_byte_lane, 3'b000};
    wire [31:0] swp_byte_val   = (swp_loaded_q >> swp_byte_shift) & 32'h0000_00FF;
    wire [31:0] swp_load_value = swp_byte_q ? swp_byte_val : swp_loaded_q;

    // Regfile write-port mux (priority as in non-pipelined core)
    always_comb begin
        if (ddata_writes_rd) begin
            rf_write_addr = ls_rd_q;
            rf_write_data = load_value_q;     // §18 latched at S_DDATA end
            rf_write_en   = 1'b1;
        end else if (block_writes_ldm) begin
            rf_write_addr = block_curr_reg_q;
            rf_write_data = RDATA;
            rf_write_en   = 1'b1;
        end else if (block_ldm_abort_writeback) begin
            rf_write_addr = block_rn_q;
            rf_write_data = block_writeback_addr_q;
            rf_write_en   = 1'b1;
        end else if (swp_writes_rd) begin
            rf_write_addr = swp_rd_q;
            rf_write_data = swp_load_value;
            rf_write_en   = 1'b1;
        end else if (cp_ls_writes_base) begin
            rf_write_addr = cp_ls_rn_q;
            rf_write_data = cp_ls_writeback_value_q;
            rf_write_en   = 1'b1;
        end else if (cp_mrc_wb_state) begin
            rf_write_addr = cp_mrc_rd_q;
            rf_write_data = cp_mrc_data_q;
            // Rd=r15 is the MRC flags form. It updates CPSR.NZCV below
            // and must not request a PC write through the register file.
            rf_write_en   = (cp_mrc_rd_q != 4'd15);
        end else if (any_exc_fires) begin
            rf_write_addr = 4'd14;
            rf_write_data = exception_lr_value;
            rf_write_en   = 1'b1;
        end else if (branch_link_writes) begin
            rf_write_addr = 4'd14;
            rf_write_data = dec.branch_thumb_link
                            ? ((de_q.pc + 32'd2) | 32'h1)
                            : (de_q.pc + 32'd4);
            rf_write_en   = 1'b1;
        end else if (ls_writeback_in_exec) begin
            rf_write_addr = dec.rn;
            rf_write_data = ls_data_addr_calc;
            rf_write_en   = 1'b1;
        end else if (block_stm_early_writeback) begin
            rf_write_addr = dec.rn;
            rf_write_data = block_writeback_addr;
            rf_write_en   = 1'b1;
        end else if (block_does_writeback) begin
            // dec.* is stale by S_BLOCK_WB (de_q advanced); use latched
            // block_rn_q and block_writeback_addr_q snapshotted at S_EXEC.
            rf_write_addr = block_rn_q;
            rf_write_data = block_writeback_addr_q;
            rf_write_en   = 1'b1;
        end else if (state_q == S_MULL_HI) begin
            // §9d: RdHi commit cycle for UMULL/SMULL/UMLAL/SMLAL.
            rf_write_addr = mull_rdhi_q;
            rf_write_data = mull_result_hi_q;
            rf_write_en   = 1'b1;
        end else if (state_q == S_MULL_ACC) begin
            // §9c: RdLo commit for UMLAL/SMLAL. dec is stale by this
            // cycle so use mull_rdlo_q (snapshotted at S_EXEC). The
            // multiplier sees both accumulator halves this cycle
            // (acc_lo_q + current rf_ra_data as acc_hi via the latched
            // operand inputs) so mul_result_lo is the final value.
            rf_write_addr = mull_rdlo_q;
            rf_write_data = mul_result_lo;
            rf_write_en   = 1'b1;
        end else if (mull_writes_lo) begin
            // §9d: RdLo (= dec.rd) := result_lo, in the same S_EXEC cycle.
            rf_write_addr = dec.rd;
            rf_write_data = mul_result_lo;
            rf_write_en   = 1'b1;
        end else if (mul_writes_dest) begin
            rf_write_addr = dec.rn;
            rf_write_data = mul_result_lo;
            rf_write_en   = 1'b1;
        end else if (mrs_fires) begin
            rf_write_addr = dec.rd;
            rf_write_data = dec.psr_use_spsr ? 32'(spsr_value) : 32'(cpsr);
            rf_write_en   = 1'b1;
        end else if (cp14_mrc_fires) begin
            // Exact c0/c1/c2 CP14 reads share normal MRC destination
            // semantics. Rd=r15 updates NZCV below rather than the PC.
            rf_write_addr = dec.rd;
            rf_write_data = cp14_mrc_value;
            rf_write_en   = (dec.rd != 4'd15);
        end else if (state_q == S_DP_SHIFT) begin
            // §18 DP shift-by-reg: commit deferred from S_EXEC. Uses
            // latched values since dec.* and alu_result have moved on
            // by this cycle.
            rf_write_addr = dp_shift_rd_q;
            rf_write_data = dp_shift_result_q;
            rf_write_en   = dp_shift_writes_q;
        end else begin
            rf_write_addr = dec.rd;
            rf_write_data = alu_result;
            rf_write_en   = exec_writes_rf;
        end
    end

    wire        flags_from_mul       = mul_writes_flags;
    wire        flags_from_dp_shift  = (state_q == S_DP_SHIFT) && dp_shift_flags_we_q;
    wire        flags_from_cp_mrc    = cp_mrc_wb_state
                                     && (cp_mrc_rd_q == 4'd15);
    wire        flags_from_cp14_mrc  = cp14_mrc_fires && (dec.rd == 4'd15);
    wire [3:0]  flags_value          = flags_from_mul
                                       ? {mul_n_out, mul_z_out, cpsr.c, cpsr.v}
                                       : alu_flags_merged;
    assign cpsr_write_en   = writes_flags || msr_to_cpsr
                           || flags_from_dp_shift || flags_from_cp_mrc
                           || flags_from_cp14_mrc;
    assign cpsr_write_data = msr_to_cpsr      ? sh_result
                           : flags_from_dp_shift ? {dp_shift_flags_q, 28'h0}
                           : flags_from_cp_mrc   ? {cp_mrc_data_q[31:28], 28'h0}
                           : flags_from_cp14_mrc ? {cp14_mrc_value[31:28], 28'h0}
                                                 : {flags_value, 28'h0};
    assign cpsr_write_mask = msr_to_cpsr ? dec.msr_field_mask : 4'b1000;

    // =====================================================================
    // Flush triggers (Phase 4)
    // =====================================================================
    //
    // Any PC write — DP-to-Rd=15, B/BL, BX, exception, LDR-to-PC,
    // LDM-with-PC — fires `flush` for one cycle. F clears in-flight and
    // fd_q; D clears de_q; fetch_pc_q reloads from `flush_target_pc`.
    //
    // The chosen target depends on which source wrote PC: pc_target_exec
    // (S_EXEC), load_value (S_DDATA with Rd=PC), or RDATA (S_BLOCK_DATA
    // with current reg = r15).

    wire ddata_writes_pc = (state_q == S_LOAD_WB) && (ls_rd_q == 4'd15) && !data_abort_q;
    wire block_writes_pc = (state_q == S_BLOCK_DATA) && block_load_q
                        && (block_curr_reg_q == 4'd15)
                        && !data_abort_q && !data_abort_now;

    assign flush           = writes_pc_exec || ddata_writes_pc || block_writes_pc;

    // §18 branch fast-path: branches/BX/DP-to-PC trigger their flush during
    // an S_EXEC cycle, where the bus is otherwise wasted on a prefetch that
    // will be discarded. Instead, drive ADDR = flush_target_pc with TRANS=N
    // on that same cycle and capture it as the inflight prefetch — closes a
    // 1-cycle bubble and brings these to TRM 2S+1N=3 cycles total. Excluded:
    // exception entry (any_exc_fires) keeps the existing timing because the
    // TRM entry sequence saves PC/SPSR + drives the vector, with cycle
    // counts that don't trivially align with a single-cycle fast-flush.
    // Also excluded: ddata_writes_pc (LDR Rd=PC, TRM 2S+2N+1I, the loaded
    // value isn't bus-stable in time) and block_writes_pc (LDM with PC).
    wire early_flush_fetch = writes_pc_exec && !any_exc_fires;
    wire early_flush_t = bx_writes_pc ? rf_rb_data[0]
                       : ((dp_writes_pc && dec.s_bit && spsr_valid)
                          ? spsr_value.t : cpsr.t);
    assign flush_target_pc = ddata_writes_pc ? load_value_q
                           : block_writes_pc ? RDATA
                                             : pc_target_exec;

    // =====================================================================
    // E-stage sequential state
    // =====================================================================
    always_ff @(posedge CLK) begin
        if (!nRESET) begin
                state_q             <= S_EXEC;
                ls_data_addr_q      <= 32'h0;
                ls_store_data_q     <= 32'h0;
                ls_rd_q             <= 4'h0;
                ls_byte_q           <= 1'b0;
                ls_halfword_q       <= 1'b0;
                ls_signed_q         <= 1'b0;
                ls_load_q           <= 1'b0;
                ls_addr_lo_q        <= 2'h0;
                memory_instr_pc_q   <= 32'h0;
                block_remaining_q   <= 16'h0;
                block_curr_addr_q   <= 32'h0;
                block_curr_reg_q    <= 4'h0;
                block_load_q        <= 1'b0;
                block_first_beat_q  <= 1'b0;
                block_user_mode_q      <= 1'b0;
                block_has_pc_q         <= 1'b0;
                block_writeback_q      <= 1'b0;
                block_writeback_addr_q <= 32'h0;
                block_base_value_q     <= 32'h0;
                block_rn_q             <= 4'h0;
                swp_addr_q          <= 32'h0;
                swp_store_q         <= 32'h0;
                swp_loaded_q        <= 32'h0;
                swp_rd_q            <= 4'h0;
                swp_byte_q          <= 1'b0;
                swp_addr_lo_q       <= 2'h0;
                mull_rdhi_q              <= 4'h0;
                mull_result_hi_q         <= 32'h0;
                mul_busy_remaining_q     <= 3'h0;
                mull_active_q            <= 1'b0;
                acc_lo_q                 <= 32'h0;
                mull_accumulate_active_q <= 1'b0;
                mull_rdlo_q              <= 4'h0;
                mull_op_a_q              <= 32'h0;
                mull_op_b_q              <= 32'h0;
                mull_signed_q            <= 1'b0;
                mull_s_q                 <= 1'b0;
                dp_shift_rd_q            <= 4'h0;
                dp_shift_result_q        <= 32'h0;
                dp_shift_flags_q         <= 4'h0;
                dp_shift_writes_q        <= 1'b0;
                dp_shift_flags_we_q      <= 1'b0;
                dp_shift_writes_pc_q     <= 1'b0;
                load_value_q             <= 32'h0;
                cp_instr_pc_q            <= 32'h0;
                cp_mcr_data_q            <= 32'h0;
                cp_mrc_data_q            <= 32'h0;
                cp_mrc_rd_q              <= 4'h0;
                cp_wait_is_mcr_q         <= 1'b0;
                cp_wait_is_mrc_q         <= 1'b0;
                cp_wait_is_ldc_q         <= 1'b0;
                cp_wait_is_stc_q         <= 1'b0;
                cp_ls_addr_q             <= 32'h0;
                cp_ls_writeback_value_q  <= 32'h0;
                cp_ls_rn_q               <= 4'h0;
                cp_ls_writeback_q        <= 1'b0;
                cp_ls_first_q            <= 1'b0;
                cp_ls_response_q         <= 1'b0;
        end else if (CLKEN) begin
                state_q <= state_next;
                // Each LDC/STC address phase returns one enabled cycle
                // later. This stays asserted across back-to-back words
                // and into the terminal response/cleanup cycle.
                cp_ls_response_q <= cp_ls_data_state;

                // Snapshot an external CP request before the normal
                // pipeline advances at the end of S_EXEC. Busy requests
                // retain the same identity throughout S_CP_WAIT.
                if (state_q == S_EXEC
                    && (external_cp_busy || external_cp_ready)) begin
                    cp_instr_pc_q    <= de_q.pc;
                    // MCR names r15 as a source, unlike an ordinary
                    // register read: the transferred value is this
                    // instruction's address plus 12.
                    cp_mcr_data_q    <= (dec.rd == 4'd15)
                                      ? (de_q.pc + 32'd12)
                                      : rf_rc_data;
                    cp_mrc_rd_q      <= dec.rd;
                    cp_wait_is_mcr_q <= external_cp_is_mcr;
                    cp_wait_is_mrc_q <= external_cp_is_mrc;
                    cp_wait_is_ldc_q <= external_cp_is_ldc;
                    cp_wait_is_stc_q <= external_cp_is_stc;
                    if (external_cp_is_ldc || external_cp_is_stc) begin
                        cp_ls_addr_q            <= cp_ls_start_addr;
                        cp_ls_writeback_value_q <= cp_ls_adjusted_base;
                        cp_ls_rn_q              <= dec.rn;
                        cp_ls_writeback_q       <= de_q.instr[21];
                        cp_ls_first_q           <= 1'b1;
                    end
                end

                if (state_q == S_CP_MRC_DATA)
                    cp_mrc_data_q <= RDATA;

                if (cp_ls_data_state) begin
                    cp_ls_addr_q  <= cp_ls_addr_q + 32'd4;
                    cp_ls_first_q <= 1'b0;
                end

                // L/S micro-op snapshot at end of S_EXEC.
                if (state_q == S_EXEC && ls_take_data_cycle) begin
                    ls_data_addr_q  <= ls_data_addr_used;
                    ls_store_data_q <= rf_rc_data;
                    ls_rd_q         <= dec.rd;
                    ls_byte_q       <= ls_effective_byte;
                    ls_halfword_q   <= ls_effective_halfword;
                    ls_signed_q     <= ls_effective_signed;
                    ls_load_q       <= dec.ls_load;
                    ls_addr_lo_q    <= ls_data_addr_used[1:0];
                end

                // Preserve the instruction identity across every memory
                // substate for exact Data Abort LR generation.
                if (state_q == S_EXEC
                    && (ls_take_data_cycle || block_take_cycle
                        || swp_take_cycle || external_cp_is_ldc
                        || external_cp_is_stc)) begin
                    memory_instr_pc_q <= de_q.pc;
                end

                // LDM/STM snapshot + iteration start. The first beat's
                // addr-class is driven by S_EXEC's bus mux (using
                // block_start_addr directly); at posedge to S_BLOCK_DATA
                // we record the second beat's addr in block_curr_addr_q,
                // which the bus mux drives in cycle 1 of S_BLOCK_DATA
                // for beat 2 (and so on iteratively).
                if (state_q == S_EXEC && block_take_cycle) begin
                    block_remaining_q      <= dec.block_reg_list;
                    block_curr_addr_q      <= block_start_addr + 32'd4;   // next addr
                    block_curr_reg_q       <= lowest_set_idx(dec.block_reg_list);
                    block_load_q           <= dec.block_load;
                    block_first_beat_q     <= 1'b1;
                    block_user_mode_q      <= dec.block_user_mode;
                    block_has_pc_q         <= dec.block_reg_list[15];
                    block_writeback_q      <= dec.block_writeback;
                    block_writeback_addr_q <= block_writeback_addr;
                    block_base_value_q     <= rf_ra_data;
                    block_rn_q             <= dec.rn;
                end

                if (state_q == S_BLOCK_DATA) begin
                    block_remaining_q <= block_after_curr;
                    if (block_has_more) begin
                        block_curr_reg_q   <= lowest_set_idx(block_after_curr);
                        block_curr_addr_q  <= block_curr_addr_q + 32'd4;
                        block_first_beat_q <= 1'b0;
                    end
                end

                // SWP snapshot.
                if (state_q == S_EXEC && swp_take_cycle) begin
                    swp_addr_q    <= rf_ra_data;
                    swp_store_q   <= rf_rb_data;
                    swp_rd_q      <= dec.rd;
                    swp_byte_q    <= dec.ls_byte;
                    swp_addr_lo_q <= rf_ra_data[1:0];
                end

                if (state_q == S_SWP_RDATA && !data_abort_now) begin
                    swp_loaded_q <= RDATA;
                end

                // §9d: snapshot RdHi register address and upper 32 bits of
                // the product at end of S_EXEC for UMULL/SMULL. For UMLAL/
                // SMLAL the upper 32 bits aren't final until S_MULL_ACC,
                // so the result_hi latch happens there instead.
                if (state_q == S_EXEC && mull_take_cycle) begin
                    mull_rdhi_q      <= dec.rn;
                    mull_result_hi_q <= mul_result_hi;
                end

                // §9c UMLAL/SMLAL: snapshot everything S_MULL_ACC will
                // need from de_q.dec at S_EXEC end (D advances de_q to
                // the next instruction at the same posedge, so live
                // references to dec.* go stale in S_MULL_ACC).
                if (state_q == S_EXEC && mull_accum_take_cycle) begin
                    acc_lo_q                 <= rf_ra_data;
                    mull_rdhi_q              <= dec.rn;
                    mull_rdlo_q              <= dec.rd;
                    mull_op_a_q              <= rf_rb_data;
                    mull_op_b_q              <= rf_rc_data;
                    mull_signed_q            <= dec.mul_signed;
                    mull_s_q                 <= dec.s_bit;
                    mull_accumulate_active_q <= 1'b1;
                    mull_active_q            <= 1'b1;
                end

                // §9c: at S_MULL_ACC end, both accumulator halves are
                // valid (acc_lo_q latched in S_EXEC; acc_hi from current
                // port-A read). Latch result_hi for commit in S_MULL_HI,
                // plus the m parameter for S_MUL_BUSY countdown.
                if (state_q == S_MULL_ACC) begin
                    mull_result_hi_q     <= mul_result_hi;
                    mul_busy_remaining_q <= mul_cycle_count;
                end

                // §18: at S_EXEC end for MUL/MLA/UMULL/SMULL, latch the m
                // parameter and whether this is a long form so the FSM
                // knows where to land after S_MUL_BUSY ends. MLA gets +1
                // cycle vs MUL (TRM Table 7-19: 1S+(m+1)I) because the
                // accumulator addition takes an extra internal cycle.
                // UMULL/SMULL already get +1 from S_MULL_HI; UMLAL/SMLAL
                // don't reach this branch (they go through S_MULL_ACC).
                if (state_q == S_EXEC && mul_take_busy) begin
                    mul_busy_remaining_q <= dec.mul_accumulate
                                          ? (mul_cycle_count + 3'd1)
                                          : mul_cycle_count;
                    mull_active_q        <= instr_class_is_mull;
                end
                // Countdown each S_MUL_BUSY cycle.
                if (state_q == S_MUL_BUSY && mul_busy_remaining_q != 3'h0) begin
                    mul_busy_remaining_q <= mul_busy_remaining_q - 3'd1;
                end
                // Clear accumulate-active when re-entering S_EXEC after
                // a MULL completes (so a subsequent MUL/MLA doesn't see
                // the stale mull_accumulate_active_q).
                if (state_q == S_MULL_HI ||
                    (state_q == S_MUL_BUSY && state_next == S_EXEC)) begin
                    mull_accumulate_active_q <= 1'b0;
                end

                // §18 DP shift-by-reg: snapshot the result + control at
                // S_EXEC end. dec.* will go stale once de_q advances at
                // the same posedge that exits S_EXEC.
                if (state_q == S_EXEC && dp_shift_take_cycle) begin
                    dp_shift_rd_q        <= dec.rd;
                    dp_shift_result_q    <= alu_result;
                    dp_shift_flags_q     <= alu_flags_merged;
                    dp_shift_writes_q    <= dp_writes_dest;
                    dp_shift_flags_we_q  <= passes_cond && instr_is_dp && dec.s_bit;
                    dp_shift_writes_pc_q <= dp_writes_pc;
                end

                // §18 LDR/LDRB: latch the formatted load value at S_DDATA
                // end so S_LOAD_WB can commit it (RDATA goes stale by
                // then since the bus is driving the next fetch).
                if (state_q == S_DDATA && ls_load_q) begin
                    load_value_q <= load_value;
                end
        end
    end

    // =====================================================================
    // Bus drive
    // =====================================================================
    wire is_priv = (cpsr.m != 5'(MODE_USER));

    wire [31:0] store_byte_data = {4{ls_store_data_q[7:0]}};
    wire [31:0] store_hw_data   = {2{ls_store_data_q[15:0]}};
    wire [31:0] store_wdata     = ls_halfword_q ? store_hw_data
                                : ls_byte_q    ? store_byte_data
                                                : ls_store_data_q;

    wire [31:0] swp_wdata = swp_byte_q ? {4{swp_store_q[7:0]}} : swp_store_q;

    // Helper: fetch size based on T-bit. Used in many places below.
    wire [1:0] fetch_size_w = cpsr.t ? 2'(SIZE_HALFWORD) : 2'(SIZE_WORD);

    // §3.3 / BUS-005: classify a fetch from the address-class phase that
    // actually preceded it. A sequential transfer either continues an
    // active same-control word/halfword burst at +4/+2, or commits a merged
    // I-S cycle at the same address. Everything else starts with N.
    logic        bus_history_valid_q;
    logic [31:0] bus_history_addr_q;
    logic        bus_history_write_q;
    logic [1:0]  bus_history_size_q;
    logic [1:0]  bus_history_prot_q;
    logic        bus_history_lock_q;
    logic [1:0]  bus_history_trans_q;

    wire bus_history_active_q = (bus_history_trans_q == 2'(TRANS_N))
                             || (bus_history_trans_q == 2'(TRANS_S));
    wire fetch_controls_match = !bus_history_write_q
                             && (bus_history_size_q == fetch_size_w)
                             && (bus_history_prot_q == {is_priv, 1'b0})
                             && (bus_history_lock_q == LOCK_FREE);
    wire [31:0] fetch_history_step = (fetch_size_w == 2'(SIZE_HALFWORD))
                                   ? 32'd2 : 32'd4;
    wire fetch_continues_burst = bus_history_valid_q
                              && bus_history_active_q
                              && fetch_controls_match
                              && (fetch_pc_q
                                  == (bus_history_addr_q + fetch_history_step));
    wire fetch_commits_merged_is = bus_history_valid_q
                                && (bus_history_trans_q == 2'(TRANS_I))
                                && fetch_controls_match
                                && (fetch_pc_q == bus_history_addr_q);
    wire [1:0] fetch_trans_w = (fetch_continues_burst
                              || fetch_commits_merged_is)
                             ? 2'(TRANS_S) : 2'(TRANS_N);

    // Capture only enabled address-class phases. A redirect without an
    // overlapped target fetch invalidates the old advertised address even
    // if it happens to equal the destination. The early branch/BX path
    // drives an explicit N target and is therefore valid new history.
    always_ff @(posedge CLK) begin
        if (!nRESET) begin
            bus_history_valid_q <= 1'b0;
            bus_history_addr_q  <= 32'h0;
            bus_history_write_q <= WRITE_READ;
            bus_history_size_q  <= 2'(SIZE_WORD);
            bus_history_prot_q  <= 2'(PROT_OPC_PRIV);
            bus_history_lock_q  <= LOCK_FREE;
            bus_history_trans_q <= 2'(TRANS_I);
        end else if (CLKEN) begin
            if (flush && !early_flush_fetch) begin
                bus_history_valid_q <= 1'b0;
            end else begin
                bus_history_valid_q <= 1'b1;
                bus_history_addr_q  <= ADDR;
                bus_history_write_q <= WRITE;
                bus_history_size_q  <= SIZE;
                bus_history_prot_q  <= PROT;
                bus_history_lock_q  <= LOCK;
                bus_history_trans_q <= TRANS;
            end
        end
    end

    always_comb begin
        // Default: idle bus with fetch_pc_q on ADDR (cosmetic).
        ADDR  = fetch_pc_q;
        WRITE = WRITE_READ;
        SIZE  = fetch_size_w;
        PROT  = {is_priv, 1'b0};
        LOCK  = LOCK_FREE;
        TRANS = 2'(TRANS_I);
        WDATA = 32'h0;

        unique case (state_q)
            S_EXEC: begin
                if (ls_take_data_cycle) begin
                    // §18 overlap: drive the data addr-class one cycle
                    // earlier than the non-pipelined model used to —
                    // memory captures it at posedge entering S_DDATA, and
                    // the data appears on RDATA during S_DDATA.
                    ADDR  = ls_data_addr_used;
                    TRANS = 2'(TRANS_N);
                    WRITE = dec.ls_load ? WRITE_READ : WRITE_WRITE;
                    SIZE  = (dec.instr_class == INSTR_LDRH_STRH)
                              ? (dec.hs_halfword ? 2'(SIZE_HALFWORD) : 2'(SIZE_BYTE))
                              : (dec.ls_byte ? 2'(SIZE_BYTE) : 2'(SIZE_WORD));
                    PROT  = {is_priv && !ls_is_translated, 1'b1};
                end else if (block_take_cycle) begin
                    ADDR  = block_start_addr;
                    TRANS = 2'(TRANS_N);
                    WRITE = dec.block_load ? WRITE_READ : WRITE_WRITE;
                    SIZE  = 2'(SIZE_WORD);
                    PROT  = {is_priv, 1'b1};
                end else if (swp_take_cycle) begin
                    ADDR  = rf_ra_data;
                    TRANS = 2'(TRANS_N);
                    WRITE = WRITE_READ;
                    SIZE  = dec.ls_byte ? 2'(SIZE_BYTE) : 2'(SIZE_WORD);
                    PROT  = {is_priv, 1'b1};
                    LOCK  = LOCK_LOCKED;
                end else if (external_cp_request) begin
                    // The first external-CP handshake occupies the normal
                    // pc+8 prefetch slot. Register transfers advertise C;
                    // ready CDP/LDC/STC operations advertise their N cycle.
                    ADDR = de_q.pc + 32'd8;
                    SIZE = 2'(SIZE_WORD);
                    PROT = {is_priv, 1'b0};
                    if (external_cp_ready) begin
                        TRANS = (external_cp_is_mcr || external_cp_is_mrc)
                              ? 2'(TRANS_C) : 2'(TRANS_N);
                    end else begin
                        TRANS = 2'(TRANS_I);
                    end
                end else begin
                    // Standard fetch.
                    ADDR  = fetch_pc_q;
                    TRANS = (flush || !issue_fetch) ? 2'(TRANS_I) : fetch_trans_w;
                    SIZE  = fetch_size_w;
                    PROT  = {is_priv, 1'b0};
                end
            end
            S_DDATA: begin
                // RDATA carries load data this cycle (latched at end of
                // S_EXEC). Address-class drives the next instruction
                // fetch — §18 bus overlap saves the cycle the non-
                // pipelined model used to spend re-fetching.
                ADDR  = fetch_pc_q;
                TRANS = (flush || !issue_fetch) ? 2'(TRANS_I) : fetch_trans_w;
                WRITE = WRITE_READ;
                SIZE  = fetch_size_w;
                PROT  = {is_priv, 1'b0};
                WDATA = ls_load_q ? 32'h0 : store_wdata;
            end
            S_BLOCK_DATA: begin
                if (block_has_more) begin
                    // Drive the NEXT beat's addr-class. Data of the
                    // current beat is on RDATA/WDATA via latched bus
                    // signals captured at the previous posedge.
                    ADDR  = block_curr_addr_q;
                    TRANS = 2'(TRANS_S);
                    WRITE = block_load_q ? WRITE_READ : WRITE_WRITE;
                    SIZE  = 2'(SIZE_WORD);
                    PROT  = {is_priv, 1'b1};
                end else begin
                    // Last beat — overlap with next instr fetch.
                    ADDR  = fetch_pc_q;
                    TRANS = (flush || !issue_fetch) ? 2'(TRANS_I) : fetch_trans_w;
                    WRITE = WRITE_READ;
                    SIZE  = fetch_size_w;
                    PROT  = {is_priv, 1'b0};
                end
                // ARM ARM A4.1.97: when an STM writeback base is the
                // lowest register in the list, store its original value,
                // even though r4p3's Base Updated abort model requires
                // architectural writeback before any response can abort.
                // Other base-in-list positions are architecturally
                // UNPREDICTABLE and retain the deterministic updated-base
                // behavior.
                WDATA = block_load_q ? 32'h0
                      : (block_first_beat_q
                         && block_writeback_q
                         && (block_curr_reg_q == block_rn_q))
                        ? block_base_value_q : rf_rc_data;
            end
            S_SWP_RDATA: begin
                if (data_abort_now) begin
                    // Cancel the pipelined write address in the same
                    // enabled cycle that returns the failed read. The
                    // address value is don't-care for I, but keeping the
                    // fetch address makes the raw-bus trace deterministic.
                    ADDR  = fetch_pc_q;
                    TRANS = 2'(TRANS_I);
                    WRITE = WRITE_READ;
                    SIZE  = fetch_size_w;
                    PROT  = {is_priv, 1'b0};
                    LOCK  = LOCK_FREE;
                end else begin
                    // Drive the SWP write addr-class so the memory commits
                    // the write at posedge entering S_SWP_WDATA. LOCK stays
                    // asserted across the locked read-write window.
                    ADDR  = swp_addr_q;
                    TRANS = 2'(TRANS_N);
                    WRITE = WRITE_WRITE;
                    SIZE  = swp_byte_q ? 2'(SIZE_BYTE) : 2'(SIZE_WORD);
                    PROT  = {is_priv, 1'b1};
                    LOCK  = LOCK_LOCKED;
                end
            end
            S_SWP_WDATA: begin
                // WDATA drives the write; memory commits at next posedge.
                // Addr-class overlaps with next instr fetch — LOCK
                // drops since the locked sequence has ended.
                ADDR  = fetch_pc_q;
                TRANS = (flush || !issue_fetch) ? 2'(TRANS_I) : fetch_trans_w;
                WRITE = WRITE_READ;
                SIZE  = fetch_size_w;
                PROT  = {is_priv, 1'b0};
                LOCK  = LOCK_FREE;
                WDATA = swp_wdata;
            end
            S_MULL_HI: begin
                // No bus access for the multiply — drive the next fetch.
                ADDR  = fetch_pc_q;
                TRANS = (flush || !issue_fetch) ? 2'(TRANS_I) : fetch_trans_w;
                SIZE  = fetch_size_w;
                PROT  = {is_priv, 1'b0};
            end
            S_MUL_BUSY: begin
                // Only the last busy cycle (state_next == S_EXEC) drives
                // the next fetch — earlier cycles let the bus stay idle.
                if (state_next == S_EXEC) begin
                    ADDR  = fetch_pc_q;
                    TRANS = (flush || !issue_fetch) ? 2'(TRANS_I) : fetch_trans_w;
                    SIZE  = fetch_size_w;
                    PROT  = {is_priv, 1'b0};
                end
            end
            S_MULL_ACC: begin
                // Idle bus — no bus access during the UMLAL/SMLAL
                // accumulator-read cycle.
            end
            S_BLOCK_WB: begin
                // §17: LDM/STM Rn writeback cycle. The actual writeback
                // happens via the regfile mux below; bus drives the next
                // instr fetch addr-class (overlap, same pattern as
                // S_DDATA-last etc.).
                ADDR  = fetch_pc_q;
                TRANS = (flush || !issue_fetch) ? 2'(TRANS_I) : fetch_trans_w;
                SIZE  = fetch_size_w;
                PROT  = {is_priv, 1'b0};
            end
            S_DP_SHIFT: begin
                // §18: DP shift-by-reg I cycle. No data access; bus
                // drives the next instr fetch (overlap).
                ADDR  = fetch_pc_q;
                TRANS = (flush || !issue_fetch) ? 2'(TRANS_I) : fetch_trans_w;
                SIZE  = fetch_size_w;
                PROT  = {is_priv, 1'b0};
            end
            S_LOAD_WB: begin
                // §18: LDR/LDRB writeback I cycle. Bus drives next instr
                // fetch — addr-class drive in S_DDATA already started
                // this fetch, so S_LOAD_WB just continues it.
                ADDR  = fetch_pc_q;
                TRANS = (flush || !issue_fetch) ? 2'(TRANS_I) : fetch_trans_w;
                SIZE  = fetch_size_w;
                PROT  = {is_priv, 1'b0};
            end
            S_SWP_WB: begin
                // §18: SWP Rd writeback I cycle (TRM 1S+2N+1I). Bus
                // continues the next-instr fetch started in S_SWP_WDATA.
                ADDR  = fetch_pc_q;
                TRANS = (flush || !issue_fetch) ? 2'(TRANS_I) : fetch_trans_w;
                SIZE  = fetch_size_w;
                PROT  = {is_priv, 1'b0};
            end
            S_CP_WAIT: begin
                ADDR = cp_instr_pc_q + 32'd8;
                SIZE = 2'(SIZE_WORD);
                PROT = {is_priv, 1'b1};
                if (cp_wait_ready) begin
                    TRANS = (cp_wait_is_mcr_q || cp_wait_is_mrc_q)
                          ? 2'(TRANS_C) : 2'(TRANS_N);
                end
            end
            S_CP_MCR_DATA: begin
                if (cp_wait_is_stc_q) begin
                    // The external coprocessor supplies store data to the
                    // system write-data mux. Low/low requests another word;
                    // high/high marks this N cycle as the final transfer.
                    ADDR  = cp_ls_addr_q;
                    WRITE = WRITE_WRITE;
                    SIZE  = 2'(SIZE_WORD);
                    PROT  = {is_priv, 1'b1};
                    TRANS = cp_ls_final ? 2'(TRANS_N) : 2'(TRANS_S);
                end else begin
                    // Register-transfer data is routed to the coprocessor
                    // while the address class begins the next opcode fetch.
                    ADDR  = fetch_pc_q;
                    WRITE = WRITE_WRITE;
                    SIZE  = 2'(SIZE_WORD);
                    PROT  = {is_priv, 1'b1};
                    TRANS = 2'(TRANS_N);
                    WDATA = cp_mcr_data_q;
                end
            end
            S_CP_MRC_DATA: begin
                if (cp_wait_is_ldc_q) begin
                    // Memory supplies each word directly to the external
                    // coprocessor over RDATA.
                    ADDR  = cp_ls_addr_q;
                    WRITE = WRITE_READ;
                    SIZE  = 2'(SIZE_WORD);
                    PROT  = {is_priv, 1'b1};
                    TRANS = cp_ls_final ? 2'(TRANS_N) : 2'(TRANS_S);
                end else begin
                    // Coprocessor drives RDATA during this internal data
                    // phase of an MRC.
                    ADDR  = fetch_pc_q;
                    WRITE = WRITE_READ;
                    SIZE  = 2'(SIZE_WORD);
                    PROT  = {is_priv, 1'b1};
                    TRANS = 2'(TRANS_I);
                end
            end
            S_CP_MRC_WB: begin
                if (cp_ls_cleanup_state) begin
                    // The final LDC/STC response is visible here. Start
                    // the next opcode fetch only if it did not abort.
                    ADDR  = fetch_pc_q;
                    WRITE = WRITE_READ;
                    SIZE  = fetch_size_w;
                    PROT  = {is_priv, 1'b0};
                    TRANS = (flush || !issue_fetch)
                          ? 2'(TRANS_I) : fetch_trans_w;
                end else begin
                    // Write the latched MRC word to Rd while completing
                    // the merged following fetch.
                    ADDR  = fetch_pc_q;
                    WRITE = WRITE_READ;
                    SIZE  = 2'(SIZE_WORD);
                    PROT  = {is_priv, 1'b1};
                    TRANS = 2'(TRANS_S);
                end
            end
            default: ;
        endcase

        // §18 branch fast-path: when a branch/BX/DP-to-PC fires its flush
        // in a prefetch-driving substate (S_EXEC or S_DP_SHIFT), override
        // the wasted prefetch with a non-sequential fetch of the target.
        // Memory captures at this posedge → RDATA next cycle, saving the
        // 1-cycle bubble that would otherwise re-issue from fetch_pc_q.
        // Excluded for any_exc_fires and for ddata/block PC writes — their
        // bus sequences are different (see comment at flush definition).
        if (early_flush_fetch) begin
            ADDR  = flush_target_pc;
            TRANS = 2'(TRANS_N);
            SIZE  = early_flush_t ? 2'(SIZE_HALFWORD) : 2'(SIZE_WORD);
            PROT  = {is_priv, 1'b0};
            WRITE = WRITE_READ;
        end

        // Debug halt isolates the core from the system. TRM §5.3.4
        // requires internal cycles throughout halt mode; using benign
        // read/opcode controls also keeps all address-timed outputs
        // deterministic for FPGA integrations.
        if (dbg_halted) begin
            ADDR  = fetch_pc_q;
            WRITE = WRITE_READ;
            SIZE  = fetch_size_w;
            PROT  = {is_priv, 1'b0};
            LOCK  = LOCK_FREE;
            TRANS = 2'(TRANS_I);
            WDATA = 32'h0000_0000;
        end

        // Reset is an idle bus cycle regardless of stale pre-reset state
        // or CLKEN. The first real request is generated after release.
        if (!nRESET) begin
            ADDR  = 32'h0000_0000;
            WRITE = WRITE_READ;
            SIZE  = 2'(SIZE_WORD);
            PROT  = 2'(PROT_OPC_PRIV);
            LOCK  = LOCK_FREE;
            TRANS = 2'(TRANS_I);
            WDATA = 32'h0000_0000;
        end
    end

    assign DMORE = nRESET && !dbg_halted && block_active && block_has_more;

    // =====================================================================
    // §19: Coprocessor pipeline-following signals
    // =====================================================================
    //
    // Per TRM §4 & §30.23.2 these mirror the bus cycle types so an external
    // coprocessor can shadow the ARM pipeline state machine. CPnI is driven
    // separately to indicate that the current decode is a coprocessor op.
    //
    //   CPnMREQ : active LOW when this cycle is a memory access (TRANS=N|S)
    //   CPSEQ   : TRANS[0], HIGH for sequential and C cycles
    //   CPnTRANS: LOW in User mode, HIGH in privileged modes
    //   CPnOPC  : active LOW when the access is an opcode fetch
    //   CPTBIT  : current CPSR.T (state of the executing instruction stream)
    //   CPnI    : active LOW when the executing instruction is a CP op
    //              (CDP/MCR/MRC/LDC/STC) — coprocessor inspects CPA/CPB to
    //              accept or refuse.

    wire trans_is_active = (TRANS == 2'(TRANS_N)) || (TRANS == 2'(TRANS_S));
    assign CPnMREQ = !trans_is_active;
    assign CPSEQ   =  TRANS[0];
    assign CPnTRANS = is_priv;
    assign CPnOPC   =  PROT[PROT_BIT_DATA];   // mirror — opcode fetch → CPnOPC=0
    assign CPTBIT   = cpsr.t;
    assign CPnI     = dbg_halted || !((passes_cond && instr_is_cp)
                      || ((state_q == S_CP_WAIT)
                          && !cp_wait_abandon_pending));

    // =====================================================================
    // §24: ETM-facing pipeline-state outputs
    // =====================================================================
    //
    // DBGINSTRVALID: HIGH when E has a valid decoded instruction this cycle
    //                (= executing). Bubble cycles → LOW.
    // DBGnEXEC     : LOW when the instruction is actually executing
    //                (passes_cond gate). HIGH for unexecuted instructions
    //                (condition failed). See TRM Table 7-23 — even
    //                cond-fail instructions consume cycles but signal
    //                DBGnEXEC HIGH so ETM can distinguish.
    assign DBGINSTRVALID = CLKEN && executing;
    assign DBGnEXEC      = !(CLKEN && passes_cond);


    // ---- TB / debug observability ----
    // PC of the most recently committed instruction. Equivalent in spirit
    // to the non-pipelined core's `pc_q`, but updated only on cycles where
    // an instruction actually completes its execute phase (state_q==S_EXEC
    // with valid de_q). Lets the TB compare against absolute addresses
    // without worrying about which pipeline stage to look at.
    /* verilator lint_off UNUSEDSIGNAL */
    logic [31:0] pc_q;
    /* verilator lint_on UNUSEDSIGNAL */
    always_ff @(posedge CLK) begin
        if (!nRESET)
            pc_q <= 32'h0;
        else if (dbg_pc_write)
            pc_q <= dbg_pc_aligned;
        else if (CLKEN) begin
            if (state_q == S_EXEC && de_q.valid)
                pc_q <= de_q.pc;
        end
    end

    // ---- Unused-signal drain ----
    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0,
        CPB,                              // §19: busy-wait wiring is later
        spsr_valid,
        arm_is_dataproc_w, thumb_is_dataproc_w,
        rf_pc_written,
        alu_flag_we,
        cpsr[27:6],
        ls_data_addr_q,                   // §18 overlap: data addr is now
                                          //   driven from S_EXEC directly;
                                          //   the latched value is only used
                                          //   for ls_addr_lo_q lookup.
        block_first_beat_q,               // §18 overlap: first-beat distinction
                                          //   no longer needed in bus mux.
        mull_accumulate_active_q,         // §9c: tracked but currently only
                                          //   for symmetry (state_q checks do
                                          //   the actual dispatch).
        ls_data_addr_calc[31:12],
        ls_store_data_q[31:8],
        mul_flag_we,
        dec.dp_imm_value,
        dec.hs_signed, dec.hs_halfword, dec.hs_use_imm, dec.hs_imm_offset,
        dec.psr_use_spsr, dec.msr_field_mask, dec.msr_use_imm,
        dec.swi_comment, dec.cp_num
    };
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
