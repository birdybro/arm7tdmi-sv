// ISA-008/BUS-008 regression: post-indexed T-form loads and stores use
// User-mode memory privilege while retaining the current processor mode.
// Cover both word and byte transfers plus ordinary architectural effects.

module arm7tdmis_translated_ls_tb
    import arm7tdmis_bus_pkg::*;
;

    logic CLK;
    logic nRESET;

    arm7tdmis_test_fixture #(
        .CYCLE_LIMIT (220),
        .INIT_HEX    ("../tb/programs/translated_ls_test.hex"),
        .TEST_NAME   ("translated_ls"),
        .FST_FILE    ("translated_ls.fst")
    ) u_fixture (
        .CFGBIGEND   (1'b0),
        .CLKEN       (1'b1),
        .nIRQ        (1'b1),
        .nFIQ        (1'b1),
        .inject_abort(1'b0),
        .CLK         (CLK),
        .nRESET      (nRESET)
    );

    int unsigned data_cycles;
    int unsigned privilege_errors;

    always_ff @(posedge CLK or negedge nRESET) begin
        if (!nRESET) begin
            data_cycles      <= 0;
            privilege_errors <= 0;
        end else if ((u_fixture.TRANS inside {TRANS_N, TRANS_S})
                     && u_fixture.PROT[PROT_BIT_DATA]) begin
            data_cycles <= data_cycles + 1;
            if (u_fixture.PROT[PROT_BIT_PRIV] !== 1'b0) begin
                if (privilege_errors < 4)
                    $display("[translated_ls] FAIL privileged translated transfer at %08x",
                             u_fixture.ADDR);
                privilege_errors <= privilege_errors + 1;
            end
        end
    end

    int unsigned errors = 0;

    initial begin
        wait (nRESET);
        repeat (150) @(posedge CLK);

        if (data_cycles != 4) begin
            $display("[translated_ls] FAIL expected 4 data cycles, got %0d",
                     data_cycles);
            errors = errors + 1;
        end

        if (privilege_errors != 0) begin
            $display("[translated_ls] FAIL %0d translated transfers used privileged PROT",
                     privilege_errors);
            errors = errors + 1;
        end

        if (u_fixture.u_dut.u_core.cpsr.m !== 5'b10011) begin
            $display("[translated_ls] FAIL processor left SVC mode: %05b",
                     u_fixture.u_dut.u_core.cpsr.m);
            errors = errors + 1;
        end

        if (u_fixture.u_dut.u_core.u_regfile.regs[0] !== 32'h00000105) begin
            $display("[translated_ls] FAIL post-index base expected 0x105, got %08x",
                     u_fixture.u_dut.u_core.u_regfile.regs[0]);
            errors = errors + 1;
        end

        if (u_fixture.u_dut.u_core.u_regfile.regs[2] !== 32'h000000AA
            || u_fixture.u_dut.u_core.u_regfile.regs[4] !== 32'h000000BB) begin
            $display("[translated_ls] FAIL load results word=%08x byte=%08x",
                     u_fixture.u_dut.u_core.u_regfile.regs[2],
                     u_fixture.u_dut.u_core.u_regfile.regs[4]);
            errors = errors + 1;
        end

        if (u_fixture.u_mem.mem[64] !== 32'h000000AA
            || u_fixture.u_mem.mem[65][7:0] !== 8'hBB) begin
            $display("[translated_ls] FAIL memory word=%08x next=%08x",
                     u_fixture.u_mem.mem[64], u_fixture.u_mem.mem[65]);
            errors = errors + 1;
        end

        if (u_fixture.u_dut.u_core.u_regfile.regs[5] !== 32'h00000055) begin
            $display("[translated_ls] FAIL completion marker missing");
            errors = errors + 1;
        end

        if (errors != 0)
            $fatal(1, "[translated_ls] FAIL (%0d errors)", errors);
        $display("[translated_ls] PASS");
        $finish;
    end

endmodule
