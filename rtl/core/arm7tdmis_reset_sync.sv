// External-nRESET synchronizer.
//
// AGENTS.md says synchronous deassertion of nRESET at the macrocell boundary
// is required (TRM §4 / §30.4); inside the core, every other flop uses sync
// reset and reads `core_nreset` instead of `nRESET` directly. This module is
// the only place where nRESET appears as an asynchronous flop reset.
//
// The TRM also mandates that the system hold nRESET LOW for ≥ 2 CLK cycles
// (§30.4.1). The synchronizer enforces a 2-cycle deassertion delay anyway:
// when nRESET returns HIGH, q1 picks up the 1 on the next CLK, q2 follows
// the cycle after, so `core_nreset` stays LOW for at least one full
// post-deassert cycle. Clean for downstream sync flops.
//
// On Cyclone V, ALM flops have async clear, so this maps cleanly. On other
// FPGAs without async preset/clear, the pattern still works but the
// synthesizer may insert sync-reset emulation logic.

module arm7tdmis_reset_sync (
    input  logic CLK,
    input  logic nRESET,
    output logic core_nreset
);

    (* altera_attribute = "-name PRESERVE_REGISTER ON; -name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    logic q1;
    (* altera_attribute = "-name PRESERVE_REGISTER ON; -name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    logic q2;

    always_ff @(posedge CLK or negedge nRESET) begin
        if (!nRESET) begin
            q1 <= 1'b0;
            q2 <= 1'b0;
        end else begin
            q1 <= 1'b1;
            q2 <= q1;
        end
    end

    assign core_nreset = q2;

endmodule
