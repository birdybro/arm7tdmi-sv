// MIST-013 fail-first contract for the public thin bus adapters.
//
// Both adapters are deliberately stateless: the canonical wrapper owns
// request stability and response buffering. This test proves exact payload,
// backpressure, successful completion, and error completion mappings without
// depending on CPU hierarchy.

`timescale 1ns/1ps

module adapters_tb;

    logic        mem_valid;
    logic [31:0] mem_addr;
    logic        mem_write;
    logic [31:0] mem_wdata;
    logic [3:0]  mem_byte_enable;
    logic        mem_code;
    logic        mem_privileged;
    logic        mem_lock;
    logic        mem_sequential;
    logic        mem_more;

    logic        wb_mem_ready;
    logic [31:0] wb_mem_rdata;
    logic        wb_mem_error;
    logic        wb_cyc;
    logic        wb_stb;
    logic        wb_we;
    logic [31:0] wb_adr;
    logic [31:0] wb_dat_w;
    logic [3:0]  wb_sel;
    logic        wb_lock;
    logic [2:0]  wb_cti;
    logic [1:0]  wb_bte;
    logic        wb_code;
    logic        wb_privileged;
    logic        wb_sequential;
    logic        wb_more;
    logic        wb_ack;
    logic        wb_err;
    logic [31:0] wb_dat_r;

    arm7tdmi_wishbone_adapter u_wishbone (
        .MEM_VALID      (mem_valid),
        .MEM_READY      (wb_mem_ready),
        .MEM_ADDR       (mem_addr),
        .MEM_WRITE      (mem_write),
        .MEM_WDATA      (mem_wdata),
        .MEM_BYTE_ENABLE(mem_byte_enable),
        .MEM_CODE       (mem_code),
        .MEM_PRIVILEGED (mem_privileged),
        .MEM_LOCK       (mem_lock),
        .MEM_SEQUENTIAL (mem_sequential),
        .MEM_MORE       (mem_more),
        .MEM_RDATA      (wb_mem_rdata),
        .MEM_ERROR      (wb_mem_error),
        .WB_CYC         (wb_cyc),
        .WB_STB         (wb_stb),
        .WB_WE          (wb_we),
        .WB_ADR         (wb_adr),
        .WB_DAT_W       (wb_dat_w),
        .WB_SEL         (wb_sel),
        .WB_LOCK        (wb_lock),
        .WB_CTI         (wb_cti),
        .WB_BTE         (wb_bte),
        .WB_CODE        (wb_code),
        .WB_PRIVILEGED  (wb_privileged),
        .WB_SEQUENTIAL  (wb_sequential),
        .WB_MORE        (wb_more),
        .WB_ACK         (wb_ack),
        .WB_ERR         (wb_err),
        .WB_DAT_R       (wb_dat_r)
    );

    logic        ed_mem_ready;
    logic [31:0] ed_mem_rdata;
    logic        ed_mem_error;
    logic        host_enable;
    logic [31:0] host_addr;
    logic        host_write;
    logic [31:0] host_wdata;
    logic [3:0]  host_byte_enable;
    logic        host_code;
    logic        host_privileged;
    logic        host_lock;
    logic        host_sequential;
    logic        host_more;
    logic        host_done;
    logic [31:0] host_rdata;
    logic        host_error;

    arm7tdmi_mister_enable_done_adapter u_enable_done (
        .MEM_VALID      (mem_valid),
        .MEM_READY      (ed_mem_ready),
        .MEM_ADDR       (mem_addr),
        .MEM_WRITE      (mem_write),
        .MEM_WDATA      (mem_wdata),
        .MEM_BYTE_ENABLE(mem_byte_enable),
        .MEM_CODE       (mem_code),
        .MEM_PRIVILEGED (mem_privileged),
        .MEM_LOCK       (mem_lock),
        .MEM_SEQUENTIAL (mem_sequential),
        .MEM_MORE       (mem_more),
        .MEM_RDATA      (ed_mem_rdata),
        .MEM_ERROR      (ed_mem_error),
        .HOST_ENABLE    (host_enable),
        .HOST_ADDR      (host_addr),
        .HOST_WRITE     (host_write),
        .HOST_WDATA     (host_wdata),
        .HOST_BYTE_ENABLE(host_byte_enable),
        .HOST_CODE      (host_code),
        .HOST_PRIVILEGED(host_privileged),
        .HOST_LOCK      (host_lock),
        .HOST_SEQUENTIAL(host_sequential),
        .HOST_MORE      (host_more),
        .HOST_DONE      (host_done),
        .HOST_RDATA     (host_rdata),
        .HOST_ERROR     (host_error)
    );

    task automatic check(input logic condition, input string description);
        if (!condition)
            $fatal(1, "[adapters] FAIL: %s", description);
    endtask

    task automatic check_payload;
        check(wb_cyc && wb_stb, "Wishbone cycle/strobe not asserted");
        check(wb_adr == mem_addr, "Wishbone byte address changed");
        check(wb_we == mem_write, "Wishbone direction changed");
        check(wb_dat_w == mem_wdata, "Wishbone write data changed");
        check(wb_sel == mem_byte_enable, "Wishbone byte selects changed");
        check(wb_lock == mem_lock, "Wishbone lock changed");
        check(wb_cti == 3'b000 && wb_bte == 2'b00,
              "Wishbone adapter did not use a classic linear cycle");
        check({wb_code, wb_privileged, wb_sequential, wb_more}
              == {mem_code, mem_privileged, mem_sequential, mem_more},
              "Wishbone metadata sideband changed");

        check(host_enable, "enable/done request not asserted");
        check(host_addr == mem_addr, "enable/done address changed");
        check(host_write == mem_write, "enable/done direction changed");
        check(host_wdata == mem_wdata, "enable/done write data changed");
        check(host_byte_enable == mem_byte_enable,
              "enable/done byte enables changed");
        check({host_code, host_privileged, host_lock,
               host_sequential, host_more}
              == {mem_code, mem_privileged, mem_lock,
                  mem_sequential, mem_more},
              "enable/done metadata changed");
    endtask

    initial begin
        mem_valid       = 1'b0;
        mem_addr        = 32'h1234_5679;
        mem_write       = 1'b1;
        mem_wdata       = 32'hA5C3_7E19;
        mem_byte_enable = 4'b0010;
        mem_code        = 1'b0;
        mem_privileged  = 1'b1;
        mem_lock        = 1'b1;
        mem_sequential  = 1'b1;
        mem_more        = 1'b1;
        wb_ack          = 1'b1;
        wb_err          = 1'b0;
        wb_dat_r        = 32'h1122_3344;
        host_done       = 1'b1;
        host_rdata      = 32'h5566_7788;
        host_error      = 1'b0;
        #1;

        check(!wb_cyc && !wb_stb && !wb_mem_ready,
              "Wishbone completed without MEM_VALID");
        check(!host_enable && !ed_mem_ready,
              "enable/done completed without MEM_VALID");

        wb_ack    = 1'b0;
        host_done = 1'b0;
        mem_valid = 1'b1;
        #1;
        check_payload();
        check(!wb_mem_ready && !ed_mem_ready,
              "adapter completed before target response");

        // Payload stays transparent and stable for every wait cycle.
        repeat (3) begin
            #1;
            check_payload();
            check(!wb_mem_ready && !ed_mem_ready,
                  "adapter invented a completion under backpressure");
        end

        wb_ack    = 1'b1;
        host_done = 1'b1;
        #1;
        check(wb_mem_ready && !wb_mem_error,
              "Wishbone success did not complete cleanly");
        check(wb_mem_rdata == wb_dat_r,
              "Wishbone read data changed");
        check(ed_mem_ready && !ed_mem_error,
              "enable/done success did not complete cleanly");
        check(ed_mem_rdata == host_rdata,
              "enable/done read data changed");

        wb_ack     = 1'b0;
        wb_err     = 1'b1;
        host_error = 1'b1;
        #1;
        check(wb_mem_ready && wb_mem_error,
              "Wishbone error did not complete with MEM_ERROR");
        check(ed_mem_ready && ed_mem_error,
              "enable/done error did not complete with MEM_ERROR");

        mem_valid = 1'b0;
        #1;
        check(!wb_mem_ready && !wb_mem_error,
              "Wishbone response escaped request qualification");
        check(!ed_mem_ready && !ed_mem_error,
              "enable/done response escaped request qualification");

        $display("[adapters] PASS");
        $finish;
    end

    initial begin
        #100;
        $fatal(1, "[adapters] TIMEOUT");
    end

endmodule
