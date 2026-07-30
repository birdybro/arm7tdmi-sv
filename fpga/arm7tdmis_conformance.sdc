# Raw, feature-complete ARM7TDMI-S Cyclone V timing profile.
#
# ARM DDI 0234B Table 8-1 is provisional supplier-dependent macrocell timing,
# expressed as a fraction of the clock at maximum operating frequency. It is
# not an FPGA pin guarantee. This profile deliberately translates each
# applicable fraction at its selected 25 MHz (40 ns) target:
#   input max delay = period - source setup budget
#   output max delay = period - source clock-to-valid budget
#   zero/>zero source holds use a 0 ns portable boundary and must retain
#   positive routed hold slack.
# The revision-locked row inventory and disposition are in
# verification/ac_timing.json and docs/AC_TIMING.md.

# AC-T8:tcyc -- 100% minimum CLK cycle; selected target is 40 ns.
create_clock -name CLK -period 40.000 [get_ports {CLK}]
derive_clock_uncertainty

# nRESET and DBGnTRST assert asynchronously. nRESET releases through the
# architectural synchronizer; raw DBGnTRST release is integration-owned.
# AC-OWN:reset -- replaces the nRESET part of tisexc/tihexc.
set_false_path -from [get_ports {nRESET DBGnTRST}]

# AC-T8:tisclken -- 40% setup leaves a 16 ns port-to-register budget.
set_input_delay -clock CLK -max 24.000 [get_ports {CLKEN}]
# AC-T8:tihclken -- source maximum hold is 0%.
set_input_delay -clock CLK -min 0.000 [get_ports {CLKEN}]

# AC-T8:tisabort -- 15% setup leaves a 6 ns port-to-register budget.
set_input_delay -clock CLK -max 34.000 [get_ports {ABORT}]
# AC-T8:tihabort -- source maximum hold is 0%.
set_input_delay -clock CLK -min 0.000 [get_ports {ABORT}]

# AC-T8:tisrdata -- 10% setup leaves a 4 ns port-to-register budget.
set_input_delay -clock CLK -max 36.000 [get_ports {RDATA[*]}]
# AC-T8:tihrdata -- source maximum hold is 0%.
set_input_delay -clock CLK -min 0.000 [get_ports {RDATA[*]}]

# AC-T8:tiscpstat -- 20% setup leaves an 8 ns port-to-register budget.
set_input_delay -clock CLK -max 32.000 [get_ports {CPA CPB}]
# AC-T8:tihcpstat -- source maximum hold is 0%.
set_input_delay -clock CLK -min 0.000 [get_ports {CPA CPB}]

# AC-T8:tisexc -- 10% setup for synchronous nFIQ/nIRQ; nRESET is AC-OWN:reset.
set_input_delay -clock CLK -max 36.000 [get_ports {nFIQ nIRQ}]
# AC-T8:tihexc -- 0% hold for synchronous nFIQ/nIRQ; nRESET is AC-OWN:reset.
set_input_delay -clock CLK -min 0.000 [get_ports {nFIQ nIRQ}]

# AC-T8:tiscfg -- 10% setup leaves a 4 ns static-config input budget.
set_input_delay -clock CLK -max 36.000 [get_ports {CFGBIGEND}]
# AC-T8:tihcfg -- source maximum hold is 0%.
set_input_delay -clock CLK -min 0.000 [get_ports {CFGBIGEND}]

# Table 8-1 calls these "debug status inputs" and uses tisdbgstat/tihdbgstat;
# Figure 8-4 calls the same input group debug control and labels the arrows
# tisdbgctl/tihdbgctl. The table symbols are the revision-locked identifiers.
# AC-T8:tisdbgstat -- 10% setup for DBGRQ/DBGBREAK/DBGEXT.
set_input_delay -clock CLK -max 36.000 [get_ports {
    DBGRQ
    DBGBREAK
    DBGEXT[*]
}]
# AC-T8:tihdbgstat -- source maximum hold is 0%.
set_input_delay -clock CLK -min 0.000 [get_ports {
    DBGRQ
    DBGBREAK
    DBGEXT[*]
}]

# AC-T8:tistcken -- 40% setup leaves a 16 ns DBGTCKEN budget.
set_input_delay -clock CLK -max 24.000 [get_ports {DBGTCKEN}]
# AC-T8:tihtcken -- source maximum hold is 0%.
set_input_delay -clock CLK -min 0.000 [get_ports {DBGTCKEN}]

# AC-T8:tistctl -- 35% setup leaves a 14 ns scan-control budget.
set_input_delay -clock CLK -max 26.000 [get_ports {DBGTDI DBGTMS}]
# AC-T8:tihtctl -- source maximum hold is 0%.
set_input_delay -clock CLK -min 0.000 [get_ports {DBGTDI DBGTMS}]

# DBGEN is a real raw top input but has no Table 8-1 row. Keep the existing
# conservative target boundary assumption explicit instead of inventing an
# ARM percentage.
# AC-NONTABLE:input -- target-specific synchronous input.
set_input_delay -clock CLK -max 5.000 [get_ports {DBGEN}]
set_input_delay -clock CLK -min 0.000 [get_ports {DBGEN}]

# For output-valid rows, output delay is period minus the source maximum
# clock-to-valid fraction. A zero minimum models the nonnegative external
# hold boundary; checked post-fit reports must retain positive hold slack.

# AC-T8:tovaddr -- 90% valid => 36 ns internal, 4 ns output delay.
set_output_delay -clock CLK -max 4.000 [get_ports {ADDR[*]}]
# AC-T8:tohaddr -- source minimum hold is >0%.
set_output_delay -clock CLK -min 0.000 [get_ports {ADDR[*]}]

# AC-T8:tovctl -- 90% valid for the Appendix B control group.
set_output_delay -clock CLK -max 4.000 [get_ports {
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

# AC-T8:tovtrans -- 50% valid => 20 ns internal and output delay.
set_output_delay -clock CLK -max 20.000 [get_ports {TRANS[*]}]
# AC-T8:tohtrans -- source minimum hold is >0%.
set_output_delay -clock CLK -min 0.000 [get_ports {TRANS[*]}]

# AC-T8:tovwdata -- 40% valid => 16 ns internal, 24 ns output delay.
set_output_delay -clock CLK -max 24.000 [get_ports {WDATA[*]}]
# AC-T8:tohwdata -- source minimum hold is >0%.
set_output_delay -clock CLK -min 0.000 [get_ports {WDATA[*]}]

# AC-T8:tovcpctl -- 80% coprocessor-control valid.
set_output_delay -clock CLK -max 8.000 [get_ports {
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
set_output_delay -clock CLK -max 24.000 [get_ports {CPnI}]
# AC-T8:tohcpni -- source minimum hold is >0%.
set_output_delay -clock CLK -min 0.000 [get_ports {CPnI}]

# Table 8-1 has two 40% debug-output pairs while Figure 8-4 labels both
# visible groups tovdbgstat/tohdbgstat. Preserve both table rows: the first
# group is DBGACK/DCC handshakes and the second is DBGRNG.
# AC-T8:tovdbgctl -- first debug-output group, 40% valid.
set_output_delay -clock CLK -max 24.000 [get_ports {
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
set_output_delay -clock CLK -max 32.000 [get_ports {DBGTDO}]
# AC-T8:tohtdo -- source minimum hold is >0%.
set_output_delay -clock CLK -min 0.000 [get_ports {DBGTDO}]

# AC-T8:tovdbgstat -- second debug-output group, 40% valid.
set_output_delay -clock CLK -max 24.000 [get_ports {DBGRNG[*]}]
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
