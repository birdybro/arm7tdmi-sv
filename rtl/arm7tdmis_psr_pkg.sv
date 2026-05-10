// CPSR / SPSR layout, MSR field-mask encoding, and reset value.
// Bit map per TRM §2.8 Fig. 2-6 / TASKS.md §30.3.1.
// No Q flag (ARMv4T predates DSP saturation; see §30.0).

package arm7tdmis_psr_pkg;

    import arm7tdmis_types_pkg::MODE_SUPERVISOR;

    // ---- CPSR/SPSR bit positions ----
    localparam int unsigned PSR_BIT_N    = 31;
    localparam int unsigned PSR_BIT_Z    = 30;
    localparam int unsigned PSR_BIT_C    = 29;
    localparam int unsigned PSR_BIT_V    = 28;
    // [27:8] reserved — preserve under read-modify-write; never assume value.
    localparam int unsigned PSR_BIT_I    = 7;   // IRQ disable
    localparam int unsigned PSR_BIT_F    = 6;   // FIQ disable
    localparam int unsigned PSR_BIT_T    = 5;   // ARM=0 / Thumb=1
    localparam int unsigned PSR_BIT_M_HI = 4;
    localparam int unsigned PSR_BIT_M_LO = 0;

    // ---- MSR field selector bits (instr[19:16] in ARM-state MSR) ----
    localparam int unsigned MSR_FIELD_BIT_C = 16;  // control: M[4:0], T, F, I
    localparam int unsigned MSR_FIELD_BIT_X = 17;  // extension [15:8]   (RAZ/SBZP on r4p3)
    localparam int unsigned MSR_FIELD_BIT_S = 18;  // status    [23:16]  (RAZ/SBZP on r4p3)
    localparam int unsigned MSR_FIELD_BIT_F = 19;  // flags     [31:24]

    // ---- 32-bit byte-lane masks corresponding to each MSR field ----
    localparam logic [31:0] PSR_MASK_C = 32'h0000_00FF;
    localparam logic [31:0] PSR_MASK_X = 32'h0000_FF00;
    localparam logic [31:0] PSR_MASK_S = 32'h00FF_0000;
    localparam logic [31:0] PSR_MASK_F = 32'hFF00_0000;

    // ---- Structured packed view. First member is MSB; total = 32 bits. ----
    typedef struct packed {
        logic        n;
        logic        z;
        logic        c;
        logic        v;
        logic [19:0] reserved;  // [27:8]; do not depend on a value
        logic        i;
        logic        f;
        logic        t;
        logic [4:0]  m;
    } psr_t;

    // ---- Reset value (TRM §2.11): Supervisor mode, I=1, F=1, T=0, ARM state,
    // flags 0, reserved 0. Match all of these — don't just clear PC.
    localparam psr_t PSR_RESET_VALUE = '{
        n: 1'b0, z: 1'b0, c: 1'b0, v: 1'b0,
        reserved: 20'h0,
        i: 1'b1, f: 1'b1, t: 1'b0,
        m: MODE_SUPERVISOR
    };

    // Convenience: privileged-mode test. User-mode is the only non-privileged
    // mode (System shares User's bank but is privileged). M[4:0]==MODE_USER.
    function automatic logic mode_is_privileged(input logic [4:0] m);
        return (m != 5'b10000);
    endfunction

endpackage
