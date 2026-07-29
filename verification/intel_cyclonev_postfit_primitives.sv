// Clean-room functional models for the small Cyclone V primitive subset
// emitted by the FPGA-006 validation profile. These models are repository
// authored from the public primitive port/parameter contract; no Intel model
// source is copied or redistributed. They intentionally model zero delay.

`timescale 1ps/1ps

module dffeas #(
    parameter is_wysiwyg = "false",
    parameter power_up = "low"
) (
    input  wire d,
    input  wire clk,
    input  wire ena,
    input  wire clrn,
    input  wire prn,
    input  wire aload,
    input  wire asdata,
    input  wire sclr,
    input  wire sload,
    input  wire devclrn,
    input  wire devpor,
    output reg  q
);
    initial q = (power_up == "high") ? 1'b1 : 1'b0;

    always @(posedge clk or negedge clrn or negedge prn
             or negedge devclrn or negedge devpor or posedge aload) begin
        if (!devpor || !devclrn || !clrn)
            q <= 1'b0;
        else if (!prn)
            q <= 1'b1;
        else if (aload)
            q <= asdata;
        else if (ena) begin
            if (sclr)
                q <= 1'b0;
            else if (sload)
                q <= asdata;
            else
                q <= d;
        end
    end

    wire _unused_parameter = &{1'b0, is_wysiwyg == "true"};
endmodule

module cyclonev_lcell_comb #(
    parameter [63:0] lut_mask = 64'hffff_ffff_ffff_ffff,
    parameter shared_arith = "off",
    parameter extended_lut = "off",
    parameter dont_touch = "off",
    parameter lpm_type = "cyclonev_lcell_comb"
) (
    input  wire dataa,
    input  wire datab,
    input  wire datac,
    input  wire datad,
    input  wire datae,
    input  wire dataf,
    input  wire datag,
    input  wire cin,
    input  wire sharein,
    output reg  combout,
    output reg  sumout,
    output reg  cout,
    output reg  shareout
);
    reg f0;
    reg f1;
    reg f2;
    reg f3;
    reg mux0;
    reg mux1;
    reg addend;

    always @* begin
        f0 = lut_mask[      {datad, datac, datab, dataa}];
        f1 = lut_mask[16 + {datad, datag, datab, dataa}];
        f2 = lut_mask[32 + {datad, datac, datab, dataa}];
        f3 = lut_mask[48 + {datad, datag, datab, dataa}];

        if (extended_lut == "on") begin
            mux0 = datae ? f1 : f0;
            mux1 = datae ? f3 : f2;
            combout = dataf ? mux1 : mux0;
        end else begin
            mux0 = 1'b0;
            mux1 = 1'b0;
            combout = lut_mask[{dataf, datae, datad, datac,
                                datab, dataa}];
        end

        if (shared_arith == "on")
            addend = sharein;
        else
            addend = ~lut_mask[32 + {dataf, datac, datab, dataa}];
        sumout = cin ^ f0 ^ addend;
        cout = (cin & f0) | (cin & addend) | (f0 & addend);
        shareout = f2;
    end

    wire _unused_parameter = &{
        1'b0, dont_touch == "on", lpm_type == "cyclonev_lcell_comb"
    };
endmodule

module cyclonev_io_ibuf #(
    parameter differential_mode = "false",
    parameter bus_hold = "false",
    parameter simulate_z_as = "z",
    parameter lpm_type = "cyclonev_io_ibuf"
) (
    input  wire i,
    input  wire ibar,
    input  wire dynamicterminationcontrol,
    output wire o
);
    assign o = (differential_mode == "true") ? (i & ~ibar) : i;
    wire _unused_parameter = &{
        1'b0, dynamicterminationcontrol, bus_hold == "true",
        simulate_z_as == "x", lpm_type == "cyclonev_io_ibuf"
    };
endmodule

module cyclonev_io_obuf #(
    parameter open_drain_output = "false",
    parameter bus_hold = "false",
    parameter shift_series_termination_control = "false",
    parameter sim_dynamic_termination_control_is_connected = "false",
    parameter lpm_type = "cyclonev_io_obuf"
) (
    input  wire        i,
    input  wire        oe,
    input  wire        dynamicterminationcontrol,
    input  wire [15:0] seriesterminationcontrol,
    input  wire [15:0] parallelterminationcontrol,
    input  wire        devoe,
    output wire        o,
    output wire        obar
);
    wire driven = (open_drain_output == "true" && i) ? 1'bz : i;
    assign o = (oe && devoe) ? driven : 1'bz;
    assign obar = (oe && devoe) ? ~driven : 1'bz;
    wire _unused_parameter = &{
        1'b0, dynamicterminationcontrol, seriesterminationcontrol,
        parallelterminationcontrol, bus_hold == "true",
        shift_series_termination_control == "true",
        sim_dynamic_termination_control_is_connected == "true",
        lpm_type == "cyclonev_io_obuf"
    };
endmodule

module cyclonev_clkena #(
    parameter clock_type = "auto",
    parameter ena_register_mode = "always enabled",
    parameter lpm_type = "cyclonev_clkena",
    parameter ena_register_power_up = "high",
    parameter disable_mode = "low",
    parameter test_syn = "high"
) (
    input  wire inclk,
    input  wire ena,
    output wire enaout,
    output wire outclk
);
    assign enaout = ena;
    assign outclk = ena ? inclk : (disable_mode == "high");
    wire _unused_parameter = &{
        1'b0, clock_type == "global clock",
        ena_register_mode == "always enabled",
        lpm_type == "cyclonev_clkena",
        ena_register_power_up == "high", test_syn == "high"
    };
endmodule
