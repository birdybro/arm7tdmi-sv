// Apply the reusable raw-bus checker to every pin-level DUT instantiated by
// the directed integration suite.

bind arm7tdmis_top arm7tdmis_raw_bus_checker u_raw_bus_checker (
    .CLK,
    .CLKEN,
    .nRESET,
    .CFGBIGEND,
    .ADDR,
    .WRITE,
    .SIZE,
    .PROT,
    .LOCK,
    .TRANS,
    .WDATA,
    .DMORE,
    .CPnMREQ,
    .CPSEQ,
    .CPnOPC,
    .CPnI
`ifdef ARM7TDMIS_SAVE_STATE
    ,
    .STATE_RESUME,
    .STATE_WRITE
`endif
);
