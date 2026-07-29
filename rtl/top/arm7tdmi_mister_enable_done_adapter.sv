// Stateless bridge from the canonical arm7tdmi_mister valid/ready request to
// a selected MiSTer-style enable/done convention.
//
// HOST_ENABLE and its entire payload stay asserted until HOST_DONE. The
// canonical wrapper owns that stability and buffers a completion received
// while CPU_CE is low. HOST_DONE may therefore be independent of CPU_CE.

module arm7tdmi_mister_enable_done_adapter (
    input  logic        MEM_VALID,
    output logic        MEM_READY,
    input  logic [31:0] MEM_ADDR,
    input  logic        MEM_WRITE,
    input  logic [31:0] MEM_WDATA,
    input  logic [3:0]  MEM_BYTE_ENABLE,
    input  logic        MEM_CODE,
    input  logic        MEM_PRIVILEGED,
    input  logic        MEM_LOCK,
    input  logic        MEM_SEQUENTIAL,
    input  logic        MEM_MORE,
    output logic [31:0] MEM_RDATA,
    output logic        MEM_ERROR,

    output logic        HOST_ENABLE,
    output logic [31:0] HOST_ADDR,
    output logic        HOST_WRITE,
    output logic [31:0] HOST_WDATA,
    output logic [3:0]  HOST_BYTE_ENABLE,
    output logic        HOST_CODE,
    output logic        HOST_PRIVILEGED,
    output logic        HOST_LOCK,
    output logic        HOST_SEQUENTIAL,
    output logic        HOST_MORE,
    input  logic        HOST_DONE,
    input  logic [31:0] HOST_RDATA,
    input  logic        HOST_ERROR
);

    assign HOST_ENABLE      = MEM_VALID;
    assign HOST_ADDR        = MEM_ADDR;
    assign HOST_WRITE       = MEM_WRITE;
    assign HOST_WDATA       = MEM_WDATA;
    assign HOST_BYTE_ENABLE = MEM_BYTE_ENABLE;
    assign HOST_CODE        = MEM_CODE;
    assign HOST_PRIVILEGED  = MEM_PRIVILEGED;
    assign HOST_LOCK        = MEM_LOCK;
    assign HOST_SEQUENTIAL  = MEM_SEQUENTIAL;
    assign HOST_MORE        = MEM_MORE;

    assign MEM_READY = MEM_VALID && HOST_DONE;
    assign MEM_RDATA = HOST_RDATA;
    assign MEM_ERROR = MEM_VALID && HOST_DONE && HOST_ERROR;

endmodule
