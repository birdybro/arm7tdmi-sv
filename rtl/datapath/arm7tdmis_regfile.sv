// 31-entry GPR bank with mode banking per TRM §2.7 / TASKS.md §3.
//
// PC (r15) does NOT live in this module — it's owned by the integrating
// core, which feeds its current value in via `pc_in`. Rationale: the
// regfile has one write port; the core's writeback path is busy with the
// instruction's Rd. If r15 were stored here, advancing PC on every
// instruction would conflict with Rd writes for non-r15 destinations.
// Keeping PC in the core lets `pc_q` advance independently while the
// regfile write port commits Rd.
//
// Regfile responsibilities for r15:
//   - Reads of reg_num=15 return `pc_in + offset` (8 in ARM, 4 in Thumb)
//     — that's what software sees, two instructions ahead of the actual
//     fetch address.
//   - Writes with wa_addr=15 are NOT applied to internal storage; the
//     `pc_written` output signals the core that this instruction wants
//     to update PC, and the core updates its `pc_q` from `wa_data`.
//
// Storage layout for r0..r14 (with banking) is unchanged from §3:
//
//   [0..7]   r0..r7        always shared
//   [8..12]  r8..r12       User/System/IRQ/SVC/ABT/UND view (FIQ uses 16..20)
//   [13..14] r13_user, r14_user
//   [15]     unused        (was r15 — now in core; entry kept to avoid
//                           reindexing bank_index)
//   [16..20] r8_fiq..r12_fiq
//   [21..22] r13_fiq, r14_fiq
//   [23..24] r13_irq, r14_irq
//   [25..26] r13_svc, r14_svc
//   [27..28] r13_abt, r14_abt
//   [29..30] r13_und, r14_und

module arm7tdmis_regfile
    import arm7tdmis_types_pkg::*;
    import arm7tdmis_instr_pkg::*;
(
    input  logic        CLK,
    input  logic        CLKEN,
    input  logic        nRESET,

    // Mode + state from CPSR (drives banking and r15 read offset)
    input  logic [4:0]  mode,
    input  logic        t_bit,

    // Live PC value from the core, used for r15 reads
    input  logic [31:0] pc_in,

    // Three read ports (Rn / Rm / Rs)
    input  logic [3:0]  ra_addr,
    input  logic [3:0]  rb_addr,
    input  logic [3:0]  rc_addr,
    output logic [31:0] ra_data,
    output logic [31:0] rb_data,
    output logic [31:0] rc_data,

    // Write port (commits Rd; r15 writes go to pc_written / pc_data
    // for the core to consume rather than to internal storage)
    input  logic [3:0]  wa_addr,
    input  logic [31:0] wa_data,
    input  logic        wa_enable,

    // Force-User-bank read/write (LDM ^ flag in §11)
    input  logic        force_user_bank,

    // Raised when wa_enable && wa_addr==15 — instruction wants to write PC.
    output logic        pc_written
);

    logic [31:0] regs [0:30];

    // ---- Bank index: (reg_num, mode) → flat-array index ----
    function automatic logic [4:0] bank_index(
        input logic [3:0] r,
        input logic [4:0] m
    );
        if (r <= 4'd7 || r == 4'd15) begin
            return {1'b0, r};
        end
        if (r >= 4'd8 && r <= 4'd12) begin
            return (m == MODE_FIQ) ? (5'(r) + 5'd8) : 5'(r);
        end
        // r13 / r14
        unique case (m)
            MODE_USER, MODE_SYSTEM: return 5'(r);
            MODE_FIQ:               return 5'(r) + 5'd8;
            MODE_IRQ:               return 5'(r) + 5'd10;
            MODE_SUPERVISOR:        return 5'(r) + 5'd12;
            MODE_ABORT:             return 5'(r) + 5'd14;
            MODE_UNDEFINED:         return 5'(r) + 5'd16;
            default:                return 5'(r);
        endcase
    endfunction

    wire [4:0] effective_mode = force_user_bank ? 5'(MODE_USER) : mode;

    // ---- Read paths with PC offset ----
    function automatic logic [31:0] pc_offset(input logic t);
        return t ? PC_AHEAD_THUMB : PC_AHEAD_ARM;
    endfunction

    function automatic logic [31:0] read_with_offset(
        input logic [3:0] r,
        input logic       t
    );
        if (r == 4'd15) begin
            return pc_in + pc_offset(t);
        end else begin
            return regs[bank_index(r, effective_mode)];
        end
    endfunction

    assign ra_data = read_with_offset(ra_addr, t_bit);
    assign rb_data = read_with_offset(rb_addr, t_bit);
    assign rc_data = read_with_offset(rc_addr, t_bit);

    // ---- Write port (suppressed for wa_addr=15 — PC lives in core) ----
    always_ff @(posedge CLK) begin
        if (!nRESET) begin
            for (int i = 0; i < 31; i = i + 1) regs[i] <= 32'h0;
        end else if (CLKEN) begin
            if (wa_enable && wa_addr != 4'd15) begin
                regs[bank_index(wa_addr, effective_mode)] <= wa_data;
            end
        end
    end

    assign pc_written = wa_enable && (wa_addr == 4'd15) && nRESET && CLKEN;

    // Slot 15 is reserved by the bank layout but never read (r15 reads use
    // pc_in) and never written (suppressed above). Drain it into a no-op
    // so the linter doesn't flag the dead storage.
    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused_slot15 = &{1'b0, regs[15]};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
