# Portable source manifest for the canonical FPGA wrapper.
# Paths are relative to this file and packages precede their consumers.

+incdir+../rtl

../rtl/arm7tdmis_types_pkg.sv
../rtl/arm7tdmis_psr_pkg.sv
../rtl/arm7tdmis_bus_pkg.sv
../rtl/arm7tdmis_instr_pkg.sv
../rtl/arm7tdmis_debug_pkg.sv

../rtl/datapath/arm7tdmis_regfile.sv
../rtl/datapath/arm7tdmis_shifter.sv
../rtl/datapath/arm7tdmis_alu.sv
../rtl/datapath/arm7tdmis_multiplier.sv
../rtl/decode/arm7tdmis_condition.sv
../rtl/decode/arm7tdmis_decoder.sv
../rtl/decode/arm7tdmis_thumb_decoder.sv
../rtl/core/arm7tdmis_psr.sv
../rtl/core/arm7tdmis_reset_sync.sv
../rtl/core/arm7tdmis_core_pipelined.sv

../rtl/jtag/arm7tdmis_jtag_tap.sv
../rtl/jtag/arm7tdmis_sync_debug_port.sv
../rtl/debug/arm7tdmis_ice_rt.sv

../rtl/top/arm7tdmis_top.sv
../rtl/top/arm7tdmi_mister.sv
