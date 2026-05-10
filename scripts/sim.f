// Verilator filelist. Order matters: packages first (in dependency order),
// then modules. Run with `make -C scripts lint` (or `make lint` from here).

+incdir+../rtl

../rtl/arm7tdmis_types_pkg.sv
../rtl/arm7tdmis_psr_pkg.sv
../rtl/arm7tdmis_bus_pkg.sv
../rtl/arm7tdmis_instr_pkg.sv
../rtl/arm7tdmis_debug_pkg.sv

../rtl/top/arm7tdmis_top.sv
