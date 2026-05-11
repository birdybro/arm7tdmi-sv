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

    // ---- FSM state ----
    typedef enum logic [0:0] {
        S_FETCH   = 1'b0,
        S_EXECUTE = 1'b1
    } state_e;

    state_e       state_q;
    logic [31:0]  pc_q;

    // ---- PSR ----
    psr_t         cpsr;
    psr_t         spsr_unused;
    logic         spsr_valid_unused;
    logic         cpsr_write_en;
    logic [31:0]  cpsr_write_data;
    logic [3:0]   cpsr_write_mask;

    // cpsr_restore is for "exception return via data-processing": MOVS PC,
    // LR / SUBS PC, R14, #N etc. — when an S=1 DP instruction writes Rd=15,
    // CPSR is restored from the current-mode SPSR (TRM §2.9 / ARM ARM).
    // Computed below alongside writes_pc / writes_flags.
    logic cpsr_restore_now;

    arm7tdmis_psr u_psr (
        .CLK             (CLK),
        .CLKEN           (CLKEN),
        .nRESET          (nRESET),
        .cpsr            (cpsr),
        .spsr            (spsr_unused),
        .spsr_valid      (spsr_valid_unused),
        .cpsr_write_en   (cpsr_write_en),
        .cpsr_write_data (cpsr_write_data),
        .cpsr_write_mask (cpsr_write_mask),
        .spsr_write_en   (1'b0),
        .spsr_write_data (32'h0),
        .spsr_write_mask (4'h0),
        .cpsr_restore_en (cpsr_restore_now)
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

    arm7tdmis_regfile u_regfile (
        .CLK             (CLK),
        .CLKEN           (CLKEN),
        .nRESET          (nRESET),
        .mode            (cpsr.m),
        .t_bit           (cpsr.t),
        .pc_in           (pc_q),
        .ra_addr         (dec.rn),         // Rn → ALU op_a
        .rb_addr         (dec.rm),         // Rm → shifter input (DP-reg)
        .rc_addr         (dec.rs),         // Rs → shifter amount (DP-reg-reg)
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

    // ---- FSM transitions ----
    state_e state_next;

    always_comb begin
        unique case (state_q)
            S_FETCH:   state_next = S_EXECUTE;
            S_EXECUTE: state_next = S_FETCH;
            default:   state_next = S_FETCH;
        endcase
    end

    // ---- Writeback control. §9: every DP variant commits. Non-DP classes
    //      (LDR/STR, branch, multiply, ...) still execute as NOP until
    //      §10-§13 wire their paths. MOVS PC, LR (S=1 + Rd=15) restores
    //      CPSR from SPSR — the PSR module's restore path overrides any
    //      flag write from this same instruction.
    wire executing       = (state_q == S_EXECUTE);
    wire passes_cond     = executing && condition_pass && !dec_is_unimplemented;
    wire writes_dest     = passes_cond && !dec.is_test_op;
    wire writes_pc       = writes_dest && (dec.rd == 4'd15);
    wire writes_flags    = passes_cond && dec.s_bit;

    assign cpsr_restore_now = writes_pc && dec.s_bit;

    logic [3:0]  rf_write_addr;
    logic [31:0] rf_write_data;
    logic        rf_write_en;

    assign rf_write_addr = dec.rd;
    assign rf_write_data = alu_result;
    assign rf_write_en   = writes_dest;

    // CPSR flag update: only the _f byte (bits [31:24]) per the ALU
    // outputs. The S-bit + condition-pass gates are folded into write_flags.
    assign cpsr_write_en   = writes_flags;
    assign cpsr_write_data = {alu_n, alu_z, alu_c, alu_v, 28'h0};
    assign cpsr_write_mask = 4'b1000;

    // ---- Sequential state ----
    always_ff @(posedge CLK) begin
        if (CLKEN) begin
            if (!nRESET) begin
                state_q <= S_FETCH;
                pc_q    <= 32'h0;
            end else begin
                state_q <= state_next;

                // Advance PC at end of EXECUTE
                if (state_q == S_EXECUTE) begin
                    if (writes_pc) begin
                        pc_q <= alu_result;
                    end else begin
                        pc_q <= pc_q + 32'd4;
                    end
                end
            end
        end
    end

    // ---- Bus drive ----
    wire is_priv = (cpsr.m != 5'(MODE_USER));

    always_comb begin
        ADDR  = pc_q;
        WRITE = WRITE_READ;
        SIZE  = 2'(SIZE_WORD);
        PROT  = {is_priv, 1'b0};      // {priv, opcode_fetch}
        LOCK  = LOCK_FREE;
        WDATA = 32'h0;

        // Drive an active fetch only in S_FETCH; idle in S_EXECUTE.
        TRANS = (state_q == S_FETCH) ? 2'(TRANS_N) : 2'(TRANS_I);
    end

    assign DMORE = 1'b0;     // no LDM/STM yet

    // ---- Inputs / outputs not yet consumed at this milestone.
    //      cpsr[27:6] = reserved bits + I + F (interrupt masking is §14);
    //      alu_flag_we is unused because we drive a fixed _f-byte mask
    //      and gate writes by S+condition externally.
    //      Most of the decoded_t fields are unused too — they describe
    //      classes whose execute paths (§9-§13) haven't landed yet.
    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0,
        CFGBIGEND, nIRQ, nFIQ, ABORT,
        rf_rb_data, rf_rc_data,
        spsr_unused, spsr_valid_unused,
        cond_is_nv, dec_is_dataproc, rf_pc_written,
        alu_flag_we,
        cpsr[27:6],
        // Decoder fields not yet routed to execute logic
        dec.instr_class,
        dec.rs,
        dec.dp_use_imm, dec.dp_imm_value, dec.shifter_use_rs,
        dec.mul_accumulate, dec.mul_signed,
        dec.branch_link, dec.branch_offset,
        dec.ls_pre_index, dec.ls_up, dec.ls_byte, dec.ls_writeback,
        dec.ls_load, dec.ls_use_imm, dec.ls_imm_offset,
        dec.hs_signed, dec.hs_halfword, dec.hs_use_imm, dec.hs_imm_offset,
        dec.block_pre_index, dec.block_up, dec.block_user_mode,
        dec.block_writeback, dec.block_load, dec.block_reg_list,
        dec.psr_use_spsr, dec.msr_field_mask, dec.msr_use_imm,
        dec.swi_comment, dec.cp_num
    };
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
