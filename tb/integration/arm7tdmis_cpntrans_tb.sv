// CP-003 regression: CPnTRANS reports the current privilege level on every
// active opcode and data address phase.  It must not encode code versus data;
// that distinction is carried separately by CPnOPC.

module arm7tdmis_cpntrans_tb
    import arm7tdmis_bus_pkg::*;
;

    logic CLK;
    logic nRESET;

    arm7tdmis_test_fixture #(
        .CYCLE_LIMIT (200),
        .INIT_HEX    ("../tb/programs/cpntrans_test.hex"),
        .TEST_NAME   ("cpntrans"),
        .FST_FILE    ("cpntrans.fst")
    ) u_fixture (
        .CFGBIGEND   (1'b0),
        .CLKEN       (1'b1),
        .nIRQ        (1'b1),
        .nFIQ        (1'b1),
        .inject_abort(1'b0),
        .CLK         (CLK),
        .nRESET      (nRESET)
    );

    int unsigned pin_errors;
    logic [3:0] seen;

    always_ff @(posedge CLK or negedge nRESET) begin
        if (!nRESET) begin
            pin_errors <= 0;
            seen       <= 4'b0000;
        end else if (u_fixture.TRANS inside {TRANS_N, TRANS_S}) begin
            seen[{u_fixture.PROT[PROT_BIT_PRIV],
                  u_fixture.PROT[PROT_BIT_DATA]}] <= 1'b1;

            if (u_fixture.CPnTRANS !==
                u_fixture.PROT[PROT_BIT_PRIV]) begin
                if (pin_errors < 8)
                    $display("[cpntrans] FAIL CPnTRANS=%b for PROT=%b ADDR=%08x",
                             u_fixture.CPnTRANS, u_fixture.PROT, u_fixture.ADDR);
                pin_errors <= pin_errors + 1;
            end
        end
    end

    int unsigned errors = 0;

    initial begin
        wait (nRESET);
        repeat (130) @(posedge CLK);

        if (u_fixture.u_dut.u_core.u_regfile.regs[3] !== 32'h00000003) begin
            $display("[cpntrans] FAIL User-mode marker expected 3, got %08x",
                     u_fixture.u_dut.u_core.u_regfile.regs[3]);
            errors = errors + 1;
        end

        if (u_fixture.u_dut.u_core.cpsr.m !== 5'b10000) begin
            $display("[cpntrans] FAIL final mode expected User, got %05b",
                     u_fixture.u_dut.u_core.cpsr.m);
            errors = errors + 1;
        end

        if (seen !== 4'b1111) begin
            $display("[cpntrans] FAIL did not observe all privilege/data combinations: %04b",
                     seen);
            errors = errors + 1;
        end

        if (pin_errors != 0) begin
            $display("[cpntrans] FAIL %0d pin-level mismatches", pin_errors);
            errors = errors + 1;
        end

        if (errors != 0)
            $fatal(1, "[cpntrans] FAIL (%0d errors)", errors);
        $display("[cpntrans] PASS");
        $finish;
    end

endmodule
