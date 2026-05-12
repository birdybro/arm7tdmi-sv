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
    output logic        in_capture_dr,

    // ---- Scan chain 2 (38-bit) — EmbeddedICE-RT register access.
    // Active when held IR == INTEST AND scan_n_q == 2. The 38-bit data
    // is [37]=R/W, [36:32]=addr, [31:0]=data per TRM §30.23.5.
    output logic [4:0]  ice_scan_addr,    // valid every cycle (= dr_shift_q[36:32])
    output logic [37:0] ice_scan_wdata,
    output logic        ice_scan_we,      // pulse high on Update-DR when chain 2 active and R/W=1
    input  logic [31:0] ice_scan_rdata,   // captured at Capture-DR

    // ---- Scan chain 1 (33-bit) — debug instruction injection.
    // Held register, written when held IR == INTEST AND scan_n_q == 1
    // at Update-DR. Layout per TRM §30.23.6:
    //   [32]    DBGBREAK control cell (debug-speed vs system-speed)
    //   [31:0]  Instruction to inject
    output logic [31:0] ice_inject_instr,
    output logic        ice_inject_break,
    output logic        ice_inject_we,    // pulse high on Update-DR when chain 1 active

    // §22 debug-state exit: pulses HIGH on Update-IR when IR=RESTART
    output logic        tap_restart_req
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

    // ---- DR shift register (38-bit; sized for scan chain 2. IDCODE and
    // BYPASS use the low 32 / 1 bits respectively; the upper bits stay at
    // 0 for those instructions.
    logic [37:0] dr_shift_q;

    // ---- Scan chain selector (4-bit, set via IR=SCAN_N). Chain numbers
    // per TRM §30.23.5: 0 reserved, 1 = 33-bit (instruction/data + break),
    // 2 = 38-bit (EmbeddedICE-RT register access). Default 0 at reset.
    logic [3:0]  scan_n_q;

    // ---- TAP sequential. Async DBGnTRST per IEEE 1149.1.
    always_ff @(posedge CLK or negedge DBGnTRST) begin
        if (!DBGnTRST) begin
            tap_q      <= TLR;
            ir_hold_q  <= 4'(IR_IDCODE);   // post-reset latches IDCODE
            ir_shift_q <= 4'b0;
            dr_shift_q <= 38'h0;
            scan_n_q   <= 4'h0;
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
                        4'(IR_IDCODE): dr_shift_q <= {6'h0, IDCODE_VALUE};
                        4'(IR_BYPASS): dr_shift_q <= 38'h0;
                        4'(IR_SCAN_N): dr_shift_q <= 38'h0;
                        4'(IR_INTEST): begin
                            // Capture current chain state. For chain 2, that's
                            // the addressed ICE-RT register (with R/W bit and
                            // addr bits below it indeterminate — capture as 0).
                            if (scan_n_q == 4'd2)
                                dr_shift_q <= {6'h0, ice_scan_rdata};
                            else
                                dr_shift_q <= 38'h0;
                        end
                        default:       dr_shift_q <= 38'h0;
                    endcase
                end
                SDR: begin
                    // Shift LSB-first toward TDO; TDI enters at the high bit
                    // of the active width.
                    //   IDCODE  : 32-bit width — shift positions [31:1]
                    //   BYPASS  : 1-bit — single bit through position 0
                    //   SCAN_N  : 4-bit — shift through bits [3:0]
                    //   INTEST chain 2: 38-bit — full width
                    unique case (ir_hold_q)
                        4'(IR_IDCODE):
                            dr_shift_q <= {6'h0, DBGTDI, dr_shift_q[31:1]};
                        4'(IR_BYPASS):
                            dr_shift_q <= {37'h0, DBGTDI};
                        4'(IR_SCAN_N):
                            dr_shift_q <= {34'h0, DBGTDI, dr_shift_q[3:1]};
                        4'(IR_INTEST): begin
                            unique case (scan_n_q)
                                4'd2:    dr_shift_q <= {DBGTDI, dr_shift_q[37:1]};
                                4'd1:    dr_shift_q <= {5'h0, DBGTDI, dr_shift_q[32:1]};
                                default: dr_shift_q <= {37'h0, DBGTDI};
                            endcase
                        end
                        default:
                            dr_shift_q <= {37'h0, DBGTDI};
                    endcase
                end
                UDR: begin
                    // Update-DR commits the shift register to the target.
                    // For IR=SCAN_N, the low 4 bits become the new chain
                    // selector. For IR=INTEST with chain 2 and the R/W bit
                    // set, an ICE-RT register write fires (handled
                    // combinationally via ice_scan_we below).
                    if (ir_hold_q == 4'(IR_SCAN_N))
                        scan_n_q <= dr_shift_q[3:0];
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

    // ---- Chain 2 outputs to the ICE-RT module.
    assign ice_scan_addr  = dr_shift_q[36:32];
    assign ice_scan_wdata = dr_shift_q;
    assign ice_scan_we    = DBGTCKEN
                         && (tap_q == UDR)
                         && (ir_hold_q == 4'(IR_INTEST))
                         && (scan_n_q == 4'd2)
                         && dr_shift_q[37];      // R/W=1 (write)

    // ---- Chain 1 outputs to the debug-state instruction-inject path.
    assign ice_inject_instr = dr_shift_q[31:0];
    assign ice_inject_break = dr_shift_q[32];
    assign ice_inject_we    = DBGTCKEN
                           && (tap_q == UDR)
                           && (ir_hold_q == 4'(IR_INTEST))
                           && (scan_n_q == 4'd1);

    // RESTART pulse: when the TAP latches IR=RESTART at Update-IR, signal
    // the ICE-RT FSM to exit halt. Re-asserts each time the user re-issues
    // RESTART; ICE-RT FSM takes the rising edge.
    assign tap_restart_req = DBGTCKEN
                          && (tap_q == UIR)
                          && (ir_shift_q == 4'(IR_RESTART));

endmodule
