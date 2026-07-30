// Portable, synthesizable ROM/RAM/timer/UART/test system around
// arm7tdmi_mister.
//
// This is deliberately framework-neutral. It demonstrates a complete target
// for the canonical valid/ready API without generated clocks, private
// hierarchy, vendor primitives, firmware files, or simulation-only setup.

module arm7tdmi_generic_soc (
    input  logic       CLK,
    input  logic       RESET_N,
    input  logic       CPU_CE,
    input  logic       UART_TX_READY,
    output logic       UART_TX_VALID,
    output logic [7:0] UART_TX_DATA,
    output logic       TIMER_IRQ,
    output logic [31:0] TEST_STATUS,
    output logic [31:0] TEST_SIGNATURE
);

    localparam logic [31:0] ROM_BASE   = 32'h0000_0000;
    localparam logic [31:0] RAM_BASE   = 32'h1000_0000;
    localparam logic [31:0] TIMER_BASE = 32'h2000_0000;
    localparam logic [31:0] UART_BASE  = 32'h2000_1000;
    localparam logic [31:0] TEST_BASE  = 32'h2000_2000;

    logic        mem_valid;
    logic        mem_ready;
    logic [31:0] mem_addr;
    logic        mem_write;
    logic [31:0] mem_wdata;
    logic [3:0]  mem_byte_enable;
    logic        mem_code;
    logic        mem_privileged;
    logic        mem_lock;
    logic        mem_sequential;
    logic        mem_more;
    logic [31:0] mem_rdata;
    logic        mem_error;

    logic        cpnmreq_unused;
    logic        cpseq_unused;
    logic        cpntrans_unused;
    logic        cpnopc_unused;
    logic        cptbit_unused;
    logic        cpni_unused;
    logic        dbg_step_ready_unused;
    logic        dbg_step_rsp_valid_unused;
    logic        dbg_step_tdo_unused;
    logic        dbg_step_tdo_oe_unused;
    logic        dbgack_unused;
    logic        dbgnexec_unused;
    logic        dbginstrvalid_unused;
    logic [1:0]  dbgrng_unused;
    logic        dbgcommtx_unused;
    logic        dbgcommrx_unused;

    logic [31:0] ram_q [0:255];
    logic [31:0] timer_counter_q;
    logic [31:0] timer_compare_q;
    logic [1:0]  timer_control_q;
    logic        timer_pending_q;
    logic        uart_tx_valid_q;
    logic [7:0]  uart_tx_data_q;
    logic [31:0] test_status_q;
    logic [31:0] test_signature_q;

    wire rom_selected = mem_addr[31:10] == ROM_BASE[31:10];
    wire ram_selected = mem_addr[31:10] == RAM_BASE[31:10];
    wire timer_selected = mem_addr[31:4] == TIMER_BASE[31:4];
    wire uart_selected = mem_addr[31:4] == UART_BASE[31:4];
    wire test_selected = mem_addr[31:4] == TEST_BASE[31:4];
    wire uart_data_write = uart_selected && mem_write
                         && mem_addr[3:2] == 2'b00;
    wire memory_accept = mem_valid && mem_ready;

    // Exact little-endian words assembled from program.S. The mandatory
    // generic-soc-rom-check target compares all 256 words before regression.
    function automatic logic [31:0] rom_word(input logic [7:0] index);
        unique case (index)
            8'h00: return 32'hea00_000e;
            8'h01: return 32'hea00_00a5;
            8'h02: return 32'hea00_00a6;
            8'h03: return 32'hea00_00a7;
            8'h04: return 32'hea00_00a8;
            8'h05: return 32'hea00_00a9;
            8'h06: return 32'hea00_00ae;
            8'h07: return 32'hea00_00a9;
            8'h10: return 32'he3a0_a202;
            8'h11: return 32'he28a_aa02;
            8'h12: return 32'he59f_02b0;
            8'h13: return 32'he58a_0000;
            8'h14: return 32'he3a0_b001;
            8'h15: return 32'he58a_b004;
            8'h16: return 32'he3a0_d201;
            8'h17: return 32'he28d_db01;
            8'h18: return 32'he3a0_4201;
            8'h19: return 32'he59f_0298;
            8'h1a: return 32'he584_0000;
            8'h1b: return 32'he594_1000;
            8'h1c: return 32'he151_0000;
            8'h1d: return 32'h1a00_007d;
            8'h1e: return 32'he5d4_1001;
            8'h1f: return 32'he351_0033;
            8'h20: return 32'h1a00_007a;
            8'h21: return 32'he3a0_10aa;
            8'h22: return 32'he5c4_1002;
            8'h23: return 32'he594_1000;
            8'h24: return 32'he59f_2270;
            8'h25: return 32'he151_0002;
            8'h26: return 32'h1a00_0074;
            8'h27: return 32'he59f_1268;
            8'h28: return 32'he1c4_10b4;
            8'h29: return 32'he1d4_20b4;
            8'h2a: return 32'he152_0001;
            8'h2b: return 32'h1a00_006f;
            8'h2c: return 32'he1d4_20d4;
            8'h2d: return 32'he372_0011;
            8'h2e: return 32'h1a00_006c;
            8'h2f: return 32'he3a0_b002;
            8'h30: return 32'he58a_b004;
            8'h31: return 32'he3e0_0102;
            8'h32: return 32'he290_1001;
            8'h33: return 32'h7a00_0067;
            8'h34: return 32'h5a00_0066;
            8'h35: return 32'he3a0_2102;
            8'h36: return 32'he151_0002;
            8'h37: return 32'h1a00_0063;
            8'h38: return 32'he3a0_3000;
            8'h39: return 32'he353_0000;
            8'h3a: return 32'h03a0_305a;
            8'h3b: return 32'h13a0_30a5;
            8'h3c: return 32'he353_005a;
            8'h3d: return 32'h1a00_005d;
            8'h3e: return 32'he3a0_3001;
            8'h3f: return 32'he1a0_3f83;
            8'h40: return 32'he153_0002;
            8'h41: return 32'h1a00_0059;
            8'h42: return 32'he1b0_30e3;
            8'h43: return 32'h2a00_0057;
            8'h44: return 32'he3a0_2101;
            8'h45: return 32'he153_0002;
            8'h46: return 32'h1a00_0054;
            8'h47: return 32'he3a0_b003;
            8'h48: return 32'he58a_b004;
            8'h49: return 32'he3a0_0025;
            8'h4a: return 32'he3a0_100d;
            8'h4b: return 32'he002_0190;
            8'h4c: return 32'he59f_31d8;
            8'h4d: return 32'he152_0003;
            8'h4e: return 32'h1a00_004c;
            8'h4f: return 32'he3e0_0000;
            8'h50: return 32'he3a0_1002;
            8'h51: return 32'he083_2190;
            8'h52: return 32'he3e0_0001;
            8'h53: return 32'he152_0000;
            8'h54: return 32'h1a00_0046;
            8'h55: return 32'he353_0001;
            8'h56: return 32'h1a00_0044;
            8'h57: return 32'he3a0_b004;
            8'h58: return 32'he58a_b004;
            8'h59: return 32'he3a0_5015;
            8'h5a: return 32'he3a0_6026;
            8'h5b: return 32'he3a0_7037;
            8'h5c: return 32'he3a0_8048;
            8'h5d: return 32'he92d_01e0;
            8'h5e: return 32'he3a0_5000;
            8'h5f: return 32'he3a0_6000;
            8'h60: return 32'he3a0_7000;
            8'h61: return 32'he3a0_8000;
            8'h62: return 32'he8bd_01e0;
            8'h63: return 32'he355_0015;
            8'h64: return 32'h0356_0026;
            8'h65: return 32'h0357_0037;
            8'h66: return 32'h0358_0048;
            8'h67: return 32'h1a00_0033;
            8'h68: return 32'he3a0_0021;
            8'h69: return 32'heb00_0037;
            8'h6a: return 32'he350_0042;
            8'h6b: return 32'h1a00_002f;
            8'h6c: return 32'he3a0_b005;
            8'h6d: return 32'he58a_b004;
            8'h6e: return 32'he59f_0154;
            8'h6f: return 32'he584_0020;
            8'h70: return 32'he59f_1150;
            8'h71: return 32'he284_3020;
            8'h72: return 32'he103_2091;
            8'h73: return 32'he152_0000;
            8'h74: return 32'h1a00_0026;
            8'h75: return 32'he593_2000;
            8'h76: return 32'he152_0001;
            8'h77: return 32'h1a00_0023;
            8'h78: return 32'he3a0_b006;
            8'h79: return 32'he58a_b004;
            8'h7a: return 32'he3a0_0012;
            8'h7b: return 32'he28f_e004;
            8'h7c: return 32'he59f_1124;
            8'h7d: return 32'he12f_ff11;
            8'h7e: return 32'he350_002a;
            8'h7f: return 32'h1a00_001b;
            8'h80: return 32'he3a0_0047;
            8'h81: return 32'heb00_0021;
            8'h82: return 32'he3a0_b007;
            8'h83: return 32'he58a_b004;
            8'h84: return 32'he3a0_0000;
            8'h85: return 32'he584_0080;
            8'h86: return 32'he3a0_5202;
            8'h87: return 32'he3a0_0080;
            8'h88: return 32'he585_0004;
            8'h89: return 32'he3a0_0003;
            8'h8a: return 32'he585_0008;
            8'h8b: return 32'he10f_0000;
            8'h8c: return 32'he3c0_0080;
            8'h8d: return 32'he121_f000;
            8'h8e: return 32'he3a0_6801;
            8'h8f: return 32'he594_0080;
            8'h90: return 32'he350_0001;
            8'h91: return 32'h0a00_0002;
            8'h92: return 32'he256_6001;
            8'h93: return 32'h1aff_fffa;
            8'h94: return 32'hea00_0006;
            8'h95: return 32'he59f_00c4;
            8'h96: return 32'he58a_0004;
            8'h97: return 32'he59f_00c0;
            8'h98: return 32'he58a_0000;
            8'h99: return 32'he3a0_0050;
            8'h9a: return 32'heb00_0008;
            8'h9b: return 32'heaff_fffe;
            8'h9c: return 32'he58a_b004;
            8'h9d: return 32'he59f_00ac;
            8'h9e: return 32'he58a_0000;
            8'h9f: return 32'he3a0_0046;
            8'ha0: return 32'heb00_0002;
            8'ha1: return 32'heaff_fffe;
            8'ha2: return 32'he080_0000;
            8'ha3: return 32'he1a0_f00e;
            8'ha4: return 32'he3a0_1202;
            8'ha5: return 32'he281_1a01;
            8'ha6: return 32'he581_0000;
            8'ha7: return 32'he1a0_f00e;
            8'ha8: return 32'he3a0_b0e1;
            8'ha9: return 32'hea00_0008;
            8'haa: return 32'he3a0_b0e2;
            8'hab: return 32'hea00_0006;
            8'hac: return 32'he3a0_b0e3;
            8'had: return 32'hea00_0004;
            8'hae: return 32'he3a0_b0e4;
            8'haf: return 32'hea00_0002;
            8'hb0: return 32'he3a0_b0e5;
            8'hb1: return 32'hea00_0000;
            8'hb2: return 32'he3a0_b0e6;
            8'hb3: return 32'he3a0_a202;
            8'hb4: return 32'he28a_aa02;
            8'hb5: return 32'heaff_ffe5;
            8'hb6: return 32'he3a0_0001;
            8'hb7: return 32'he585_000c;
            8'hb8: return 32'he584_0080;
            8'hb9: return 32'he3a0_0049;
            8'hba: return 32'he3a0_1202;
            8'hbb: return 32'he281_1a01;
            8'hbc: return 32'he581_0000;
            8'hbd: return 32'he25e_f004;
            8'hbe: return 32'h0040_3018;
            8'hbf: return 32'h4770_0840;
            8'hc0: return 32'h5255_4e21;
            8'hc1: return 32'h1122_3344;
            8'hc2: return 32'h11aa_3344;
            8'hc3: return 32'h0000_beef;
            8'hc4: return 32'h0000_01e1;
            8'hc5: return 32'hdead_beef;
            8'hc6: return 32'ha5a5_a5a5;
            8'hc7: return 32'h0000_02f9;
            8'hc8: return 32'ha7d1_c0de;
            8'hc9: return 32'h5041_5353;
            8'hca: return 32'h4641_494c;
            default: return 32'h0000_0000;
        endcase
    endfunction

    always_comb begin
        mem_ready = 1'b0;
        mem_rdata = 32'h0000_0000;
        mem_error = 1'b0;

        if (mem_valid) begin
            mem_ready = 1'b1;
            if (rom_selected) begin
                mem_rdata = rom_word(mem_addr[9:2]);
                mem_error = mem_write;
            end else if (ram_selected) begin
                mem_rdata = ram_q[mem_addr[9:2]];
            end else if (timer_selected) begin
                unique case (mem_addr[3:2])
                    2'b00: mem_rdata = timer_counter_q;
                    2'b01: mem_rdata = timer_compare_q;
                    2'b10: mem_rdata = {30'h0, timer_control_q};
                    2'b11: mem_rdata = {31'h0, timer_pending_q};
                    default: mem_rdata = 32'h0000_0000;
                endcase
                if (mem_write && mem_byte_enable != 4'b1111)
                    mem_error = 1'b1;
            end else if (uart_selected) begin
                unique case (mem_addr[3:2])
                    2'b00: begin
                        mem_rdata = {24'h0, uart_tx_data_q};
                        if (uart_data_write) begin
                            mem_ready = !uart_tx_valid_q || UART_TX_READY;
                            if (mem_byte_enable != 4'b1111)
                                mem_error = 1'b1;
                        end
                    end
                    2'b01: mem_rdata = {
                        30'h0, uart_tx_valid_q, UART_TX_READY
                    };
                    default: mem_error = 1'b1;
                endcase
            end else if (test_selected) begin
                unique case (mem_addr[3:2])
                    2'b00: mem_rdata = test_status_q;
                    2'b01: mem_rdata = test_signature_q;
                    default: mem_error = 1'b1;
                endcase
                if (mem_write && mem_byte_enable != 4'b1111)
                    mem_error = 1'b1;
            end else begin
                mem_error = 1'b1;
            end
        end
    end

    always_ff @(posedge CLK or negedge RESET_N) begin
        if (!RESET_N) begin
            timer_counter_q <= 32'h0000_0000;
            timer_compare_q <= 32'h0000_0000;
            timer_control_q <= 2'b00;
            timer_pending_q <= 1'b0;
            uart_tx_valid_q <= 1'b0;
            uart_tx_data_q  <= 8'h00;
            test_status_q    <= 32'h0000_0000;
            test_signature_q <= 32'h0000_0000;
        end else begin
            if (timer_control_q[0] && !timer_pending_q) begin
                if (timer_compare_q != 32'h0000_0000
                    && timer_counter_q + 32'd1 >= timer_compare_q) begin
                    timer_pending_q <= 1'b1;
                end else begin
                    timer_counter_q <= timer_counter_q + 32'd1;
                end
            end

            if (uart_tx_valid_q && UART_TX_READY)
                uart_tx_valid_q <= 1'b0;

            if (memory_accept && mem_write && !mem_error) begin
                if (ram_selected) begin
                    for (int lane = 0; lane < 4; lane++) begin
                        if (mem_byte_enable[lane])
                            ram_q[mem_addr[9:2]][lane * 8 +: 8]
                                <= mem_wdata[lane * 8 +: 8];
                    end
                end else if (timer_selected) begin
                    unique case (mem_addr[3:2])
                        2'b01: timer_compare_q <= mem_wdata;
                        2'b10: begin
                            timer_control_q <= mem_wdata[1:0];
                            timer_counter_q <= 32'h0000_0000;
                            timer_pending_q <= 1'b0;
                        end
                        2'b11: begin
                            if (mem_wdata[0]) begin
                                timer_pending_q   <= 1'b0;
                                timer_control_q[0] <= 1'b0;
                            end
                        end
                        default: begin
                        end
                    endcase
                end else if (uart_data_write) begin
                    uart_tx_valid_q <= 1'b1;
                    uart_tx_data_q  <= mem_wdata[7:0];
                end else if (test_selected) begin
                    unique case (mem_addr[3:2])
                        2'b00: test_status_q <= mem_wdata;
                        2'b01: test_signature_q <= mem_wdata;
                        default: begin
                        end
                    endcase
                end
            end
        end
    end

    assign UART_TX_VALID = uart_tx_valid_q;
    assign UART_TX_DATA  = uart_tx_data_q;
    assign TIMER_IRQ     = timer_pending_q && timer_control_q[1];
    assign TEST_STATUS    = test_status_q;
    assign TEST_SIGNATURE = test_signature_q;

    arm7tdmi_mister u_cpu (
        .CLK,
        .RESET_N,
        .CPU_CE,
        .IRQ_ASYNC            (TIMER_IRQ),
        .FIQ_ASYNC            (1'b0),
        .MEM_VALID            (mem_valid),
        .MEM_READY            (mem_ready),
        .MEM_ADDR             (mem_addr),
        .MEM_WRITE            (mem_write),
        .MEM_WDATA            (mem_wdata),
        .MEM_BYTE_ENABLE      (mem_byte_enable),
        .MEM_CODE             (mem_code),
        .MEM_PRIVILEGED       (mem_privileged),
        .MEM_LOCK             (mem_lock),
        .MEM_SEQUENTIAL       (mem_sequential),
        .MEM_MORE             (mem_more),
        .MEM_RDATA            (mem_rdata),
        .MEM_ERROR            (mem_error),
        .CPnMREQ              (cpnmreq_unused),
        .CPSEQ                (cpseq_unused),
        .CPnTRANS             (cpntrans_unused),
        .CPnOPC               (cpnopc_unused),
        .CPTBIT               (cptbit_unused),
        .CPnI                 (cpni_unused),
        .CPA                  (1'b1),
        .CPB                  (1'b1),
        .DEBUG_ENABLE_ASYNC   (1'b0),
        .DBGRQ_ASYNC          (1'b0),
        .DBGBREAK_ASYNC       (1'b0),
        .DBGEXT_ASYNC         (2'b00),
        .DBG_STEP_VALID       (1'b0),
        .DBG_STEP_READY       (dbg_step_ready_unused),
        .DBG_STEP_TMS         (1'b0),
        .DBG_STEP_TDI         (1'b0),
        .DBG_STEP_RSP_VALID   (dbg_step_rsp_valid_unused),
        .DBG_STEP_RSP_READY   (1'b1),
        .DBG_STEP_TDO         (dbg_step_tdo_unused),
        .DBG_STEP_TDO_OE      (dbg_step_tdo_oe_unused),
        .DBGACK               (dbgack_unused),
        .DBGnEXEC             (dbgnexec_unused),
        .DBGINSTRVALID        (dbginstrvalid_unused),
        .DBGRNG               (dbgrng_unused),
        .DBGCOMMTX            (dbgcommtx_unused),
        .DBGCOMMRX            (dbgcommrx_unused)
    );

    wire _unused_cpu_outputs = &{
        1'b0,
        mem_addr[1:0],
        mem_code,
        mem_privileged,
        mem_lock,
        mem_sequential,
        mem_more,
        cpnmreq_unused,
        cpseq_unused,
        cpntrans_unused,
        cpnopc_unused,
        cptbit_unused,
        cpni_unused,
        dbg_step_ready_unused,
        dbg_step_rsp_valid_unused,
        dbg_step_tdo_unused,
        dbg_step_tdo_oe_unused,
        dbgack_unused,
        dbgnexec_unused,
        dbginstrvalid_unused,
        dbgrng_unused,
        dbgcommtx_unused,
        dbgcommrx_unused
    };

endmodule
