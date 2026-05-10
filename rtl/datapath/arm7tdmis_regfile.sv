// 31-entry GPR bank with mode banking per TRM §2.7 / TASKS.md §3.
//
// Storage layout — flat 31-deep array; bank_index() maps (reg_num, mode) to
// the right slot:
//
//   [0..7]   r0..r7        always shared
//   [8..12]  r8..r12       User/System/IRQ/SVC/ABT/UND view (FIQ uses 16..20)
//   [13..14] r13_user, r14_user
//   [15]     r15 (PC)
//   [16..20] r8_fiq..r12_fiq
//   [21..22] r13_fiq, r14_fiq
//   [23..24] r13_irq, r14_irq
//   [25..26] r13_svc, r14_svc
//   [27..28] r13_abt, r14_abt
//   [29..30] r13_und, r14_und
//
// PC read offset: r15 reads return stored PC + (8 in ARM, 4 in Thumb), per
// TRM §2.4 / instr_pkg PC_AHEAD_*. The stored PC is the actual fetch
// address; the +offset reflects what software sees (two instructions ahead
// because of the prefetch pipeline).
//
// PC write: any write to r15 raises pc_written this cycle so the pipeline
// (§16) can flush + refill. PC update commits at the next clock edge.
//
// force_user_bank overrides the bank-select with User mode for both reads
// and writes. Used by LDM with the ^ flag (§11) to access the User register
// set from a privileged mode. Tie LOW for normal data-processing instructions.

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

    // Three read ports (Rn / Rm / Rs)
    input  logic [3:0]  ra_addr,
    input  logic [3:0]  rb_addr,
    input  logic [3:0]  rc_addr,
    output logic [31:0] ra_data,
    output logic [31:0] rb_data,
    output logic [31:0] rc_data,

    // Write port
    input  logic [3:0]  wa_addr,
    input  logic [31:0] wa_data,
    input  logic        wa_enable,

    // Force-User-bank read/write (LDM ^ flag in §11)
    input  logic        force_user_bank,

    // Raised when wa_enable && wa_addr==15. Pipeline flushes + refills.
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
            return regs[15] + pc_offset(t);
        end else begin
            return regs[bank_index(r, effective_mode)];
        end
    endfunction

    assign ra_data = read_with_offset(ra_addr, t_bit);
    assign rb_data = read_with_offset(rb_addr, t_bit);
    assign rc_data = read_with_offset(rc_addr, t_bit);

    // ---- Write port ----
    always_ff @(posedge CLK) begin
        if (CLKEN) begin
            if (!nRESET) begin
                for (int i = 0; i < 31; i = i + 1) regs[i] <= 32'h0;
            end else if (wa_enable) begin
                regs[bank_index(wa_addr, effective_mode)] <= wa_data;
            end
        end
    end

    assign pc_written = wa_enable && (wa_addr == 4'd15) && nRESET && CLKEN;

endmodule
