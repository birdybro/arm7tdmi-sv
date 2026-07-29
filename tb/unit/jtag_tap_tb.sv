// JTAG-001/JTAG-003 fail-hard compliance regression for the ARM7TDMI-S TAP.
//
// This bench covers every edge of the 16-state IEEE 1149.1 state machine,
// asynchronous DBGnTRST, DBGTCKEN holds, the fixed IR/SCAN_N capture values,
// all five public instructions, BYPASS behavior for every unused opcode,
// reserved scan chains, physical scan-chain ordering, update pulses, and
// RESTART taking effect only on entry to Run-Test/Idle.

`timescale 1ns/1ps

module jtag_tap_tb
    import arm7tdmis_debug_pkg::*;
;

    logic CLK = 1'b0;
    initial forever #5 CLK = ~CLK;

    logic DBGTCKEN = 1'b1;
    logic DBGnTRST;
    logic DBGTMS;
    logic DBGTDI;
    logic DBGTDO;
    logic DBGnTDOEN;
    ir_e  current_ir;
    logic in_shift_dr;
    logic in_update_dr;
    logic in_capture_dr;

    logic [4:0]  ice_scan_addr;
    logic [37:0] ice_scan_wdata;
    logic        ice_scan_we;
    logic        ice_scan_re;
    logic [31:0] ice_scan_rdata;
    logic [4:0]  ice_scan_raddr;
    logic [31:0] ice_inject_instr;
    logic        ice_inject_break;
    logic        ice_inject_we;
    logic        tap_restart_req;

    arm7tdmis_jtag_tap dut (
        .CLK,
        .DBGTCKEN,
        .DBGnTRST,
        .DBGTMS,
        .DBGTDI,
        .DBGTDO,
        .DBGnTDOEN,
        .current_ir,
        .in_shift_dr,
        .in_update_dr,
        .in_capture_dr,
        .ice_scan_addr,
        .ice_scan_wdata,
        .ice_scan_we,
        .ice_scan_re,
        .ice_scan_rdata,
        .ice_scan_raddr,
        .ice_inject_instr,
        .ice_inject_break,
        .ice_inject_we,
        .tap_restart_req
    );

    // The encoding is internal, but checking it here makes every transition
    // observable without adding verification-only ports to the synthesizable
    // TAP. The architectural behavior does not depend on these values.
    localparam logic [3:0] TLR  = 4'h0;
    localparam logic [3:0] RTI  = 4'h1;
    localparam logic [3:0] SDRS = 4'h2;
    localparam logic [3:0] CDR  = 4'h3;
    localparam logic [3:0] SDR  = 4'h4;
    localparam logic [3:0] E1DR = 4'h5;
    localparam logic [3:0] PDR  = 4'h6;
    localparam logic [3:0] E2DR = 4'h7;
    localparam logic [3:0] UDR  = 4'h8;
    localparam logic [3:0] SIRS = 4'h9;
    localparam logic [3:0] CIR  = 4'hA;
    localparam logic [3:0] SIR  = 4'hB;
    localparam logic [3:0] E1IR = 4'hC;
    localparam logic [3:0] PIR  = 4'hD;
    localparam logic [3:0] E2IR = 4'hE;
    localparam logic [3:0] UIR  = 4'hF;

    int errors = 0;
    int scan_we_count;
    int scan_re_count;
    int inject_we_count;
    int restart_count;

    always @(posedge CLK or negedge DBGnTRST) begin
        if (!DBGnTRST) begin
            scan_we_count  <= 0;
            scan_re_count  <= 0;
            inject_we_count <= 0;
            restart_count  <= 0;
        end else begin
            if (ice_scan_we)
                scan_we_count <= scan_we_count + 1;
            if (ice_scan_re)
                scan_re_count <= scan_re_count + 1;
            if (ice_inject_we)
                inject_we_count <= inject_we_count + 1;
            if (tap_restart_req)
                restart_count <= restart_count + 1;
        end
    end

    task automatic check(input logic condition, input string message);
        if (!condition) begin
            $display("[jtag_tap] FAIL: %s", message);
            errors = errors + 1;
        end
    endtask

    task automatic tck(input logic tms, input logic tdi);
        DBGTMS = tms;
        DBGTDI = tdi;
        @(posedge CLK);
        #1;
    endtask

    task automatic reset_tap;
        DBGnTRST = 1'b0;
        #1;
        check($unsigned(dut.tap_q) == TLR,
              "DBGnTRST did not asynchronously enter Test-Logic-Reset");
        check(current_ir == IR_IDCODE,
              "DBGnTRST did not asynchronously select IDCODE");
        DBGnTRST = 1'b1;
        #1;
    endtask

    function automatic logic [3:0] expected_next(
        input logic [3:0] state_value,
        input logic       tms
    );
        unique case (state_value)
            TLR:  return tms ? TLR  : RTI;
            RTI:  return tms ? SDRS : RTI;
            SDRS: return tms ? SIRS : CDR;
            CDR:  return tms ? E1DR : SDR;
            SDR:  return tms ? E1DR : SDR;
            E1DR: return tms ? UDR  : PDR;
            PDR:  return tms ? E2DR : PDR;
            E2DR: return tms ? UDR  : SDR;
            UDR:  return tms ? SDRS : RTI;
            SIRS: return tms ? TLR  : CIR;
            CIR:  return tms ? E1IR : SIR;
            SIR:  return tms ? E1IR : SIR;
            E1IR: return tms ? UIR  : PIR;
            PIR:  return tms ? E2IR : PIR;
            E2IR: return tms ? UIR  : SIR;
            UIR:  return tms ? SDRS : RTI;
            default: return TLR;
        endcase
    endfunction

    task automatic goto_state(input logic [3:0] target);
        reset_tap();
        unique case (target)
            TLR: ;
            RTI:  tck(0, 0);
            SDRS: begin tck(0, 0); tck(1, 0); end
            CDR:  begin tck(0, 0); tck(1, 0); tck(0, 0); end
            SDR:  begin tck(0, 0); tck(1, 0); tck(0, 0); tck(0, 0); end
            E1DR: begin tck(0, 0); tck(1, 0); tck(0, 0); tck(1, 0); end
            PDR:  begin tck(0, 0); tck(1, 0); tck(0, 0); tck(1, 0);
                        tck(0, 0); end
            E2DR: begin tck(0, 0); tck(1, 0); tck(0, 0); tck(1, 0);
                        tck(0, 0); tck(1, 0); end
            UDR:  begin tck(0, 0); tck(1, 0); tck(0, 0); tck(1, 0);
                        tck(1, 0); end
            SIRS: begin tck(0, 0); tck(1, 0); tck(1, 0); end
            CIR:  begin tck(0, 0); tck(1, 0); tck(1, 0); tck(0, 0); end
            SIR:  begin tck(0, 0); tck(1, 0); tck(1, 0); tck(0, 0);
                        tck(0, 0); end
            E1IR: begin tck(0, 0); tck(1, 0); tck(1, 0); tck(0, 0);
                        tck(1, 0); end
            PIR:  begin tck(0, 0); tck(1, 0); tck(1, 0); tck(0, 0);
                        tck(1, 0); tck(0, 0); end
            E2IR: begin tck(0, 0); tck(1, 0); tck(1, 0); tck(0, 0);
                        tck(1, 0); tck(0, 0); tck(1, 0); end
            UIR:  begin tck(0, 0); tck(1, 0); tck(1, 0); tck(0, 0);
                        tck(1, 0); tck(1, 0); end
            default: ;
        endcase
        check($unsigned(dut.tap_q) == target,
              $sformatf("could not navigate to TAP state %0h", target));
    endtask

    task automatic load_ir(
        input  logic [3:0] value,
        output logic [3:0] captured_ir
    );
        // Precondition: Run-Test/Idle. Return there after Update-IR.
        tck(1, 0); // Select-DR-Scan
        tck(1, 0); // Select-IR-Scan
        tck(0, 0); // Capture-IR
        tck(0, 0); // Shift-IR, capture has occurred
        captured_ir = '0;
        for (int i = 0; i < 4; i++) begin
            captured_ir[i] = DBGTDO;
            check(!DBGnTDOEN, "TDO was not enabled during Shift-IR");
            tck(i == 3, value[i]);
        end
        tck(1, 0); // Update-IR
        tck(0, 0); // Run-Test/Idle; update takes effect on this edge
    endtask

    task automatic scan_dr(
        input  int unsigned width,
        input  logic [37:0] serial_in,
        output logic [37:0] serial_out
    );
        // serial_in[0] is the first bit presented to TDI.
        tck(1, 0); // Select-DR-Scan
        tck(0, 0); // Capture-DR
        tck(0, 0); // Shift-DR, capture has occurred
        serial_out = '0;
        for (int unsigned i = 0; i < width; i++) begin
            serial_out[i] = DBGTDO;
            check(!DBGnTDOEN, "TDO was not enabled during Shift-DR");
            tck(i == width - 1, serial_in[i]);
        end
        tck(1, 0); // Update-DR
        tck(0, 0); // Run-Test/Idle; update takes effect on this edge
    endtask

    task automatic select_chain(
        input  logic [3:0] chain,
        output logic [3:0] capture_value
    );
        logic [3:0]  ir_capture;
        logic [37:0] serial_in;
        logic [37:0] serial_out;
        load_ir(4'(IR_SCAN_N), ir_capture);
        check(ir_capture == IR_CAPTURE_PATTERN,
              "Capture-IR was not fixed 0001 for SCAN_N");
        serial_in = '0;
        serial_in[3:0] = chain;
        scan_dr(4, serial_in, serial_out);
        capture_value = serial_out[3:0];
        check(serial_out[37:4] == '0,
              "SCAN_N shifted beyond its four-bit register");
    endtask

    function automatic logic is_public_ir(input logic [3:0] value);
        return (value == 4'(IR_SCAN_N))
            || (value == 4'(IR_RESTART))
            || (value == 4'(IR_INTEST))
            || (value == 4'(IR_IDCODE))
            || (value == 4'(IR_BYPASS));
    endfunction

    initial begin
        logic [3:0]  ir_capture;
        logic [3:0]  scan_capture;
        logic [37:0] serial_in;
        logic [37:0] serial_out;
        logic [31:0] idcode;
        logic [31:0] inject_word;
        logic        inject_break;
        logic [31:0] scan_data;
        logic [4:0]  scan_addr;
        int          count_before;

        $dumpfile("jtag_tap.fst");
        DBGnTRST      = 1'b1;
        DBGTMS        = 1'b1;
        DBGTDI        = 1'b0;
        ice_scan_rdata = 32'hCAFE_BABE;
        ice_scan_raddr = 5'h15;
        #1;

        // Exercise both outgoing transitions from every TAP state.
        for (int state_value = 0; state_value < 16; state_value++) begin
            for (int tms_value = 0; tms_value < 2; tms_value++) begin
                goto_state(4'(state_value));
                tck(logic'(tms_value), 0);
                check($unsigned(dut.tap_q)
                      == expected_next(4'(state_value), logic'(tms_value)),
                      $sformatf("wrong transition from %0h with TMS=%0d",
                                state_value, tms_value));
            end
        end

        // DBGTCKEN must hold all TAP state, shift state, and output enables.
        goto_state(SIR);
        DBGTCKEN = 1'b0;
        tck(1, 1);
        check($unsigned(dut.tap_q) == SIR,
              "DBGTCKEN=0 advanced the TAP");
        check(!DBGnTDOEN, "DBGTCKEN hold changed Shift-IR TDO enable");
        DBGTCKEN = 1'b1;

        // Async reset must work from a paused path without a clock event.
        goto_state(PDR);
        DBGnTRST = 1'b0;
        #1;
        check($unsigned(dut.tap_q) == TLR,
              "async reset failed from Pause-DR");
        check(current_ir == IR_IDCODE,
              "async reset did not restore IDCODE");
        DBGnTRST = 1'b1;
        tck(0, 0); // Run-Test/Idle

        // Capture-IR is fixed for all 16 shifted values. Every unused
        // instruction must select the one-bit BYPASS data register.
        for (int opcode = 0; opcode < 16; opcode++) begin
            load_ir(4'(opcode), ir_capture);
            check(ir_capture == IR_CAPTURE_PATTERN,
                  $sformatf("Capture-IR mismatch while loading %0h", opcode));
            if (!is_public_ir(4'(opcode))) begin
                serial_in = '0;
                serial_in[0] = 1'b1;
                serial_in[1] = 1'b0;
                serial_in[2] = 1'b1;
                scan_dr(3, serial_in, serial_out);
                check(serial_out[0] == 1'b0
                      && serial_out[1] == serial_in[0]
                      && serial_out[2] == serial_in[1],
                      $sformatf("unused IR %0h did not behave as BYPASS",
                                opcode));
            end
        end

        // IDCODE fields and LSB-first serial order.
        load_ir(4'(IR_IDCODE), ir_capture);
        serial_in = '0;
        scan_dr(32, serial_in, serial_out);
        idcode = serial_out[31:0];
        check(idcode == IDCODE_VALUE, "IDCODE serial value mismatch");
        check(idcode[0] == 1'b1, "IDCODE bit zero was not one");
        check(idcode[31:28] == 4'h7, "IDCODE version field mismatch");
        check(idcode[27:12] == 16'hF1F0, "IDCODE part field mismatch");
        check(idcode[11:1] == 11'h787, "IDCODE manufacturer field mismatch");

        // SCAN_N has its own fixed 1000 Capture-DR value and only commits
        // the selected chain at Update-DR.
        select_chain(4'd1, scan_capture);
        check(scan_capture == 4'b1000,
              "SCAN_N Capture-DR did not return fixed 1000");

        // Physical chain-1 path is TDI -> DATA[0]..DATA[31] -> DBGBREAK
        // -> TDO. Therefore the host sends DBGBREAK first, followed by
        // instruction bits 31 down to 0.
        load_ir(4'(IR_INTEST), ir_capture);
        inject_word  = 32'hE8B0_1FFE;
        inject_break = 1'b1;
        serial_in = '0;
        serial_in[0] = inject_break;
        for (int i = 0; i < 32; i++)
            serial_in[i + 1] = inject_word[31 - i];
        count_before = inject_we_count;
        scan_dr(SCAN_CHAIN1_WIDTH, serial_in, serial_out);
        check(inject_we_count == count_before + 1,
              "chain 1 did not produce exactly one Update-DR pulse");
        check(ice_inject_instr == inject_word,
              "chain 1 physical ordering corrupted instruction data");
        check(ice_inject_break == inject_break,
              "chain 1 physical ordering corrupted DBGBREAK");

        // Reserved chains scan out zeros regardless of shifted input and
        // cannot trigger either architectural update path.
        select_chain(4'd3, scan_capture);
        load_ir(4'(IR_INTEST), ir_capture);
        serial_in = 38'h3_FFFF_FFFFF;
        count_before = inject_we_count + scan_we_count + scan_re_count;
        scan_dr(8, serial_in, serial_out);
        check(serial_out[7:0] == 8'h00,
              "reserved scan chain did not scan out zeros");
        check(inject_we_count + scan_we_count + scan_re_count == count_before,
              "reserved scan chain caused an architectural side effect");

        // Physical chain-2 path is TDI -> R/W -> ADDR[4:0] -> DATA[0:31]
        // -> TDO. Load DATA[31:0], ADDR[0:4], then R/W in serial time.
        select_chain(4'd2, scan_capture);
        load_ir(4'(IR_INTEST), ir_capture);
        scan_data = 32'hA5C3_69F0;
        scan_addr = 5'h15;
        serial_in = '0;
        for (int i = 0; i < 32; i++)
            serial_in[i] = scan_data[31 - i];
        for (int i = 0; i < 5; i++)
            serial_in[32 + i] = scan_addr[i];
        serial_in[37] = 1'b1;
        count_before = scan_we_count;
        scan_dr(SCAN_CHAIN2_WIDTH, serial_in, serial_out);
        check(scan_we_count == count_before + 1,
              "chain 2 write did not commit exactly at Update-DR");
        check(ice_scan_wdata == {1'b1, scan_addr, scan_data},
              "chain 2 physical ordering corrupted write request");
        check(ice_scan_addr == scan_addr,
              "chain 2 address output did not match shifted request");

        // A chain-2 read also takes place at Update-DR; Capture-DR itself
        // must not initiate the EmbeddedICE-RT access.
        serial_in[37] = 1'b0;
        count_before = scan_re_count;
        scan_dr(SCAN_CHAIN2_WIDTH, serial_in, serial_out);
        check(scan_re_count == count_before + 1,
              "chain 2 read did not commit at Update-DR");

        // The completed read is retained across the following Capture-DR.
        // Decode the physical scan-out order back into logical fields.
        serial_in = '0;
        scan_dr(SCAN_CHAIN2_WIDTH, serial_in, serial_out);
        for (int i = 0; i < 32; i++)
            scan_data[31 - i] = serial_out[i];
        for (int i = 0; i < 5; i++)
            scan_addr[i] = serial_out[32 + i];
        check(scan_data == ice_scan_rdata,
              "chain 2 read data was not retained through Capture-DR");
        check(scan_addr == ice_scan_raddr,
              "chain 2 read response address was not scanned out");
        check(serial_out[37] == 1'b0,
              "chain 2 read response had write bit set");

        // RESTART behaves as BYPASS but the architectural request occurs
        // once, on the edge entering Run-Test/Idle.
        count_before = restart_count;
        load_ir(4'(IR_RESTART), ir_capture);
        check(restart_count == count_before + 1,
              "RESTART did not pulse exactly once on Run-Test/Idle entry");
        tck(0, 0);
        check(restart_count == count_before + 1,
              "RESTART repeated while remaining in Run-Test/Idle");

        if (errors != 0)
            $fatal(1, "jtag_tap_tb: FAIL (%0d errors)", errors);
        $display("jtag_tap_tb: PASS");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "jtag_tap_tb: TIMEOUT");
    end

    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused = &{1'b0, in_shift_dr, in_update_dr, in_capture_dr};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
