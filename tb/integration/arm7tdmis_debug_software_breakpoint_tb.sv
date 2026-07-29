// DBG-003 / TRM §5.21.2 data-dependent software-breakpoint regression.
//
// Five independent cores program WP0 through public JTAG with an ignored
// address and exact opcode data:
//   0. an ARM word match must halt;
//   1. a Thumb match in the lower bus half must halt;
//   2. a Thumb match in the upper bus half must halt;
//   3. a lower-half Thumb fetch must ignore a matching adjacent upper half;
//   4. an upper-half Thumb fetch must ignore a matching adjacent lower half.
//   5-8. repeat both matches and both negative cases in big-endian mode.
//
// The memory deliberately returns the complete 32-bit word for halfword
// reads, as permitted by TRM §3.5.4. EmbeddedICE-RT must select only the
// valid fetched halfword. The repeated Thumb pattern is the programming
// sequence mandated by §5.21.2.

`timescale 1ns/1ps

/* verilator lint_off DECLFILENAME */
module arm7tdmis_debug_software_breakpoint_scenario #(
    parameter int unsigned SCENARIO = 0
) (
    input  logic CLK,
    output logic done,
    output logic failed
);
    import arm7tdmis_bus_pkg::*;
    import arm7tdmis_debug_pkg::*;
    import arm7tdmis_jtag_tb_pkg::*;

    localparam int unsigned ARM_MATCH         = 0;
    localparam int unsigned THUMB_LOW_MATCH   = 1;
    localparam int unsigned THUMB_HIGH_MATCH  = 2;
    localparam int unsigned THUMB_LOW_FALSE   = 3;
    localparam int unsigned THUMB_HIGH_FALSE  = 4;
    localparam int unsigned THUMB_BE_LOW_MATCH  = 5;
    localparam int unsigned THUMB_BE_HIGH_MATCH = 6;
    localparam int unsigned THUMB_BE_LOW_FALSE  = 7;
    localparam int unsigned THUMB_BE_HIGH_FALSE = 8;
    localparam bit BIG_ENDIAN = SCENARIO >= THUMB_BE_LOW_MATCH;

    logic nRESET = 1'b0;
    logic CLKEN = 1'b0;
    logic DBGTCKEN = 1'b0;
    logic DBGTMS = 1'b1;
    logic DBGTDI = 1'b0;
    logic DBGnTRST = 1'b0;

    logic [31:0] ADDR, WDATA, RDATA;
    logic WRITE, LOCK;
    logic [1:0] SIZE, PROT, TRANS;
    logic CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI;
    logic DBGACK, DBGnEXEC, DBGINSTRVALID;
    logic [1:0] DBGRNG;
    logic DBGCOMMTX, DBGCOMMRX, DBGTDO, DBGnTDOEN, DMORE;

    arm7tdmis_top u_dut (
        .CLK,
        .CLKEN,
        .nRESET,
        .CFGBIGEND        (BIG_ENDIAN),
        .nIRQ             (1'b1),
        .nFIQ             (1'b1),
        .ABORT            (1'b0),
        .ADDR, .WRITE, .SIZE, .PROT, .LOCK, .TRANS, .WDATA, .RDATA,
        .CPnMREQ, .CPSEQ, .CPnTRANS, .CPnOPC, .CPTBIT, .CPnI,
        .CPA              (1'b1),
        .CPB              (1'b1),
        .DBGEN            (1'b1),
        .DBGRQ            (1'b0),
        .DBGBREAK         (1'b0),
        .DBGACK,
        .DBGnEXEC,
        .DBGINSTRVALID,
        .DBGEXT           (2'b00),
        .DBGRNG,
        .DBGCOMMTX,
        .DBGCOMMRX,
        .DBGTCKEN,
        .DBGTMS,
        .DBGTDI,
        .DBGTDO,
        .DBGnTRST,
        .DBGnTDOEN,
        .DMORE
    );

    logic [31:0] mem_addr_q;
    logic        mem_active_q;

    // A legal 32-bit memory may return the complete word for a halfword
    // read. The core and EmbeddedICE-RT independently select the addressed
    // Thumb halfword.
    function automatic logic [31:0] memory_word(
        input logic [5:0] word_address
    );
        unique case (word_address)
            6'h00: memory_word = 32'hEA00_0006; // B 0x20
            6'h08: begin
                if (SCENARIO == ARM_MATCH)
                    memory_word = 32'hE7F1_23F4;
                else if ((SCENARIO == THUMB_HIGH_MATCH)
                          || (SCENARIO == THUMB_HIGH_FALSE)
                          || (SCENARIO == THUMB_BE_HIGH_MATCH)
                          || (SCENARIO == THUMB_BE_HIGH_FALSE))
                    memory_word = 32'hE3A0_0043; // MOV r0,#0x43
                else
                    memory_word = 32'hE3A0_0041; // MOV r0,#0x41
            end
            6'h09: memory_word = 32'hE12F_FF10; // BX r0
            6'h0A: memory_word = 32'hEAFF_FFFE;
            6'h10: begin
                unique case (SCENARIO)
                    THUMB_LOW_MATCH:  memory_word = 32'h2233_DE55;
                    THUMB_HIGH_MATCH: memory_word = 32'hDE55_2233;
                    THUMB_LOW_FALSE:  memory_word = 32'hDE55_E002;
                    THUMB_HIGH_FALSE: memory_word = 32'hE001_DE55;
                    THUMB_BE_LOW_MATCH:  memory_word = 32'hDE55_2233;
                    THUMB_BE_HIGH_MATCH: memory_word = 32'h2233_DE55;
                    THUMB_BE_LOW_FALSE:  memory_word = 32'hE002_DE55;
                    THUMB_BE_HIGH_FALSE: memory_word = 32'hDE55_E001;
                    default:          memory_word = 32'hE7FE_E7FE;
                endcase
            end
            6'h12: memory_word = BIG_ENDIAN
                                   ? 32'h2155_E7FE
                                   : 32'hE7FE_2155; // MOV r1,#0x55; B .
            default: memory_word = 32'hE1A0_0000; // ARM NOP
        endcase
    endfunction

    always_ff @(posedge CLK) begin
        if (!nRESET) begin
            mem_addr_q   <= 32'h0;
            mem_active_q <= 1'b0;
        end else if (CLKEN) begin
            mem_addr_q   <= ADDR;
            mem_active_q <= TRANS inside {2'(TRANS_N), 2'(TRANS_S)};
        end
    end

    assign RDATA = mem_active_q ? memory_word(mem_addr_q[7:2]) : 32'h0;

    logic [37:0] scan_ignored;

    task automatic tck(input logic tms, input logic tdi);
        @(negedge CLK);
        DBGTMS   = tms;
        DBGTDI   = tdi;
        DBGTCKEN = 1'b1;
        @(posedge CLK);
        #1;
        DBGTCKEN = 1'b0;
    endtask

    task automatic load_ir(input logic [3:0] instruction);
        tck(1'b1, 1'b0);
        tck(1'b1, 1'b0);
        tck(1'b0, 1'b0);
        tck(1'b0, 1'b0);
        for (int i = 0; i < 4; i++)
            tck(i == 3, instruction[i]);
        tck(1'b1, 1'b0);
        tck(1'b0, 1'b0);
    endtask

    task automatic shift_dr(
        input  int unsigned width,
        input  logic [37:0] scan_in,
        output logic [37:0] scan_out
    );
        scan_out = '0;
        tck(1'b1, 1'b0);
        tck(1'b0, 1'b0);
        tck(1'b0, 1'b0);
        for (int i = 0; i < width; i++) begin
            scan_out[i] = DBGTDO;
            tck(i == (width - 1), scan_in[i]);
        end
        tck(1'b1, 1'b0);
        tck(1'b0, 1'b0);
    endtask

    task automatic select_chain2;
        load_ir(4'(IR_SCAN_N));
        shift_dr(4, 38'd2, scan_ignored);
        load_ir(4'(IR_INTEST));
    endtask

    task automatic write_ice(
        input logic [4:0] address,
        input logic [31:0] data
    );
        shift_dr(38, chain2_serial_in(1'b1, address, data),
                 scan_ignored);
    endtask

    logic range_seen;
    always_ff @(posedge CLK) begin
        if (!nRESET)
            range_seen <= 1'b0;
        else if (DBGRNG[0])
            range_seen <= 1'b1;
    end

    initial begin : run
        logic [31:0] pattern;
        logic [31:0] expected_pc;
        bit halt_expected;
        bit outcome_seen;

        done   = 1'b0;
        failed = 1'b0;

        repeat (4) @(posedge CLK);
        nRESET = 1'b1;
        repeat (2) @(posedge CLK);
        DBGnTRST = 1'b1;
        tck(1'b0, 1'b0);
        select_chain2();

        pattern = (SCENARIO == ARM_MATCH)
                ? 32'hE7F1_23F4 : 32'hDE55_DE55;

        // Software-breakpoint recipe: ignore the address and every control
        // field except PROT[0], then compare exact instruction data.
        write_ice(5'h08, 32'h0000_0000);
        write_ice(5'h09, 32'hFFFF_FFFF);
        write_ice(5'h0A, pattern);
        write_ice(5'h0B, 32'h0000_0000);
        write_ice(5'h0C, 32'h0000_0100);
        write_ice(5'h0D, 32'h0000_00F7);

        CLKEN = 1'b1;
        halt_expected = SCENARIO inside {
            ARM_MATCH, THUMB_LOW_MATCH, THUMB_HIGH_MATCH,
            THUMB_BE_LOW_MATCH, THUMB_BE_HIGH_MATCH
        };
        expected_pc = (SCENARIO == ARM_MATCH) ? 32'h0000_0020
                    : (((SCENARIO == THUMB_HIGH_MATCH)
                        || (SCENARIO == THUMB_BE_HIGH_MATCH))
                       ? 32'h0000_0042 : 32'h0000_0040);
        outcome_seen = 1'b0;

        for (int i = 0; i < 220; i++) begin
            @(posedge CLK);
            #1;
            if (DBGACK) begin
                outcome_seen = 1'b1;
                if (!halt_expected) begin
                    $display("[debug_software_breakpoint/%0d] FAIL false halt at %08x",
                             SCENARIO, u_dut.u_core.de_q.pc);
                    failed = 1'b1;
                end else begin
                    if (u_dut.u_core.de_q.pc !== expected_pc) begin
                        $display("[debug_software_breakpoint/%0d] FAIL halt PC expected %08x got %08x",
                                 SCENARIO, expected_pc,
                                 u_dut.u_core.de_q.pc);
                        failed = 1'b1;
                    end
                    if (!range_seen) begin
                        $display("[debug_software_breakpoint/%0d] FAIL DBGRNG never matched",
                                 SCENARIO);
                        failed = 1'b1;
                    end
                end
                break;
            end
            if (!halt_expected
                && u_dut.u_core.u_regfile.regs[1] == 32'h0000_0055) begin
                outcome_seen = 1'b1;
                break;
            end
        end

        if (!outcome_seen) begin
            $display("[debug_software_breakpoint/%0d] FAIL expected %s outcome not observed",
                     SCENARIO, halt_expected ? "halt" : "completion");
            failed = 1'b1;
        end
        if (halt_expected
            && u_dut.u_core.u_regfile.regs[1] !== 32'h0) begin
            $display("[debug_software_breakpoint/%0d] FAIL post-breakpoint marker executed",
                     SCENARIO);
            failed = 1'b1;
        end

        done = 1'b1;
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, WRITE, SIZE, PROT, LOCK, WDATA, CPnMREQ,
        CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI, DBGnEXEC,
        DBGINSTRVALID, DBGRNG[1], DBGCOMMTX, DBGCOMMRX, DBGnTDOEN,
        DMORE, scan_ignored, mem_addr_q[31:8], mem_addr_q[1:0]};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
/* verilator lint_on DECLFILENAME */

module arm7tdmis_debug_software_breakpoint_tb;
    localparam int CYCLE_LIMIT = 2600;

    logic CLK = 1'b0;
    initial forever #5 CLK = ~CLK;

    logic [8:0] done;
    logic [8:0] failed;

    arm7tdmis_debug_software_breakpoint_scenario #(.SCENARIO(0)) u_arm (
        .CLK, .done(done[0]), .failed(failed[0])
    );
    arm7tdmis_debug_software_breakpoint_scenario #(.SCENARIO(1)) u_thumb_low (
        .CLK, .done(done[1]), .failed(failed[1])
    );
    arm7tdmis_debug_software_breakpoint_scenario #(.SCENARIO(2)) u_thumb_high (
        .CLK, .done(done[2]), .failed(failed[2])
    );
    arm7tdmis_debug_software_breakpoint_scenario #(.SCENARIO(3)) u_false_low (
        .CLK, .done(done[3]), .failed(failed[3])
    );
    arm7tdmis_debug_software_breakpoint_scenario #(.SCENARIO(4)) u_false_high (
        .CLK, .done(done[4]), .failed(failed[4])
    );
    arm7tdmis_debug_software_breakpoint_scenario #(.SCENARIO(5)) u_be_thumb_low (
        .CLK, .done(done[5]), .failed(failed[5])
    );
    arm7tdmis_debug_software_breakpoint_scenario #(.SCENARIO(6)) u_be_thumb_high (
        .CLK, .done(done[6]), .failed(failed[6])
    );
    arm7tdmis_debug_software_breakpoint_scenario #(.SCENARIO(7)) u_be_false_low (
        .CLK, .done(done[7]), .failed(failed[7])
    );
    arm7tdmis_debug_software_breakpoint_scenario #(.SCENARIO(8)) u_be_false_high (
        .CLK, .done(done[8]), .failed(failed[8])
    );

    initial begin
        $dumpfile("debug_software_breakpoint.fst");
        $dumpvars(0, arm7tdmis_debug_software_breakpoint_tb);
        wait (&done);
        if (|failed)
            $fatal(1, "[debug_software_breakpoint] FAIL scenarios=%09b",
                   failed);
        $display("[debug_software_breakpoint] PASS");
        $finish;
    end

    initial begin
        repeat (CYCLE_LIMIT) @(posedge CLK);
        $fatal(1, "[debug_software_breakpoint] TIMEOUT done=%09b failed=%09b",
               done, failed);
    end
endmodule
