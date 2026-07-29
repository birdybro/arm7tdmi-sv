// VAL-007 physical-bank isolation and write-enable proof harness.

module arm7tdmis_regfile_formal
    import arm7tdmis_types_pkg::*, arm7tdmis_instr_pkg::*;
(
    input logic        CLK,
    input logic        CLKEN,
    input logic [4:0]  mode,
    input logic        t_bit,
    input logic [31:0] pc_in,
    input logic [3:0]  ra_addr,
    input logic [3:0]  rb_addr,
    input logic [3:0]  rc_addr,
    input logic [3:0]  wa_addr,
    input logic [31:0] wa_data,
    input logic        wa_enable,
    input logic        force_user_bank,
    input logic        dbg_we,
    input logic [3:0]  dbg_addr,
    input logic [31:0] dbg_wdata,
    input logic        dbg_force_user_bank
);
    logic [2:0] f_cycle = 3'd0;
    logic       f_past_valid = 1'b0;
    wire        nRESET = (f_cycle != 3'd0);
    logic [31:0] ra_data;
    logic [31:0] rb_data;
    logic [31:0] rc_data;
    logic [31:0] dbg_rdata;
    logic        pc_written;
    logic [991:0] VER_GPRS;

    arm7tdmis_regfile dut (
        .CLK,
        .CLKEN,
        .nRESET,
        .mode,
        .t_bit,
        .pc_in,
        .ra_addr,
        .rb_addr,
        .rc_addr,
        .ra_data,
        .rb_data,
        .rc_data,
        .wa_addr,
        .wa_data,
        .wa_enable,
        .force_user_bank,
        .dbg_we,
        .dbg_addr,
        .dbg_wdata,
        .dbg_force_user_bank,
        .dbg_rdata,
        .pc_written,
        .VER_GPRS
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

    function automatic logic [4:0] physical_index(
        input logic [3:0] address,
        input logic [4:0] selected_mode
    );
        if (address <= 4'd7 || address == 4'd15)
            return {1'b0, address};
        if (address <= 4'd12)
            return (selected_mode == 5'(MODE_FIQ))
                 ? (5'(address) + 5'd8) : 5'(address);
        case (selected_mode)
            5'(MODE_USER), 5'(MODE_SYSTEM): return 5'(address);
            5'(MODE_FIQ):        return 5'(address) + 5'd8;
            5'(MODE_IRQ):        return 5'(address) + 5'd10;
            5'(MODE_SUPERVISOR): return 5'(address) + 5'd12;
            5'(MODE_ABORT):      return 5'(address) + 5'd14;
            5'(MODE_UNDEFINED):  return 5'(address) + 5'd16;
            default:             return 5'(address);
        endcase
    endfunction

    wire [4:0] normal_mode = force_user_bank ? 5'(MODE_USER) : mode;
    wire [4:0] normal_index = physical_index(wa_addr, normal_mode);
    wire [4:0] debug_mode = dbg_force_user_bank ? 5'(MODE_USER) : mode;
    wire [4:0] debug_index = physical_index(dbg_addr, debug_mode);

    always_ff @(posedge CLK) begin
        f_past_valid <= 1'b1;
        if (f_cycle != 3'h7)
            f_cycle <= f_cycle + 3'd1;
        assume (mode_valid(mode));

        if (nRESET) begin
            assert (dut.regs[15] == 32'h0000_0000);
            assert (pc_written
                    == (wa_enable && (wa_addr == 4'd15) && CLKEN));
            if (ra_addr == 4'd15)
                assert (ra_data == pc_in
                        + (t_bit ? PC_AHEAD_THUMB : PC_AHEAD_ARM));
        end

        if (f_past_valid && $past(nRESET)) begin
            if (!$past(dbg_we)
                && (!$past(CLKEN) || !$past(wa_enable)
                    || ($past(wa_addr) == 4'd15))) begin
                assert (VER_GPRS == $past(VER_GPRS));
            end
            for (int index = 0; index < 31; index = index + 1) begin
                if ($past(dbg_we) && ($past(dbg_addr) != 4'd15)) begin
                    if (index != $past(debug_index))
                        assert (
                            VER_GPRS[index * 32 +: 32]
                            == $past(VER_GPRS[index * 32 +: 32])
                        );
                end else if ($past(CLKEN && wa_enable)
                             && ($past(wa_addr) != 4'd15)
                             && (index != $past(normal_index))) begin
                    assert (
                        VER_GPRS[index * 32 +: 32]
                        == $past(VER_GPRS[index * 32 +: 32])
                    );
                end
            end
        end
    end
endmodule
