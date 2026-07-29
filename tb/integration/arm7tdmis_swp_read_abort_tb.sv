// EXC-007 regression: ARM7TDMI-S requires a SWP abort to be returned
// on the read. The failed read must suppress the following write transfer
// and destination writeback for both SWP and SWPB.

`timescale 1ns/1ps

/* verilator lint_off DECLFILENAME */
module arm7tdmis_swp_read_abort_scenario #(
    parameter bit    BYTE     = 1'b0,
    parameter string FST_FILE = "swp_read_abort.fst"
) (
    output logic done,
    output logic failed
);
    import arm7tdmis_bus_pkg::*;

    logic CLK;
    logic nRESET;
    logic inject_abort;

    arm7tdmis_test_fixture #(
        .CYCLE_LIMIT (220),
        .INIT_HEX    ("../tb/programs/swp_read_abort_test.hex"),
        .TEST_NAME   ("swp_read_abort"),
        .FST_FILE    (FST_FILE)
    ) u_fixture (
        .CFGBIGEND   (1'b0),
        .CLKEN       (1'b1),
        .nIRQ        (1'b1),
        .nFIQ        (1'b1),
        .inject_abort(inject_abort),
        .CLK         (CLK),
        .nRESET      (nRESET)
    );

    // Patch the placeholder while reset is asserted. Encodings are:
    //   SWP  r1,r2,[r4] = E1041092
    //   SWPB r1,r2,[r4] = E1441092
    initial begin
        @(posedge CLK);
        u_fixture.u_mem.mem[11] = BYTE ? 32'hE1441092 : 32'hE1041092;
    end

    assign inject_abort =
        (u_fixture.u_dut.u_core.state_q == 5'd3); // S_SWP_RDATA

    logic seen_abort;
    logic seen_write_address;

    always_ff @(posedge CLK or negedge nRESET) begin
        if (!nRESET) begin
            seen_abort         <= 1'b0;
            seen_write_address <= 1'b0;
        end else begin
            if (u_fixture.ABORT)
                seen_abort <= 1'b1;
            if ((u_fixture.TRANS inside {TRANS_N, TRANS_S})
                && u_fixture.WRITE && u_fixture.PROT[0])
                seen_write_address <= 1'b1;
        end
    end

    int unsigned errors;
    string kind;

    initial begin
        done   = 1'b0;
        failed = 1'b0;
        errors = 0;
        kind   = BYTE ? "SWPB" : "SWP";

        wait (nRESET);
        repeat (165) @(posedge CLK);

        if (!seen_abort || seen_write_address) begin
            $display("[swp_read_abort/%s] FAIL abort=%b write-address=%b",
                     kind, seen_abort, seen_write_address);
            errors = errors + 1;
        end
        if (u_fixture.u_mem.mem[64] !== 32'hCAFE_BABE) begin
            $display("[swp_read_abort/%s] FAIL memory changed to %08x",
                     kind, u_fixture.u_mem.mem[64]);
            errors = errors + 1;
        end
        if (u_fixture.u_dut.u_core.u_regfile.regs[1]
            !== 32'h00000055) begin
            $display("[swp_read_abort/%s] FAIL r1 changed to %08x",
                     kind, u_fixture.u_dut.u_core.u_regfile.regs[1]);
            errors = errors + 1;
        end
        if (u_fixture.u_dut.u_core.u_regfile.regs[8] !== 32'h0
            || u_fixture.u_dut.u_core.u_regfile.regs[9]
               !== 32'h000000EE) begin
            $display("[swp_read_abort/%s] FAIL flow markers r8=%08x r9=%08x",
                     kind,
                     u_fixture.u_dut.u_core.u_regfile.regs[8],
                     u_fixture.u_dut.u_core.u_regfile.regs[9]);
            errors = errors + 1;
        end
        if (u_fixture.u_dut.u_core.u_regfile.regs[28]
            !== 32'h00000034
            || u_fixture.u_dut.u_core.cpsr.m !== 5'b10111
            || u_fixture.u_dut.u_core.pc_q !== 32'h00000054
            || u_fixture.LOCK !== LOCK_FREE) begin
            $display("[swp_read_abort/%s] FAIL lr=%08x mode=%05b pc=%08x lock=%b",
                     kind,
                     u_fixture.u_dut.u_core.u_regfile.regs[28],
                     u_fixture.u_dut.u_core.cpsr.m,
                     u_fixture.u_dut.u_core.pc_q, u_fixture.LOCK);
            errors = errors + 1;
        end

        failed = (errors != 0);
        done   = 1'b1;
    end
endmodule
/* verilator lint_on DECLFILENAME */

module arm7tdmis_swp_read_abort_tb;
    logic word_done, byte_done;
    logic word_failed, byte_failed;

    arm7tdmis_swp_read_abort_scenario #(
        .BYTE     (1'b0),
        .FST_FILE ("swp_read_abort_word.fst")
    ) u_word (
        .done   (word_done),
        .failed (word_failed)
    );

    arm7tdmis_swp_read_abort_scenario #(
        .BYTE     (1'b1),
        .FST_FILE ("swp_read_abort_byte.fst")
    ) u_byte (
        .done   (byte_done),
        .failed (byte_failed)
    );

    initial begin
        wait (word_done && byte_done);
        if (word_failed || byte_failed)
            $fatal(1, "[swp_read_abort] FAIL");
        $display("[swp_read_abort] PASS (SWP and SWPB)");
        $finish;
    end
endmodule
