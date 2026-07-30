# Raw, feature-complete ARM7TDMI-S Cyclone V timing profile.
#
# ARM DDI 0234B Table 8-1 is provisional supplier-dependent macrocell timing,
# expressed as a fraction of the clock at maximum operating frequency. It is
# not an FPGA pin guarantee. This profile deliberately translates each
# applicable fraction at its selected 16 MHz (62.5 ns) target:
#   input max delay = negative source setup budget relative to the capture edge
#   output max delay = period - source clock-to-valid budget
#   source 0% input holds use a 0.25 ns target clock-skew margin
#   source >0% output holds use a 0 ns boundary and must retain positive slack.
# The revision-locked row inventory and disposition are in
# verification/ac_timing.json and docs/AC_TIMING.md.

# AC-T8:tcyc -- 100% minimum CLK cycle; selected target is 62.5 ns.
create_clock -name CLK -period 62.500 [get_ports {CLK}]
derive_clock_uncertainty

# nRESET and DBGnTRST assert asynchronously. nRESET releases through the
# architectural synchronizer; raw DBGnTRST release is integration-owned.
# AC-OWN:reset -- replaces the nRESET part of tisexc/tihexc.
set_false_path -from [get_ports {nRESET DBGnTRST}]

# AC-T8:tisclken -- stable 25 ns before the rising capture edge.
set_input_delay -clock CLK -max -25.000 [get_ports {CLKEN}]
# AC-T8:tihclken -- source 0% hold plus target clock-skew margin.
set_input_delay -clock CLK -min 0.250 [get_ports {CLKEN}]

# AC-T8:tisabort -- stable 9.375 ns before the rising capture edge.
set_input_delay -clock CLK -max -9.375 [get_ports {ABORT}]
# AC-T8:tihabort -- source 0% hold plus target clock-skew margin.
set_input_delay -clock CLK -min 0.250 [get_ports {ABORT}]

# AC-T8:tisrdata -- stable 6.25 ns before the rising capture edge.
set_input_delay -clock CLK -max -6.250 [get_ports {RDATA[*]}]
# AC-T8:tihrdata -- source 0% hold plus target clock-skew margin.
set_input_delay -clock CLK -min 0.250 [get_ports {RDATA[*]}]

# AC-T8:tiscpstat -- stable 12.5 ns before the rising capture edge.
set_input_delay -clock CLK -max -12.500 [get_ports {CPA CPB}]
# AC-T8:tihcpstat -- source 0% hold plus target clock-skew margin.
set_input_delay -clock CLK -min 0.250 [get_ports {CPA CPB}]

# AC-T8:tisexc -- 10% setup for synchronous nFIQ/nIRQ; nRESET is AC-OWN:reset.
set_input_delay -clock CLK -max -6.250 [get_ports {nFIQ nIRQ}]
# AC-T8:tihexc -- 0% hold for synchronous nFIQ/nIRQ; nRESET is AC-OWN:reset.
set_input_delay -clock CLK -min 0.250 [get_ports {nFIQ nIRQ}]

# AC-T8:tiscfg -- stable 6.25 ns before the rising capture edge.
set_input_delay -clock CLK -max -6.250 [get_ports {CFGBIGEND}]
# AC-T8:tihcfg -- source 0% hold plus target clock-skew margin.
set_input_delay -clock CLK -min 0.250 [get_ports {CFGBIGEND}]

# Table 8-1 calls these "debug status inputs" and uses tisdbgstat/tihdbgstat;
# Figure 8-4 calls the same input group debug control and labels the arrows
# tisdbgctl/tihdbgctl. The table symbols are the revision-locked identifiers.
# AC-T8:tisdbgstat -- 10% setup for DBGRQ/DBGBREAK/DBGEXT.
set_input_delay -clock CLK -max -6.250 [get_ports {
    DBGRQ
    DBGBREAK
    DBGEXT[*]
}]
# AC-T8:tihdbgstat -- source maximum hold is 0%.
set_input_delay -clock CLK -min 0.250 [get_ports {
    DBGRQ
    DBGBREAK
    DBGEXT[*]
}]

# AC-T8:tistcken -- stable 25 ns before the rising capture edge.
set_input_delay -clock CLK -max -25.000 [get_ports {DBGTCKEN}]
# AC-T8:tihtcken -- source 0% hold plus target clock-skew margin.
set_input_delay -clock CLK -min 0.250 [get_ports {DBGTCKEN}]

# AC-T8:tistctl -- stable 21.875 ns before the rising capture edge.
set_input_delay -clock CLK -max -21.875 [get_ports {DBGTDI DBGTMS}]
# AC-T8:tihtctl -- source 0% hold plus target clock-skew margin.
set_input_delay -clock CLK -min 0.250 [get_ports {DBGTDI DBGTMS}]

