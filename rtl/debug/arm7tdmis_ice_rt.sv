// EmbeddedICE-RT macrocell scaffold (TRM §5.14 / TASKS.md §22).
//
// At this milestone:
//   • Full register bank for both watchpoint units (WP0 + WP1) plus the
//     Debug Control / Debug Status / Vector Catch / DCC registers.
//   • Watchpoint comparators (address/data/control with XNOR+mask per
//     TRM §5.20.2 — common implementation bug is to use AND; we use
//     OR over (value XNOR input) OR mask).
//   • DBGBREAK_internal asserted on any enabled WP match.
//   • DBGRNG[1:0] outputs reflect each WP's address+control match
//     *independent* of the ENABLE bit (so trace observers can see
//     range hits without forcing debug entry — TRM §30.22.3).
//
// Deferred (lands when scan chain 2 wires in alongside the TAP):
//   • Register read/write through TAP scan chain 2.
//   • CHAIN / RANGE coupling between WP1 and WP0 (latch on chain out;
//     power-of-2 range comparison).
//   • Debug state machine (entry, halt-mode, monitor-mode, debug-state
//     instruction scan-in path).
//   • IFEN/INTDIS/force-DBGRQ/force-DBGACK interrupt-mask logic.
//   • CP14 DCC data/control register transfers (§20).
//
// Without scan chain 2, the registers stay at reset (all zero), which
// keeps ENABLE = 0 and watchpoints disabled. The module produces zero
// DBGBREAK output and zero DBGRNG until scan plumbing wires in.

