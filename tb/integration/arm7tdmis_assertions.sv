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
                else $error("SIZE drove reserved value 2'b11");
        end
    end

    // ABORT must only assert during active S/N memory cycles per TRM §3.5.3
    // / TASKS.md §30.17.5. The behavioral memory model already enforces this
    // on its own output, but assert at the DUT boundary too — if the core
    // ever sees ABORT during I/C cycles in a real system, it must ignore
    // the input rather than trap.
    always_ff @(posedge CLK) begin
        if (nRESET && ABORT) begin
            assert (TRANS == 2'(TRANS_N) || TRANS == 2'(TRANS_S))
                else $error("ABORT asserted during non-S/N cycle (TRANS=%b)", TRANS);
        end
    end

endmodule
