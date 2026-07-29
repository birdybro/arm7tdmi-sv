// Cycle logger. Writes one CSV row per CLKEN-active cycle. Internal-state
// columns (PC, CPSR, mode, ARM/Thumb state, decoded/executed instruction,
// exception state, debug state) are listed in TASKS.md §2.7 and will be
// added as ports once the core surfaces them — the §1 core is a port shell
// with no observable internal state, so only bus signals are logged today.

module arm7tdmis_cycle_logger #(
    parameter string LOG_FILE = "cycle.csv"
) (
    input logic        CLK,
    input logic        CLKEN,
    input logic        nRESET,

    input logic [63:0] cycle_count,

    // Bus signals (always present)
    input logic [31:0] ADDR,
    input logic        WRITE,
    input logic [1:0]  SIZE,
    input logic [1:0]  PROT,
    input logic        LOCK,
    input logic [1:0]  TRANS,
    input logic [31:0] WDATA,
    input logic [31:0] RDATA,
    input logic        ABORT
);

    int fh;

    initial begin
        fh = $fopen(LOG_FILE, "w");
        if (fh == 0) begin
            $fatal(1, "[cycle_logger] could not open %s", LOG_FILE);
        end
        $fdisplay(fh, "cycle,nRESET,ADDR,WRITE,SIZE,PROT,LOCK,TRANS,WDATA,RDATA,ABORT");
    end

    final $fclose(fh);

    always_ff @(posedge CLK) begin
        if (CLKEN) begin
            $fdisplay(fh,
                "%0d,%b,%08x,%b,%b,%b,%b,%b,%08x,%08x,%b",
                cycle_count, nRESET, ADDR, WRITE, SIZE, PROT, LOCK, TRANS,
                WDATA, RDATA, ABORT);
        end
    end

endmodule