module arm7tdmis_ice_rt (
    input  logic        CLK,
    input  logic        CLKEN,
    input  logic        DBGnTRST,        // active-low async reset of macrocell state
    input  logic        DBGEN,           // enable; gates DBGBREAK/DBGACK output

    // Bus signals being watched
    input  logic [31:0] watch_addr,
    input  logic [31:0] watch_data,      // RDATA for loads, WDATA for stores
    input  logic        watch_nopc,      // 0 = opcode fetch, 1 = data access
    input  logic        watch_nrw,       // 0 = read, 1 = write
    input  logic [1:0]  watch_size,
    input  logic        watch_tbit,
    input  logic [1:0]  watch_extern,
    input  logic        watch_priv,        // §22: PROT[1] for Debug Status[3]
    input  logic        dbg_rq_in,         // §22: external DBGRQ pin synced
                                            //      (used for Debug Status[1])    // DBGEXT[1:0] from outside

    // Outputs
    output logic        dbg_break_internal,
    output logic        dbg_ack,             // §22: forced via Debug Control[0],
                                              //      or set by debug state machine
                                              //      when the FSM lands.
    output logic        ifen,                 // §22: interrupt-enable gate.
                                              //      LOW masks IRQ/FIQ to core.
                                              //      Per TRM §30.22.6 derived
                                              //      from INTDIS (ctrl[2]) and
                                              //      DBGACKI (debug FSM signal).
    output logic [1:0]  DBGRNG,

    // Scan-chain-2 placeholder — currently tied off in the wrapper that
    // instantiates this module. When the TAP wiring lands, these become
    // read/write ports into the register bank.
    input  logic        scan_we,
    input  logic [4:0]  scan_addr,
    input  logic [37:0] scan_wdata,       // 38-bit chain: [37]=R/W, [36:32]=addr, [31:0]=data
    output logic [31:0] scan_rdata
);

    // ---- Register bank
    // Indexed by 5-bit address. Most are 32-bit; smaller ones (Debug
    // Control = 6 bits, Debug Status = 5 bits, Vector Catch = 8 bits)
    // get the upper bits SBZ.
    //
    // Address map (TRM Table 5-2 / §5.14.5):
    //   0x00: Debug Control     (6 bits used)
    //   0x01: Debug Status      (5 bits, read-only)
    //   0x02: Vector Catch      (8 bits)
    //   0x04: Debug Comms Data  (32 bits) — moved with §20 to CP14
    //   0x05: Debug Comms Ctrl  (2 bits)
    //   0x08-0x0F: WP0 (Addr Val, Addr Mask, Data Val, Data Mask,
    //              Ctrl Val, Ctrl Mask, reserved, reserved)
    //   0x10-0x17: WP1 (same shape)

    logic [31:0] regs [0:31];

    // Public names for the WP register subset (just the slots that drive
    // the comparators below — the wrapper sees the full bank via scan).
    localparam logic [4:0] WP0_ADDR_VAL  = 5'h08;
    localparam logic [4:0] WP0_ADDR_MASK = 5'h09;
    localparam logic [4:0] WP0_DATA_VAL  = 5'h0A;
    localparam logic [4:0] WP0_DATA_MASK = 5'h0B;
    localparam logic [4:0] WP0_CTRL_VAL  = 5'h0C;
    localparam logic [4:0] WP0_CTRL_MASK = 5'h0D;
    localparam logic [4:0] WP1_ADDR_VAL  = 5'h10;
    localparam logic [4:0] WP1_ADDR_MASK = 5'h11;
    localparam logic [4:0] WP1_DATA_VAL  = 5'h12;
    localparam logic [4:0] WP1_DATA_MASK = 5'h13;
    localparam logic [4:0] WP1_CTRL_VAL  = 5'h14;
    localparam logic [4:0] WP1_CTRL_MASK = 5'h15;

    // Async reset (DBGnTRST) per TRM. Synchronous write port for now.
    always_ff @(posedge CLK or negedge DBGnTRST) begin
        if (!DBGnTRST) begin
            for (int i = 0; i < 32; i = i + 1) regs[i] <= 32'h0;
        end else if (CLKEN && scan_we) begin
            regs[scan_addr] <= scan_wdata[31:0];
        end
    end

    // §30.22.5: Debug Status Register (addr 0x01) is read-only and
    // exposes live signals — TBIT, TRANS[1], IFEN, synced DBGRQ, synced
    // DBGACK. Override the regs[] read for this address so the debugger
    // sees current state rather than whatever was written.
    wire [4:0] dbg_status = {
        watch_tbit,         // [4] TBIT
        watch_priv,         // [3] TRANS[1] (privileged mode bit)
        ifen,               // [2] IFEN
        dbg_rq_in,          // [1] synced DBGRQ
        dbg_ack             // [0] synced DBGACK
    };
    assign scan_rdata = (scan_addr == 5'h01) ? {27'h0, dbg_status}
                                              : regs[scan_addr];

    // ---- Watchpoint comparator: XNOR-with-mask match (TRM §30.22.2).
    // match[i] = (value_i XNOR input_i) OR mask_i; full match = all bits set.
    // Mask bit = 1 ⇒ that position always matches; mask bit = 0 ⇒ exact.
    function automatic logic masked_match32(
        input logic [31:0] value,
        input logic [31:0] mask,
        input logic [31:0] in
    );
        return &((value ~^ in) | mask);
    endfunction

    // 9-bit control compare. Layout per TRM §5.18.2:
    //   [8] ENABLE      (unmaskable)
    //   [7] RANGE       (WP0 only — RANGEOUT from WP1)
    //   [6] CHAIN       (WP0 only — CHAINOUT from WP1)
    //   [5:4] EXTERN[1:0]
    //   [3] nTRANS      (effectively PROT[1])
    //   [2] nOPC
    //   [1] nRW
    //   [0] SIZE[1] / SIZE[0] split or combined depending on impl —
    //       here we treat [1:0] as the full 2-bit SIZE.
    // For this scaffold we compare nOPC, nRW, SIZE, EXTERN, TBIT. CHAIN
    // and RANGE lands with the coupling logic.
    // SIZE doesn't enter the 9-bit control compare directly (the
    // architectural size compare in EmbeddedICE-RT goes through ADDR[1:0]
    // mask bits instead) — we accept watch_size at the module port for
    // future use and silence its unused warning at the boundary.
    function automatic logic ctrl_match(
        input logic [8:0]  val,
        input logic [8:0]  mask,
        input logic        nopc_in,
        input logic        nrw_in,
        input logic [1:0]  extern_in,
        input logic        tbit_in
    );
        logic [8:0] in9;
        in9 = {1'b0,            // ENABLE bit position — input N/A
               2'b00,           // RANGE/CHAIN — wp coupling, not bus
               extern_in,
               1'b0,            // nTRANS placeholder
               nopc_in,
               nrw_in,
               tbit_in};
        return &((val ~^ in9) | mask);
    endfunction

    wire wp0_addr_match = masked_match32(regs[WP0_ADDR_VAL],  regs[WP0_ADDR_MASK],  watch_addr);
    wire wp0_data_match = masked_match32(regs[WP0_DATA_VAL],  regs[WP0_DATA_MASK],  watch_data);
    wire wp0_ctrl_match = ctrl_match(    regs[WP0_CTRL_VAL][8:0], regs[WP0_CTRL_MASK][8:0],
                                          watch_nopc, watch_nrw,
                                          watch_extern, watch_tbit);
    wire wp0_enable     = regs[WP0_CTRL_VAL][8];

    wire wp1_addr_match = masked_match32(regs[WP1_ADDR_VAL],  regs[WP1_ADDR_MASK],  watch_addr);
    wire wp1_data_match = masked_match32(regs[WP1_DATA_VAL],  regs[WP1_DATA_MASK],  watch_data);
    wire wp1_ctrl_match = ctrl_match(    regs[WP1_CTRL_VAL][8:0], regs[WP1_CTRL_MASK][8:0],
                                          watch_nopc, watch_nrw,
                                          watch_extern, watch_tbit);
    wire wp1_enable     = regs[WP1_CTRL_VAL][8];

    // DBGRNG reflects address+control matches *independent of ENABLE* per
    // §30.22.3 — useful for trace, doesn't gate debug entry.
    assign DBGRNG[0] = wp0_addr_match && wp0_ctrl_match;
    assign DBGRNG[1] = wp1_addr_match && wp1_ctrl_match;

    // Full match per WP. CHAIN / RANGE coupling not yet wired — when
    // enabled together both WP1's chainout latch and WP0's range input
    // qualify the WP0 match. For now treat each WP independently.
    wire wp0_full_match = wp0_addr_match && wp0_data_match && wp0_ctrl_match
                       && wp0_enable;
    wire wp1_full_match = wp1_addr_match && wp1_data_match && wp1_ctrl_match
                       && wp1_enable;

    // §30.22.1: DBGEN=0 forces all debug outputs LOW.
    assign dbg_break_internal = DBGEN && (wp0_full_match || wp1_full_match);

    // §30.22.6: DBGACK_pin = ICE_control[0] OR DBGACKI (from debug state
    // machine). DBGACKI comes in when the FSM lands; for now the
    // OR-with-zero collapses to just the forced-DBGACK control bit.
    // Index 0x00 is the Debug Control register.
    wire ice_dbg_ack_forced = regs[5'h00][0];
    assign dbg_ack = DBGEN && ice_dbg_ack_forced;

    // §30.22.6: IFEN_to_core = !((INTDIS) | DBGACKI). INTDIS is
    // Debug Control bit 2. Without the debug FSM the DBGACKI term is 0,
    // so IFEN is simply !INTDIS. DBGEN=0 disables the entire macrocell
    // so IFEN reverts to "interrupts enabled" — which matches the
    // pass-through behavior we want when debug is off.
    wire ice_intdis = regs[5'h00][2];
    assign ifen = !(DBGEN && ice_intdis);

    // Scan chain 2 upper bits (R/W flag + 5-bit addr field), DBGEN gating
    // outside the macrocell, and SIZE field (size_in not yet folded into
    // the 9-bit ctrl compare) all silenced here until they have consumers.
    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, scan_wdata[37:32], watch_size};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
