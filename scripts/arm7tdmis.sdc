# ARM7TDMI-S Cyclone V timing constraints (TASKS.md §26 / §30.26).
#
# Target part: Cyclone V (concrete partnumber TBD — see §30.26.1).
# Conservative initial constraints to allow first-pass place-and-route;
# tighten once timing closure measurements come back from Quartus.

# ---- Main clock (CLK). 100 MHz nominal for first bring-up.
create_clock -name CLK -period 10.0 [get_ports CLK]

# JTAG TCK runs much slower than the system clock (typical Multi-ICE
# settings: 10 MHz). Treat as an asynchronous clock.
create_clock -name DBGTCK -period 100.0 [get_ports DBGTCK]

# CLK and DBGTCK are asynchronous to each other.
set_clock_groups -asynchronous \
    -group {CLK} \
    -group {DBGTCK}

# ---- Async reset paths.
# nRESET and DBGnTRST are asynchronous resets, synchronized inside the
# design (arm7tdmis_reset_sync.sv for nRESET; per-stage flops for the
# JTAG TAP and ICE-RT macrocell). Mark the paths from these pins as
# false (timing analysis can't bound async assert).
set_false_path -from [get_ports nRESET]
set_false_path -from [get_ports DBGnTRST]

# ---- Async control pins.
# nIRQ / nFIQ / DBGRQ / DBGBREAK / DBGEXT* are asynchronous to CLK and
# get sampled through 2-flop synchronizers inside the macrocell. Don't
# constrain the input-delay tightly; mark as false.
set_false_path -from [get_ports nIRQ]
set_false_path -from [get_ports nFIQ]
set_false_path -from [get_ports DBGRQ]
set_false_path -from [get_ports DBGBREAK]
set_false_path -from [get_ports DBGEXT[*]]

# ---- I/O timing — relaxed to 5 ns I/O delay for first pass.
set_input_delay  -clock CLK -max 5.0 [get_ports {RDATA[*] ABORT CPA CPB CFGBIGEND CLKEN DBGEN DBGTCKEN DBGTMS DBGTDI}]
set_output_delay -clock CLK -max 5.0 [get_ports {ADDR[*] WRITE SIZE[*] PROT[*] LOCK TRANS[*] WDATA[*] CPnMREQ CPSEQ CPnTRANS CPnOPC CPTBIT CPnI DBGACK DBGnEXEC DBGINSTRVALID DBGRNG[*] DBGCOMMTX DBGCOMMRX DMORE}]

# DBGTDO is in the DBGTCK domain.
set_output_delay -clock DBGTCK -max 20.0 [get_ports {DBGTDO DBGnTDOEN}]

# ---- DFT scan chain — held LOW during functional timing analysis.
# Scan paths through SE/SI/SO are timed separately by scan-insertion
# tools (Quartus DFT or Tessent ScanPro).
set_false_path -from [get_ports SE]
set_false_path -from [get_ports SI]
set_false_path -to   [get_ports SO]
