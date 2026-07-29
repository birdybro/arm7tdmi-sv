// Canonical FPGA/MiSTer integration wrapper for arm7tdmis_top.
//
// The ARM7TDMI-S raw bus is address/data pipelined and uses CLKEN to hold
// every architectural phase. This wrapper converts it into one conventional
// outstanding request with a valid/ready completion handshake. A target may
// accept MEM_VALID independently of CPU_CE; the response is buffered until
// the next enabled CPU edge. No generated or gated clock is created.
//
// Board/framework event inputs are explicitly named *_ASYNC and pass through
// two-flop synchronizers here. The underlying raw core contract remains
// synchronous. The optional coprocessor and synchronous debug interfaces are
// completely tied off internally when their parameters are false.

module arm7tdmi_mister
    import arm7tdmis_bus_pkg::*, arm7tdmis_debug_pkg::*;
#(
    parameter bit BIG_ENDIAN = 1'b0,
    parameter bit ENABLE_DEBUG = 1'b0,
    parameter bit ENABLE_COPROCESSOR = 1'b0,
    parameter logic [3:0] JTAG_VERSION = JTAG_DEFAULT_VERSION,
    parameter logic [15:0] JTAG_PART_NUMBER = JTAG_DEFAULT_PART_NUMBER,
    parameter logic [10:0] JTAG_MANUFACTURER_ID =
        JTAG_DEFAULT_MANUFACTURER_ID
) (
    input  logic CLK,
    input  logic RESET_N,
    input  logic CPU_CE,

    // Asynchronous board/framework events. Active HIGH at this boundary.
    input  logic IRQ_ASYNC,
    input  logic FIQ_ASYNC,

    // Canonical single-outstanding memory request.
    output logic        MEM_VALID,
    input  logic        MEM_READY,
    output logic [31:0] MEM_ADDR,
    output logic        MEM_WRITE,
    output logic [31:0] MEM_WDATA,
    output logic [3:0]  MEM_BYTE_ENABLE,
    output logic        MEM_CODE,
    output logic        MEM_PRIVILEGED,
    output logic        MEM_LOCK,
    output logic        MEM_SEQUENTIAL,
    output logic        MEM_MORE,
    input  logic [31:0] MEM_RDATA,
    input  logic        MEM_ERROR,

    // Optional raw ARM coprocessor interface.
    output logic        CPnMREQ,
    output logic        CPSEQ,
    output logic        CPnTRANS,
    output logic        CPnOPC,
    output logic        CPTBIT,
    output logic        CPnI,
    input  logic        CPA,
    input  logic        CPB,

    // Optional debug policy/events, all asynchronous at this boundary.
    input  logic        DEBUG_ENABLE_ASYNC,
    input  logic        DBGRQ_ASYNC,
    input  logic        DBGBREAK_ASYNC,
    input  logic [1:0]  DBGEXT_ASYNC,

    // Explicit same-CLK serialized debug transport.
    input  logic        DBG_STEP_VALID,
    output logic        DBG_STEP_READY,
    input  logic        DBG_STEP_TMS,
    input  logic        DBG_STEP_TDI,
    output logic        DBG_STEP_RSP_VALID,
    input  logic        DBG_STEP_RSP_READY,
    output logic        DBG_STEP_TDO,
    output logic        DBG_STEP_TDO_OE,

    // Architectural debug/trace status.
    output logic        DBGACK,
    output logic        DBGnEXEC,
    output logic        DBGINSTRVALID,
    output logic [1:0]  DBGRNG,
    output logic        DBGCOMMTX,
    output logic        DBGCOMMRX
`ifdef ARM7TDMIS_SAVE_STATE
    ,
    // Version-1 architectural save-state transport. Assert REQUEST until
    // READY, read or write one of STATE_WORDS words, then deassert REQUEST
    // to discard the saved pipeline and refetch from the state PC.
    input  logic        STATE_REQUEST,
    output logic        STATE_READY,
    input  logic        STATE_WRITE,
    input  logic [5:0]  STATE_INDEX,
    input  logic [31:0] STATE_WDATA,
    output logic [31:0] STATE_RDATA
`endif
);

