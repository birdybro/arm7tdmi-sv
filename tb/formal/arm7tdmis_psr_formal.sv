// VAL-007 CPSR/SPSR flag-preservation and mode-isolation proof harness.

module arm7tdmis_psr_formal
    import arm7tdmis_psr_pkg::*, arm7tdmis_types_pkg::*;
(
    input logic        CLK,
    input logic        CLKEN,
    input logic        cpsr_write_en,
    input logic [31:0] cpsr_write_data,
    input logic [3:0]  cpsr_write_mask,
    input logic        spsr_write_en,
    input logic [31:0] spsr_write_data,
    input logic [3:0]  spsr_write_mask,
    input logic        cpsr_restore_en,
    input logic        bx_set_t_en,
    input logic        bx_set_t_value,
    input logic        exc_enter_en,
    input logic [2:0]  exc_target_spsr_idx,
    input psr_t        exc_new_cpsr
);
    logic [2:0] f_cycle = 3'd0;
    logic       f_past_valid = 1'b0;
    wire        nRESET = (f_cycle != 3'd0);
    psr_t       cpsr;
    psr_t       spsr;
    logic       spsr_valid;
    logic [31:0] VER_CPSR;
    logic [159:0] VER_SPSRS;

    arm7tdmis_psr dut (
        .CLK,
        .CLKEN,
        .nRESET,
        .cpsr,
        .spsr,
        .spsr_valid,
        .cpsr_write_en,
        .cpsr_write_data,
        .cpsr_write_mask,
        .spsr_write_en,
        .spsr_write_data,
        .spsr_write_mask,
        .cpsr_restore_en,
        .bx_set_t_en,
        .bx_set_t_value,
        .exc_enter_en,
        .exc_target_spsr_idx,
        .exc_new_cpsr,
        .VER_CPSR,
        .VER_SPSRS
    );

    function automatic logic mode_valid(input logic [4:0] value);
        case (value)
            5'(MODE_USER), 5'(MODE_FIQ), 5'(MODE_IRQ),
            5'(MODE_SUPERVISOR), 5'(MODE_ABORT),
            5'(MODE_UNDEFINED), 5'(MODE_SYSTEM):
                return 1'b1;
            default:
                return 1'b0;
        endcase
    endfunction

    always_ff @(posedge CLK) begin
        f_past_valid <= 1'b1;
        if (f_cycle != 3'h7)
            f_cycle <= f_cycle + 3'd1;
        if (exc_enter_en) begin
            assume (mode_valid(exc_new_cpsr.m));
            assume (exc_target_spsr_idx < 3'd5);
        end

        if (nRESET) begin
            assert (mode_valid(cpsr.m));
            assert (spsr_valid == (
                (cpsr.m != 5'(MODE_USER))
                && (cpsr.m != 5'(MODE_SYSTEM))
            ));
        end
        if (f_past_valid && $past(nRESET)) begin
            if (!$past(CLKEN))
                assert ({VER_CPSR, VER_SPSRS}
                        == $past({VER_CPSR, VER_SPSRS}));
            if ($past(CLKEN)
                && !$past(exc_enter_en)
                && !$past(cpsr_restore_en)
                && !($past(cpsr_write_en)
                     && $past(cpsr_write_mask[3]))) begin
                assert (VER_CPSR[31:28] == $past(VER_CPSR[31:28]));
            end
            if ($past(CLKEN && spsr_write_en)
                && !$past(spsr_valid)
                && !$past(exc_enter_en)) begin
                assert (VER_SPSRS == $past(VER_SPSRS));
            end
        end
    end
endmodule
