// Verilator filelist. Order matters: packages first (in dependency order),
// then RTL units, then top. Run with `make -C scripts lint` (or `make lint`
// from here).

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
../rtl/core/arm7tdmis_psr.sv
../rtl/core/arm7tdmis_reset_sync.sv

../rtl/top/arm7tdmis_top.sv
