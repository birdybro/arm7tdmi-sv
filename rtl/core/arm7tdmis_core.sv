// Simple non-pipelined ARM execution model (TASKS.md §7).
//
// Two-state FSM that fetches one instruction per round-trip and executes
// it combinationally before committing to register/PSR/PC at the rising
// edge. Cycle timing here is "2 cycles per instruction" — far from the
// TRM's 1S throughput target — but it gives us a correct architectural
// reference to validate against. §16 replaces this with the real 3-stage
// pipeline.
//
//   S_FETCH:   drive ADDR=pc_q with TRANS=N. Memory captures.
//   S_EXECUTE: RDATA holds the instruction. Decode + read regs + shift +
//              ALU + condition all combinational. At the rising clock
//              edge ending this state we commit Rd writeback (if any),
//              CPSR flag updates (if S=1 and condition passed), and
//              advance pc_q (to alu_result if Rd=15, else pc_q+4).
//
// Decoder coverage today is DP-immediate only (per arm7tdmis_decoder).
// Anything else is treated as a NOP — pc_q still advances. §8 grows the
// decoder; §9-§13 add the corresponding execute paths here.
//
// Several TRM features are stubbed out: no Thumb (CPTBIT=0), no exception
// handling (nIRQ/nFIQ/ABORT inputs accepted but not consumed), no
// coprocessor (CPnI tied HIGH externally), no debug. These are landed in
// their respective milestones (§14, §15, §19, §22).

