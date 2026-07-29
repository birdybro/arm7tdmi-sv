// Stateless bridge from the canonical arm7tdmi_mister memory request to a
// Wishbone B4 classic cycle.
//
// WB_ADR remains a byte address and WB_SEL carries the canonical byte lanes.
// Each canonical request is one classic Wishbone transfer (CTI=000). MEM_MORE
// and MEM_SEQUENTIAL are preserved as optional sidebands, but are not
// misrepresented as a Wishbone burst: a CPU_CE stall can place time between
// two canonical requests even when MEM_MORE predicts a sequential follower.
// The canonical wrapper owns request stability and response buffering.

module arm7tdmi_wishbone_adapter (
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

    output logic        WB_CYC,
    output logic        WB_STB,
    output logic        WB_WE,
    output logic [31:0] WB_ADR,
    output logic [31:0] WB_DAT_W,
    output logic [3:0]  WB_SEL,
    output logic        WB_LOCK,
    output logic [2:0]  WB_CTI,
    output logic [1:0]  WB_BTE,
    output logic        WB_CODE,
    output logic        WB_PRIVILEGED,
    output logic        WB_SEQUENTIAL,
    output logic        WB_MORE,
    input  logic        WB_ACK,
    input  logic        WB_ERR,
    input  logic [31:0] WB_DAT_R
);

    assign WB_CYC        = MEM_VALID;
    assign WB_STB        = MEM_VALID;
    assign WB_WE         = MEM_WRITE;
    assign WB_ADR        = MEM_ADDR;
    assign WB_DAT_W      = MEM_WDATA;
    assign WB_SEL        = MEM_BYTE_ENABLE;
    assign WB_LOCK       = MEM_LOCK;
    assign WB_CTI        = 3'b000;
    assign WB_BTE        = 2'b00;
    assign WB_CODE       = MEM_CODE;
    assign WB_PRIVILEGED = MEM_PRIVILEGED;
    assign WB_SEQUENTIAL = MEM_SEQUENTIAL;
    assign WB_MORE       = MEM_MORE;

    assign MEM_READY = MEM_VALID && (WB_ACK || WB_ERR);
    assign MEM_RDATA = WB_DAT_R;
    assign MEM_ERROR = MEM_VALID && WB_ERR;

endmodule