`ifdef ARM7TDMIS_SAVE_STATE
    localparam logic [31:0] STATE_SCHEMA_VERSION = 32'h0001_0000;
    localparam int unsigned STATE_WORDS = 37;
`endif

    // ------------------------------------------------------------------
    // Board/framework event synchronization
    // ------------------------------------------------------------------

    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    logic irq_meta_q;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    logic irq_sync_q;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    logic fiq_meta_q;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    logic fiq_sync_q;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    logic debug_enable_meta_q;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    logic debug_enable_sync_q;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    logic dbgrq_meta_q;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    logic dbgrq_sync_q;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    logic dbgbreak_meta_q;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    logic dbgbreak_sync_q;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    logic [1:0] dbgext_meta_q;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    logic [1:0] dbgext_sync_q;

    always_ff @(posedge CLK or negedge RESET_N) begin
        if (!RESET_N) begin
            irq_meta_q          <= 1'b0;
            irq_sync_q          <= 1'b0;
            fiq_meta_q          <= 1'b0;
            fiq_sync_q          <= 1'b0;
            debug_enable_meta_q <= 1'b0;
            debug_enable_sync_q <= 1'b0;
            dbgrq_meta_q        <= 1'b0;
            dbgrq_sync_q        <= 1'b0;
            dbgbreak_meta_q     <= 1'b0;
            dbgbreak_sync_q     <= 1'b0;
            dbgext_meta_q       <= 2'b00;
            dbgext_sync_q       <= 2'b00;
        end else begin
            irq_meta_q          <= IRQ_ASYNC;
            irq_sync_q          <= irq_meta_q;
            fiq_meta_q          <= FIQ_ASYNC;
            fiq_sync_q          <= fiq_meta_q;
            debug_enable_meta_q <= DEBUG_ENABLE_ASYNC;
            debug_enable_sync_q <= debug_enable_meta_q;
            dbgrq_meta_q        <= DBGRQ_ASYNC;
            dbgrq_sync_q        <= dbgrq_meta_q;
            dbgbreak_meta_q     <= DBGBREAK_ASYNC;
            dbgbreak_sync_q     <= dbgbreak_meta_q;
            dbgext_meta_q       <= DBGEXT_ASYNC;
            dbgext_sync_q       <= dbgext_meta_q;
        end
    end

    wire debug_enabled = ENABLE_DEBUG && debug_enable_sync_q;
    wire core_cpa = ENABLE_COPROCESSOR ? CPA : 1'b1;
    wire core_cpb = ENABLE_COPROCESSOR ? CPB : 1'b1;

    // ------------------------------------------------------------------
    // Raw bus and one-outstanding response bridge
    // ------------------------------------------------------------------

    logic [31:0] raw_addr;
    logic        raw_write;
    logic [1:0]  raw_size;
    logic [1:0]  raw_prot;
    logic        raw_lock;
    logic [1:0]  raw_trans;
    logic [31:0] raw_wdata;
    logic        raw_dmore;

    logic        request_valid_q;
    logic [31:0] request_addr_q;
    logic        request_write_q;
    logic [1:0]  request_size_q;
    logic [1:0]  request_prot_q;
    logic        request_lock_q;
    logic        request_sequential_q;
    logic        request_more_q;

    logic        response_valid_q;
    logic [31:0] response_data_q;
    logic        response_error_q;

    wire raw_active = (raw_trans == 2'(TRANS_N))
                   || (raw_trans == 2'(TRANS_S));
    wire memory_accept = request_valid_q && MEM_READY;
    wire bus_waiting = request_valid_q || response_valid_q;
    wire response_available = response_valid_q || memory_accept;

    // When no raw memory response is pending, CPU_CE advances ordinary
    // opcode/internal cycles. While a response is pending, only a buffered
    // or same-edge memory completion can release that enabled edge.
`ifdef ARM7TDMIS_SAVE_STATE
    logic state_halted_q;
    logic core_state_boundary;
    wire state_capture = STATE_REQUEST && !state_halted_q
                       && core_clken && core_state_boundary;
    wire state_resume = state_halted_q && !STATE_REQUEST;
    wire state_access_write = STATE_WRITE && STATE_READY
                            && (STATE_INDEX < 6'(STATE_WORDS));
    assign STATE_READY = state_halted_q;

    always_ff @(posedge CLK or negedge RESET_N) begin
        if (!RESET_N)
            state_halted_q <= 1'b0;
        else if (state_capture)
            state_halted_q <= 1'b1;
        else if (state_resume)
            state_halted_q <= 1'b0;
    end
`else
    wire state_halted_q = 1'b0;
`endif

    wire core_clken = CPU_CE && !state_halted_q
                    && (!bus_waiting || response_available);
    wire core_abort = bus_waiting && response_available
                    && (response_valid_q ? response_error_q : MEM_ERROR);
    wire [31:0] core_rdata = response_valid_q
                           ? response_data_q : MEM_RDATA;

    always_ff @(posedge CLK or negedge RESET_N) begin
        if (!RESET_N) begin
            request_valid_q      <= 1'b0;
            request_addr_q       <= 32'h0000_0000;
            request_write_q      <= 1'b0;
            request_size_q       <= 2'(SIZE_WORD);
            request_prot_q       <= 2'(PROT_OPC_PRIV);
            request_lock_q       <= 1'b0;
            request_sequential_q <= 1'b0;
            request_more_q       <= 1'b0;
            response_valid_q     <= 1'b0;
            response_data_q      <= 32'h0000_0000;
            response_error_q     <= 1'b0;
        end else begin
            // A normal valid/ready target completes independently of CPU_CE.
            // If the core cannot advance on this edge, retain the response.
            if (memory_accept) begin
                request_valid_q <= 1'b0;
                if (!core_clken) begin
                    response_valid_q <= 1'b1;
                    response_data_q  <= MEM_RDATA;
                    response_error_q <= MEM_ERROR;
                end
            end

            // A buffered response is consumed exactly once on the next
            // enabled CPU edge.
            if (response_valid_q && core_clken)
                response_valid_q <= 1'b0;

            // This is the raw bus address-sampling edge. If an old response
            // was consumed, the already-present next address phase can be
            // captured at the same edge for full back-to-back throughput.
            if (core_clken) begin
                if (bus_waiting)
                    response_valid_q <= 1'b0;

`ifdef ARM7TDMIS_SAVE_STATE
                request_valid_q <= state_capture ? 1'b0 : raw_active;
`else
                request_valid_q <= raw_active;
`endif
                if (raw_active
`ifdef ARM7TDMIS_SAVE_STATE
                    && !state_capture
`endif
                ) begin
                    request_addr_q       <= raw_addr;
                    request_write_q      <= raw_write;
                    request_size_q       <= raw_size;
                    request_prot_q       <= raw_prot;
                    request_lock_q       <= raw_lock;
                    request_sequential_q <=
                        (raw_trans == 2'(TRANS_S));
                    request_more_q       <= raw_dmore;
                end
            end
        end
    end

    function automatic logic [3:0] byte_enable(
        input logic [1:0] size,
        input logic [1:0] address
    );
        logic [1:0] byte_lane;
        logic       half_high;
        begin
            byte_lane = BIG_ENDIAN ? ~address : address;
            half_high = BIG_ENDIAN ? ~address[1] : address[1];
            unique case (size)
                2'(SIZE_BYTE):     return 4'b0001 << byte_lane;
                2'(SIZE_HALFWORD): return half_high ? 4'b1100 : 4'b0011;
                2'(SIZE_WORD):     return 4'b1111;
                default:           return 4'b0000;
            endcase
        end
    endfunction

    assign MEM_VALID       = request_valid_q;
    assign MEM_ADDR        = request_addr_q;
    assign MEM_WRITE       = request_write_q;
    assign MEM_WDATA       = raw_wdata;
    assign MEM_BYTE_ENABLE = byte_enable(request_size_q,
                                         request_addr_q[1:0]);
    assign MEM_CODE        = !request_prot_q[PROT_BIT_DATA];
    assign MEM_PRIVILEGED  = request_prot_q[PROT_BIT_PRIV];
    assign MEM_LOCK        = request_lock_q;
    assign MEM_SEQUENTIAL  = request_sequential_q;
    assign MEM_MORE        = request_more_q;

    // ------------------------------------------------------------------
    // Synchronous debug transport and raw core
    // ------------------------------------------------------------------

    logic raw_dbgtcken;
    logic raw_dbgtms;
    logic raw_dbgtdi;
    logic raw_dbgtdo;
    logic raw_dbgntdoen;

    arm7tdmis_sync_debug_port u_debug_transport (
        .CLK,
        .nRESET        (RESET_N),
        .PORT_ENABLE   (debug_enabled),
        .STEP_VALID    (DBG_STEP_VALID),
        .STEP_READY    (DBG_STEP_READY),
        .STEP_TMS      (DBG_STEP_TMS),
        .STEP_TDI      (DBG_STEP_TDI),
        .STEP_RSP_VALID(DBG_STEP_RSP_VALID),
        .STEP_RSP_READY(DBG_STEP_RSP_READY),
        .STEP_TDO      (DBG_STEP_TDO),
        .STEP_TDO_OE   (DBG_STEP_TDO_OE),
        .DBGTCKEN      (raw_dbgtcken),
        .DBGTMS        (raw_dbgtms),
        .DBGTDI        (raw_dbgtdi),
        .DBGTDO        (raw_dbgtdo),
        .DBGnTDOEN     (raw_dbgntdoen)
    );

    arm7tdmis_top #(
        .JTAG_VERSION         (JTAG_VERSION),
        .JTAG_PART_NUMBER     (JTAG_PART_NUMBER),
        .JTAG_MANUFACTURER_ID (JTAG_MANUFACTURER_ID)
    ) u_core (
        .CLK,
        .CLKEN          (core_clken),
        .nRESET         (RESET_N),
        .CFGBIGEND      (BIG_ENDIAN),
        .nIRQ           (!irq_sync_q),
        .nFIQ           (!fiq_sync_q),
        .ABORT          (core_abort),
        .ADDR           (raw_addr),
        .WRITE          (raw_write),
        .SIZE           (raw_size),
        .PROT           (raw_prot),
        .LOCK           (raw_lock),
        .TRANS          (raw_trans),
        .WDATA          (raw_wdata),
        .RDATA          (core_rdata),
        .CPnMREQ,
        .CPSEQ,
        .CPnTRANS,
        .CPnOPC,
        .CPTBIT,
        .CPnI,
        .CPA            (core_cpa),
        .CPB            (core_cpb),
        .DBGEN          (debug_enabled),
        .DBGRQ          (ENABLE_DEBUG && dbgrq_sync_q),
        .DBGBREAK       (ENABLE_DEBUG && dbgbreak_sync_q),
        .DBGACK,
        .DBGnEXEC,
        .DBGINSTRVALID,
        .DBGEXT         (ENABLE_DEBUG ? dbgext_sync_q : 2'b00),
        .DBGRNG,
        .DBGCOMMTX,
        .DBGCOMMRX,
        .DBGTCKEN       (raw_dbgtcken),
        .DBGTMS         (raw_dbgtms),
        .DBGTDI         (raw_dbgtdi),
        .DBGTDO         (raw_dbgtdo),
        .DBGnTRST       (RESET_N),
        .DBGnTDOEN      (raw_dbgntdoen),
        .DMORE          (raw_dmore)
`ifdef ARM7TDMIS_SAVE_STATE
        ,
        .STATE_CAPTURE  (state_capture),
        .STATE_RESUME   (state_resume),
        .STATE_WRITE    (state_access_write),
        .STATE_INDEX    (STATE_INDEX),
        .STATE_WDATA    (STATE_WDATA),
        .STATE_BOUNDARY (core_state_boundary),
        .STATE_RDATA    (STATE_RDATA)
`endif
`ifdef ARM7TDMIS_VERIFICATION
        ,
        .VER_RETIRE_VALID(ver_retire_unused[0]),
        .VER_RETIRE_PC(ver_retire_unused[32:1]),
        .VER_RETIRE_OPCODE(ver_retire_unused[64:33]),
        .VER_RETIRE_THUMB(ver_retire_unused[65]),
        .VER_RETIRE_CONDITION_PASS(ver_retire_unused[66]),
        .VER_RETIRE_INJECTED(ver_retire_unused[67]),
        .VER_RETIRE_EXCEPTION_VALID(ver_retire_unused[68]),
        .VER_RETIRE_EXCEPTION(ver_retire_unused[71:69]),
        .VER_RETIRE_GPRS(ver_retire_unused[1063:72]),
        .VER_RETIRE_CPSR(ver_retire_unused[1095:1064]),
        .VER_RETIRE_SPSRS(ver_retire_unused[1255:1096])
`endif
    );

`ifdef ARM7TDMIS_VERIFICATION
    wire [1255:0] ver_retire_unused;
    wire _unused_ver_retire = &{1'b0, ver_retire_unused};
`endif

    // Keep optional physical inputs intentional in a trimmed elaboration.
    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused_optional_inputs = &{1'b0, CPA, CPB};
    /* verilator lint_on UNUSEDSIGNAL */

endmodule
