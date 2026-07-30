# Core-local constraints layered on the unmodified MiSTer sys/sys_top.sdc.
# The template PLL produces the 12.5 MHz clk_sys used by the CPU and video.
derive_pll_clocks
derive_clock_uncertainty

# The official framework can select either its 148.54 MHz scaler clock or the
# core's 12.5 MHz direct-video clock at runtime.  The ADV7513 captures video on
# the rising edge of HDMI_TX_CLK; the DDIO forwarding cell deliberately
# inverts that edge relative to the output-register launch edge.  Rev. B of the
# ADV7513 data sheet specifies 1.0 ns setup and 0.7 ns hold for video inputs.
set core_video_clock [get_clocks \
    {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
set scaled_video_clock [get_clocks \
    {pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}]
set hdmi_ddio_clock_pin [get_pins -compatibility_mode \
    {hdmiclk_ddr|auto_generated|ddio_outa[0]|clkhi}]
set hdmi_video_ports [get_ports \
    {HDMI_TX_D[*] HDMI_TX_DE HDMI_TX_HS HDMI_TX_VS}]

create_generated_clock -name HDMI_TX_CAPTURE_SCALED \
    -master_clock $scaled_video_clock -source $hdmi_ddio_clock_pin -invert \
    [get_ports HDMI_TX_CLK]
create_generated_clock -name HDMI_TX_CAPTURE_DIRECT \
    -master_clock $core_video_clock -source $hdmi_ddio_clock_pin -invert -add \
    [get_ports HDMI_TX_CLK]
set_output_delay -clock HDMI_TX_CAPTURE_SCALED -max 1.0 $hdmi_video_ports
set_output_delay -clock HDMI_TX_CAPTURE_SCALED -min -0.7 $hdmi_video_ports
set_output_delay -clock HDMI_TX_CAPTURE_DIRECT -max 1.0 -add_delay \
    $hdmi_video_ports
set_output_delay -clock HDMI_TX_CAPTURE_DIRECT -min -0.7 -add_delay \
    $hdmi_video_ports

# Do not analyze a launch clock against the capture clock for the inactive
# input of the runtime clock mux.  Each active launch/capture pair remains
# timed above.
set_false_path -from $core_video_clock \
    -to [get_clocks HDMI_TX_CAPTURE_SCALED]
set_false_path -from $scaled_video_clock \
    -to [get_clocks HDMI_TX_CAPTURE_DIRECT]

# The audio PLL drives MCLK directly.  The framework divides it by 16 for the
# I2S bit clock.  Model the divider at its register output, propagate that
# clock to the physical SCLK pin, and apply the ADV7513's 2.0 ns I2S/LRCLK
# setup and hold requirements.
set audio_clock [get_clocks \
    {pll_audio|pll_audio_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
create_generated_clock -name HDMI_MCLK_OUT -master_clock $audio_clock \
    -source [get_pins \
    {pll_audio|pll_audio_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    [get_ports HDMI_MCLK]
create_generated_clock -name HDMI_SCLK_OUT -master_clock $audio_clock \
    -source [get_pins -compatibility_mode {audio_out|i2s|sclk|clk}] \
    -divide_by 16 \
    [get_pins -compatibility_mode {audio_out|i2s|sclk|q}]
set_output_delay -clock HDMI_SCLK_OUT -max 2.0 \
    [get_ports {HDMI_I2S HDMI_LRCLK}]
set_output_delay -clock HDMI_SCLK_OUT -min -2.0 \
    [get_ports {HDMI_I2S HDMI_LRCLK}]
create_generated_clock -name HDMI_SCLK_PIN -master_clock HDMI_SCLK_OUT \
    -source [get_pins -compatibility_mode {audio_out|i2s|sclk|q}] \
    [get_ports HDMI_SCLK]

# These inputs are asynchronous open-drain/status boundaries.  The listed
# outputs are open-drain, board indicators, or runtime mode-multiplexed
# SD/user pins with no phase relationship to an FPGA clock.  Enumerating the
# exact fitted ports prevents an accidental catch-all timing waiver.
set_false_path -from [get_ports \
    {HDMI_I2C_SDA HDMI_TX_INT IO_SDA SDCD_SPDIF}]
set_false_path -to [get_ports \
    {HDMI_I2C_SCL HDMI_I2C_SDA IO_SCL IO_SDA \
     LED[0] LED[2] LED[6] SDCD_SPDIF \
     SDIO_CLK SDIO_CMD SDIO_DAT[*] SD_SPI_CS \
     USER_IO[2] USER_IO[4] USER_IO[5]}]
