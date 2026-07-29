// VAL-007 exhaustive IEEE 1149.1 TAP-transition proof harness.

module arm7tdmis_jtag_formal
    import arm7tdmis_debug_pkg::*;
(
    input logic        CLK,
    input logic        DBGTCKEN,
    input logic        DBGTMS,
    input logic        DBGTDI,
    input logic [31:0] ice_scan_rdata,
    input logic [4:0]  ice_scan_raddr,
    input logic [31:0] ice_chain1_capture_data,
    input logic        ice_chain1_capture_break
);
    logic [2:0] f_cycle = 3'd0;
    logic       f_past_valid = 1'b0;
    wire        DBGnTRST = (f_cycle != 3'd0);
    logic       DBGTDO;
    logic       DBGnTDOEN;
    ir_e        current_ir;
    logic       in_shift_dr;
    logic       in_update_dr;
    logic       in_capture_dr;
    logic       tap_run_idle;
    logic [4:0] ice_scan_addr;
    logic [37:0] ice_scan_wdata;
    logic       ice_scan_we;
    logic       ice_scan_re;
    logic       ice_chain1_capture;
    logic [31:0] ice_inject_instr;
    logic       ice_inject_break;
    logic       ice_inject_we;
    logic       tap_restart_req;

    arm7tdmis_jtag_tap dut (
        .CLK,
        .DBGTCKEN,
        .DBGnTRST,
        .DBGTMS,
        .DBGTDI,
        .DBGTDO,
        .DBGnTDOEN,
        .current_ir,
        .in_shift_dr,
        .in_update_dr,
        .in_capture_dr,
        .tap_run_idle,
        .ice_scan_addr,
        .ice_scan_wdata,
        .ice_scan_we,
        .ice_scan_re,
        .ice_scan_rdata,
        .ice_scan_raddr,
        .ice_chain1_capture_data,
        .ice_chain1_capture_break,
        .ice_chain1_capture,
        .ice_inject_instr,
        .ice_inject_break,
        .ice_inject_we,
        .tap_restart_req
    );

    function automatic logic [3:0] expected_next(
        input logic [3:0] state,
        input logic tms
    );
        case (state)
            4'h0: return tms ? 4'h0 : 4'h1;
            4'h1: return tms ? 4'h2 : 4'h1;
            4'h2: return tms ? 4'h9 : 4'h3;
            4'h3: return tms ? 4'h5 : 4'h4;
            4'h4: return tms ? 4'h5 : 4'h4;
            4'h5: return tms ? 4'h8 : 4'h6;
            4'h6: return tms ? 4'h7 : 4'h6;
            4'h7: return tms ? 4'h8 : 4'h4;
            4'h8: return tms ? 4'h2 : 4'h1;
            4'h9: return tms ? 4'h0 : 4'hA;
            4'hA: return tms ? 4'hC : 4'hB;
            4'hB: return tms ? 4'hC : 4'hB;
            4'hC: return tms ? 4'hF : 4'hD;
            4'hD: return tms ? 4'hE : 4'hD;
            4'hE: return tms ? 4'hF : 4'hB;
            4'hF: return tms ? 4'h2 : 4'h1;
            default: return 4'h0;
        endcase
    endfunction

    always_ff @(posedge CLK) begin
        f_past_valid <= 1'b1;
        if (f_cycle != 3'h7)
            f_cycle <= f_cycle + 3'd1;
        if (DBGnTRST) begin
            assert (DBGnTDOEN
                    == !((dut.tap_q == 4'h4) || (dut.tap_q == 4'hB)));
        end
        if (f_past_valid) begin
            if (!$past(DBGnTRST)) begin
                assert (dut.tap_q == 4'h0);
                assert (current_ir == IR_IDCODE);
            end else if ($past(DBGTCKEN)) begin
                assert (dut.tap_q
                        == expected_next($past(dut.tap_q), $past(DBGTMS)));
            end else begin
                assert (dut.tap_q == $past(dut.tap_q));
            end
        end
    end
endmodule
