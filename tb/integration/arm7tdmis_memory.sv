// Behavioral memory model for the §2 verification framework.
//
// Bus protocol (TRM §3.3 / TASKS.md §30.17):
//   Address-class signals (ADDR, WRITE, SIZE, PROT, LOCK, TRANS) are driven
//   by the core in cycle N. The memory latches them at the cycle-N rising
//   edge and produces RDATA / accepts WDATA in cycle N+1. CLKEN gates the
//   pipeline — on cycles where CLKEN=0 nothing advances.
//
// Endianness (TRM §3.5.5):
//   LE (CFGBIGEND=0): byte at ADDR[1:0]=B → DATA[8B+7:8B];
//                     halfword at ADDR[1]=H → DATA[16H+15:16H].
//   BE (CFGBIGEND=1): mirror image — lane index becomes (3-B) for byte,
//                     (~H) for halfword.
//
// ABORT injection (TRM §3.5.3 / §30.17.5):
//   ABORT must only assert during active S/N memory cycles; gated here so
//   testbench-driven `inject_abort` cannot accidentally fire during I/C
//   cycles.
//
// Program load:
//   If parameter INIT_HEX is non-empty, $readmemh loads it into mem[]
//   during initial. Path is resolved relative to the simulation cwd.

module arm7tdmis_memory
    import arm7tdmis_bus_pkg::*;
#(
    parameter int    WORDS    = 16384,           // 64 KiB default
    parameter string INIT_HEX = ""
) (
    input  logic        CLK,
    input  logic        CLKEN,
    input  logic        nRESET,
    input  logic        CFGBIGEND,

    // Address-class
    input  logic [31:0] ADDR,
    input  logic        WRITE,
    input  logic [1:0]  SIZE,
    input  logic [1:0]  PROT,
    input  logic        LOCK,
    input  logic [1:0]  TRANS,

    // Data
    input  logic [31:0] WDATA,
    output logic [31:0] RDATA,

    // Bus exception
    output logic        ABORT,

    // TB-only injection hook
    input  logic        inject_abort
);

    // Word-addressed storage
    logic [31:0] mem [0:WORDS-1];

    localparam int INDEX_BITS = $clog2(WORDS);

    // Latched address phase (cycle N → cycle N+1)
    logic [31:0]      addr_q;
    logic             write_q;
    logic [1:0]       size_q;
    logic [1:0]       trans_q;

    wire is_active_q = (trans_q == 2'(TRANS_N)) || (trans_q == 2'(TRANS_S));
    wire [INDEX_BITS-1:0] index_q = addr_q[INDEX_BITS+1:2];

    // ---- Address-phase capture (synchronous reset; matches CLAUDE.md's
    //      FPGA preference and avoids a sync/async-net warning across
    //      modules that read nRESET as data, e.g. the cycle logger).
    always_ff @(posedge CLK) begin
        if (CLKEN) begin
            if (!nRESET) begin
                addr_q  <= 32'h0;
                write_q <= 1'b0;
                size_q  <= 2'(SIZE_WORD);
                trans_q <= 2'(TRANS_I);
            end else begin
                addr_q  <= ADDR;
                write_q <= WRITE;
                size_q  <= SIZE;
                trans_q <= TRANS;
            end
        end
    end

    // ---- Read path: combinational from latched address. Byte-lane mapping
    //      per TRM §3.5.5. Inactive cycles drive 0 (UNPREDICTABLE per spec).
    always_comb begin
        logic       hw_hi;
        logic [1:0] byte_lane;
        RDATA = 32'h0;
        if (is_active_q && !write_q) begin
            unique case (size_q)
                2'(SIZE_WORD): RDATA = mem[index_q];
                2'(SIZE_HALFWORD): begin
                    hw_hi = CFGBIGEND ? ~addr_q[1] : addr_q[1];
                    RDATA = hw_hi ? {mem[index_q][31:16], 16'h0}
                                  : {16'h0, mem[index_q][15:0]};
                end
                2'(SIZE_BYTE): begin
                    byte_lane = CFGBIGEND ? ~addr_q[1:0] : addr_q[1:0];
                    unique case (byte_lane)
                        2'd0: RDATA = {24'h0, mem[index_q][7:0]};
                        2'd1: RDATA = {16'h0, mem[index_q][15:8], 8'h0};
                        2'd2: RDATA = {8'h0, mem[index_q][23:16], 16'h0};
                        2'd3: RDATA = {mem[index_q][31:24], 24'h0};
                    endcase
                end
                default: RDATA = 32'h0;     // SIZE_RESERVED — never legal
            endcase
        end
    end

    // ---- Write path: synchronous, partial-word merge per SIZE/CFGBIGEND.
    //      No explicit nRESET gate — the address-phase async reset clears
    //      trans_q to TRANS_I, which makes is_active_q false and naturally
    //      suppresses writes during reset (avoids a sync/async-net warning).
    always_ff @(posedge CLK) begin
        logic       hw_hi;
        logic [1:0] byte_lane;
        if (CLKEN && is_active_q && write_q) begin
            unique case (size_q)
                2'(SIZE_WORD): mem[index_q] <= WDATA;
                2'(SIZE_HALFWORD): begin
                    hw_hi = CFGBIGEND ? ~addr_q[1] : addr_q[1];
                    if (hw_hi) mem[index_q][31:16] <= WDATA[31:16];
                    else       mem[index_q][15:0]  <= WDATA[15:0];
                end
                2'(SIZE_BYTE): begin
                    byte_lane = CFGBIGEND ? ~addr_q[1:0] : addr_q[1:0];
                    unique case (byte_lane)
                        2'd0: mem[index_q][7:0]   <= WDATA[7:0];
                        2'd1: mem[index_q][15:8]  <= WDATA[15:8];
                        2'd2: mem[index_q][23:16] <= WDATA[23:16];
                        2'd3: mem[index_q][31:24] <= WDATA[31:24];
                    endcase
                end
                default: ;     // SIZE_RESERVED — never legal
            endcase
        end
    end

    // ---- ABORT only during active S/N cycles ----
    assign ABORT = inject_abort && is_active_q;

    // ---- Program load ----
    initial begin
        if (INIT_HEX != "") begin
            $readmemh(INIT_HEX, mem);
        end
    end

    // PROT/LOCK accepted but unused at this scaffold level — they will be
    // checked once the core drives them with real semantics (§17/§22).
    // addr_q upper bits beyond INDEX_BITS+1 are not consulted by an N-word
    // memory; the index slice already discards them.
    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, PROT, LOCK, addr_q[31:INDEX_BITS+2]};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
