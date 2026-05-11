// CPSR + 5 banked SPSRs (FIQ/IRQ/SVC/ABT/UND), per TRM §2.8 / TASKS.md §3
// tasks 8 and 12. User and System modes share CPSR and have no SPSR.
//
// Reset: CPSR ← PSR_RESET_VALUE (Supervisor, I=1, F=1, T=0, ARM, flags 0,
// reserved 0). SPSRs reset to zero — architecturally undefined per the TRM,
// but a defined value keeps simulation deterministic.
//
// Write paths exposed today (§3 scope):
//   1. cpsr_write_en  — MSR-style field-masked write to CPSR. T-bit (bit 5)
//      is dropped from the byte mask per §30.8.3 / TRM §2.8.2 (programs
//      must not alter T via MSR; behavior is UNPREDICTABLE if they try, so
//      we suppress the write rather than honor it).
//   2. spsr_write_en  — same shape, targeting SPSR-of-current-mode.
//      Ignored in User/System modes (no SPSR to write).
//   3. cpsr_restore_en — exception return: CPSR ← SPSR-of-current-mode.
//      Ignored in User/System modes.
//
// Exception-entry paths (set CPSR full, save CPSR→SPSR_target_mode, etc.)
// land in §14 by extending this interface.
//
// MSR field mask follows the four-bit MSR encoding from instruction[19:16],
// passed in here as `{f, s, x, c}`:
//   bit 0 (_c): bits [7:0]   control + mode + I/F/T
//   bit 1 (_x): bits [15:8]  extension (RAZ/SBZP on r4p3)
//   bit 2 (_s): bits [23:16] status    (RAZ/SBZP on r4p3)
//   bit 3 (_f): bits [31:24] flags

module arm7tdmis_psr
    import arm7tdmis_psr_pkg::*;
    import arm7tdmis_types_pkg::*;
(
    input  logic        CLK,
    input  logic        CLKEN,
    input  logic        nRESET,

    // Outputs: CPSR + SPSR-of-current-mode (struct view) and validity bit
    output psr_t        cpsr,
    output psr_t        spsr,
    output logic        spsr_valid,

    // CPSR field-masked write (MSR target = CPSR)
    input  logic        cpsr_write_en,
    input  logic [31:0] cpsr_write_data,
    input  logic [3:0]  cpsr_write_mask,

    // SPSR-of-current-mode field-masked write (MSR target = SPSR)
    input  logic        spsr_write_en,
    input  logic [31:0] spsr_write_data,
    input  logic [3:0]  spsr_write_mask,

    // Restore CPSR ← SPSR-of-current-mode (exception return path)
    input  logic        cpsr_restore_en,

    // Architectural T-bit set from BX (ARM↔Thumb interworking). This path
    // bypasses the MSR T-drop policy in §30.8.3 because BX is the legal
    // way to change CPSR.T — and is the only way prior to ARMv5 where
    // BLX or load-to-PC don't exist.
    input  logic        bx_set_t_en,
    input  logic        bx_set_t_value
);

    // ---- Storage ----
    logic [31:0] cpsr_q;
    logic [31:0] spsr_q [0:4];

    // ---- Mode → SPSR-bank index ----
    function automatic logic [2:0] spsr_index(input logic [4:0] m);
        unique case (m)
            MODE_FIQ:        return 3'd0;
            MODE_IRQ:        return 3'd1;
            MODE_SUPERVISOR: return 3'd2;
            MODE_ABORT:      return 3'd3;
            MODE_UNDEFINED:  return 3'd4;
            default:         return 3'd0;
        endcase
    endfunction

    function automatic logic mode_has_spsr(input logic [4:0] m);
        unique case (m)
            MODE_FIQ, MODE_IRQ, MODE_SUPERVISOR, MODE_ABORT, MODE_UNDEFINED:
                return 1'b1;
            default:
                return 1'b0;
        endcase
    endfunction

    // ---- Field-mask expansion ----
    function automatic logic [31:0] expand_mask(input logic [3:0] fld);
        logic [31:0] m;
        m = '0;
        if (fld[0]) m |= PSR_MASK_C;
        if (fld[1]) m |= PSR_MASK_X;
        if (fld[2]) m |= PSR_MASK_S;
        if (fld[3]) m |= PSR_MASK_F;
        return m;
    endfunction

    // ---- Combinational outputs ----
    wire [4:0] cur_mode    = cpsr_q[4:0];
    wire [2:0] cur_spsr_ix = spsr_index(cur_mode);

    assign cpsr       = psr_t'(cpsr_q);
    assign spsr_valid = mode_has_spsr(cur_mode);
    assign spsr       = psr_t'(spsr_q[cur_spsr_ix]);

    // ---- Sequential update ----
    always_ff @(posedge CLK) begin
        logic [31:0] cpsr_mask;
        logic [31:0] spsr_mask;
        logic [31:0] cpsr_next;
        logic [31:0] spsr_next;

        if (CLKEN) begin
            if (!nRESET) begin
                cpsr_q    <= 32'(PSR_RESET_VALUE);
                spsr_q[0] <= 32'h0;
                spsr_q[1] <= 32'h0;
                spsr_q[2] <= 32'h0;
                spsr_q[3] <= 32'h0;
                spsr_q[4] <= 32'h0;
            end else begin
                cpsr_next = cpsr_q;

                // CPSR field-masked write — drop T (bit 5) per §30.8.3.
                if (cpsr_write_en) begin
                    cpsr_mask = expand_mask(cpsr_write_mask) & ~(32'h1 << PSR_BIT_T);
                    cpsr_next = (cpsr_next & ~cpsr_mask) |
                                (cpsr_write_data & cpsr_mask);
                end

                // Exception-return restore overrides the field write — if
                // the same cycle requests both, restore wins (matches the
                // architectural intent of MOVS/SUBS PC,...).
                if (cpsr_restore_en && mode_has_spsr(cur_mode)) begin
                    cpsr_next = spsr_q[cur_spsr_ix];
                end

                // BX writes CPSR.T explicitly (and only that bit). Applied
                // last so BX during exception return — which shouldn't
                // happen architecturally but is defined here — would let
                // BX dominate.
                if (bx_set_t_en) begin
                    cpsr_next[PSR_BIT_T] = bx_set_t_value;
                end

                cpsr_q <= cpsr_next;

                // SPSR field-masked write to current-mode SPSR.
                if (spsr_write_en && mode_has_spsr(cur_mode)) begin
                    spsr_mask = expand_mask(spsr_write_mask);
                    spsr_next = (spsr_q[cur_spsr_ix] & ~spsr_mask) |
                                (spsr_write_data & spsr_mask);
                    spsr_q[cur_spsr_ix] <= spsr_next;
                end
            end
        end
    end

endmodule
