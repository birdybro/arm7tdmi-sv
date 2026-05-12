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
    output logic        DBGINSTRVALID
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
        logic        valid;
    } fd_t;

    typedef struct packed {
        decoded_t    dec;
        logic [31:0] instr;   // raw instruction bits — needed for DP-imm raw imm8
        logic [31:0] pc;       // PC of this instruction
        logic        thumb;    // T-bit when fetched
        logic        pabort;   // §17: carried from fd_q
        logic        valid;
    } de_t;

    // =====================================================================
    // E-stage substate FSM (memory + lock holds)
    // =====================================================================
    //
    //   S_EXEC       : one-cycle execute. Consumes de_q (if valid). Single-
    //                  cycle DP/branch/etc. complete here. L/S, LDM/STM,
    //                  SWP enter their substate sequences at end of S_EXEC.
    //   S_DADDR/...  : same shape as the non-pipelined core. Bus is owned
    //                  by E during these states; F prefetch is stalled.

    typedef enum logic [3:0] {
        S_EXEC       = 4'd0,
        S_DADDR      = 4'd1,
        S_DDATA      = 4'd2,
        S_BLOCK_ADDR = 4'd3,
        S_BLOCK_DATA = 4'd4,
        S_SWP_RADDR  = 4'd5,
        S_SWP_RDATA  = 4'd6,
        S_SWP_WADDR  = 4'd7,
        S_SWP_WDATA  = 4'd8,
        S_MULL_HI    = 4'd9     // §9d: 64-bit multiply RdHi writeback cycle
    } state_e;

    state_e state_q;

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

    // F is allowed to own the bus only when E isn't doing memory traffic.
    // In any non-S_EXEC state, the E substates drive the bus.
    wire f_owns_bus = (state_q == S_EXEC);

    // E-stall (Phase 5): whenever E is in a memory substate, hold F and D.
    wire e_busy = (state_q != S_EXEC);

    // Flush triggers come from the E stage (Phase 4).
    logic        flush;
    logic [31:0] flush_target_pc;

    // F-stage advance control (Phase 1).
    // issue_fetch only fires when the NEXT cycle will be S_EXEC — otherwise
    // the prefetched result arrives during a memory substate cycle where
    // we can't latch it, and the instruction is lost. Gating on state_next
    // ensures we only issue a fetch when there's a downstream cycle ready
    // to consume the result.
    wire issue_fetch   = !flush && !e_busy && (state_next == S_EXEC);
    wire latch_into_fd = !flush && !e_busy && inflight_valid_q;

    // D-stage advance — same shape; takes the decoded view of fd_q.
    de_t          de_q;

    wire [15:0]   thumb_instr_w = fd_q.pc[1] ? fd_q.instr[31:16]
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

    // F stage update — synchronous reset, gated by CLKEN.
    always_ff @(posedge CLK) begin
        if (CLKEN) begin
            if (!nRESET) begin
                fetch_pc_q       <= 32'h0;
                inflight_pc_q    <= 32'h0;
                inflight_valid_q <= 1'b0;
                fd_q             <= '{instr:32'h0, pc:32'h0, thumb:1'b0,
                                  pabort:1'b0, valid:1'b0};
            end else if (flush) begin
                fetch_pc_q       <= flush_target_pc;
                inflight_valid_q <= 1'b0;
                fd_q.valid       <= 1'b0;
            end else begin
                if (issue_fetch) begin
                    fetch_pc_q       <= fetch_pc_q + fetch_step;
                    inflight_pc_q    <= fetch_pc_q;
                    inflight_valid_q <= 1'b1;
                end else begin
                    inflight_valid_q <= 1'b0;
                end

                if (latch_into_fd) begin
                    fd_q.instr <= RDATA;
                    fd_q.pc    <= inflight_pc_q;
                    fd_q.thumb <= cpsr.t;
                    fd_q.pabort <= ABORT;       // §17: sample at fetch landing
                    fd_q.valid <= 1'b1;
                end else if (d_advance) begin
                    fd_q.valid <= 1'b0;
                end
            end
        end
    end

    // D stage update.
    always_ff @(posedge CLK) begin
        if (CLKEN) begin
            if (!nRESET) begin
                de_q <= '{dec:'0, instr:32'h0, pc:32'h0, thumb:1'b0,
                          pabort:1'b0, valid:1'b0};
            end else if (flush) begin
                de_q.valid <= 1'b0;
            end else if (!e_busy) begin
                if (fd_q.valid) begin
                    de_q.dec   <= dec_w;
                    de_q.instr <= fd_q.instr;
                    de_q.pc    <= fd_q.pc;
                    de_q.thumb <= fd_q.thumb;
                    de_q.pabort <= fd_q.pabort;
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

    logic [15:0]  block_remaining_q;
    logic [31:0]  block_curr_addr_q;
    logic [3:0]   block_curr_reg_q;
    logic         block_load_q;
    logic         block_first_beat_q;
    logic         block_user_mode_q;     // LDM/STM ^ — force user-bank regs
    logic         block_has_pc_q;        // r15 in this block's reg list?

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

    wire instr_is_ls_decoder = (dec.instr_class == INSTR_LDR_STR);
    wire block_active        = (state_q == S_BLOCK_ADDR) || (state_q == S_BLOCK_DATA);
    wire [3:0] rc_addr_eff   = block_active        ? block_curr_reg_q
                             : instr_is_ls_decoder ? dec.rd
                                                   : dec.rs;

    wire instr_is_mul_decoder = (dec.instr_class == INSTR_MUL);
    wire [3:0] ra_addr_eff    = instr_is_mul_decoder ? dec.rd : dec.rn;

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
        .pc_written      (rf_pc_written)
    );

    // ---- Shifter ----
    logic [31:0] sh_result;
    logic        sh_carry_out;

    // DP-imm shifter input uses raw imm8 from the executing instruction.
    // In the non-pipelined core this came from RDATA[7:0] (RDATA still held
    // the instruction during S_EXECUTE). Here, RDATA may carry a freshly-
    // fetched instruction for a different PC entirely, so we use the
    // latched de_q.instr instead.
    wire [31:0] op2_shifter_in     = dec.dp_use_imm
                                     ? {24'h0, de_q.instr[7:0]}
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

    arm7tdmis_alu u_alu (
        .op            (dec.alu_op),
        .op_a          (rf_ra_data),
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

    // ---- Multiplier ----
    logic [31:0] mul_result_lo, mul_result_hi;
    logic        mul_n_out, mul_z_out;
    logic [3:0]  mul_flag_we;
    logic [2:0]  mul_cycle_count;

    // §9d: is_long=1 for MULL forms (UMULL/SMULL/UMLAL/SMLAL); is_signed=1
    // for SMULL/SMLAL (decoder sets dec.mul_signed accordingly). MUL/MLA
    // keep is_long=0 / is_signed=0. UMLAL/SMLAL accumulate forms aren't
    // wired yet — they need a 4th regfile read port (RdHi as accumulator
    // high half) which the 3-port regfile can't supply in one cycle. Path
    // for those gets added when the cycle-shaping work (§18) lengthens E.
    wire instr_class_is_mull = (dec.instr_class == INSTR_MULL);

    arm7tdmis_multiplier u_mul (
        .is_signed   (dec.mul_signed),
        .is_long     (instr_class_is_mull),
        .accumulate  (dec.mul_accumulate),
        .op_a        (rf_rb_data),
        .op_b        (rf_rc_data),
        .acc_lo      (rf_ra_data),
        .acc_hi      (32'h0),
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

    wire block_does_writeback = block_take_cycle && dec.block_writeback;

    wire [15:0] block_after_curr = block_remaining_q & ~(16'h1 << block_curr_reg_q);
    wire        block_has_more   = (block_after_curr != 16'h0);

    wire swp_take_cycle = passes_cond && (dec.instr_class == INSTR_SWP);

    // §9d: UMULL/SMULL take an extra cycle in S_MULL_HI to write RdHi.
    // Accumulate forms (UMLAL/SMLAL) are deferred until §18 cycle shaping.
    wire mull_take_cycle = passes_cond && instr_class_is_mull
                        && !dec.mul_accumulate;

    // E-stage substate transitions. Single-cycle "execute" loops back to
    // S_EXEC; multi-cycle ops take the appropriate substate detour.
    // While in S_EXEC, an invalid de_q (bubble) still loops to S_EXEC —
    // the bus is idle that cycle.
    state_e state_next;
    always_comb begin
        unique case (state_q)
            S_EXEC:       state_next = ls_take_data_cycle ? S_DADDR
                                     : block_take_cycle   ? S_BLOCK_ADDR
                                     : swp_take_cycle     ? S_SWP_RADDR
                                     : mull_take_cycle    ? S_MULL_HI
                                                          : S_EXEC;
            S_DADDR:      state_next = S_DDATA;
            S_DDATA:      state_next = S_EXEC;
            S_BLOCK_ADDR: state_next = S_BLOCK_DATA;
            S_BLOCK_DATA: state_next = block_has_more ? S_BLOCK_ADDR : S_EXEC;
            S_SWP_RADDR:  state_next = S_SWP_RDATA;
            S_SWP_RDATA:  state_next = S_SWP_WADDR;
            S_SWP_WADDR:  state_next = S_SWP_WDATA;
            S_SWP_WDATA:  state_next = S_EXEC;
            S_MULL_HI:    state_next = S_EXEC;
            default:      state_next = S_EXEC;
        endcase
    end

    // =====================================================================
    // Writeback / commit / flush computation (S_EXEC + memory substates)
    // =====================================================================

    // `executing` predicate — only valid de_q during S_EXEC writes back.
    wire executing = (state_q == S_EXEC) && de_q.valid;
    wire passes_cond = executing && condition_pass && !dec_is_unimplemented_q;

    // We need the unimplemented bit latched alongside de_q.dec. Use a
    // small companion register driven from dec_is_unimplemented_w at the
    // same time we latch de_q.
    logic dec_is_unimplemented_q;
    always_ff @(posedge CLK) begin
        if (CLKEN) begin
            if (!nRESET)
                dec_is_unimplemented_q <= 1'b0;
            else if (flush)
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

    // §19/§20/§21: coprocessor instructions. With no external coprocessor
    // present (CPA=1 from the top), CP instructions trap UNDEF except:
    //   • CP14 (Debug Communications Channel) — internal, TRM §5.18.
    //   • CP15 c0 (Main ID Register) read — internal, returns a fixed
    //     implementation ID per TRM §4.1.
    // Other CP15 ops (control, cache, MMU — none of which exist in
    // ARM7TDMI-S r4p3 at the architectural level) still trap UNDEF.
    wire instr_is_cp = (dec.instr_class == INSTR_CDP)
                    || (dec.instr_class == INSTR_MCR_MRC)
                    || (dec.instr_class == INSTR_LDC_STC);
    wire instr_is_cp14 = instr_is_cp && (dec.cp_num == 4'd14);
    wire instr_is_cp15 = instr_is_cp && (dec.cp_num == 4'd15);
    wire instr_is_mrc  = (dec.instr_class == INSTR_MCR_MRC) && de_q.instr[20];
    wire cp15_crn0     = (de_q.instr[19:16] == 4'd0);
    wire cp15_mrc_id   = instr_is_cp15 && instr_is_mrc && cp15_crn0;
    wire cp_undef_trap = executing && instr_is_cp && CPA
                      && !instr_is_cp14
                      && !cp15_mrc_id;

    // CP15 Main ID Register value (TRM §4.1). Layout per architecture:
    //   [31:24] Implementor = 0x41 (ARM Ltd)
    //   [23:20] Variant     = 4 (r4)
    //   [19:16] Architecture= 2 (ARMv4T)
    //   [15:4 ] Primary part= 0x924 (ARM7TDMI family)
    //   [3:0  ] Revision    = 3 (p3)
    localparam logic [31:0] CP15_MAIN_ID = 32'h41429243;
    wire cp15_mrc_id_fires = passes_cond && cp15_mrc_id;

    wire msr_fires   = passes_cond && instr_is_msr;
    wire mrs_fires   = passes_cond && instr_is_mrs;
    wire msr_to_cpsr = msr_fires && !dec.psr_use_spsr;
    wire msr_to_spsr = msr_fires &&  dec.psr_use_spsr;

    wire dp_writes_dest     = passes_cond && instr_is_dp && !dec.is_test_op;
    wire dp_writes_pc       = dp_writes_dest && (dec.rd == 4'd15);
    wire branch_link_writes = passes_cond && instr_is_branch && dec.branch_link;
    wire branch_writes_pc   = passes_cond && instr_is_branch;
    wire bx_writes_pc       = passes_cond && instr_is_bx;
    wire swi_fires          = passes_cond && instr_is_swi;
    wire undef_fires        = executing &&
                              ((condition_pass && instr_is_undef) || cond_is_nv
                               || cp_undef_trap);

    wire irq_pending = executing && !nIRQ && !cpsr.i;
    wire fiq_pending = executing && !nFIQ && !cpsr.f;
    wire fiq_fires   = fiq_pending && !swi_fires && !undef_fires;
    wire irq_fires   = irq_pending && !fiq_pending
                    && !swi_fires && !undef_fires;

    // §17: prefetch abort fires when an aborted instruction reaches execute.
    // The abort bit was sampled at the fetch landing (F-stage latch) and
    // carried through fd_q/de_q. PABT takes precedence over UNDEF for the
    // same instruction; the architecturally correct order is PABT before
    // any decode-based traps.
    wire pabt_fires = executing && de_q.pabort;

    // §17: data abort fires when ABORT is asserted during the active data
    // cycle of an LDR/STR/LDM/STM/SWP. Latched so the exception can be
    // raised at the boundary back to S_EXEC.
    wire data_abort_now = ABORT && ((state_q == S_DDATA)
                                  || (state_q == S_BLOCK_DATA)
                                  || (state_q == S_SWP_RDATA)
                                  || (state_q == S_SWP_WDATA));

    logic data_abort_q;
    always_ff @(posedge CLK) begin
        if (CLKEN) begin
            if (!nRESET) begin
                data_abort_q <= 1'b0;
            end else if (state_q == S_EXEC) begin
                data_abort_q <= 1'b0;             // clear on entering a new instr
            end else if (data_abort_now) begin
                data_abort_q <= 1'b1;
            end
        end
    end

    // Fire DABT at the end of the memory-substate sequence — i.e., on the
    // transition back to S_EXEC. This is the cycle where commits would
    // otherwise complete and the next instruction would normally enter.
    wire dabt_fires = data_abort_q && (state_next == S_EXEC) && (state_q != S_EXEC);

    wire any_exc_fires    = swi_fires || undef_fires || irq_fires || fiq_fires
                         || pabt_fires || dabt_fires;

    // §9d: MUL/MLA write Rd at bits[19:16] (= dec.rn) in S_EXEC.
    // UMULL/SMULL write RdLo at bits[15:12] (= dec.rd) in S_EXEC and
    // RdHi at bits[19:16] (= dec.rn) in S_MULL_HI. Flag updates (NZ from
    // the full result) happen in S_EXEC for both — the multiplier's
    // result_hi is combinational, so we can sample flags in the first
    // execute cycle even though RdHi commits a cycle later.
    wire mul_writes_dest  = passes_cond && instr_is_mul;
    wire mull_writes_lo   = mull_take_cycle;
    wire mul_writes_flags = (mul_writes_dest || mull_take_cycle) && dec.s_bit;

    wire writes_pc_exec   = dp_writes_pc || branch_writes_pc || bx_writes_pc
                          || any_exc_fires;
    wire exec_writes_rf   = dp_writes_dest || branch_link_writes || any_exc_fires;
    wire writes_flags     = (passes_cond && instr_is_dp && dec.s_bit) || mul_writes_flags;

    // CPSR := SPSR-of-current-mode fires on:
    //   - DP to PC with S=1 (MOVS PC, LR family)
    //   - LDM ^ with PC in list, at the cycle r15 loads
    wire block_ldm_pc_restore = (state_q == S_BLOCK_DATA) && block_load_q
                             && (block_curr_reg_q == 4'd15)
                             && block_user_mode_q;
    assign cpsr_restore_now = (dp_writes_pc && dec.s_bit) || block_ldm_pc_restore;
    assign bx_set_t_en      = bx_writes_pc;
    assign bx_set_t_value   = rf_rb_data[0];

    // Exception target tables
    logic [4:0]  exc_mode_target;
    logic [2:0]  exc_spsr_target;
    logic [31:0] exc_pc_target_addr;

    always_comb begin
        // Default: SWI (most common entry path)
        exc_mode_target    = 5'(MODE_SUPERVISOR);
        exc_spsr_target    = 3'd2;
        exc_pc_target_addr = 32'h0000_0008;
        // Priority order matters: TRM §2.9 puts UNDEF/SWI ahead of PABT,
        // PABT ahead of FIQ, FIQ ahead of IRQ. DABT ranks above FIQ as
        // well (TRM Fig. 2-1). We layer the if/else chain to match.
        if (undef_fires) begin
            exc_mode_target    = 5'(MODE_UNDEFINED);
            exc_spsr_target    = 3'd4;
            exc_pc_target_addr = 32'h0000_0004;
        end else if (pabt_fires) begin
            exc_mode_target    = 5'(MODE_ABORT);
            exc_spsr_target    = 3'd3;
            exc_pc_target_addr = 32'h0000_000C;
        end else if (dabt_fires) begin
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
    wire [31:0] bx_pc_target     = rf_rb_data & 32'hFFFFFFFE;

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
    wire [4:0]  load_byte_shift = {ls_addr_lo_q, 3'b000};
    wire [7:0]  load_byte_raw   = 8'((RDATA >> load_byte_shift) & 32'h0000_00FF);
    wire [31:0] load_byte_val   = ls_signed_q
                                  ? {{24{load_byte_raw[7]}}, load_byte_raw}
                                  : {24'h0, load_byte_raw};

    wire [15:0] load_hw_raw     = ls_addr_lo_q[1] ? RDATA[31:16] : RDATA[15:0];
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
    wire ddata_writes_rd  = (state_q == S_DDATA) && ls_load_q && !data_abort_now;
    wire block_writes_ldm = (state_q == S_BLOCK_DATA) && block_load_q && !data_abort_now;
    wire swp_writes_rd    = (state_q == S_SWP_WDATA) && !data_abort_q;

    wire [4:0]  swp_byte_shift = {swp_addr_lo_q, 3'b000};
    wire [31:0] swp_byte_val   = (swp_loaded_q >> swp_byte_shift) & 32'h0000_00FF;
    wire [31:0] swp_load_value = swp_byte_q ? swp_byte_val : swp_loaded_q;

    // Regfile write-port mux (priority as in non-pipelined core)
    always_comb begin
        if (ddata_writes_rd) begin
            rf_write_addr = ls_rd_q;
            rf_write_data = load_value;
            rf_write_en   = 1'b1;
        end else if (block_writes_ldm) begin
            rf_write_addr = block_curr_reg_q;
            rf_write_data = RDATA;
            rf_write_en   = 1'b1;
        end else if (swp_writes_rd) begin
            rf_write_addr = swp_rd_q;
            rf_write_data = swp_load_value;
            rf_write_en   = 1'b1;
        end else if (any_exc_fires) begin
            rf_write_addr = 4'd14;
            rf_write_data = de_q.pc + 32'd4;
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
        end else if (block_does_writeback) begin
            rf_write_addr = dec.rn;
            rf_write_data = block_writeback_addr;
            rf_write_en   = 1'b1;
        end else if (state_q == S_MULL_HI) begin
            // §9d: RdHi commit cycle for UMULL/SMULL.
            rf_write_addr = mull_rdhi_q;
            rf_write_data = mull_result_hi_q;
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
        end else if (cp15_mrc_id_fires) begin
            // §21: MRC p15, 0, Rd, c0, c0, 0 — Main ID Register read.
            rf_write_addr = dec.rd;
            rf_write_data = CP15_MAIN_ID;
            rf_write_en   = 1'b1;
        end else begin
            rf_write_addr = dec.rd;
            rf_write_data = alu_result;
            rf_write_en   = exec_writes_rf;
        end
    end

    wire        flags_from_mul = mul_writes_flags;
    wire [3:0]  flags_value = flags_from_mul
                            ? {mul_n_out, mul_z_out, cpsr.c, cpsr.v}
                            : {alu_n, alu_z, alu_c, alu_v};
    assign cpsr_write_en   = writes_flags || msr_to_cpsr;
    assign cpsr_write_data = msr_to_cpsr ? sh_result : {flags_value, 28'h0};
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

    wire ddata_writes_pc = (state_q == S_DDATA) && ls_load_q && (ls_rd_q == 4'd15);
    wire block_writes_pc = (state_q == S_BLOCK_DATA) && block_load_q
                        && (block_curr_reg_q == 4'd15);

    assign flush           = writes_pc_exec || ddata_writes_pc || block_writes_pc;
    assign flush_target_pc = ddata_writes_pc ? load_value
                           : block_writes_pc ? RDATA
                                             : pc_target_exec;

    // =====================================================================
    // E-stage sequential state
    // =====================================================================
    always_ff @(posedge CLK) begin
        if (CLKEN) begin
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
                block_remaining_q   <= 16'h0;
                block_curr_addr_q   <= 32'h0;
                block_curr_reg_q    <= 4'h0;
                block_load_q        <= 1'b0;
                block_first_beat_q  <= 1'b0;
                block_user_mode_q   <= 1'b0;
                block_has_pc_q      <= 1'b0;
                swp_addr_q          <= 32'h0;
                swp_store_q         <= 32'h0;
                swp_loaded_q        <= 32'h0;
                swp_rd_q            <= 4'h0;
                swp_byte_q          <= 1'b0;
                swp_addr_lo_q       <= 2'h0;
                mull_rdhi_q         <= 4'h0;
                mull_result_hi_q    <= 32'h0;
            end else begin
                state_q <= state_next;

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

                // LDM/STM snapshot + iteration start.
                if (state_q == S_EXEC && block_take_cycle) begin
                    block_remaining_q  <= dec.block_reg_list;
                    block_curr_addr_q  <= block_start_addr;
                    block_curr_reg_q   <= lowest_set_idx(dec.block_reg_list);
                    block_load_q       <= dec.block_load;
                    block_first_beat_q <= 1'b1;
                    block_user_mode_q  <= dec.block_user_mode;
                    block_has_pc_q     <= dec.block_reg_list[15];
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

                if (state_q == S_SWP_RDATA) begin
                    swp_loaded_q <= RDATA;
                end

                // §9d: snapshot RdHi register address and upper 32 bits of
                // the product at end of S_EXEC for UMULL/SMULL.
                if (state_q == S_EXEC && mull_take_cycle) begin
                    mull_rdhi_q      <= dec.rn;
                    mull_result_hi_q <= mul_result_hi;
                end
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

    always_comb begin
        // Default: F-stage opcode fetch (S_EXEC owns the bus).
        ADDR  = fetch_pc_q;
        WRITE = WRITE_READ;
        SIZE  = cpsr.t ? 2'(SIZE_HALFWORD) : 2'(SIZE_WORD);
        PROT  = {is_priv, 1'b0};
        LOCK  = LOCK_FREE;
        TRANS = f_owns_bus ? 2'(TRANS_S) : 2'(TRANS_I);
        WDATA = 32'h0;

        unique case (state_q)
            S_EXEC: begin
                // F drives the fetch. On flush this cycle, the next-cycle
                // fetch will use flush_target_pc; here we still drive
                // fetch_pc_q (the pre-flush value), which will be discarded
                // anyway (latch_into_fd will be 0 next cycle since flush
                // killed inflight_valid).
                ADDR  = fetch_pc_q;
                TRANS = (flush || !issue_fetch) ? 2'(TRANS_I) : 2'(TRANS_S);
                SIZE  = cpsr.t ? 2'(SIZE_HALFWORD) : 2'(SIZE_WORD);
                PROT  = {is_priv, 1'b0};
            end
            S_DADDR: begin
                ADDR  = ls_data_addr_q;
                TRANS = 2'(TRANS_N);
                WRITE = ls_load_q ? WRITE_READ : WRITE_WRITE;
                SIZE  = ls_halfword_q ? 2'(SIZE_HALFWORD)
                      : ls_byte_q    ? 2'(SIZE_BYTE)
                                     : 2'(SIZE_WORD);
                PROT  = {is_priv, 1'b1};
            end
            S_DDATA: begin
                ADDR  = ls_data_addr_q;
                TRANS = 2'(TRANS_I);
                WRITE = ls_load_q ? WRITE_READ : WRITE_WRITE;
                SIZE  = ls_halfword_q ? 2'(SIZE_HALFWORD)
                      : ls_byte_q    ? 2'(SIZE_BYTE)
                                     : 2'(SIZE_WORD);
                PROT  = {is_priv, 1'b1};
                WDATA = ls_load_q ? 32'h0 : store_wdata;
            end
            S_BLOCK_ADDR: begin
                ADDR  = block_curr_addr_q;
                TRANS = block_first_beat_q ? 2'(TRANS_N) : 2'(TRANS_S);
                WRITE = block_load_q ? WRITE_READ : WRITE_WRITE;
                SIZE  = 2'(SIZE_WORD);
                PROT  = {is_priv, 1'b1};
            end
            S_BLOCK_DATA: begin
                ADDR  = block_curr_addr_q;
                TRANS = 2'(TRANS_I);
                WRITE = block_load_q ? WRITE_READ : WRITE_WRITE;
                SIZE  = 2'(SIZE_WORD);
                PROT  = {is_priv, 1'b1};
                WDATA = block_load_q ? 32'h0 : rf_rc_data;
            end
            S_SWP_RADDR: begin
                ADDR  = swp_addr_q;
                TRANS = 2'(TRANS_N);
                WRITE = WRITE_READ;
                SIZE  = swp_byte_q ? 2'(SIZE_BYTE) : 2'(SIZE_WORD);
                PROT  = {is_priv, 1'b1};
                LOCK  = LOCK_LOCKED;
            end
            S_SWP_RDATA: begin
                ADDR  = swp_addr_q;
                TRANS = 2'(TRANS_I);
                WRITE = WRITE_READ;
                SIZE  = swp_byte_q ? 2'(SIZE_BYTE) : 2'(SIZE_WORD);
                PROT  = {is_priv, 1'b1};
                LOCK  = LOCK_LOCKED;
            end
            S_SWP_WADDR: begin
                ADDR  = swp_addr_q;
                TRANS = 2'(TRANS_N);
                WRITE = WRITE_WRITE;
                SIZE  = swp_byte_q ? 2'(SIZE_BYTE) : 2'(SIZE_WORD);
                PROT  = {is_priv, 1'b1};
                LOCK  = LOCK_LOCKED;
            end
            S_SWP_WDATA: begin
                ADDR  = swp_addr_q;
                TRANS = 2'(TRANS_I);
                WRITE = WRITE_WRITE;
                SIZE  = swp_byte_q ? 2'(SIZE_BYTE) : 2'(SIZE_WORD);
                PROT  = {is_priv, 1'b1};
                LOCK  = LOCK_LOCKED;
                WDATA = swp_wdata;
            end
            default: ;
        endcase
    end

    assign DMORE = block_active && block_has_more;

    // =====================================================================
    // §19: Coprocessor pipeline-following signals
    // =====================================================================
    //
    // Per TRM §4 & §30.23.2 these mirror the bus cycle types so an external
    // coprocessor can shadow the ARM pipeline state machine. CPnI is driven
    // separately to indicate that the current decode is a coprocessor op.
    //
    //   CPnMREQ : active LOW when this cycle is a memory access (TRANS=N|S)
    //   CPSEQ   : active HIGH when this cycle is sequential (TRANS=S)
    //   CPnTRANS: active LOW when the access is a data access (not opcode)
    //   CPnOPC  : active LOW when the access is an opcode fetch
    //   CPTBIT  : current CPSR.T (state of the executing instruction stream)
    //   CPnI    : active LOW when the executing instruction is a CP op
    //              (CDP/MCR/MRC/LDC/STC) — coprocessor inspects CPA/CPB to
    //              accept or refuse.

    wire trans_is_active = (TRANS == 2'(TRANS_N)) || (TRANS == 2'(TRANS_S));
    wire trans_is_seq    = (TRANS == 2'(TRANS_S));

    assign CPnMREQ = !trans_is_active;
    assign CPSEQ   =  trans_is_seq;
    assign CPnTRANS = !PROT[PROT_BIT_DATA];   // PROT[0]=0 opcode → CPnTRANS=1
    assign CPnOPC   =  PROT[PROT_BIT_DATA];   // mirror — opcode fetch → CPnOPC=0
    assign CPTBIT   = cpsr.t;
    assign CPnI     = !(executing && instr_is_cp);

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
    assign DBGINSTRVALID = executing;
    assign DBGnEXEC      = !passes_cond;


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
        if (CLKEN) begin
            if (!nRESET)
                pc_q <= 32'h0;
            else if (state_q == S_EXEC && de_q.valid)
                pc_q <= de_q.pc;
        end
    end

    // ---- Unused-signal drain ----
    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0,
        CFGBIGEND,
        CPB,                              // §19: busy-wait wiring is later
        spsr_valid,
        arm_is_dataproc_w, thumb_is_dataproc_w,
        rf_pc_written,
        alu_flag_we,
        cpsr[27:6],
        ls_data_addr_calc[31:12],
        ls_store_data_q[31:8],
        mul_flag_we,
        mul_cycle_count,
        dec.dp_imm_value,
        dec.hs_signed, dec.hs_halfword, dec.hs_use_imm, dec.hs_imm_offset,
        dec.psr_use_spsr, dec.msr_field_mask, dec.msr_use_imm,
        dec.swi_comment, dec.cp_num
    };
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
