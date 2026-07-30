// SPDX-License-Identifier: GPL-3.0-only
//
// Real MiSTer-framework integration shell for the repository's generic SoC.
// The official Template_MiSTer sys/ tree remains unmodified; this module is
// copied over the template's core-specific Template.sv by the pinned builder.

module emu (
    `include "sys/emu_ports.vh"
);

    `include "build_id.v"

    localparam CONF_STR = {
        "ARM7TDMI-S;;",
        "-;",
        "T[0],Reset;",
        "R[0],Reset and close OSD;",
        "V,v", `BUILD_DATE
    };

    logic         clk_sys;
    logic         pll_locked;
    logic [127:0] status;
    logic [1:0]   buttons;
    logic [1:0]   reset_release_q;
    logic [9:0]   video_h_q;
    logic [8:0]   video_v_q;
    logic [26:0]  activity_q;
    logic [7:0]   uart_last_q;
    logic         uart_valid;
    logic [7:0]   uart_data;
    logic         timer_irq;

    wire reset_request = RESET | status[0] | buttons[1] | !pll_locked;
    wire reset_n = reset_release_q[1];
    wire video_active = video_h_q < 10'd640 && video_v_q < 9'd400;
    wire hsync = !(video_h_q >= 10'd656 && video_h_q < 10'd752);
    wire vsync = !(video_v_q >= 9'd412 && video_v_q < 9'd414);

    pll u_pll (
        .refclk   (CLK_50M),
        .rst      (1'b0),
        .outclk_0 (clk_sys),
        .locked   (pll_locked)
    );

    hps_io #(.CONF_STR(CONF_STR)) u_hps_io (
        .clk_sys         (clk_sys),
        .HPS_BUS         (HPS_BUS),
        .EXT_BUS         (),
        .gamma_bus       (),
        .buttons         (buttons),
        .status          (status),
        .status_menumask (1'b0)
    );

    always_ff @(posedge clk_sys or posedge reset_request) begin
        if (reset_request) begin
            reset_release_q <= 2'b00;
        end else begin
            reset_release_q <= {reset_release_q[0], 1'b1};
        end
    end

    always_ff @(posedge clk_sys) begin
        if (!reset_n) begin
            video_h_q  <= 10'd0;
            video_v_q  <= 9'd0;
            activity_q <= 27'd0;
            uart_last_q <= 8'h00;
        end else begin
            activity_q <= activity_q + 27'd1;
            if (video_h_q == 10'd799) begin
                video_h_q <= 10'd0;
                if (video_v_q == 9'd499)
                    video_v_q <= 9'd0;
                else
                    video_v_q <= video_v_q + 9'd1;
            end else begin
                video_h_q <= video_h_q + 10'd1;
            end
            if (uart_valid)
                uart_last_q <= uart_data;
        end
    end

    arm7tdmi_generic_soc u_soc (
        .CLK           (clk_sys),
        .RESET_N       (reset_n),
        .CPU_CE        (1'b1),
        .UART_TX_READY (1'b1),
        .UART_TX_VALID (uart_valid),
        .UART_TX_DATA  (uart_data),
        .TIMER_IRQ     (timer_irq)
    );

    assign CLK_VIDEO = clk_sys;
    assign CE_PIXEL = 1'b1;
    assign VIDEO_ARX = 13'd4;
    assign VIDEO_ARY = 13'd3;
    assign VGA_DE = video_active;
    assign VGA_HS = hsync;
    assign VGA_VS = vsync;
    assign VGA_R = video_active ? {uart_last_q[7:5], video_h_q[4:0]} : 8'h00;
    assign VGA_G = video_active ? {uart_last_q[4:2], video_v_q[4:0]} : 8'h00;
    assign VGA_B = video_active ? {uart_last_q[1:0], video_h_q[5:0]} : 8'h00;
    assign VGA_F1 = 1'b0;
    assign VGA_SL = 2'b00;
    assign VGA_SCALER = 1'b0;
    assign VGA_DISABLE = 1'b0;
    assign HDMI_FREEZE = 1'b0;
    assign HDMI_BLACKOUT = 1'b0;
    assign HDMI_BOB_DEINT = 1'b0;

    assign LED_USER = activity_q[24] | timer_irq;
    assign LED_POWER = 2'b00;
    assign LED_DISK = 2'b00;
    assign BUTTONS = 2'b00;

    assign AUDIO_L = 16'h0000;
    assign AUDIO_R = 16'h0000;
    assign AUDIO_S = 1'b0;
    assign AUDIO_MIX = 2'b00;

    assign ADC_BUS = 'z;
    assign SD_SCK = 1'bz;
    assign SD_MOSI = 1'bz;
    assign SD_CS = 1'bz;
    assign DDRAM_CLK = 1'b0;
    assign DDRAM_BURSTCNT = 8'h00;
    assign DDRAM_ADDR = 29'h0000_0000;
    assign DDRAM_DIN = 64'h0000_0000_0000_0000;
    assign DDRAM_BE = 8'h00;
    assign DDRAM_RD = 1'b0;
    assign DDRAM_WE = 1'b0;
    assign SDRAM_CLK = 1'bz;
    assign SDRAM_CKE = 1'bz;
    assign SDRAM_A = 'z;
    assign SDRAM_BA = 'z;
    assign SDRAM_DQ = 'z;
    assign SDRAM_DQML = 1'bz;
    assign SDRAM_DQMH = 1'bz;
    assign SDRAM_nCS = 1'bz;
    assign SDRAM_nCAS = 1'bz;
    assign SDRAM_nRAS = 1'bz;
    assign SDRAM_nWE = 1'bz;
    assign UART_RTS = 1'b0;
    assign UART_TXD = 1'b1;
    assign UART_DTR = 1'b0;
    assign USER_OUT = '1;

`ifdef MISTER_FB
    assign FB_EN = 1'b0;
    assign FB_FORMAT = 5'h00;
    assign FB_WIDTH = 12'h000;
    assign FB_HEIGHT = 12'h000;
    assign FB_BASE = 32'h0000_0000;
    assign FB_STRIDE = 14'h0000;
    assign FB_FORCE_BLANK = 1'b0;
`ifdef MISTER_FB_PALETTE
    assign FB_PAL_CLK = 1'b0;
    assign FB_PAL_ADDR = 8'h00;
    assign FB_PAL_DOUT = 24'h000000;
    assign FB_PAL_WR = 1'b0;
`endif
`endif

`ifdef MISTER_DUAL_SDRAM
    assign SDRAM2_CLK = 1'bz;
    assign SDRAM2_A = 'z;
    assign SDRAM2_BA = 'z;
    assign SDRAM2_DQ = 'z;
    assign SDRAM2_nCS = 1'bz;
    assign SDRAM2_nCAS = 1'bz;
    assign SDRAM2_nRAS = 1'bz;
    assign SDRAM2_nWE = 1'bz;
`endif

    wire _unused_inputs = &{
        1'b0,
        HDMI_WIDTH,
        HDMI_HEIGHT,
        CLK_AUDIO,
        SD_MISO,
        SD_CD,
        DDRAM_BUSY,
        DDRAM_DOUT,
        DDRAM_DOUT_READY,
        UART_CTS,
        UART_RXD,
        UART_DSR,
        USER_IN,
        OSD_STATUS
`ifdef MISTER_FB
        ,
        FB_VBL,
        FB_LL
`ifdef MISTER_FB_PALETTE
        ,
        FB_PAL_DIN
`endif
`endif
`ifdef MISTER_DUAL_SDRAM
        ,
        SDRAM2_EN
`endif
    };

endmodule
