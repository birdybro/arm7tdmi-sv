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

module arm7tdmis_ice_rt
    import arm7tdmis_debug_pkg::*;
(
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
                                            //      (used for Debug Status[1])
    input  logic        dbg_break_in,      // §22: external DBGBREAK pin
    input  logic        tap_restart_req,   // §22: TAP RESTART instruction
                                            //      pulse (Update-IR with
                                            //      IR_RESTART loaded)

    // §20: CP14 DCC data path from/to the core. core_dcc_we/data writes
    // the DCC Data register (addr 0x04) from the core side (MCR p14 c0);
    // core_dcc_rd_data exposes the register for the core to read on
    // MRC p14 c0.
    input  logic        core_dcc_we,
    input  logic [31:0] core_dcc_wdata,
    output logic [31:0] core_dcc_rdata,

    // Outputs
    output logic        dbg_break_internal,
    output logic        dbg_ack,             // §22: forced via Debug Control[0],
                                              //      OR set when the debug-state
                                              //      FSM is in HALTED.
    output logic        ifen,                 // §22: interrupt-enable gate.
                                              //      LOW masks IRQ/FIQ to core.
                                              //      Per TRM §30.22.6 derived
                                              //      from INTDIS (ctrl[2]) and
                                              //      DBGACKI (debug FSM signal).
    output logic        core_halt,            // §22: HIGH freezes the core
                                              //      pipeline (debug state).
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

    // Async reset (DBGnTRST) per TRM. Two write ports: JTAG scan chain 2
    // (scan_we) and the core's CP14 DCC TX path (core_dcc_we). Scan wins
    // on simultaneous writes — the architectural rule is "don't issue
    // both at once" but we resolve deterministically rather than fault.
    localparam logic [4:0] DCC_DATA_ADDR = 5'h04;
    always_ff @(posedge CLK or negedge DBGnTRST) begin
        if (!DBGnTRST) begin
            for (int i = 0; i < 32; i = i + 1) regs[i] <= 32'h0;
        end else if (CLKEN) begin
            if (scan_we) begin
                regs[scan_addr] <= scan_wdata[31:0];
            end else if (core_dcc_we) begin
                regs[DCC_DATA_ADDR] <= core_dcc_wdata;
            end
        end
    end

    assign core_dcc_rdata = regs[DCC_DATA_ADDR];

    // §30.22.6: 2-flop synchronizer for asynchronous DBGRQ. The external
    // DBGRQ pin can fire any time relative to CLK; metastability mitigated
    // with the standard two-flop chain. Reset shared with the rest of the
    // macrocell (DBGnTRST async clear).
    logic [1:0] dbg_rq_sync_q;
    logic [1:0] dbg_break_sync_q;
    always_ff @(posedge CLK or negedge DBGnTRST) begin
        if (!DBGnTRST) begin
            dbg_rq_sync_q    <= 2'b00;
            dbg_break_sync_q <= 2'b00;
        end else if (CLKEN) begin
            dbg_rq_sync_q    <= {dbg_rq_sync_q[0], dbg_rq_in};
            dbg_break_sync_q <= {dbg_break_sync_q[0], dbg_break_in};
        end
    end
    wire dbg_rq_synced    = dbg_rq_sync_q[1];
    wire dbg_break_synced = dbg_break_sync_q[1];

    // §22 / §30.22.4: Debug-state FSM. Three-state at the architectural
    // level (RUNNING / HALTED / MONITOR), but our scaffold only implements
    // the HALTED branch; MONITOR mode (where a debug-abort exception
    // fires instead of stopping the pipeline) is left for the cycle-
    // accuracy pass since it overlaps the DABT exception path.
    //
    // Entry conditions (any of):
    //   - dbg_break_internal (WP/VC hit, see above)
    //   - dbg_break_in (external DBGBREAK pin, synced)
    //   - DBGRQI = Debug Control[1] OR dbg_rq_synced
    // All gated by DBGEN.
    //
    // Exit: TAP RESTART instruction observed (tap_restart_req pulse).
    debug_state_e dbg_state_q;

    wire ice_dbgrq_force = regs[5'h00][1];
    wire dbgrqi          = (ice_dbgrq_force || dbg_rq_synced) && DBGEN;
    wire halt_entry_req  = DBGEN
                         && (dbg_break_internal_pre || dbg_break_synced || dbgrqi);

    // dbg_break_internal_pre exists so we can use it BEFORE the wires
    // below see the FSM output — recursive feedback otherwise.
    logic dbg_break_internal_pre;

    // §30.22.5: Debug Status Register (addr 0x01) is read-only and
    // exposes live signals — TBIT, TRANS[1], IFEN, synced DBGRQ, synced
    // DBGACK. Override the regs[] read for this address so the debugger
    // sees current state rather than whatever was written.
    wire [4:0] dbg_status = {
        watch_tbit,         // [4] TBIT
        watch_priv,         // [3] TRANS[1] (privileged mode bit)
        ifen,               // [2] IFEN
        dbg_rq_synced,      // [1] synced DBGRQ (2-flop CDC chain)
        dbg_ack             // [0] DBGACK
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

    // §30.22.3: CHAIN/RANGE coupling. WP1's CHAINOUT (latched) feeds
    // WP0's CHAIN input. WP1's RANGEOUT (combinational addr+ctrl match)
    // feeds WP0's RANGE input. Both are qualified by the corresponding
    // CHAIN/RANGE bits in WP0's control-value register (bits [6] and [7]).
    //
    // CHAINOUT latch: write-enabled by WP1's addr+ctrl match, D-input
    // is WP1's data match. Cleared on WP1 ctrl-val write or DBGnTRST.
    wire wp1_addr_ctrl_match = wp1_addr_match && wp1_ctrl_match;
    logic chainout_q;
    always_ff @(posedge CLK or negedge DBGnTRST) begin
        if (!DBGnTRST)
            chainout_q <= 1'b0;
        else if (CLKEN) begin
            if (scan_we && (scan_addr == WP1_CTRL_VAL))
                chainout_q <= 1'b0;            // clear on ctrl-value write
            else if (wp1_addr_ctrl_match)
                chainout_q <= wp1_data_match;  // latch full match
        end
    end
    wire rangeout      = wp1_addr_ctrl_match;
    wire wp0_chain_bit = regs[WP0_CTRL_VAL][6];
    wire wp0_range_bit = regs[WP0_CTRL_VAL][7];
    wire wp0_chain_q   = !wp0_chain_bit || chainout_q;
    wire wp0_range_q   = !wp0_range_bit || rangeout;

    // DBGRNG reflects address+control matches *independent of ENABLE* per
    // §30.22.3 — useful for trace, doesn't gate debug entry.
    assign DBGRNG[0] = wp0_addr_match && wp0_ctrl_match;
    assign DBGRNG[1] = wp1_addr_match && wp1_ctrl_match;

    // Full match per WP. WP0 incorporates CHAIN/RANGE qualification from
    // WP1; WP1 has no upstream chain (it's the source of CHAINOUT/RANGEOUT).
    wire wp0_full_match = wp0_addr_match && wp0_data_match && wp0_ctrl_match
                       && wp0_enable && wp0_chain_q && wp0_range_q;
    wire wp1_full_match = wp1_addr_match && wp1_data_match && wp1_ctrl_match
                       && wp1_enable;

    // §22: Vector Catch (ICE-RT register 0x02, 8 bits) — trap on opcode
    // fetch of an exception vector address. Each bit corresponds to one
    // vector (TRM §5.27):
    //   [0] Reset       — vector 0x00
    //   [1] Undef       — 0x04
    //   [2] SWI         — 0x08
    //   [3] PrefAbort   — 0x0C
    //   [4] DataAbort   — 0x10
    //   [5] reserved    — 0x14
    //   [6] IRQ         — 0x18
    //   [7] FIQ         — 0x1C
    wire [7:0]  vector_catch = regs[5'h02][7:0];
    wire        is_vec_fetch = !watch_nopc && (watch_addr[31:5] == 27'h0);
    wire [2:0]  vec_index    = watch_addr[4:2];
    wire        vec_catch_hit = is_vec_fetch && vector_catch[vec_index];

    // §30.22.1: DBGEN=0 forces all debug outputs LOW.
    // dbg_break_internal_pre is the raw watchpoint/vec-catch hit gated by
    // DBGEN, used by the FSM entry condition above. dbg_break_internal
    // (the module output) is the same — kept separate to make the
    // intent-of-feedback explicit.
    assign dbg_break_internal_pre = DBGEN &&
                                    (wp0_full_match || wp1_full_match || vec_catch_hit);
    assign dbg_break_internal     = dbg_break_internal_pre;

    // ---- Debug-state FSM body
    always_ff @(posedge CLK or negedge DBGnTRST) begin
        if (!DBGnTRST) begin
            dbg_state_q <= DBG_RUNNING;
        end else if (CLKEN) begin
            unique case (dbg_state_q)
                DBG_RUNNING: if (halt_entry_req) dbg_state_q <= DBG_HALTED;
                DBG_HALTED:  if (tap_restart_req) dbg_state_q <= DBG_RUNNING;
                DBG_MONITOR: dbg_state_q <= DBG_MONITOR;     // (no FSM transitions yet)
                default:     dbg_state_q <= DBG_RUNNING;
            endcase
        end
    end

    wire in_debug_halt = (dbg_state_q == DBG_HALTED);
    assign core_halt   = in_debug_halt;

    // §30.22.6: DBGACK_pin = ICE_control[0] OR DBGACKI. DBGACKI is HIGH
    // while the debug-state FSM is in HALTED. Index 0x00 is the Debug
    // Control register.
    wire ice_dbg_ack_forced = regs[5'h00][0];
    wire dbgacki            = in_debug_halt;
    assign dbg_ack = DBGEN && (ice_dbg_ack_forced || dbgacki);

    // §30.22.6: IFEN_to_core = !(INTDIS | DBGACKI). Per TRM §5.19.2 on
    // debug-state entry IRQ/FIQ are forced disabled regardless of
    // CPSR.I/F — that's the DBGACKI term doing it here. Pending
    // interrupts at entry are remembered by virtue of the core being
    // frozen and nIRQ/nFIQ being captured-but-suppressed.
    wire ice_intdis = regs[5'h00][2];
    assign ifen = !(DBGEN && (ice_intdis || dbgacki));

    // Scan chain 2 upper bits (R/W flag + 5-bit addr field), DBGEN gating
    // outside the macrocell, and SIZE field (size_in not yet folded into
    // the 9-bit ctrl compare) all silenced here until they have consumers.
    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, scan_wdata[37:32], watch_size};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
