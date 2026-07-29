// Bus / architectural assertions. §2 starter set — grows with the core.
// Today, only invariants the core must never violate at the bus boundary
// can be checked; programmer-visible state assertions (PC alignment, CPSR
// updates, exception vectoring, condition-fail no-write-back) need the
// core to surface internal state and land in §3+.
//
// The TRM-level checks here can run regardless of what the core is doing.
// Add one assertion per cycle test as features mature.

module arm7tdmis_assertions (
    input logic       CLK,
    input logic       nRESET,
    input logic [1:0] SIZE,
    input logic       ABORT,
    input logic [1:0] TRANS
);

    import arm7tdmis_bus_pkg::*;

    // SIZE = 2'b11 is reserved per TRM §3.4.3 Table 3-3 / TASKS.md §30.17.3.
    // The core must never produce it.
    always_ff @(posedge CLK) begin
        if (nRESET) begin
            assert (SIZE != 2'(SIZE_RESERVED))
                else $fatal(1, "SIZE drove reserved value 2'b11");
        end
    end

    // ABORT is an unconstrained input. Per TRM §3.5.3 the core samples it
    // only during enabled S/N data or opcode phases and must ignore it in
    // I/C cycles. Do not assert an environment restriction here; BUS-007
    // supplies directed ignore/sampling tests.
    wire _unused_abort = ABORT;
    wire _unused_trans = ^TRANS;

    // nRESET hold-time check per TRM §30.4.1: the system must hold nRESET
    // LOW for at least 2 CLK cycles. This is a system-side contract, not a
    // core requirement, but tracking it in the TB catches stimulus bugs.
    int unsigned nreset_low_cycles;
    logic        nreset_q;

    always_ff @(posedge CLK) begin
        nreset_q <= nRESET;
        if (!nRESET) begin
            nreset_low_cycles <= nreset_low_cycles + 1;
        end else if (!nreset_q && nRESET) begin
            // rising edge of nRESET — verify hold count
            assert (nreset_low_cycles >= 2)
                else $fatal(1,
                    "nRESET held LOW for only %0d cycles (TRM requires >= 2)",
                    nreset_low_cycles);
            nreset_low_cycles <= 0;
        end
    end

endmodule
