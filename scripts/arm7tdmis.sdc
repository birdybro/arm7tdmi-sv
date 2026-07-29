# Standalone raw-interface constraints for synthesis top arm7tdmis_top.
#
# This is intentionally not the DFT chip wrapper and therefore contains no
# SE/SI/SO constraints. DBGTCKEN is a synchronous enable in the CLK domain;
# there is no DBGTCK port or generated debug clock in this implementation.

# Initial raw-core characterization point: 100 MHz.
create_clock -name CLK -period 10.000 [get_ports {CLK}]
derive_clock_uncertainty

# Both reset pins assert asynchronously. Integration must release each only
# after CLK is stable; nRESET's architectural release is synchronized inside
# arm7tdmis_top. Debug state is independently held by DBGnTRST.
set_false_path -from [get_ports {nRESET DBGnTRST}]

# Every non-reset input below is synchronous to CLK at this raw boundary.
# In particular, nIRQ/nFIQ and the debug event pins are not synchronized by
# arm7tdmis_top; an asynchronous board source needs an external synchronizer
# or the canonical arm7tdmi_mister wrapper.
set_input_delay -clock CLK -min 0.000 [get_ports {
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
