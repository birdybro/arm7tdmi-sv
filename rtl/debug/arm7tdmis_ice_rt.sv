// EmbeddedICE-RT macrocell (TRM §5.14 / TASKS.md §22).

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
    input  logic        watch_priv,        // address-phase PROT[1] / nTRANS
    input  logic        core_trans1,       // live core TRANS[1] for Debug Status[3]
    input  logic        core_halt_boundary,// current instruction commits this edge
    input  logic        core_breakpoint_execute,
    input  logic        dbg_rq_in,         // §22: external DBGRQ pin synced
                                            //      (used for Debug Status[1])
    input  logic        dbg_break_in,      // §22: external DBGBREAK pin
    input  logic        tap_restart_req,   // §22: TAP RESTART instruction
                                            //      pulse (Update-IR with
                                            //      IR_RESTART loaded)
    input  logic        tap_chain1_capture,// first Capture-DR consumes the
                                            //      latched entry-cause bit
    output logic        chain1_capture_break,

    // §20: CP14 DCC and Debug Abort Status paths. Processor c1 writes fill
    // TX; processor c1 reads consume RX. c0 returns live version/W/R status.
    input  logic        core_dcc_we,
    input  logic        core_dcc_re,
    input  logic [31:0] core_dcc_wdata,
    output logic [31:0] core_dcc_control,
    output logic [31:0] core_dcc_rdata,
    input  logic        core_dbgabt_we,
    input  logic        core_dbgabt_wdata,
    output logic [31:0] core_dbgabt_rdata,
    input  logic        debug_abort_set,
    output logic        dcc_tx_empty,
    output logic        dcc_rx_full,

    // §22 scan-chain-1 instruction injection. TAP latches a 33-bit value
    // on Update-DR (instruction + break flag); ice_rt buffers it and uses
    // accepted/retired handshakes to release the core for exactly the
    // injected instruction's lifetime.
    input  logic        tap_inject_we,
    input  logic [31:0] tap_inject_instr,
    input  logic        tap_inject_break,
    input  logic        core_inject_accept,
    input  logic        core_inject_retire,
    output logic        dbg_inject_we,
    output logic [31:0] dbg_inject_instr,
    output logic        dbg_inject_active,

    // Outputs
    output logic        dbg_break_internal,
    output logic        breakpoint_fetch,    // tag for the aligned opcode fetch
    output logic        dbg_ack,             // §22: forced via Debug Control[0],
                                              //      OR set when the debug-state
                                              //      FSM is in HALTED.
    output logic        ifen,                 // §22: interrupt-enable gate.
                                              //      LOW masks IRQ/FIQ to core.
                                              //      Per TRM §30.22.6 derived
                                              //      from INTDIS (ctrl[2]) and
                                              //      DBGACKI (debug FSM signal).
    output logic        halt_request,         // §5.3: synchronized request to
                                              //      finish/terminate the
                                              //      current instruction before
                                              //      the core is frozen.
    output logic        core_halt,            // §22: HIGH freezes the core
                                              //      pipeline (debug state).
    output logic [1:0]  DBGRNG,

    // Scan-chain-2 placeholder — currently tied off in the wrapper that
    // instantiates this module. When the TAP wiring lands, these become
    // read/write ports into the register bank.
    input  logic        scan_we,
    input  logic        scan_re,
    input  logic [4:0]  scan_addr,
    input  logic [37:0] scan_wdata,       // 38-bit chain: [37]=R/W, [36:32]=addr, [31:0]=data
    output logic [31:0] scan_rdata,
    output logic [4:0]  scan_raddr
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
    //   0x04: Debug Comms Control (32-bit live version/W/R value)
    //   0x05: Debug Comms Data    (RX on host write, TX on host read)
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

    // Async reset (DBGnTRST) per TRM. Normal ICE registers are writable
    // from scan chain 2. DCC control/data are live resources implemented
    // separately below rather than ordinary storage slots.
    localparam logic [4:0] DCC_CTRL_ADDR = 5'h04;
    always_ff @(posedge CLK or negedge DBGnTRST) begin
        if (!DBGnTRST) begin
            for (int i = 0; i < 32; i = i + 1) regs[i] <= 32'h0;
        end else begin
            if (scan_we && (scan_addr != DCC_CTRL_ADDR)
                        && (scan_addr != 5'h05)) begin
                regs[scan_addr] <= scan_wdata[31:0];
            end
        end
    end

    // ---- Debug Communications Channel
    // W=1 means unread processor TX is pending. R=1 means unread host RX
    // is pending. If a producer and consumer act on the same edge, the new
    // producer wins so a newly-arrived word is never lost.
    logic [31:0] dcc_tx_data_q;
    logic [31:0] dcc_rx_data_q;
    logic        dcc_tx_full_q;
    logic        dcc_rx_full_q;
    logic        dbg_abt_q;

    always_ff @(posedge CLK or negedge DBGnTRST) begin
        if (!DBGnTRST) begin
            dcc_tx_data_q <= 32'h0;
            dcc_rx_data_q <= 32'h0;
            dcc_tx_full_q <= 1'b0;
            dcc_rx_full_q <= 1'b0;
            dbg_abt_q     <= 1'b0;
        end else begin
            // Host consumption clears W; a simultaneous CPU write replaces
            // the consumed word and leaves W asserted.
            if (scan_re && (scan_addr == 5'h05))
                dcc_tx_full_q <= 1'b0;
            if (CLKEN && core_dcc_we) begin
                dcc_tx_data_q <= core_dcc_wdata;
                dcc_tx_full_q <= 1'b1;
            end

            // CPU consumption clears R; a simultaneous host write installs
            // a new word and leaves R asserted.
            if (CLKEN && core_dcc_re)
                dcc_rx_full_q <= 1'b0;
            if (scan_we && (scan_addr == 5'h05)) begin
                dcc_rx_data_q <= scan_wdata[31:0];
                dcc_rx_full_q <= 1'b1;
            end else if (scan_we && (scan_addr == DCC_CTRL_ADDR)
                                 && !scan_wdata[0]) begin
                // Backward-compatible debugger escape for a stuck R bit.
                dcc_rx_full_q <= 1'b0;
            end

            // Debug-generated aborts are sticky. Software may write c2;
            // debug set wins a coincident clear.
            if (CLKEN && core_dbgabt_we)
                dbg_abt_q <= core_dbgabt_wdata;
            if (debug_abort_set)
                dbg_abt_q <= 1'b1;
        end
    end

    assign core_dcc_control = {4'b0111, 26'h0,
                               dcc_tx_full_q, dcc_rx_full_q};
    assign core_dcc_rdata   = dcc_rx_data_q;
    assign core_dbgabt_rdata = {31'h0, dbg_abt_q};
    assign dcc_tx_empty = !dcc_tx_full_q;
    assign dcc_rx_full  = dcc_rx_full_q;

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
    // level (RUNNING / HALTED / MONITOR), but this implementation only has
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
    logic         halt_pending_q;
    logic         halt_watchpoint_q;
    logic         breakpoint_halt_q;
    logic         breakpoint_resume_q;
    logic         entry_watchpoint_q;
    logic         system_speed_armed_q;
    logic         system_speed_pending_q;
    logic         system_speed_active_q;
    logic [31:0]  system_speed_instr_q;

    // Bit 33 on one scan arms the following pipeline word. Only memory
    // transfers are legal system-speed instructions (TRM §5.16.2).
    // A non-memory word is the final debug-exit PC-control instruction;
    // it remains a synchronization marker for the scan-loaded resume PC
    // and must not trigger automatic system-speed re-entry.
    wire tap_system_speed_memory =
           (tap_inject_instr[27:26] == 2'b01)
        || (tap_inject_instr[27:25] == 3'b100)
        || ((tap_inject_instr[27:25] == 3'b000)
            && tap_inject_instr[7] && tap_inject_instr[4]
            && (tap_inject_instr[6:5] != 2'b00));

    wire ice_dbgrq_force = regs[5'h00][1];
    wire dbgrqi          = (ice_dbgrq_force || dbg_rq_synced) && DBGEN;
    wire halt_entry_req  = DBGEN
                         && (watchpoint_halt_pre || dbg_break_synced || dbgrqi);
    wire halt_entry_watchpoint = watchpoint_halt_pre
                               || (dbg_break_synced && watch_nopc_q);

    // dbg_break_internal_pre exists so we can use it BEFORE the wires
    // below see the FSM output — recursive feedback otherwise.
    logic dbg_break_internal_pre;
    logic watchpoint_halt_pre;
    logic breakpoint_fetch_pre;

    // §30.22.5: Debug Status Register (addr 0x01) is read-only and
    // exposes live signals — TBIT, TRANS[1], IFEN, synced DBGRQ, synced
    // DBGACK. Override the regs[] read for this address so the debugger
    // sees current state rather than whatever was written.
    wire [4:0] dbg_status = {
        watch_tbit,         // [4] TBIT
        core_trans1,        // [3] live core TRANS[1]
        ifen,               // [2] IFEN
        dbg_rq_synced,      // [1] synced DBGRQ (2-flop CDC chain)
        dbg_ack             // [0] DBGACK
    };
    always_comb begin
        unique case (scan_addr)
            5'h01: scan_rdata = {27'h0, dbg_status};
            5'h04: scan_rdata = core_dcc_control;
            5'h05: scan_rdata = dcc_tx_data_q;
            default: scan_rdata = regs[scan_addr];
        endcase
    end
    // Rev-4 DCC optimization: a data-register response replaces address
    // bit 0 with W, so the debugger receives data-valid status in the same
    // scan. Other reads return the addressed register number unchanged.
    assign scan_raddr = (scan_addr == 5'h05)
                      ? {scan_addr[4:1], dcc_tx_full_q}
                      : scan_addr;

    // ---- Watchpoint transaction alignment
    //
    // ADDR/WRITE/SIZE/PROT describe the address phase, while RDATA/WDATA
    // belong to that transfer one enabled cycle later. Preserve the
    // address-class metadata here so all comparator fields refer to the
    // same transaction. core_trans1 is HIGH only for N/S memory cycles and
    // therefore becomes the data-phase-valid bit. DBGEXT is sampled on the
    // rising edge with the transaction as required by §5.27.
    logic        watch_valid_q;
    logic [31:0] watch_addr_q;
    logic        watch_nopc_q;
    logic        watch_nrw_q;
    logic [1:0]  watch_size_q;
    logic        watch_priv_q;
    logic [1:0]  watch_extern_q;

    always_ff @(posedge CLK or negedge DBGnTRST) begin
        if (!DBGnTRST) begin
            watch_valid_q  <= 1'b0;
            watch_addr_q   <= 32'h0;
            watch_nopc_q   <= 1'b0;
            watch_nrw_q    <= 1'b0;
            watch_size_q   <= 2'b00;
            watch_priv_q   <= 1'b0;
            watch_extern_q <= 2'b00;
        end else if (CLKEN) begin
            watch_valid_q  <= core_trans1;
            watch_addr_q   <= watch_addr;
            watch_nopc_q   <= watch_nopc;
            watch_nrw_q    <= watch_nrw;
            watch_size_q   <= watch_size;
            watch_priv_q   <= watch_priv;
            watch_extern_q <= watch_extern;
        end
    end

    // ---- Watchpoint comparators: XNOR-with-mask matching (TRM §5.20.2).
    // match[i] = (value_i XNOR input_i) OR mask_i; mask 1 means don't-care.
    function automatic logic masked_match32(
        input logic [31:0] value,
        input logic [31:0] mask,
        input logic [31:0] in
    );
        return &((value ~^ in) | mask);
    endfunction

    function automatic logic masked_match8(
        input logic [7:0] value,
        input logic [7:0] mask,
        input logic [7:0] in
    );
        return &((value ~^ in) | mask);
    endfunction

    // Figure 5-13 control layout:
    //   [7] RANGE, [6] CHAIN, [5] DBGEXT, [4] PROT[1],
    //   [3] PROT[0], [2:1] SIZE, [0] WRITE.
    // Watchpoint 0 consumes DBGEXT[0] and WP1's range/chain outputs.
    // Watchpoint 1 consumes DBGEXT[1] and has no upstream RANGE/CHAIN.
    wire [4:0] watch_control_low = {
        watch_priv_q, watch_nopc_q, watch_size_q, watch_nrw_q
    };

    wire wp0_addr_match = masked_match32(
        regs[WP0_ADDR_VAL], regs[WP0_ADDR_MASK], watch_addr_q);
    wire wp0_data_match = masked_match32(
        regs[WP0_DATA_VAL], regs[WP0_DATA_MASK], watch_data);
    wire wp1_addr_match = masked_match32(
        regs[WP1_ADDR_VAL], regs[WP1_ADDR_MASK], watch_addr_q);
    wire wp1_data_match = masked_match32(
        regs[WP1_DATA_VAL], regs[WP1_DATA_MASK], watch_data);

    // TRM §5.26.1 publishes the comparator split used by CHAINOUT:
    // address plus control[4:0] enables the latch; data plus control[7:5]
    // supplies its D input. This also reconstructs the complete WP1
    // RANGEOUT/DBGRNG match without relying on ENABLE.
    wire wp1_addr_low_match = wp1_addr_match
                            && &((regs[WP1_CTRL_VAL][4:0]
                                ~^ watch_control_low)
                                | regs[WP1_CTRL_MASK][4:0]);
    wire [2:0] wp1_control_high = {
        1'b0, 1'b0, watch_extern_q[1]
    };
    wire wp1_data_high_match = wp1_data_match
                             && &((regs[WP1_CTRL_VAL][7:5]
                                 ~^ wp1_control_high)
                                 | regs[WP1_CTRL_MASK][7:5]);
    wire wp1_rangeout = watch_valid_q
                      && wp1_addr_low_match
                      && wp1_data_high_match;

    // CHAINOUT is cleared by writing WP1 Control Value. Otherwise a lower
    // address/control match clocks the corresponding data/high-control
    // result into the latch at the end of that transfer.
    logic chainout_q;
    always_ff @(posedge CLK or negedge DBGnTRST) begin
        if (!DBGnTRST)
            chainout_q <= 1'b0;
        else if (scan_we && (scan_addr == WP1_CTRL_VAL))
            chainout_q <= 1'b0;
        else if (CLKEN && watch_valid_q && wp1_addr_low_match)
            chainout_q <= wp1_data_high_match;
    end

    wire [7:0] wp0_control_in = {
        wp1_rangeout, chainout_q, watch_extern_q[0], watch_control_low
    };
    wire [7:0] wp1_control_in = {
        1'b0, 1'b0, watch_extern_q[1], watch_control_low
    };
    wire wp0_ctrl_match = masked_match8(
        regs[WP0_CTRL_VAL][7:0], regs[WP0_CTRL_MASK][7:0],
        wp0_control_in);
    wire wp1_ctrl_match = masked_match8(
        regs[WP1_CTRL_VAL][7:0], regs[WP1_CTRL_MASK][7:0],
        wp1_control_in);
    wire wp0_rangeout = watch_valid_q && wp0_addr_match
                      && wp0_data_match && wp0_ctrl_match;
    // Keep the direct full-vector computation visible as an equivalence
    // check on the split form used for WP1 CHAINOUT.
    wire wp1_full_vector_match = watch_valid_q && wp1_addr_match
                               && wp1_data_match && wp1_ctrl_match;
    wire wp0_enable = regs[WP0_CTRL_VAL][8];
    wire wp1_enable = regs[WP1_CTRL_VAL][8];

    // DBGRNG includes address, data, and all control fields, ignores ENABLE,
    // and is forced LOW with all other debug outputs when DBGEN is LOW.
    assign DBGRNG = DBGEN ? {wp1_rangeout, wp0_rangeout} : 2'b00;

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
    wire        is_vec_fetch = watch_valid_q && !watch_nopc_q
                             && (watch_addr_q[31:5] == 27'h0);
    wire [2:0]  vec_index    = watch_addr_q[4:2];
    wire        vec_catch_hit = is_vec_fetch && vector_catch[vec_index];

    // §5.3: opcode breakpoints are marked in the fetch pipeline and only
    // stop the core if the marked instruction reaches Execute. A branch,
    // PC write, or exception therefore cancels a breakpoint by flushing
    // its tag. Data watchpoints instead request a halt after the current
    // instruction reaches its architectural completion boundary.
    wire enabled_wp_match = (wp0_rangeout && wp0_enable)
                         || (wp1_rangeout && wp1_enable);
    assign breakpoint_fetch_pre = DBGEN
                                && ((enabled_wp_match && !watch_nopc_q)
                                    || vec_catch_hit);
    assign watchpoint_halt_pre   = DBGEN && enabled_wp_match && watch_nopc_q;

    // §30.22.1: DBGEN=0 forces all debug outputs LOW.
    assign dbg_break_internal_pre = breakpoint_fetch_pre
                                  || watchpoint_halt_pre;
    assign dbg_break_internal     = dbg_break_internal_pre;
    assign breakpoint_fetch       = breakpoint_fetch_pre;

    // ---- Debug-state FSM body
    always_ff @(posedge CLK or negedge DBGnTRST) begin
        if (!DBGnTRST) begin
            dbg_state_q       <= DBG_RUNNING;
            halt_pending_q    <= 1'b0;
            halt_watchpoint_q <= 1'b0;
            breakpoint_halt_q <= 1'b0;
            breakpoint_resume_q <= 1'b0;
            entry_watchpoint_q <= 1'b0;
        end else begin
            // The first chain-1 capture after entry reports the reason.
            // TAP activity is independent of CLKEN, so consumption cannot
            // be hidden behind the core clock-enable gate.
            if (tap_chain1_capture)
                entry_watchpoint_q <= 1'b0;
            if (core_inject_retire && system_speed_active_q)
                entry_watchpoint_q <= 1'b1;

            if (CLKEN) begin
                unique case (dbg_state_q)
                    DBG_RUNNING: begin
                        if (!DBGEN) begin
                            halt_pending_q <= 1'b0;
                            halt_watchpoint_q <= 1'b0;
                            breakpoint_halt_q <= 1'b0;
                            breakpoint_resume_q <= 1'b0;
                            entry_watchpoint_q <= 1'b0;
                        end else if (breakpoint_resume_q
                                     && core_breakpoint_execute) begin
                            // Consume exactly the breakpoint tag that caused
                            // the preceding halt. A simultaneous ordinary halt
                            // request is taken after this instruction completes.
                            breakpoint_halt_q   <= 1'b0;
                            breakpoint_resume_q <= 1'b0;
                            if (halt_entry_req && core_halt_boundary) begin
                                dbg_state_q    <= DBG_HALTED;
                                halt_pending_q <= 1'b0;
                                halt_watchpoint_q <= 1'b0;
                                entry_watchpoint_q <= halt_entry_watchpoint;
                            end else if (halt_entry_req) begin
                                halt_pending_q <= 1'b1;
                                halt_watchpoint_q <= halt_entry_watchpoint;
                            end
                        end else if (core_breakpoint_execute) begin
                            // The core suppresses this edge's execution and
                            // freezes while this FSM enters debug state.
                            dbg_state_q       <= DBG_HALTED;
                            halt_pending_q    <= 1'b0;
                            halt_watchpoint_q <= 1'b0;
                            breakpoint_halt_q <= 1'b1;
                            entry_watchpoint_q <= 1'b0;
                        end else if ((halt_pending_q || halt_entry_req)
                                     && core_halt_boundary) begin
                            // The core commits its final state on this edge;
                            // freezing begins immediately after the edge.
                            dbg_state_q       <= DBG_HALTED;
                            halt_pending_q    <= 1'b0;
                            breakpoint_halt_q <= 1'b0;
                            entry_watchpoint_q <= halt_watchpoint_q
                                               || halt_entry_watchpoint;
                            halt_watchpoint_q <= 1'b0;
                        end else if (halt_entry_req) begin
                            halt_pending_q <= 1'b1;
                            halt_watchpoint_q <= halt_watchpoint_q
                                               || halt_entry_watchpoint;
                        end
                    end
                    DBG_HALTED: begin
                        halt_pending_q    <= 1'b0;
                        halt_watchpoint_q <= 1'b0;
                        if (tap_restart_req && !system_speed_pending_q
                                            && !system_speed_active_q) begin
                            dbg_state_q <= DBG_RUNNING;
                            breakpoint_resume_q <= breakpoint_halt_q;
                        end
                    end
                    DBG_MONITOR: begin
                        halt_pending_q      <= 1'b0;
                        halt_watchpoint_q   <= 1'b0;
                        breakpoint_halt_q   <= 1'b0;
                        breakpoint_resume_q <= 1'b0;
                        dbg_state_q         <= DBG_MONITOR;
                    end
                    default: begin
                        dbg_state_q       <= DBG_RUNNING;
                        halt_pending_q    <= 1'b0;
                        halt_watchpoint_q <= 1'b0;
                        breakpoint_halt_q <= 1'b0;
                        breakpoint_resume_q <= 1'b0;
                        entry_watchpoint_q <= 1'b0;
                    end
                endcase
            end
        end
    end

    assign chain1_capture_break = entry_watchpoint_q;

    wire in_debug_halt = (dbg_state_q == DBG_HALTED);

    // This is asserted for the final running DBGRQI cycle, before
    // dbg_state_q enters HALTED. Only a debug request has the special
    // §5.3.3 rule that terminates a coprocessor busy-wait immediately.
    // Keeping breakpoint/watchpoint matches on the normal registered
    // halt path also avoids feeding watched bus outputs combinationally
    // back into the core's next-state decision.
    assign halt_request = (dbg_state_q == DBG_RUNNING) && dbgrqi;

    // §5.16 debug-speed scan-chain-1 execution. A scan update is held
    // pending until the core accepts it, then the core remains released
    // for as many enabled cycles as the instruction actually requires.
    // Retirement—not a guessed cycle count—returns it to debug halt.
    logic         inject_active_q;
    logic         inject_accepted_q;
    logic [31:0] inject_instr_q;
    always_ff @(posedge CLK or negedge DBGnTRST) begin
        if (!DBGnTRST) begin
            inject_active_q   <= 1'b0;
            inject_accepted_q <= 1'b0;
            inject_instr_q    <= 32'h0;
            system_speed_armed_q   <= 1'b0;
            system_speed_pending_q <= 1'b0;
            system_speed_active_q  <= 1'b0;
            system_speed_instr_q   <= 32'h0;
        end else if (tap_inject_we && in_debug_halt
                     && !inject_active_q && !system_speed_pending_q) begin
            if (system_speed_armed_q) begin
                // DBGBREAK HIGH on the preceding scan marks a legal
                // load/store as the system-speed instruction. The
                // non-memory case is the final branch/SUB-PC debug-exit
                // word; scan-loaded PC state already contains the exact
                // resume target, so RESTART performs an ordinary exit.
                if (tap_system_speed_memory) begin
                    system_speed_instr_q   <= tap_inject_instr;
                    system_speed_pending_q <= 1'b1;
                end
                system_speed_armed_q   <= 1'b0;
            end else begin
                inject_instr_q    <= tap_inject_instr;
                inject_active_q   <= 1'b1;
                inject_accepted_q <= 1'b0;
                system_speed_armed_q <= tap_inject_break;
            end
        end else if (tap_restart_req && in_debug_halt
                     && system_speed_pending_q && !inject_active_q) begin
            inject_instr_q          <= system_speed_instr_q;
            inject_active_q         <= 1'b1;
            inject_accepted_q       <= 1'b0;
            system_speed_pending_q  <= 1'b0;
            system_speed_active_q   <= 1'b1;
        end else if (CLKEN && inject_active_q) begin
            if (core_inject_retire) begin
                inject_active_q   <= 1'b0;
                inject_accepted_q <= 1'b0;
                system_speed_active_q <= 1'b0;
            end else if (core_inject_accept) begin
                inject_accepted_q <= 1'b1;
            end
        end else if (tap_restart_req && in_debug_halt
                     && !system_speed_pending_q) begin
            // Ordinary debug exit discards an unmatched synchronization
            // marker rather than leaking it into a later halt session.
            system_speed_armed_q <= 1'b0;
        end
    end

    // A breakpoint instruction must be stopped before its Execute edge.
    // The ICE FSM itself still advances on raw CLKEN and enters HALTED on
    // that edge; the top-level gates only the core's clock enable.
    wire breakpoint_stop = (dbg_state_q == DBG_RUNNING)
                         && DBGEN && core_breakpoint_execute
                         && !breakpoint_resume_q;

    // Core un-halts while injecting.
    assign core_halt = (in_debug_halt || breakpoint_stop)
                     && !inject_active_q;

    // Hold the request until an enabled core edge accepts it.
    assign dbg_inject_we     = inject_active_q && !inject_accepted_q;
    assign dbg_inject_instr = inject_instr_q;
    assign dbg_inject_active = inject_active_q;

    // §30.22.6: DBGACK_pin = ICE_control[0] OR DBGACKI. DBGACKI is HIGH
    // while the debug-state FSM is in HALTED. Index 0x00 is the Debug
    // Control register.
    wire ice_dbg_ack_forced = regs[5'h00][0];
    wire dbgacki            = in_debug_halt && !system_speed_active_q;
    assign dbg_ack = DBGEN && (ice_dbg_ack_forced || dbgacki);

    // §30.22.6: IFEN_to_core = !(INTDIS | DBGACKI). Per TRM §5.19.2 on
    // debug-state entry IRQ/FIQ are forced disabled regardless of
    // CPSR.I/F. The debug context remains active during a system-speed
    // access even though DBGACKI temporarily drops, so pending interrupts
    // stay suppressed until a real debug exit.
    wire ice_intdis = regs[5'h00][2];
    assign ifen = !(DBGEN && (ice_intdis || in_debug_halt));

    // Scan chain 2 upper bits are decoded by the TAP-facing wrapper.
    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, scan_wdata[37:32], wp1_full_vector_match};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