module arm7tdmis_core
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
    output logic        DMORE
);

    // ---- FSM state.
    //   Non-L/S         : FETCH → EXECUTE → FETCH                          (2)
    //   Single LDR/STR  : FETCH → EXECUTE → DADDR → DDATA → FETCH          (4)
    //   LDM/STM         : FETCH → EXECUTE → BLOCK_ADDR → BLOCK_DATA → …    (2+2n)
    //   SWP / SWPB      : FETCH → EXECUTE → SWP_RADDR → SWP_RDATA →
    //                     SWP_WADDR → SWP_WDATA → FETCH                    (6)
    //                     LOCK asserted across all four SWP_* states so the
    //                     bus arbiter can't grant another master between
    //                     the read and the write (TRM §30.13).
    typedef enum logic [3:0] {
        S_FETCH      = 4'd0,
        S_EXECUTE    = 4'd1,
        S_DADDR      = 4'd2,    // single L/S address phase
        S_DDATA      = 4'd3,    // single L/S data phase
        S_BLOCK_ADDR = 4'd4,    // LDM/STM per-register address phase
        S_BLOCK_DATA = 4'd5,    // LDM/STM per-register data phase
        S_SWP_RADDR  = 4'd6,    // SWP read address phase
        S_SWP_RDATA  = 4'd7,    // SWP read data phase
        S_SWP_WADDR  = 4'd8,    // SWP write address phase
        S_SWP_WDATA  = 4'd9     // SWP write data phase + Rd commit
    } state_e;

    state_e       state_q;
    logic [31:0]  pc_q;

    // L/S latches captured at end of S_EXECUTE for use in S_DADDR/S_DDATA.
    // dec.* fields are combinational from RDATA; once we transition to
    // S_DADDR the data bus drives the memory address and RDATA in S_DDATA
    // carries the loaded value, so the decoder's view of the instruction
    // is gone — we must snapshot what we need.
    logic [31:0]  ls_data_addr_q;
    logic [31:0]  ls_store_data_q;
    logic [3:0]   ls_rd_q;
    logic         ls_byte_q;
    logic         ls_load_q;
    logic [1:0]   ls_addr_lo_q;

    // Block transfer latches. block_remaining_q tracks the registers
    // still to be transferred (including the one in flight); each
    // S_BLOCK_DATA cycle clears the bit for block_curr_reg_q and
    // computes the next register from the priority encoder.
    logic [15:0]  block_remaining_q;
    logic [31:0]  block_curr_addr_q;
    logic [3:0]   block_curr_reg_q;
    logic         block_load_q;

    // SWP latches. swp_loaded_q holds the value read in S_SWP_RDATA
    // for commit to Rd at the end of S_SWP_WDATA — Rd is only updated
    // after the full read/write sequence completes (TRM §13).
    logic [31:0]  swp_addr_q;
    logic [31:0]  swp_store_q;
    logic [31:0]  swp_loaded_q;
    logic [3:0]   swp_rd_q;
    logic         swp_byte_q;
    logic [1:0]   swp_addr_lo_q;

    // ---- PSR ----
    psr_t         cpsr;
    psr_t         spsr_unused;
    logic         spsr_valid_unused;
    logic         cpsr_write_en;
    logic [31:0]  cpsr_write_data;
    logic [3:0]   cpsr_write_mask;

    // PSR control. Three exception-aware paths plus the normal MSR write:
    //   cpsr_restore_now : MOVS PC, LR family — CPSR <- SPSR-of-current-mode.
    //   bx_set_t_*       : BX writes CPSR.T atomically (ARM↔Thumb switch).
    //   exc_enter_*      : SWI (and later other exceptions) — atomic save
    //                      current CPSR to target SPSR + load new CPSR.
    logic       cpsr_restore_now;
    logic       bx_set_t_en;
    logic       bx_set_t_value;
    logic       exc_enter_en;
    logic [2:0] exc_target_spsr_idx;
    psr_t       exc_new_cpsr;

    arm7tdmis_psr u_psr (
        .CLK                 (CLK),
        .CLKEN               (CLKEN),
        .nRESET              (nRESET),
        .cpsr                (cpsr),
        .spsr                (spsr_unused),
        .spsr_valid          (spsr_valid_unused),
        .cpsr_write_en       (cpsr_write_en),
        .cpsr_write_data     (cpsr_write_data),
        .cpsr_write_mask     (cpsr_write_mask),
        .spsr_write_en       (1'b0),
        .spsr_write_data     (32'h0),
        .spsr_write_mask     (4'h0),
        .cpsr_restore_en     (cpsr_restore_now),
        .bx_set_t_en         (bx_set_t_en),
        .bx_set_t_value      (bx_set_t_value),
        .exc_enter_en        (exc_enter_en),
        .exc_target_spsr_idx (exc_target_spsr_idx),
        .exc_new_cpsr        (exc_new_cpsr)
    );

    // ---- Decoder ----
    // The decoder hands back a normalized decoded_t with classification
    // and all class-specific fields; we also keep three legacy scalars
    // for §7-style write-back gating (the integration path still only
    // executes DP-immediate — DP-register and the other classes get their
    // execute paths in §9-§13).
    //
    // Decoder fed directly from RDATA. The memory model produces RDATA
    // combinationally from a registered address (latched at end of S_FETCH),
    // so RDATA carries the instruction throughout the S_EXECUTE cycle.
    // In S_FETCH, RDATA is whatever the memory drives (typically 0 or
    // stale) — harmless because the writeback gates suppress commits
    // outside S_EXECUTE.
    decoded_t dec;
    logic     dec_is_dataproc;
    logic     dec_is_unimplemented;

    arm7tdmis_decoder u_dec (
        .instr            (RDATA),
        .dec              (dec),
        .is_dataproc      (dec_is_dataproc),
        .is_unimplemented (dec_is_unimplemented)
    );

    // ---- Condition evaluator ----
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

    // ---- Regfile ----
    logic [31:0] rf_ra_data, rf_rb_data, rf_rc_data;
    logic        rf_pc_written;

    // Read port C is shared:
    //   DP register-shift-by-register : Rs   (dec.rs)
    //   L/S single store              : Rd   (dec.rd — source for STR)
    //   LDM/STM block phase           : block_curr_reg_q (current register)
    wire instr_is_ls_decoder = (dec.instr_class == INSTR_LDR_STR);
    wire block_active = (state_q == S_BLOCK_ADDR) || (state_q == S_BLOCK_DATA);
    wire [3:0] rc_addr_eff = block_active        ? block_curr_reg_q
                           : instr_is_ls_decoder ? dec.rd
                                                 : dec.rs;

    arm7tdmis_regfile u_regfile (
        .CLK             (CLK),
        .CLKEN           (CLKEN),
        .nRESET          (nRESET),
        .mode            (cpsr.m),
        .t_bit           (cpsr.t),
        .pc_in           (pc_q),
        .ra_addr         (dec.rn),         // Rn → ALU op_a / L/S base
        .rb_addr         (dec.rm),         // Rm → shifter input (DP-reg)
        .rc_addr         (rc_addr_eff),    // Rs (DP-reg-reg) / Rd (STR source)
        .ra_data         (rf_ra_data),
        .rb_data         (rf_rb_data),
        .rc_data         (rf_rc_data),
        .wa_addr         (rf_write_addr),
        .wa_data         (rf_write_data),
        .wa_enable       (rf_write_en),
        .force_user_bank (1'b0),
        .pc_written      (rf_pc_written)
    );

    // ---- Shifter ----
    logic [31:0] sh_result;
    logic        sh_carry_out;

    // ---- Operand2 muxes (§9):
    //   - DP-imm:                shifter input = imm8 zero-extended;
    //                            amount = 2*rot4 (in dec.shifter_amount).
    //   - DP-register:           shifter input = Rm; amount comes from
    //                            either dec.shifter_amount (imm-shift) or
    //                            Rs[7:0] (reg-shift, selected by
    //                            dec.shifter_use_rs).
    wire [31:0] op2_shifter_in     = dec.dp_use_imm
                                     ? {24'h0, RDATA[7:0]}
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

    arm7tdmis_alu u_alu (
        .op            (dec.alu_op),
        .op_a          (rf_ra_data),
        .op_b          (sh_result),
        .cpsr_c        (cpsr.c),
        .shifter_carry (sh_carry_out),
        .result        (alu_result),
        .n_out         (alu_n),
        .z_out         (alu_z),
        .c_out         (alu_c),
        .v_out         (alu_v),
        .flag_we       (alu_flag_we)
    );

    // ---- FSM transitions. Non-L/S instructions go S_FETCH→S_EXECUTE→
    //      S_FETCH (2 cycles). L/S instructions take the longer path.
    //      LDM/STM iterates: BLOCK_ADDR↔BLOCK_DATA per register.
    state_e state_next;

    // Helper: lowest set bit index. Linear scan; small (16 entries).
    function automatic logic [3:0] lowest_set_idx(input logic [15:0] mask);
        for (int i = 0; i < 16; i = i + 1) begin
            if (mask[i]) return i[3:0];
        end
        return 4'd0;
    endfunction

    wire ls_take_data_cycle = passes_cond
                            && (dec.instr_class == INSTR_LDR_STR)
                            && dec.ls_use_imm
                            && dec.ls_pre_index
                            && !dec.ls_writeback;

    // Block (LDM/STM) §12 minimum: IA mode (P=0, U=1), no writeback,
    // no User-mode override, no PC in list, non-empty list.
    wire block_take_cycle = passes_cond
                          && (dec.instr_class == INSTR_LDM_STM)
                          && !dec.block_pre_index
                          && dec.block_up
                          && !dec.block_user_mode
                          && !dec.block_writeback
                          && !dec.block_reg_list[15]
                          && (dec.block_reg_list != 16'h0);

    // Block iteration: clearing the current bit yields the remaining set.
    wire [15:0] block_after_curr = block_remaining_q & ~(16'h1 << block_curr_reg_q);
    wire        block_has_more   = (block_after_curr != 16'h0);

    // SWP: take the 4-state read-modify-write detour. dec.ls_byte
    // shares the bit-22 position with SWP's B bit, so it carries SWPB
    // correctly without a new decoder field.
    wire swp_take_cycle = passes_cond && (dec.instr_class == INSTR_SWP);

    always_comb begin
        unique case (state_q)
            S_FETCH:      state_next = S_EXECUTE;
            S_EXECUTE:    state_next = ls_take_data_cycle    ? S_DADDR
                                     : block_take_cycle      ? S_BLOCK_ADDR
                                     : swp_take_cycle        ? S_SWP_RADDR
                                                             : S_FETCH;
            S_DADDR:      state_next = S_DDATA;
            S_DDATA:      state_next = S_FETCH;
            S_BLOCK_ADDR: state_next = S_BLOCK_DATA;
            S_BLOCK_DATA: state_next = block_has_more ? S_BLOCK_ADDR : S_FETCH;
            S_SWP_RADDR:  state_next = S_SWP_RDATA;
            S_SWP_RDATA:  state_next = S_SWP_WADDR;
            S_SWP_WADDR:  state_next = S_SWP_WDATA;
            S_SWP_WDATA:  state_next = S_FETCH;
            default:      state_next = S_FETCH;
        endcase
    end

    // ---- Writeback control. §10: DP, BRANCH (B/BL) and BX all commit.
    //      Other classes (LDR/STR, multiply, ...) still NOP until their
    //      execute paths land in §11–§13.
    //
    //   DP class:
    //     writes_dest_reg = Rd unless TST/TEQ/CMP/CMN
    //     writes_pc       = Rd == 15
    //     writes_flags    = S = 1
    //     cpsr_restore    = writes_pc && S = 1  (MOVS PC, LR family)
    //
    //   BRANCH class (B/BL):
    //     writes_pc       = always (target = pc_q + 8 + offset)
    //     writes_dest_reg = BL only (LR ← pc_q + 4)
    //     no flag update
    //
    //   BX class:
    //     writes_pc       = always (target = Rm & ~1)
    //     bx_set_t        = Rm[0]  (ARM↔Thumb interworking)
    //     no register write
    //     no flag update
    wire executing       = (state_q == S_EXECUTE);
    wire passes_cond     = executing && condition_pass && !dec_is_unimplemented;

    wire instr_is_dp     = (dec.instr_class == INSTR_DP);
    wire instr_is_branch = (dec.instr_class == INSTR_BRANCH);
    wire instr_is_bx     = (dec.instr_class == INSTR_BX);
    wire instr_is_swi    = (dec.instr_class == INSTR_SWI);

    wire dp_writes_dest     = passes_cond && instr_is_dp && !dec.is_test_op;
    wire dp_writes_pc       = dp_writes_dest && (dec.rd == 4'd15);
    wire branch_link_writes = passes_cond && instr_is_branch && dec.branch_link;
    wire branch_writes_pc   = passes_cond && instr_is_branch;
    wire bx_writes_pc       = passes_cond && instr_is_bx;
    wire swi_fires          = passes_cond && instr_is_swi;

    wire writes_pc      = dp_writes_pc || branch_writes_pc || bx_writes_pc || swi_fires;
    wire exec_writes_rf = dp_writes_dest || branch_link_writes || swi_fires;
    wire writes_flags   = passes_cond && instr_is_dp && dec.s_bit;

    assign cpsr_restore_now = dp_writes_pc && dec.s_bit;
    assign bx_set_t_en      = bx_writes_pc;
    assign bx_set_t_value   = rf_rb_data[0];     // Rm[0] selects new state

    // SWI: atomically enter SVC mode. exc_new_cpsr = current CPSR with
    // mode=SVC, I=1, T=0 (F preserved). spsr index for SVC = 2.
    psr_t swi_new_cpsr;
    always_comb begin
        swi_new_cpsr   = cpsr;
        swi_new_cpsr.m = 5'(MODE_SUPERVISOR);
        swi_new_cpsr.i = 1'b1;
        swi_new_cpsr.t = 1'b0;
    end
    assign exc_enter_en        = swi_fires;
    assign exc_target_spsr_idx = 3'd2;     // SPSR_svc
    assign exc_new_cpsr        = swi_new_cpsr;

    // PC target per class:
    //   DP/Rd=15:  ALU result
    //   B/BL:      pc_q + 8 + sign-extended (offset24<<2)
    //   BX:        Rm with LSB cleared (LSB is the new T bit, handled above)
    //   SWI:       0x00000008 (SWI exception vector — TRM Table 2-4)
    wire [31:0] dp_pc_target     = alu_result;
    wire [31:0] branch_pc_target = pc_q + 32'd8 + dec.branch_offset;
    wire [31:0] bx_pc_target     = rf_rb_data & 32'hFFFFFFFE;
    wire [31:0] swi_pc_target    = 32'h0000_0008;

    wire [31:0] pc_target = instr_is_swi    ? swi_pc_target    :
                            instr_is_branch ? branch_pc_target :
                            instr_is_bx     ? bx_pc_target     :
                                              dp_pc_target;

    // ---- §11: L/S address generation + byte/word extraction ----
    // Offset is dec.ls_imm_offset (12-bit), added or subtracted from Rn
    // per the U bit. Pre-indexed and no-writeback only; ls_take_data_cycle
    // above ensures unsupported variants stay on the 2-state path.
    wire [31:0] ls_offset_ext = {20'h0, dec.ls_imm_offset};
    wire [31:0] ls_data_addr_calc = dec.ls_up
                                    ? (rf_ra_data + ls_offset_ext)
                                    : (rf_ra_data - ls_offset_ext);

    // Loaded byte: shift RDATA right by 8*addr_lo, then zero-extend.
    // Loaded word: pass RDATA through (aligned access assumed for now).
    wire [4:0]  load_byte_shift = {ls_addr_lo_q, 3'b000};
    wire [31:0] load_byte_val   = (RDATA >> load_byte_shift) & 32'h0000_00FF;
    wire [31:0] load_word_val   = RDATA;
    wire [31:0] load_value      = ls_byte_q ? load_byte_val : load_word_val;

    // S_DDATA load writeback: commit RDATA into the latched Rd register.
    wire ddata_writes_rd = (state_q == S_DDATA) && ls_load_q;

    // S_BLOCK_DATA load writeback: commit RDATA to the register currently
    // being transferred (for LDM only — STM is a memory write).
    wire block_writes_ldm = (state_q == S_BLOCK_DATA) && block_load_q;

    // S_SWP_WDATA: commit the value loaded in S_SWP_RDATA (held in
    // swp_loaded_q) to Rd. Byte form zero-extends from swp_addr_lo lane.
    wire swp_writes_rd = (state_q == S_SWP_WDATA);

    wire [4:0]  swp_byte_shift = {swp_addr_lo_q, 3'b000};
    wire [31:0] swp_byte_val   = (swp_loaded_q >> swp_byte_shift) & 32'h0000_00FF;
    wire [31:0] swp_load_value = swp_byte_q ? swp_byte_val : swp_loaded_q;

    // ---- Regfile write port mux ----
    // Priorities (only one fires per cycle by construction):
    //   - S_DDATA load   : ls_rd_q ← load_value     (single LDR/LDRB)
    //   - S_BLOCK_DATA   : block_curr_reg_q ← RDATA (LDM iteration)
    //   - S_EXECUTE BL   : r14 ← pc_q + 4           (BL link)
    //   - S_EXECUTE DP   : dec.rd ← alu_result      (data-processing)
    logic [3:0]  rf_write_addr;
    logic [31:0] rf_write_data;
    logic        rf_write_en;

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
        end else if (swi_fires) begin
            // SWI: save return address (pc_q+4 = instruction after SWI)
            // into r14 of the target mode. Since the PSR's exc_enter_en
            // is asserted in the same cycle, the regfile sees the OLD
            // mode (still pre-SWI mode); the write lands in the source
            // mode's r14 bank. For boot-mode SWI (SVC→SVC) the source
            // and target bank coincide, so this is correct. Cross-mode
            // SWI (User→SVC) needs a force-target-mode override; that
            // lands when User mode is testable in §14b.
            rf_write_addr = 4'd14;
            rf_write_data = pc_q + 32'd4;
            rf_write_en   = 1'b1;
        end else if (branch_link_writes) begin
            rf_write_addr = 4'd14;
            rf_write_data = pc_q + 32'd4;
            rf_write_en   = 1'b1;
        end else begin
            rf_write_addr = dec.rd;
            rf_write_data = alu_result;
            rf_write_en   = exec_writes_rf;
        end
    end

    // CPSR flag update: only the _f byte (bits [31:24]) per the ALU
    // outputs. The S-bit + condition-pass gates are folded into write_flags.
    assign cpsr_write_en   = writes_flags;
    assign cpsr_write_data = {alu_n, alu_z, alu_c, alu_v, 28'h0};
    assign cpsr_write_mask = 4'b1000;

    // ---- Sequential state ----
    always_ff @(posedge CLK) begin
        if (CLKEN) begin
            if (!nRESET) begin
                state_q           <= S_FETCH;
                pc_q              <= 32'h0;
                ls_data_addr_q    <= 32'h0;
                ls_store_data_q   <= 32'h0;
                ls_rd_q           <= 4'h0;
                ls_byte_q         <= 1'b0;
                ls_load_q         <= 1'b0;
                ls_addr_lo_q      <= 2'h0;
                block_remaining_q <= 16'h0;
                block_curr_addr_q <= 32'h0;
                block_curr_reg_q  <= 4'h0;
                block_load_q      <= 1'b0;
                swp_addr_q        <= 32'h0;
                swp_store_q       <= 32'h0;
                swp_loaded_q      <= 32'h0;
                swp_rd_q          <= 4'h0;
                swp_byte_q        <= 1'b0;
                swp_addr_lo_q     <= 2'h0;
            end else begin
                state_q <= state_next;

                // PC advances at end of EXECUTE — for both 2-state and
                // 4-state instructions. After S_EXECUTE the next fetch
                // (eventually) uses the updated pc_q.
                if (state_q == S_EXECUTE) begin
                    if (writes_pc) begin
                        pc_q <= pc_target;
                    end else begin
                        pc_q <= pc_q + 32'd4;
                    end
                end

                // Snapshot the L/S micro-op at end of EXECUTE so the data
                // bus cycles can drive memory without the decoder context.
                if (state_q == S_EXECUTE && ls_take_data_cycle) begin
                    ls_data_addr_q  <= ls_data_addr_calc;
                    ls_store_data_q <= rf_rc_data;
                    ls_rd_q         <= dec.rd;
                    ls_byte_q       <= dec.ls_byte;
                    ls_load_q       <= dec.ls_load;
                    ls_addr_lo_q    <= ls_data_addr_calc[1:0];
                end

                // Snapshot the LDM/STM micro-op + start the iteration.
                if (state_q == S_EXECUTE && block_take_cycle) begin
                    block_remaining_q <= dec.block_reg_list;
                    block_curr_addr_q <= rf_ra_data;           // IA: start = Rn
                    block_curr_reg_q  <= lowest_set_idx(dec.block_reg_list);
                    block_load_q      <= dec.block_load;
                end

                // After each per-register data phase, clear the bit just
                // transferred, advance the address by 4, and pick the
                // next lowest register from the remaining list.
                if (state_q == S_BLOCK_DATA) begin
                    block_remaining_q <= block_after_curr;
                    if (block_has_more) begin
                        block_curr_reg_q  <= lowest_set_idx(block_after_curr);
                        block_curr_addr_q <= block_curr_addr_q + 32'd4;
                    end
                end

                // Snapshot SWP at end of EXECUTE.
                if (state_q == S_EXECUTE && swp_take_cycle) begin
                    swp_addr_q    <= rf_ra_data;        // [Rn]
                    swp_store_q   <= rf_rb_data;        // value from Rm
                    swp_rd_q      <= dec.rd;            // destination
                    swp_byte_q    <= dec.ls_byte;       // B bit (bit 22)
                    swp_addr_lo_q <= rf_ra_data[1:0];   // for SWPB byte lane
                end

                // Capture the read value at the end of S_SWP_RDATA so
                // the write phase can drive memory while we hold the
                // loaded value for the Rd writeback at S_SWP_WDATA.
                if (state_q == S_SWP_RDATA) begin
                    swp_loaded_q <= RDATA;
                end
            end
        end
    end

    // ---- Bus drive ----
    wire is_priv = (cpsr.m != 5'(MODE_USER));

    wire [31:0] store_byte_data = {4{ls_store_data_q[7:0]}};
    wire [31:0] store_wdata     = ls_byte_q ? store_byte_data : ls_store_data_q;

    // SWP store-side WDATA: byte form replicates Rm[7:0] across all lanes
    // so the memory's lane-mux picks the right one.
    wire [31:0] swp_wdata = swp_byte_q ? {4{swp_store_q[7:0]}} : swp_store_q;

    always_comb begin
        // Default: idle, post-S_EXECUTE shape
        ADDR  = pc_q;
        WRITE = WRITE_READ;
        SIZE  = 2'(SIZE_WORD);
        PROT  = {is_priv, 1'b0};        // {priv, opcode_fetch}
        LOCK  = LOCK_FREE;
        TRANS = 2'(TRANS_I);
        WDATA = 32'h0;

        unique case (state_q)
            S_FETCH: begin
                // Drive the opcode fetch address
                ADDR  = pc_q;
                TRANS = 2'(TRANS_N);
                PROT  = {is_priv, 1'b0};
            end
            S_EXECUTE: begin
                // Bus idle — the memory's address phase from the previous
                // S_FETCH cycle is producing RDATA combinationally.
                ADDR  = pc_q;
                TRANS = 2'(TRANS_I);
            end
            S_DADDR: begin
                // Drive the L/S data address.
                ADDR  = ls_data_addr_q;
                TRANS = 2'(TRANS_N);
                WRITE = ls_load_q ? WRITE_READ : WRITE_WRITE;
                SIZE  = ls_byte_q ? 2'(SIZE_BYTE) : 2'(SIZE_WORD);
                PROT  = {is_priv, 1'b1};   // data access
            end
            S_DDATA: begin
                // Memory consumes WDATA (for stores) or returns RDATA
                // (for loads) at this cycle's rising edge. Bus otherwise
                // idle from our side.
                ADDR  = ls_data_addr_q;
                TRANS = 2'(TRANS_I);
                WRITE = ls_load_q ? WRITE_READ : WRITE_WRITE;
                SIZE  = ls_byte_q ? 2'(SIZE_BYTE) : 2'(SIZE_WORD);
                PROT  = {is_priv, 1'b1};
                WDATA = ls_load_q ? 32'h0 : store_wdata;
            end
            S_BLOCK_ADDR: begin
                // Drive the address for the current register.
                ADDR  = block_curr_addr_q;
                TRANS = 2'(TRANS_N);
                WRITE = block_load_q ? WRITE_READ : WRITE_WRITE;
                SIZE  = 2'(SIZE_WORD);
                PROT  = {is_priv, 1'b1};
            end
            S_BLOCK_DATA: begin
                // Drive WDATA for STM (from regfile read port C, which is
                // routed to the current block register). LDM commits the
                // load through the regfile write port.
                ADDR  = block_curr_addr_q;
                TRANS = 2'(TRANS_I);
                WRITE = block_load_q ? WRITE_READ : WRITE_WRITE;
                SIZE  = 2'(SIZE_WORD);
                PROT  = {is_priv, 1'b1};
                WDATA = block_load_q ? 32'h0 : rf_rc_data;
            end
            S_SWP_RADDR: begin
                // SWP read phase: drive Rn address, LOCK asserted across
                // both read and write halves so no other master sneaks in.
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
                // SWP write phase
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

    assign DMORE = 1'b0;     // no LDM/STM yet

    // ---- Inputs / outputs not yet consumed at this milestone.
    //      cpsr[27:6] = reserved bits + I + F (interrupt masking is §14);
    //      alu_flag_we is unused because we drive a fixed _f-byte mask
    //      and gate writes by S+condition externally.
    //      Most of the decoded_t fields below are unused too — they
    //      describe classes whose execute paths haven't landed yet.
    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0,
        CFGBIGEND, nIRQ, nFIQ, ABORT,
        spsr_unused, spsr_valid_unused,
        cond_is_nv, dec_is_dataproc, rf_pc_written,
        alu_flag_we,
        cpsr[27:6],
        ls_data_addr_calc[31:12],         // high bits flow into ls_data_addr_q
        ls_store_data_q[31:8],            // only [7:0] used for byte store
        // dp_imm_value is the decoder's pre-rotated imm; the core feeds
        // the shifter raw imm8 and rotates there, so this field is dead.
        dec.dp_imm_value,
        // Decoder fields not yet routed to execute logic
        dec.mul_accumulate, dec.mul_signed,
        dec.hs_signed, dec.hs_halfword, dec.hs_use_imm, dec.hs_imm_offset,
        dec.psr_use_spsr, dec.msr_field_mask, dec.msr_use_imm,
        dec.swi_comment, dec.cp_num
    };
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
