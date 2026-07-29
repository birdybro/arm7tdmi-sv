// ISA-011 regression: for STM with writeback and Rn in the transfer list,
// ARMv4T defines the stored base value when Rn is the lowest-numbered
// register: it is the original, pre-writeback value. Verify that rule and
// the address/writeback result for IA, IB, DA, and DB.

`timescale 1ns/1ps

/* verilator lint_off DECLFILENAME */
module arm7tdmis_stm_base_list_scenario #(
    parameter int    MODE     = 0,
    parameter string FST_FILE = "stm_base_list.fst"
) (
    output logic done,
    output logic failed
);
    localparam int MODE_IA = 0;
    localparam int MODE_IB = 1;
    localparam int MODE_DA = 2;
    localparam int MODE_DB = 3;

    logic CLK;
    logic nRESET;

    arm7tdmis_test_fixture #(
        .CYCLE_LIMIT (220),
        .INIT_HEX    ("../tb/programs/stm_base_list_test.hex"),
        .TEST_NAME   ("stm_base_list"),
        .FST_FILE    (FST_FILE)
    ) u_fixture (
        .CFGBIGEND   (1'b0),
        .CLKEN       (1'b1),
        .nIRQ        (1'b1),
        .nFIQ        (1'b1),
        .inject_abort(1'b0),
        .CLK         (CLK),
        .nRESET      (nRESET)
    );

    logic pre;
    logic up;
    logic [31:0] opcode;
    int unsigned start_word;
    logic [31:0] final_base;
    string mode_name;

    initial begin
        unique case (MODE)
            MODE_IA: begin
                pre        = 1'b0;
                up         = 1'b1;
                start_word = 64;
                final_base = 32'h00000108;
                mode_name  = "IA";
            end
            MODE_IB: begin
                pre        = 1'b1;
                up         = 1'b1;
                start_word = 65;
                final_base = 32'h00000108;
                mode_name  = "IB";
            end
            MODE_DA: begin
                pre        = 1'b0;
                up         = 1'b0;
                start_word = 63;
                final_base = 32'h000000F8;
                mode_name  = "DA";
            end
            default: begin
                pre        = 1'b1;
                up         = 1'b0;
                start_word = 62;
                final_base = 32'h000000F8;
                mode_name  = "DB";
            end
        endcase

        // STM<mode> r4!, {r4,r5}; placeholder is at byte address 0x28.
        opcode = {4'hE, 3'b100, pre, up, 1'b0, 1'b1, 1'b0,
                  4'd4, 16'h0030};
        @(posedge CLK);
        u_fixture.u_mem.mem[10] = opcode;
        for (int word = 62; word <= 66; word++)
            u_fixture.u_mem.mem[word] = 32'hCAFE0000 | 32'(word);
    end

    int unsigned errors;

    initial begin
        done   = 1'b0;
        failed = 1'b0;
        errors = 0;

        wait (nRESET);
        repeat (150) @(posedge CLK);

        if (u_fixture.u_mem.mem[start_word]
            !== 32'h00000100) begin
            $display("[stm_base_list/%s] FAIL stored base expected 00000100 got %08x",
                     mode_name, u_fixture.u_mem.mem[start_word]);
            errors = errors + 1;
        end
        if (u_fixture.u_mem.mem[start_word + 1]
            !== 32'h00000055) begin
            $display("[stm_base_list/%s] FAIL stored r5 expected 00000055 got %08x",
                     mode_name,
                     u_fixture.u_mem.mem[start_word + 1]);
            errors = errors + 1;
        end
        if (u_fixture.u_dut.u_core.u_regfile.regs[4]
            !== final_base) begin
            $display("[stm_base_list/%s] FAIL final base expected %08x got %08x",
                     mode_name, final_base,
                     u_fixture.u_dut.u_core.u_regfile.regs[4]);
            errors = errors + 1;
        end
        if (u_fixture.u_dut.u_core.u_regfile.regs[8]
            !== 32'h000000DD
            || u_fixture.u_dut.u_core.cpsr.m !== 5'b10011) begin
            $display("[stm_base_list/%s] FAIL marker=%08x mode=%05b",
                     mode_name,
                     u_fixture.u_dut.u_core.u_regfile.regs[8],
                     u_fixture.u_dut.u_core.cpsr.m);
            errors = errors + 1;
        end

        failed = (errors != 0);
        done   = 1'b1;
    end
endmodule
/* verilator lint_on DECLFILENAME */

module arm7tdmis_stm_base_list_tb;
    logic done0, done1, done2, done3;
    logic fail0, fail1, fail2, fail3;

    arm7tdmis_stm_base_list_scenario #(
        .MODE(0), .FST_FILE("stm_base_list_ia.fst")
    ) u_ia (.done(done0), .failed(fail0));

    arm7tdmis_stm_base_list_scenario #(
        .MODE(1), .FST_FILE("stm_base_list_ib.fst")
    ) u_ib (.done(done1), .failed(fail1));

    arm7tdmis_stm_base_list_scenario #(
        .MODE(2), .FST_FILE("stm_base_list_da.fst")
    ) u_da (.done(done2), .failed(fail2));

    arm7tdmis_stm_base_list_scenario #(
        .MODE(3), .FST_FILE("stm_base_list_db.fst")
    ) u_db (.done(done3), .failed(fail3));

    initial begin
        wait (done0 && done1 && done2 && done3);
        if (fail0 || fail1 || fail2 || fail3)
            $fatal(1, "[stm_base_list] FAIL");
        $display("[stm_base_list] PASS (IA/IB/DA/DB)");
        $finish;
    end
endmodule
