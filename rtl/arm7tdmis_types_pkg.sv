// Shared architectural enums: processor state, modes, exception types and
// vectors, ALU/shift opcodes, pipeline stages, coprocessor handshake.
// Bus encodings live in arm7tdmis_bus_pkg; PSR layout in arm7tdmis_psr_pkg;
// instruction-encoding fields in arm7tdmis_instr_pkg; debug/JTAG in
// arm7tdmis_debug_pkg.

package arm7tdmis_types_pkg;

    // ---- Processor state (CPSR.T) ----
    typedef enum logic {
        STATE_ARM   = 1'b0,
        STATE_THUMB = 1'b1
    } state_e;

    // ---- Processor modes M[4:0] (TRM Table 2-2) ----
    // The high bit is always 1; the remaining four bits are a sparse encoding.
    typedef enum logic [4:0] {
        MODE_USER       = 5'b10000,
        MODE_FIQ        = 5'b10001,
        MODE_IRQ        = 5'b10010,
        MODE_SUPERVISOR = 5'b10011,
        MODE_ABORT      = 5'b10111,
        MODE_UNDEFINED  = 5'b11011,
        MODE_SYSTEM     = 5'b11111
    } mode_e;

    // ---- Exception types (TRM §2.9 / Table 2-4) ----
    // The 0x14 vector slot is reserved and intentionally not enumerated here.
    typedef enum logic [2:0] {
        EXC_RESET          = 3'd0,
        EXC_UNDEF          = 3'd1,
        EXC_SWI            = 3'd2,
        EXC_PREFETCH_ABORT = 3'd3,
        EXC_DATA_ABORT     = 3'd4,
        EXC_IRQ            = 3'd5,
        EXC_FIQ            = 3'd6
    } exception_e;

    // ---- Exception vector addresses (TRM §2.9.2 Table 2-4) ----
    localparam logic [31:0] VEC_RESET          = 32'h0000_0000;
    localparam logic [31:0] VEC_UNDEF          = 32'h0000_0004;
    localparam logic [31:0] VEC_SWI            = 32'h0000_0008;
    localparam logic [31:0] VEC_PREFETCH_ABORT = 32'h0000_000C;
    localparam logic [31:0] VEC_DATA_ABORT     = 32'h0000_0010;
    // 0x0000_0014 is reserved.
    localparam logic [31:0] VEC_IRQ            = 32'h0000_0018;
    localparam logic [31:0] VEC_FIQ            = 32'h0000_001C;

    // ---- Exception priority order (TRM §2.9.10; lower index = higher priority).
    // Used by the priority encoder when multiple exceptions are simultaneously
    // pending. Reset > Data Abort > FIQ > IRQ > Prefetch Abort > Undef > SWI.
    // Note Data Abort + FIQ interlock is handled in the exception controller,
    // not by this raw ordering; see TASKS.md §30.14.2.

    // ---- ALU operation (ARM data-processing opcode = instr[24:21]) ----
    typedef enum logic [3:0] {
        ALU_AND = 4'h0, ALU_EOR = 4'h1, ALU_SUB = 4'h2, ALU_RSB = 4'h3,
        ALU_ADD = 4'h4, ALU_ADC = 4'h5, ALU_SBC = 4'h6, ALU_RSC = 4'h7,
        ALU_TST = 4'h8, ALU_TEQ = 4'h9, ALU_CMP = 4'hA, ALU_CMN = 4'hB,
        ALU_ORR = 4'hC, ALU_MOV = 4'hD, ALU_BIC = 4'hE, ALU_MVN = 4'hF
    } alu_op_e;

    // ---- Shifter operation (instr[6:5] for register-form operands).
    // RRX is encoded as ROR-by-zero in the instruction stream; the shifter
    // distinguishes it by inspecting the shift amount, not by a separate opcode.
    typedef enum logic [1:0] {
        SHIFT_LSL = 2'b00,
        SHIFT_LSR = 2'b01,
        SHIFT_ASR = 2'b10,
        SHIFT_ROR = 2'b11
    } shift_op_e;

    // ---- Pipeline stages (3-stage Fetch/Decode/Execute, §16) ----
    typedef enum logic [1:0] {
        STAGE_FETCH   = 2'd0,
        STAGE_DECODE  = 2'd1,
        STAGE_EXECUTE = 2'd2
    } pipeline_stage_e;

    // ---- Coprocessor handshake state (TRM §4.4 / TASKS.md §30.19).
    // Encoded as {CPA, CPB} (active-HIGH inputs from the coprocessor).
    // {1, 0} is illegal and never produced by a compliant coprocessor.
    typedef enum logic [1:0] {
        CP_PRESENT_READY = 2'b00,  // CPA=0, CPB=0 — go
        CP_PRESENT_BUSY  = 2'b01,  // CPA=0, CPB=1 — busy-wait
        CP_ABSENT        = 2'b11   // CPA=1, CPB=1 — undefined-instruction trap
    } coproc_handshake_e;

endpackage
