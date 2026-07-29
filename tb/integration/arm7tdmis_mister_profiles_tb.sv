// MIST-004 eight-profile regression.
//
// All BIG_ENDIAN x ENABLE_DEBUG x ENABLE_COPROCESSOR combinations elaborate
// and execute concurrently. Each profile performs byte/halfword stores so
// endian lane mapping is externally visible. Disabled coprocessor profiles
// must take Undefined even though CPA/CPB are driven ready; enabled profiles
// must accept the same CDP. Disabled debug profiles remain isolated while all
// enabled profiles complete the same synchronous default-IDCODE scan.

`timescale 1ns/1ps

module arm7tdmis_mister_profiles_tb;

    localparam int PROFILE_COUNT = 8;

    logic CLK;
    initial CLK = 1'b0;
    always #5 CLK = ~CLK;

    logic RESET_N;

    logic                    DBG_STEP_VALID;
    logic                    DBG_STEP_TMS;
    logic                    DBG_STEP_TDI;
    logic                    DBG_STEP_RSP_READY;

    logic [PROFILE_COUNT-1:0] MEM_VALID;
    logic [PROFILE_COUNT-1:0][31:0] MEM_ADDR;
    logic [PROFILE_COUNT-1:0] MEM_WRITE;
    logic [PROFILE_COUNT-1:0][31:0] MEM_WDATA;
    logic [PROFILE_COUNT-1:0][3:0] MEM_BYTE_ENABLE;
    logic [PROFILE_COUNT-1:0] MEM_CODE;
    logic [PROFILE_COUNT-1:0] MEM_PRIVILEGED;
    logic [PROFILE_COUNT-1:0] MEM_LOCK;
    logic [PROFILE_COUNT-1:0] MEM_SEQUENTIAL;
    logic [PROFILE_COUNT-1:0] MEM_MORE;
    logic [PROFILE_COUNT-1:0][31:0] MEM_RDATA;

    logic [PROFILE_COUNT-1:0] CPnMREQ;
    logic [PROFILE_COUNT-1:0] CPSEQ;
    logic [PROFILE_COUNT-1:0] CPnTRANS;
    logic [PROFILE_COUNT-1:0] CPnOPC;
    logic [PROFILE_COUNT-1:0] CPTBIT;
    logic [PROFILE_COUNT-1:0] CPnI;

    logic [PROFILE_COUNT-1:0] DBG_STEP_READY;
    logic [PROFILE_COUNT-1:0] DBG_STEP_RSP_VALID;
    logic [PROFILE_COUNT-1:0] DBG_STEP_TDO;
    logic [PROFILE_COUNT-1:0] DBG_STEP_TDO_OE;
    logic [PROFILE_COUNT-1:0] DBGACK;
    logic [PROFILE_COUNT-1:0] DBGnEXEC;
    logic [PROFILE_COUNT-1:0] DBGINSTRVALID;
    logic [PROFILE_COUNT-1:0][1:0] DBGRNG;
    logic [PROFILE_COUNT-1:0] DBGCOMMTX;
    logic [PROFILE_COUNT-1:0] DBGCOMMRX;

    logic [31:0] memory [0:PROFILE_COUNT-1][0:255];

    genvar profile;
    generate
        for (profile = 0; profile < PROFILE_COUNT; profile++) begin : g_profile
            localparam bit PROFILE_BIG_ENDIAN = ((profile & 4) != 0);
            localparam bit PROFILE_DEBUG = ((profile & 2) != 0);
            localparam bit PROFILE_COPROCESSOR = ((profile & 1) != 0);

            assign MEM_RDATA[profile] =
                memory[profile][MEM_ADDR[profile][9:2]];

            arm7tdmi_mister #(
                .BIG_ENDIAN          (PROFILE_BIG_ENDIAN),
                .ENABLE_DEBUG        (PROFILE_DEBUG),
                .ENABLE_COPROCESSOR  (PROFILE_COPROCESSOR)
            ) u_dut (
                .CLK,
                .RESET_N,
                .CPU_CE              (1'b1),
                .IRQ_ASYNC           (1'b0),
                .FIQ_ASYNC           (1'b0),
                .MEM_VALID           (MEM_VALID[profile]),
                .MEM_READY           (MEM_VALID[profile]),
                .MEM_ADDR            (MEM_ADDR[profile]),
                .MEM_WRITE           (MEM_WRITE[profile]),
                .MEM_WDATA           (MEM_WDATA[profile]),
                .MEM_BYTE_ENABLE     (MEM_BYTE_ENABLE[profile]),
                .MEM_CODE            (MEM_CODE[profile]),
                .MEM_PRIVILEGED      (MEM_PRIVILEGED[profile]),
                .MEM_LOCK            (MEM_LOCK[profile]),
                .MEM_SEQUENTIAL      (MEM_SEQUENTIAL[profile]),
                .MEM_MORE            (MEM_MORE[profile]),
                .MEM_RDATA           (MEM_RDATA[profile]),
                .MEM_ERROR           (1'b0),
                .CPnMREQ             (CPnMREQ[profile]),
                .CPSEQ               (CPSEQ[profile]),
                .CPnTRANS            (CPnTRANS[profile]),
                .CPnOPC              (CPnOPC[profile]),
                .CPTBIT              (CPTBIT[profile]),
                .CPnI                (CPnI[profile]),
                // Deliberately ready in every profile. A disabled wrapper
                // must ignore these values and force the internal CP absent.
                .CPA                 (1'b0),
                .CPB                 (1'b0),
                .DEBUG_ENABLE_ASYNC  (1'b1),
                .DBGRQ_ASYNC         (1'b0),
                .DBGBREAK_ASYNC      (1'b0),
                .DBGEXT_ASYNC        (2'b00),
                .DBG_STEP_VALID,
                .DBG_STEP_READY      (DBG_STEP_READY[profile]),
                .DBG_STEP_TMS,
                .DBG_STEP_TDI,
                .DBG_STEP_RSP_VALID  (DBG_STEP_RSP_VALID[profile]),
                .DBG_STEP_RSP_READY,
                .DBG_STEP_TDO        (DBG_STEP_TDO[profile]),
                .DBG_STEP_TDO_OE     (DBG_STEP_TDO_OE[profile]),
                .DBGACK              (DBGACK[profile]),
                .DBGnEXEC            (DBGnEXEC[profile]),
                .DBGINSTRVALID       (DBGINSTRVALID[profile]),
                .DBGRNG              (DBGRNG[profile]),
                .DBGCOMMTX           (DBGCOMMTX[profile]),
                .DBGCOMMRX           (DBGCOMMRX[profile])
            );

            always_ff @(posedge CLK) begin
                if (RESET_N && MEM_VALID[profile] && MEM_WRITE[profile]) begin
                    for (int lane = 0; lane < 4; lane++) begin
                        if (MEM_BYTE_ENABLE[profile][lane])
                            memory[profile][MEM_ADDR[profile][9:2]]
                                  [lane*8 +: 8]
                                <= MEM_WDATA[profile][lane*8 +: 8];
                    end
                end
            end
        end
    endgenerate

    integer errors;

    task automatic check(input logic condition, input string description);
        if (!condition) begin
            $display("[mister_profiles] FAIL: %s", description);
            errors++;
        end
    endtask

    task automatic consume_debug_responses;
        @(negedge CLK);
        DBG_STEP_VALID     = 1'b0;
        DBG_STEP_RSP_READY = 1'b1;
        @(posedge CLK);
        #1;
        for (int index = 0; index < PROFILE_COUNT; index++) begin
            check(!DBG_STEP_RSP_VALID[index],
                  $sformatf("profile %0d response did not retire", index));
        end
        @(negedge CLK);
        DBG_STEP_RSP_READY = 1'b0;
    endtask

    task automatic debug_step(
        input  logic tms,
        input  logic tdi,
        output logic tdo,
        output logic tdo_oe
    );
        @(negedge CLK);
        DBG_STEP_TMS   = tms;
        DBG_STEP_TDI   = tdi;
        DBG_STEP_VALID = 1'b1;
        #1;
        for (int index = 0; index < PROFILE_COUNT; index++) begin
            if ((index & 2) != 0)
                check(DBG_STEP_READY[index],
                      $sformatf("debug profile %0d was not ready", index));
            else
                check(!DBG_STEP_READY[index],
                      $sformatf("trimmed profile %0d accepted debug", index));
        end

        @(posedge CLK);
        #1;
        tdo    = DBG_STEP_TDO[2];
        tdo_oe = DBG_STEP_TDO_OE[2];
        for (int index = 0; index < PROFILE_COUNT; index++) begin
            if ((index & 2) != 0) begin
                check(DBG_STEP_RSP_VALID[index],
                      $sformatf("debug profile %0d lost response", index));
                check(DBG_STEP_TDO[index] == tdo
                      && DBG_STEP_TDO_OE[index] == tdo_oe,
                      $sformatf("debug profile %0d response diverged", index));
            end else begin
                check(!DBG_STEP_RSP_VALID[index]
                      && !DBG_STEP_TDO[index]
                      && !DBG_STEP_TDO_OE[index],
                      $sformatf("trimmed profile %0d exposed debug", index));
            end
        end
        consume_debug_responses();
    endtask

    task automatic debug_move(input logic tms);
        logic ignored_tdo;
        logic ignored_oe;
        debug_step(tms, 1'b0, ignored_tdo, ignored_oe);
        check(!$isunknown({ignored_tdo, ignored_oe}),
              "debug control step returned unknown data");
    endtask

    initial begin
        logic [31:0] idcode;
        logic sampled_tdo;
        logic sampled_oe;
        logic all_done;

        errors             = 0;
        RESET_N            = 1'b0;
        DBG_STEP_VALID     = 1'b0;
        DBG_STEP_TMS       = 1'b0;
        DBG_STEP_TDI       = 1'b0;
        DBG_STEP_RSP_READY = 1'b0;

        for (int index = 0; index < PROFILE_COUNT; index++) begin
            for (int word_index = 0; word_index < 256; word_index++)
                memory[index][word_index] = 32'h0000_0000;

            memory[index][0]  = 32'hEA00_0006; // B main (0x20)
            memory[index][1]  = 32'hEA00_003D; // B undef (0x100)
            memory[index][2]  = 32'hEAFF_FFFE;
            memory[index][3]  = 32'hEAFF_FFFE;
            memory[index][4]  = 32'hEAFF_FFFE;
            memory[index][5]  = 32'hEAFF_FFFE;
            memory[index][6]  = 32'hEAFF_FFFE;
            memory[index][7]  = 32'hEAFF_FFFE;

            memory[index][8]  = 32'hE3A0_0C02; // MOV  r0,#0x200
            memory[index][9]  = 32'hE3A0_10AA; // MOV  r1,#0xAA
            memory[index][10] = 32'hE5C0_1001; // STRB r1,[r0,#1]
            memory[index][11] = 32'hE3A0_2055; // MOV  r2,#0x55
            memory[index][12] = 32'hE1C0_20B2; // STRH r2,[r0,#2]
            memory[index][13] = 32'hEE00_0400; // CDP  p4,0,c0,c0,c0,0
            memory[index][14] = 32'hE3A0_30A5; // MOV  r3,#0xA5
            memory[index][15] = 32'hE580_3004; // STR  r3,[r0,#4]
            memory[index][16] = 32'hEAFF_FFFE; // B .

            // Guard against a speculative/fall-through fetch being confused
            // with the exception path: every word up to the distant handler
            // is itself an infinite branch.
            for (int guard_index = 17; guard_index < 64; guard_index++)
                memory[index][guard_index] = 32'hEAFF_FFFE;

            memory[index][64] = 32'hE3A0_400D; // Undef marker
            memory[index][65] = 32'hE580_400C; // STR r4,[r0,#12]
            memory[index][66] = 32'hE1B0_F00E; // MOVS pc,lr
        end

        repeat (5) @(posedge CLK);
        @(negedge CLK);
        RESET_N = 1'b1;

        // Allow DEBUG_ENABLE_ASYNC to pass both wrapper synchronizer stages.
        repeat (5) @(posedge CLK);

        debug_move(1'b0); // TLR -> Run-Test/Idle
        debug_move(1'b1); // Select-DR-Scan
        debug_move(1'b0); // Capture-DR
        debug_move(1'b0); // Shift-DR

        idcode = 32'h0000_0000;
        for (int bit_index = 0; bit_index < 32; bit_index++) begin
            debug_step(bit_index == 31, 1'b0, sampled_tdo, sampled_oe);
            idcode[bit_index] = sampled_tdo;
            check(sampled_oe,
                  $sformatf("IDCODE bit %0d had no output enable", bit_index));
        end
        debug_move(1'b1); // Exit1-DR -> Update-DR
        debug_move(1'b0); // Update-DR -> Run-Test/Idle
        check(idcode == 32'h7F1F_0F0F,
              $sformatf("profile IDCODE mismatch: %08x", idcode));

        all_done = 1'b0;
        while (!all_done) begin
            @(posedge CLK);
            all_done = 1'b1;
            for (int index = 0; index < PROFILE_COUNT; index++) begin
                if (memory[index][129] != 32'h0000_00A5)
                    all_done = 1'b0;
            end
        end
        #1;

        for (int index = 0; index < PROFILE_COUNT; index++) begin
            if ((index & 4) != 0)
                check(memory[index][128] == 32'h00AA_0055,
                      $sformatf("profile %0d BE lanes produced %08x",
                                index, memory[index][128]));
            else
                check(memory[index][128] == 32'h0055_AA00,
                      $sformatf("profile %0d LE lanes produced %08x",
                                index, memory[index][128]));

            if ((index & 1) != 0)
                check(memory[index][131] == 32'h0000_0000,
                      $sformatf("profile %0d rejected enabled CP", index));
            else
                check(memory[index][131] == 32'h0000_000D,
                      $sformatf("profile %0d did not force CP absent", index));
        end

        check(!$isunknown({
                  MEM_VALID, MEM_ADDR, MEM_WRITE, MEM_WDATA,
                  MEM_BYTE_ENABLE, MEM_CODE, MEM_PRIVILEGED,
                  MEM_LOCK, MEM_SEQUENTIAL, MEM_MORE,
                  CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI,
                  DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG,
                  DBGCOMMTX, DBGCOMMRX
              }), "one or more profile outputs contain unknown state");

        if (errors != 0)
            $fatal(1, "[mister_profiles] FAIL (%0d errors)", errors);
        $display("[mister_profiles] PASS");
        $finish;
    end

    initial begin
        #1_000_000;
        $fatal(1, "[mister_profiles] TIMEOUT");
    end

endmodule
