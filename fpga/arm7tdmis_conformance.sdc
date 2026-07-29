# Raw, feature-complete ARM7TDMI-S characterization constraints.
#
# This profile exposes every raw memory, coprocessor, debug, JTAG, and trace
# signal so Quartus cannot trim optional behavior. It characterizes a single
# 25 MHz clock and a 0.25-to-5 ns synchronous input arrival window. A
# containing design must replace these boundary assumptions with its own.

create_clock -name CLK -period 40.000 [get_ports {CLK}]
derive_clock_uncertainty

# Both reset inputs assert asynchronously. nRESET releases through the
# architectural reset synchronizer; raw DBGnTRST ownership remains with the
# containing integration.
set_false_path -from [get_ports {nRESET DBGnTRST}]

# Every other raw input is synchronous to CLK in this profile.
set_input_delay -clock CLK -min 0.250 [get_ports {
    CLKEN
    CFGBIGEND
    nIRQ
    nFIQ
    ABORT
    RDATA[*]
    CPA
    CPB
    DBGEN
    DBGRQ
    DBGBREAK
    DBGEXT[*]
    DBGTCKEN
    DBGTMS
    DBGTDI
}]
set_input_delay -clock CLK -max 5.000 [get_ports {
    CLKEN
    CFGBIGEND
    nIRQ
    nFIQ
    ABORT
    RDATA[*]
    CPA
    CPB
    DBGEN
    DBGRQ
    DBGBREAK
    DBGEXT[*]
    DBGTCKEN
    DBGTMS
    DBGTDI
}]

set_output_delay -clock CLK -min 0.000 [get_ports {
    ADDR[*]
    WRITE
    SIZE[*]
    PROT[*]
    LOCK
    TRANS[*]
    WDATA[*]
    CPnMREQ
    CPSEQ
    CPnTRANS
    CPnOPC
    CPTBIT
    CPnI
    DBGACK
    DBGnEXEC
    DBGINSTRVALID
    DBGRNG[*]
    DBGCOMMTX
    DBGCOMMRX
    DBGTDO
    DBGnTDOEN
    DMORE
}]
set_output_delay -clock CLK -max 5.000 [get_ports {
    ADDR[*]
    WRITE
    SIZE[*]
    PROT[*]
    LOCK
    TRANS[*]
    WDATA[*]
    CPnMREQ
    CPSEQ
    CPnTRANS
    CPnOPC
    CPTBIT
    CPnI
    DBGACK
    DBGnEXEC
    DBGINSTRVALID
    DBGRNG[*]
    DBGCOMMTX
    DBGCOMMRX
    DBGTDO
    DBGnTDOEN
    DMORE
}]
