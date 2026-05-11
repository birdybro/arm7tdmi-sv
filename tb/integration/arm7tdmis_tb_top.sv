// §2 testbench top. Instantiates the DUT, the behavioral memory model,
// the cycle logger, and drives clock/reset/config. At §1 the core is a
// port shell that holds TRANS=I forever, so the simulation just runs for
// CYCLE_LIMIT cycles and exits — the framework is what's being verified
// here, not core behavior.
//
// Timescale is set on the Verilator command line (--timescale 1ns/1ps in
// scripts/Makefile) so every module gets the same units without per-file
// directives.

module arm7tdmis_tb_top
    import arm7tdmis_bus_pkg::*;
;

    // ---- Run-time knobs ----
    localparam int    CLK_HALF_PERIOD = 5;        // 100 MHz nominal
    localparam int    RESET_CYCLES    = 4;
    localparam int    CYCLE_LIMIT     = 1024;
    localparam string INIT_HEX        = "../tb/programs/smoke.hex";
    localparam string LOG_FILE        = "cycle.csv";
    localparam string FST_FILE        = "waves.fst";

    // ---- Clock + reset ----
    logic CLK;
    initial begin
        CLK = 1'b0;
        forever #(CLK_HALF_PERIOD) CLK = ~CLK;
    end

    logic nRESET;
    initial begin
        nRESET = 1'b0;
        repeat (RESET_CYCLES) @(posedge CLK);
        nRESET = 1'b1;
    end

    // ---- Static configuration ----
    logic CFGBIGEND;
    logic CLKEN;
    initial begin
        CFGBIGEND = 1'b0;          // little-endian default
        CLKEN     = 1'b1;          // no wait states by default
    end

    // ---- Interrupts and bus exception (idle) ----
    logic nIRQ, nFIQ, ABORT;
    logic mem_inject_abort;
    initial begin
        nIRQ             = 1'b1;   // active-low; HIGH = no IRQ pending
        nFIQ             = 1'b1;
        mem_inject_abort = 1'b0;
    end

    // ---- Debug + JTAG (idle until §22/§23) ----
    logic       DBGEN, DBGRQ, DBGBREAK;
    logic [1:0] DBGEXT;
    logic       DBGTCKEN, DBGTMS, DBGTDI, DBGnTRST;
    initial begin
        DBGEN    = 1'b0;           // debug disabled
        DBGRQ    = 1'b0;
        DBGBREAK = 1'b0;
        DBGEXT   = 2'b00;
        DBGTCKEN = 1'b0;
        DBGTMS   = 1'b0;
        DBGTDI   = 1'b0;
        DBGnTRST = 1'b0;           // hold TAP in reset until JTAG is exercised
    end

    // ---- Bus wires from DUT to memory ----
    logic [31:0] ADDR;
    logic        WRITE;
    logic [1:0]  SIZE;
    logic [1:0]  PROT;
    logic        LOCK;
    logic [1:0]  TRANS;
    logic [31:0] WDATA;
    logic [31:0] RDATA;

    // ---- Coprocessor handshake (no external coprocessor — TRM §4.6 / §30.19.5)
    logic CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI;
    logic CPA, CPB;
    assign CPA = 1'b1;             // absent: CPA=1, CPB=1
    assign CPB = 1'b1;

    // ---- Debug status from DUT ----
    logic       DBGACK, DBGnEXEC, DBGINSTRVALID;
    logic [1:0] DBGRNG;
    logic       DBGCOMMTX, DBGCOMMRX;
    logic       DBGTDO, DBGnTDOEN;
    logic       DMORE;

    // ---- DUT ----
    arm7tdmis_top u_dut (
        .CLK            (CLK),
        .CLKEN          (CLKEN),
        .nRESET         (nRESET),
        .CFGBIGEND      (CFGBIGEND),

        .nIRQ           (nIRQ),
        .nFIQ           (nFIQ),
        .ABORT          (ABORT),

        .ADDR           (ADDR),
        .WRITE          (WRITE),
        .SIZE           (SIZE),
        .PROT           (PROT),
        .LOCK           (LOCK),
        .TRANS          (TRANS),
        .WDATA          (WDATA),
        .RDATA          (RDATA),

        .CPnMREQ        (CPnMREQ),
        .CPSEQ          (CPSEQ),
        .CPnTRANS       (CPnTRANS),
        .CPnOPC         (CPnOPC),
        .CPTBIT         (CPTBIT),
        .CPnI           (CPnI),
        .CPA            (CPA),
        .CPB            (CPB),

        .DBGEN          (DBGEN),
        .DBGRQ          (DBGRQ),
        .DBGBREAK       (DBGBREAK),
        .DBGACK         (DBGACK),
        .DBGnEXEC       (DBGnEXEC),
        .DBGINSTRVALID  (DBGINSTRVALID),
        .DBGEXT         (DBGEXT),
        .DBGRNG         (DBGRNG),
        .DBGCOMMTX      (DBGCOMMTX),
        .DBGCOMMRX      (DBGCOMMRX),

        .DBGTCKEN       (DBGTCKEN),
        .DBGTMS         (DBGTMS),
        .DBGTDI         (DBGTDI),
        .DBGTDO         (DBGTDO),
        .DBGnTRST       (DBGnTRST),
        .DBGnTDOEN      (DBGnTDOEN),

        .DMORE          (DMORE)
    );

    // ---- Behavioral memory ----
    arm7tdmis_memory #(
        .WORDS    (16384),
        .INIT_HEX (INIT_HEX)
    ) u_mem (
        .CLK            (CLK),
        .CLKEN          (CLKEN),
        .nRESET         (nRESET),
        .CFGBIGEND      (CFGBIGEND),

        .ADDR           (ADDR),
        .WRITE          (WRITE),
        .SIZE           (SIZE),
        .PROT           (PROT),
        .LOCK           (LOCK),
        .TRANS          (TRANS),
        .WDATA          (WDATA),
        .RDATA          (RDATA),
        .ABORT          (ABORT),
        .inject_abort   (mem_inject_abort)
    );

    // ---- Cycle counter (drives logger and timeout). The reset_sync
    //      module uses nRESET as an asynchronous flop reset, while we read
    //      it here synchronously — Verilator flags this as a sync/async
    //      mismatch on the same net. In the TB it's benign (nRESET is
    //      driven procedurally, never crosses a real domain), so suppress.
    logic [63:0] cycle_count;
    /* verilator lint_off SYNCASYNCNET */
    always_ff @(posedge CLK) begin
        if (CLKEN) begin
            if (!nRESET) cycle_count <= 64'h0;
            else         cycle_count <= cycle_count + 64'h1;
        end
    end
    /* verilator lint_on SYNCASYNCNET */

    // ---- Bus / architectural assertions ----
    arm7tdmis_assertions u_assert (
        .CLK    (CLK),
        .nRESET (nRESET),
        .SIZE   (SIZE),
        .ABORT  (ABORT),
        .TRANS  (TRANS)
    );

    // ---- Cycle logger ----
    arm7tdmis_cycle_logger #(
        .LOG_FILE (LOG_FILE)
    ) u_logger (
        .CLK         (CLK),
        .CLKEN       (CLKEN),
        .nRESET      (nRESET),
        .cycle_count (cycle_count),
        .ADDR        (ADDR),
        .WRITE       (WRITE),
        .SIZE        (SIZE),
        .PROT        (PROT),
        .LOCK        (LOCK),
        .TRANS       (TRANS),
        .WDATA       (WDATA),
        .RDATA       (RDATA),
        .ABORT       (ABORT)
    );

    // ---- Wave dump ----
    initial begin
        $dumpfile(FST_FILE);
        $dumpvars(0, arm7tdmis_tb_top);
    end

    // ---- DUT output observers (consumed only by the cycle logger and FST
    //      dump today; reduction-XOR keeps lint quiet until §3+ wires real
    //      checks against them).
    /* verilator lint_off UNUSEDSIGNAL */
    wire _unused_dut_outputs = &{1'b0,
        CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI,
        DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG,
        DBGCOMMTX, DBGCOMMRX,
        DBGTDO, DBGnTDOEN,
        DMORE
    };
    /* verilator lint_on UNUSEDSIGNAL */

    // ---- End-of-sim watchdog ----
    initial begin
        $display("[tb] starting; CYCLE_LIMIT=%0d", CYCLE_LIMIT);
        wait (nRESET);
        repeat (CYCLE_LIMIT) @(posedge CLK);
        $display("[tb] reached CYCLE_LIMIT (%0d cycles); finishing.", CYCLE_LIMIT);
        $finish;
    end

    // ---- §9 smoke verification ----
    // The smoke program exercises both DP-immediate (the first four MOVs)
    // and DP-register (ADD/MOV-LSL/MOV-LSR/ORR/AND, plus a register-shifted-
    // register MOV r9, r0, LSL r1). Each instruction takes 2 cycles in the
    // non-pipelined model, so 50 post-reset cycles is comfortably above
    // the 11-instruction × 2-cycle = 22-cycle budget.
    int unsigned smoke_errors = 0;

    task automatic check_reg(input int idx, input logic [31:0] expected, input string name);
        if (u_dut.u_core.u_regfile.regs[idx] !== expected) begin
            $display("[smoke] FAIL %s (r%0d): expected %08x, got %08x",
                     name, idx, expected, u_dut.u_core.u_regfile.regs[idx]);
            smoke_errors = smoke_errors + 1;
        end
    endtask

    initial begin
        wait (nRESET);
        @(posedge CLK);
        $display("[smoke] mem[0..4] = %08x %08x %08x %08x %08x",
                 u_mem.mem[0], u_mem.mem[1], u_mem.mem[2],
                 u_mem.mem[3], u_mem.mem[4]);
        repeat (50) @(posedge CLK);

        // DP-immediate results from the first four MOVs
        check_reg(0, 32'h00000005, "r0=5");
        check_reg(1, 32'h00000007, "r1=7");
        check_reg(2, 32'h000000FF, "r2=0xFF");
        check_reg(3, 32'hFF000000, "r3=0xFF000000");

        // DP-register results
        check_reg(4, 32'h0000000C, "r4=r0+r1");                  // ADD
        check_reg(5, 32'h0000000A, "r5=r0<<1");                  // MOV LSL #1
        check_reg(6, 32'h00000003, "r6=r1>>1");                  // MOV LSR #1
        check_reg(7, 32'h00000007, "r7=r0|r1");                  // ORR
        check_reg(8, 32'h00000005, "r8=r2&r0");                  // AND
        check_reg(9, 32'h00000280, "r9=r0<<r1");                 // MOV r0,LSL r1

        if (u_dut.u_core.pc_q !== 32'h00000028) begin
            $display("[smoke] FAIL pc_q: expected 0x00000028 (self-loop), got %08x",
                     u_dut.u_core.pc_q);
            smoke_errors = smoke_errors + 1;
        end

        if (smoke_errors == 0) begin
            $display("[smoke] PASS");
        end else begin
            $display("[smoke] FAIL (%0d errors)", smoke_errors);
        end
        $finish;
    end

endmodule
