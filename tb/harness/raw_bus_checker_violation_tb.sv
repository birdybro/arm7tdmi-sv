// Expected-failure proof that the reusable checker rejects a raw integrator
// changing CFGBIGEND while the processor is out of reset.

`timescale 1ns/1ps

module raw_bus_checker_violation_tb
    import arm7tdmis_bus_pkg::*;
;

    logic CLK = 1'b0;
    initial forever #5 CLK = ~CLK;

    logic nRESET = 1'b0;
    logic CFGBIGEND = 1'b0;

    arm7tdmis_raw_bus_checker u_checker (
        .CLK,
        .CLKEN(1'b1),
        .nRESET,
        .CFGBIGEND,
        .ADDR(32'h0),
        .WRITE(WRITE_READ),
        .SIZE(2'(SIZE_WORD)),
        .PROT(2'(PROT_OPC_PRIV)),
        .LOCK(LOCK_FREE),
        .TRANS(2'(TRANS_I)),
        .WDATA(32'h0),
        .DMORE(1'b0),
        .CPnMREQ(1'b1),
        .CPSEQ(1'b0),
        .CPnOPC(1'b0),
        .CPnI(1'b1)
    );

    initial begin
        repeat (3) @(posedge CLK);
        @(negedge CLK);
        nRESET = 1'b1;
        repeat (2) @(posedge CLK);
        @(negedge CLK);
        CFGBIGEND = 1'b1;
        repeat (3) @(posedge CLK);
        $fatal(1, "raw checker accepted an out-of-reset CFGBIGEND change");
    end

endmodule
