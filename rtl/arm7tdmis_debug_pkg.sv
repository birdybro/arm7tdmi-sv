// Debug + JTAG TAP constants: scan-chain widths, public IR opcodes, IDCODE,
// and high-level debug-state enum. EmbeddedICE-RT register-bit encodings
// (control/status, watchpoint comparator field maps) land in §22 alongside
// the macrocell RTL — keeping them here would create a forward-dependency
// on register definitions that aren't fixed yet.

package arm7tdmis_debug_pkg;

    // ---- TAP IR width and reset/capture patterns (TRM §5.14.3) ----
    localparam int unsigned IR_WIDTH       = 4;
    localparam logic [IR_WIDTH-1:0] IR_CAPTURE_PATTERN = 4'b0001;

    // ---- Public JTAG instructions (TRM §5.13 Table 5-3 / §30.23.1).
    // All other 4-bit IR encodings default to BYPASS. Do NOT add EXTEST,
    // SAMPLE, PRELOAD, CLAMP, HIGHZ, CLAMPZ — r4p3 has no boundary-scan chain
    // and selecting them while a debug chain is active is UNPREDICTABLE.
    typedef enum logic [IR_WIDTH-1:0] {
        IR_SCAN_N  = 4'b0010,
        IR_RESTART = 4'b0100,
        IR_INTEST  = 4'b1100,
        IR_IDCODE  = 4'b1110,
        IR_BYPASS  = 4'b1111
    } ir_e;

    // ---- IDCODE (TRM §5.14.2 / §30.23.4).
    // Format: [31:28]=Version, [27:12]=PartNumber, [11:1]=ManufacturerID,
    // [0]=1 (always per IEEE 1149.1; do not tie low).
    localparam logic [31:0] IDCODE_VALUE = 32'h7F1F_0F0F;

    // ---- Scan chain widths (§30.23.5).
    // Chain 0 reserved (returns zeros if selected).
    // Chain 1: 33 bits = [31:0] data + bit 33 (DBGBREAK/control cell).
    // Chain 2: 38 bits = [37] R/W + [36:32] 5-bit reg-addr + [31:0] data.
    localparam int unsigned SCAN_CHAIN1_WIDTH = 33;
    localparam int unsigned SCAN_CHAIN2_WIDTH = 38;

    // ---- High-level debug state ----
    typedef enum logic [1:0] {
        DBG_RUNNING = 2'd0,  // normal execution
        DBG_HALTED  = 2'd1,  // halt-mode debug entered
        DBG_MONITOR = 2'd2   // monitor-mode (debug-abort exception taken)
    } debug_state_e;

endpackage
