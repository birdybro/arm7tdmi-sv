// EXC-011 / TRM Table 7-16 exception-entry pin matrix.
//
// Twelve reset-isolated rows cover SWI, UNDEF, PABT, DABT, IRQ, and FIQ
// from both ARM and Thumb User state.  Every row scoreboards all three
// entry cycles at the raw ARM7TDMI-S pins:
//   1. vector Xn, N, privileged ARM address class (CPSR still old)
//   2. vector Xn+4, S, privileged ARM state
//   3. vector Xn+8, S, privileged ARM state
// The response during cycle 1 is the abandoned old-state PC+2i opcode.
// Section 7.1 places the address-class values one cycle ahead of that
// returned data; the trailing Xn+8 row is therefore visible on the pins.
// Poison instructions in the abandoned sequential path additionally prove
// that returned prefetched data from the entry window is discarded.

`timescale 1ns/1ps

/* verilator lint_off DECLFILENAME */
module arm7tdmis_exception_bus_matrix_scenario #(
    parameter int KIND = 0,
    parameter bit THUMB = 1'b0
) (
    output logic done,
    output logic failed
);
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_types_pkg::*;

    localparam int K_SWI   = 0;
    localparam int K_UNDEF = 1;
    localparam int K_PABT  = 2;
    localparam int K_DABT  = 3;
    localparam int K_IRQ   = 4;
    localparam int K_FIQ   = 5;

    localparam logic [31:0] FAULT_PC = 32'h0000_0040;

    logic CLK;
    logic nRESET;
    logic nIRQ;
    logic nFIQ;
    logic inject_abort;
    logic [31:0] arm_opcode;
    logic [15:0] thumb_opcode;

    arm7tdmis_test_fixture #(
        .CYCLE_LIMIT (220),
        .MEMORY_WORDS(256),
        .INIT_HEX    (THUMB
                      ? "../tb/programs/thumb_exception_lr_test.hex"
                      : "../tb/programs/arm_exception_lr_test.hex"),
        .TEST_NAME   ("exception_bus_matrix"),
        .FST_FILE    ("exception_bus_matrix.fst")
    ) u_fixture (
        .CFGBIGEND    (1'b0),
        .CLKEN        (1'b1),
        .nIRQ         (nIRQ),
        .nFIQ         (nFIQ),
        .inject_abort (inject_abort),
        .CLK          (CLK),
        .nRESET       (nRESET)
    );

    always_comb begin
        unique case (KIND)
            K_SWI: begin
                arm_opcode   = 32'hEF00_0000; // SWI #0
                thumb_opcode = 16'hDF00;      // SWI #0
            end
            K_UNDEF: begin
                arm_opcode   = 32'hEE00_0700; // unclaimed p0 CDP
                thumb_opcode = 16'hDE00;      // reserved cond=1110
            end
            K_DABT: begin
                arm_opcode   = 32'hE594_1000; // LDR r1,[r4]
                thumb_opcode = 16'h6821;      // LDR r1,[r4,#0]
            end
            default: begin
                arm_opcode   = 32'hE1A0_0000; // MOV r0,r0
                thumb_opcode = 16'h46C0;      // MOV r8,r8 (NOP)
            end
        endcase
    end

    // Run the source instruction in User mode so cycle 1's old-state
    // protection value differs from cycles 2/3.  Place poison writes in
    // every possible abandoned sequential slot (normal and DABT).
    initial begin
        @(posedge CLK);
        u_fixture.u_mem.mem[8] = 32'hE321_F010; // MSR CPSR_c,#MODE_USER
        if (THUMB) begin
            u_fixture.u_mem.mem[16] = {16'h25A5, thumb_opcode};
            u_fixture.u_mem.mem[17] = {16'h265A, 16'h2355};
        end else begin
            u_fixture.u_mem.mem[16] = arm_opcode;
            u_fixture.u_mem.mem[17] = 32'hE3A0_50A5;
            u_fixture.u_mem.mem[18] = 32'hE3A0_605A;
            u_fixture.u_mem.mem[19] = 32'hE3A0_3055;
        end
    end

    wire collision_window =
        (u_fixture.u_dut.u_core.state_q == 4'd0)
        && u_fixture.u_dut.u_core.de_q.valid
        && (u_fixture.u_dut.u_core.de_q.pc == FAULT_PC);

    assign nIRQ = ((KIND == K_IRQ) && collision_window) ? 1'b0 : 1'b1;
    assign nFIQ = ((KIND == K_FIQ) && collision_window) ? 1'b0 : 1'b1;

    always_comb begin
        inject_abort = 1'b0;
        if (KIND == K_PABT)
            inject_abort = u_fixture.u_mem.is_active_q
                         && (u_fixture.u_mem.addr_q == FAULT_PC);
        else if (KIND == K_DABT)
            inject_abort = (u_fixture.u_dut.u_core.state_q == 4'd1);
    end

    int unsigned errors = 0;
    int unsigned phase;
    logic entry_checked;
    string kind_name;
    logic [31:0] vector;
    logic [4:0] target_mode;

    task automatic check_pin_cycle(
        input int unsigned cycle_number,
        input logic [31:0] expected_addr,
        input logic [1:0] expected_trans,
        input logic [1:0] expected_size,
        input logic [1:0] expected_prot,
        input logic [4:0] expected_mode,
        input logic expected_t
    );
        if (u_fixture.ADDR !== expected_addr
            || u_fixture.TRANS !== expected_trans
            || u_fixture.SIZE !== expected_size
            || u_fixture.PROT !== expected_prot
            || u_fixture.WRITE !== WRITE_READ
            || u_fixture.LOCK !== LOCK_FREE
            || u_fixture.DMORE !== 1'b0
            || u_fixture.u_dut.u_core.cpsr.m !== expected_mode
            || u_fixture.u_dut.u_core.cpsr.t !== expected_t) begin
            $display("[exception_bus_matrix/%s/%s] FAIL cycle %0d addr=%08x trans=%02b size=%02b prot=%02b write=%b lock=%b dmore=%b mode=%05b T=%b expected %08x/%02b/%02b/%02b/%05b/%b",
                     THUMB ? "Thumb" : "ARM", kind_name, cycle_number,
                     u_fixture.ADDR, u_fixture.TRANS, u_fixture.SIZE,
                     u_fixture.PROT, u_fixture.WRITE, u_fixture.LOCK,
                     u_fixture.DMORE, u_fixture.u_dut.u_core.cpsr.m,
                     u_fixture.u_dut.u_core.cpsr.t, expected_addr,
                     expected_trans, expected_size, expected_prot,
                     expected_mode, expected_t);
            errors = errors + 1;
        end
    endtask

    // Sample halfway through each bus cycle, after edge-triggered state has
    // settled and before the receiving rising edge.
    always @(negedge CLK) begin
        if (!nRESET) begin
            phase         <= 0;
            entry_checked <= 1'b0;
        end else begin
            if (phase == 0 && u_fixture.u_dut.u_core.any_exc_fires) begin
                check_pin_cycle(
                    1, vector, 2'(TRANS_N), 2'(SIZE_WORD),
                    2'(PROT_OPC_PRIV), 5'(MODE_USER), THUMB);
                phase <= 1;
            end else if (phase == 1) begin
                check_pin_cycle(
                    2, vector + 32'd4, 2'(TRANS_S), 2'(SIZE_WORD),
                    2'(PROT_OPC_PRIV), target_mode, 1'b0);
                phase <= 2;
            end else if (phase == 2) begin
                check_pin_cycle(
                    3, vector + 32'd8, 2'(TRANS_S), 2'(SIZE_WORD),
                    2'(PROT_OPC_PRIV), target_mode, 1'b0);
                phase         <= 3;
                entry_checked <= 1'b1;
            end
        end
    end

    initial begin
        done   = 1'b0;
        failed = 1'b0;

        unique case (KIND)
            K_SWI: begin
                kind_name  = "SWI";
                vector     = 32'h0000_0008;
                target_mode = 5'(MODE_SUPERVISOR);
            end
            K_UNDEF: begin
                kind_name  = "UNDEF";
                vector     = 32'h0000_0004;
                target_mode = 5'(MODE_UNDEFINED);
            end
            K_PABT: begin
                kind_name  = "PABT";
                vector     = 32'h0000_000C;
                target_mode = 5'(MODE_ABORT);
            end
            K_DABT: begin
                kind_name  = "DABT";
                vector     = 32'h0000_0010;
                target_mode = 5'(MODE_ABORT);
            end
            K_IRQ: begin
                kind_name  = "IRQ";
                vector     = 32'h0000_0018;
                target_mode = 5'(MODE_IRQ);
            end
            default: begin
                kind_name  = "FIQ";
                vector     = 32'h0000_001C;
                target_mode = 5'(MODE_FIQ);
            end
        endcase

        wait (entry_checked);
        repeat (12) @(posedge CLK);
        #1;

        if (u_fixture.u_dut.u_core.u_regfile.regs[3] !== 32'h0
            || u_fixture.u_dut.u_core.u_regfile.regs[5] !== 32'h0
            || u_fixture.u_dut.u_core.u_regfile.regs[6] !== 32'h0) begin
            $display("[exception_bus_matrix/%s/%s] FAIL discarded prefetch executed r3/r5/r6=%08x/%08x/%08x",
                     THUMB ? "Thumb" : "ARM", kind_name,
                     u_fixture.u_dut.u_core.u_regfile.regs[3],
                     u_fixture.u_dut.u_core.u_regfile.regs[5],
                     u_fixture.u_dut.u_core.u_regfile.regs[6]);
            errors = errors + 1;
        end

        failed = (errors != 0);
        done   = 1'b1;
    end
endmodule
/* verilator lint_on DECLFILENAME */

module arm7tdmis_exception_bus_matrix_tb;
    logic [11:0] done;
    logic [11:0] failed;

    for (genvar row = 0; row < 12; row++) begin : g_row
        arm7tdmis_exception_bus_matrix_scenario #(
            .KIND (row % 6),
            .THUMB(row >= 6)
        ) u_scenario (
            .done  (done[row]),
            .failed(failed[row])
        );
    end

    initial begin
        wait (&done);
        if (|failed)
            $fatal(1, "[exception_bus_matrix] FAIL");
        $display("[exception_bus_matrix] PASS (6 classes x 2 states)");
        $finish;
    end
endmodule