# DBGEN is a static integration strap, not a cycle-level input: Appendix A
# directs integrators to tie it HIGH when debug is used and LOW otherwise,
# and Table 8-1 defines no setup/hold row. This feature-complete profile
# leaves its value to integration and removes it from cycle-level analysis.
# AC-NONTABLE:static -- integration-owned debug configuration strap.
set_false_path -from [get_ports {DBGEN}]

# For output-valid rows, output delay is period minus the source maximum
# clock-to-valid fraction. A zero minimum models the nonnegative external
# hold boundary; checked post-fit reports must retain positive hold slack.

# AC-T8:tovaddr -- 90% valid => 56.25 ns internal, 6.25 ns output delay.
set_output_delay -clock CLK -max 6.250 [get_ports {ADDR[*]}]
# AC-T8:tohaddr -- source minimum hold is >0%.
set_output_delay -clock CLK -min 0.000 [get_ports {ADDR[*]}]

# AC-T8:tovctl -- 90% valid for the Appendix B control group.
set_output_delay -clock CLK -max 6.250 [get_ports {
    WRITE
    SIZE[*]
    PROT[*]
    LOCK
}]
# AC-T8:tohctl -- source minimum hold is >0%.
set_output_delay -clock CLK -min 0.000 [get_ports {
    WRITE
    SIZE[*]
    PROT[*]
    LOCK
}]

# AC-T8:tovtrans -- 50% valid => 31.25 ns internal and output delay.
set_output_delay -clock CLK -max 31.250 [get_ports {TRANS[*]}]
# AC-T8:tohtrans -- source minimum hold is >0%.
set_output_delay -clock CLK -min 0.000 [get_ports {TRANS[*]}]

# AC-T8:tovwdata -- 40% valid => 25 ns internal, 37.5 ns output delay.
set_output_delay -clock CLK -max 37.500 [get_ports {WDATA[*]}]
# AC-T8:tohwdata -- source minimum hold is >0%.
set_output_delay -clock CLK -min 0.000 [get_ports {WDATA[*]}]

# AC-T8:tovcpctl -- 80% coprocessor-control valid.
set_output_delay -clock CLK -max 12.500 [get_ports {
    CPnMREQ
    CPSEQ
    CPnOPC
    CPnTRANS
    CPTBIT
}]
# AC-T8:tohcpctl -- source minimum hold is >0%.
set_output_delay -clock CLK -min 0.000 [get_ports {
    CPnMREQ
    CPSEQ
    CPnOPC
    CPnTRANS
    CPTBIT
}]

# AC-T8:tovcpni -- 40% CPnI valid.
set_output_delay -clock CLK -max 37.500 [get_ports {CPnI}]
# AC-T8:tohcpni -- source minimum hold is >0%.
set_output_delay -clock CLK -min 0.000 [get_ports {CPnI}]

# Table 8-1 has two 40% debug-output pairs while Figure 8-4 labels both
# visible groups tovdbgstat/tohdbgstat. Preserve both table rows: the first
# group is DBGACK/DCC handshakes and the second is DBGRNG.
# AC-T8:tovdbgctl -- first debug-output group, 40% valid.
set_output_delay -clock CLK -max 37.500 [get_ports {
    DBGACK
    DBGCOMMTX
    DBGCOMMRX
}]
# AC-T8:tohdbctl -- exact Table 8-1 symbol; source minimum hold is >0%.
set_output_delay -clock CLK -min 0.000 [get_ports {
    DBGACK
    DBGCOMMTX
    DBGCOMMRX
}]

# AC-T8:tovtdo -- 20% DBGTDO valid.
set_output_delay -clock CLK -max 50.000 [get_ports {DBGTDO}]
# AC-T8:tohtdo -- source minimum hold is >0%.
set_output_delay -clock CLK -min 0.000 [get_ports {DBGTDO}]

# AC-T8:tovdbgstat -- second debug-output group, 40% valid.
set_output_delay -clock CLK -max 37.500 [get_ports {DBGRNG[*]}]
# AC-T8:tohdbgstat -- source minimum hold is >0%.
set_output_delay -clock CLK -min 0.000 [get_ports {DBGRNG[*]}]

# These public raw outputs have no Chapter 8/Table 8-1 row. They retain an
# explicit target-specific boundary rather than inheriting an ARM percentage.
# AC-NONTABLE:output -- ETM/scan/extension outputs.
set_output_delay -clock CLK -max 5.000 [get_ports {
    DBGnEXEC
    DBGINSTRVALID
    DBGnTDOEN
    DMORE
}]
set_output_delay -clock CLK -min 0.000 [get_ports {
    DBGnEXEC
    DBGINSTRVALID
    DBGnTDOEN
    DMORE
}]
