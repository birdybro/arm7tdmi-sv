// JTAG TAP controller (IEEE 1149.1, ARM7TDMI-S r4p3 TRM §5.13).
//
// 16-state TAP machine driven by DBGTMS on rising DBGTCK. The on-chip
// variant we implement uses DBGTCKEN as an enable on CLK rather than a
// separate TCK domain — this matches the embedded-test path in §30.23.9
// where the off-chip Multi-ICE synchronizer is deferred to a later milestone.
//
// IR is 4 bits; valid public opcodes per debug_pkg are SCAN_N, RESTART,
// INTEST, IDCODE, BYPASS. All other encodings BYPASS per IEEE 1149.1 default.
//
// DR mux for this scaffold:
//   IDCODE  → 32-bit shift register seeded with IDCODE_VALUE at Capture-DR
//   BYPASS  → 1-bit shift register
//   SCAN_N  → 4-bit shift register (selects which scan chain — chain RTL
//             lands with §22/§30.23.5)
//   INTEST  → BYPASS for now (chain 1 wiring is §22)
//   RESTART → BYPASS-shaped 1-bit, but UPDATE-DR exits debug state (§22)
//
// Reset: DBGnTRST forces the TAP to Test-Logic-Reset asynchronously per
// IEEE 1149.1 §6.1. IR is loaded with IDCODE on reset (the standard
// "post-reset captures IDCODE" behavior).

module arm7tdmis_jtag_tap
    import arm7tdmis_debug_pkg::*;
