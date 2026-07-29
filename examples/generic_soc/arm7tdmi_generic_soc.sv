// Portable, synthesizable ROM/RAM/timer/UART system around arm7tdmi_mister.
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
    output logic       TIMER_IRQ
);

    localparam logic [31:0] ROM_BASE   = 32'h0000_0000;
    localparam logic [31:0] RAM_BASE   = 32'h1000_0000;
    localparam logic [31:0] TIMER_BASE = 32'h2000_0000;
    localparam logic [31:0] UART_BASE  = 32'h2000_1000;

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

    wire rom_selected = mem_addr[31:10] == ROM_BASE[31:10];
    wire ram_selected = mem_addr[31:10] == RAM_BASE[31:10];
    wire timer_selected = mem_addr[31:4] == TIMER_BASE[31:4];
    wire uart_selected = mem_addr[31:4] == UART_BASE[31:4];
    wire uart_data_write = uart_selected && mem_write
                         && mem_addr[3:2] == 2'b00;
    wire memory_accept = mem_valid && mem_ready;

    function automatic logic [31:0] rom_word(input logic [7:0] index);
        unique case (index)
            8'h00: return 32'hea00_000e;
            8'h01: return 32'heaff_fffe;
            8'h02: return 32'heaff_fffe;
            8'h03: return 32'heaff_fffe;
            8'h04: return 32'heaff_fffe;
            8'h05: return 32'heaff_fffe;
            8'h06: return 32'hea00_0020;
            8'h07: return 32'heaff_fffe;
            8'h10: return 32'he3a0_0201;
            8'h11: return 32'he3a0_102a;
            8'h12: return 32'he580_1000;
            8'h13: return 32'he590_2000;
            8'h14: return 32'he352_002a;
            8'h15: return 32'h1a00_000e;
            8'h16: return 32'he282_2001;
            8'h17: return 32'he580_2004;
            8'h18: return 32'he3a0_3202;
            8'h19: return 32'he283_3a01;
            8'h1a: return 32'he3a0_4047;
            8'h1b: return 32'he583_4000;
            8'h1c: return 32'he3a0_5202;
            8'h1d: return 32'he3a0_6050;
            8'h1e: return 32'he585_6004;
            8'h1f: return 32'he3a0_6003;
            8'h20: return 32'he585_6008;
            8'h21: return 32'he10f_7000;
            8'h22: return 32'he3c7_7080;
            8'h23: return 32'he121_f007;
            8'h24: return 32'heaff_fffe;
            8'h25: return 32'he3a0_4046;
            8'h26: return 32'he583_4000;
            8'h27: return 32'heaff_fffe;
            8'h28: return 32'he3a0_8001;
            8'h29: return 32'he585_800c;
            8'h2a: return 32'he3a0_9049;
            8'h2b: return 32'he583_9000;
            8'h2c: return 32'he25e_f004;
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
                end
            end
        end
    end

    assign UART_TX_VALID = uart_tx_valid_q;
    assign UART_TX_DATA  = uart_tx_data_q;
    assign TIMER_IRQ     = timer_pending_q && timer_control_q[1];

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