(
    input  logic        CLK,
    input  logic        DBGTCKEN,        // gates each TAP clock event
    input  logic        DBGnTRST,        // active-low async reset of TAP
    input  logic        DBGTMS,
    input  logic        DBGTDI,
    output logic        DBGTDO,
    output logic        DBGnTDOEN,       // HiZ envelope: low while shifting

    // Exposed for §22 EmbeddedICE-RT and scan plumbing
    output ir_e         current_ir,
    output logic        in_shift_dr,
    output logic        in_update_dr,
    output logic        in_capture_dr
);

    // ---- 16-state TAP state encoding (IEEE 1149.1 §6.1)
    typedef enum logic [3:0] {
        TLR    = 4'h0,   // Test-Logic-Reset
        RTI    = 4'h1,   // Run-Test/Idle
        SDRS   = 4'h2,   // Select-DR-Scan
        CDR    = 4'h3,   // Capture-DR
        SDR    = 4'h4,   // Shift-DR
        E1DR   = 4'h5,   // Exit1-DR
        PDR    = 4'h6,   // Pause-DR
        E2DR   = 4'h7,   // Exit2-DR
        UDR    = 4'h8,   // Update-DR
        SIRS   = 4'h9,   // Select-IR-Scan
        CIR    = 4'hA,   // Capture-IR
        SIR    = 4'hB,   // Shift-IR
        E1IR   = 4'hC,   // Exit1-IR
        PIR    = 4'hD,   // Pause-IR
        E2IR   = 4'hE,   // Exit2-IR
        UIR    = 4'hF    // Update-IR
    } tap_state_e;

    tap_state_e tap_q;

    // ---- State transition (standard JTAG table)
    function automatic tap_state_e next_state(input tap_state_e s,
                                              input logic       tms);
        unique case (s)
            TLR:    return tms ? TLR  : RTI;
            RTI:    return tms ? SDRS : RTI;
            SDRS:   return tms ? SIRS : CDR;
            CDR:    return tms ? E1DR : SDR;
            SDR:    return tms ? E1DR : SDR;
            E1DR:   return tms ? UDR  : PDR;
            PDR:    return tms ? E2DR : PDR;
            E2DR:   return tms ? UDR  : SDR;
            UDR:    return tms ? SDRS : RTI;
            SIRS:   return tms ? TLR  : CIR;
            CIR:    return tms ? E1IR : SIR;
            SIR:    return tms ? E1IR : SIR;
            E1IR:   return tms ? UIR  : PIR;
            PIR:    return tms ? E2IR : PIR;
            E2IR:   return tms ? UIR  : SIR;
            UIR:    return tms ? SDRS : RTI;
            default: return TLR;
        endcase
    endfunction

    // ---- IR shift register + held value ----
    logic [IR_WIDTH-1:0] ir_shift_q;
    logic [IR_WIDTH-1:0] ir_hold_q;       // committed at Update-IR

    // ---- DR shift register (32-bit; sized for IDCODE, BYPASS uses bit 0)
    logic [31:0] dr_shift_q;

    // ---- TAP sequential. Async DBGnTRST per IEEE 1149.1.
    always_ff @(posedge CLK or negedge DBGnTRST) begin
        if (!DBGnTRST) begin
            tap_q      <= TLR;
            ir_hold_q  <= 4'(IR_IDCODE);   // post-reset latches IDCODE
            ir_shift_q <= 4'b0;
            dr_shift_q <= 32'h0;
        end else if (DBGTCKEN) begin
            tap_q <= next_state(tap_q, DBGTMS);

            // Test-Logic-Reset force-loads IR with IDCODE per spec.
            if (next_state(tap_q, DBGTMS) == TLR) begin
                ir_hold_q <= 4'(IR_IDCODE);
            end

            // ---- IR path
            unique case (tap_q)
                CIR: ir_shift_q <= 4'(IR_CAPTURE_PATTERN);
                SIR: ir_shift_q <= {DBGTDI, ir_shift_q[IR_WIDTH-1:1]};
                UIR: ir_hold_q  <= ir_shift_q;
                default: ;
            endcase

            // ---- DR path. Mux on the held IR.
            unique case (tap_q)
                CDR: begin
                    // Seed the shift register with the selected DR.
                    unique case (ir_hold_q)
                        4'(IR_IDCODE): dr_shift_q <= IDCODE_VALUE;
                        4'(IR_BYPASS): dr_shift_q <= 32'h0;     // single bit 0
                        4'(IR_SCAN_N): dr_shift_q <= 32'h0;
                        default:       dr_shift_q <= 32'h0;
                    endcase
                end
                SDR: begin
                    // Shift LSB-first toward TDO; new TDI shifts in MSB-side.
                    // BYPASS path is a single bit but the standard requires
                    // shifting through bit 0 with the rest of the register
                    // held at 0.
                    unique case (ir_hold_q)
                        4'(IR_IDCODE):
                            dr_shift_q <= {DBGTDI, dr_shift_q[31:1]};
                        4'(IR_BYPASS), 4'(IR_SCAN_N):
                            dr_shift_q <= {31'h0, DBGTDI};
                        default:
                            dr_shift_q <= {31'h0, DBGTDI};
                    endcase
                end
                default: ;
            endcase
        end
    end

    // ---- TDO drive. Per IEEE 1149.1 the TDO is updated on the falling
    // edge of TCK; we model it combinationally and the downstream consumer
    // sees the value during the cycle following the rising edge that
    // sampled TDI. nTDOEN gates the external pad HiZ when not shifting.
    //   Shift-IR : TDO = LSB of IR shift register
    //   Shift-DR : TDO = LSB of DR shift register
    //   else     : TDO drive is don't-care (DBGnTDOEN HIGH)
    assign DBGTDO    = (tap_q == SIR) ? ir_shift_q[0] : dr_shift_q[0];
    assign DBGnTDOEN = !((tap_q == SDR) || (tap_q == SIR));

    // ---- Public state observers (for §22 EmbeddedICE-RT etc.)
    assign current_ir    = ir_e'(ir_hold_q);
    assign in_shift_dr   = (tap_q == SDR);
    assign in_update_dr  = (tap_q == UDR);
    assign in_capture_dr = (tap_q == CDR);

endmodule
