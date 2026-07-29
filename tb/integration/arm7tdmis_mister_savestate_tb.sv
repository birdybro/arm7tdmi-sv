// MIST-006 fail-hard architectural save/restore determinism regression.
//
// Snapshot request is first made behind an unready data write, proving that
// READY means no bus beat is in flight. Every architectural word is exported,
// overwritten, read back, and restored. Two equal post-restore transaction
// traces then prove deterministic restart. A final imported image represents
// the precise boundary between the two Thumb BL halfwords.

`timescale 1ns/1ps

module arm7tdmis_mister_savestate_tb;

    localparam int STATE_WORDS = 37;
    localparam int TRACE_LENGTH = 24;
    localparam logic [31:0] THUMB_SUFFIX_PC = 32'h0000_0082;
    // Compact state word 25 maps physical regfile slot 26: r14_svc.
    localparam logic [5:0] STATE_R14_SVC = 6'd25;
    localparam int REQUEST_WIDTH = 74;

    logic CLK;
    initial CLK = 1'b0;
    always #5 CLK = ~CLK;

    logic RESET_N;
    logic CPU_CE;
    logic ready_enable;
    logic STATE_REQUEST;
    logic STATE_READY;
    logic STATE_WRITE;
    logic [5:0] STATE_INDEX;
    logic [31:0] STATE_WDATA;
    logic [31:0] STATE_RDATA;

    logic        MEM_VALID;
    wire         MEM_READY = MEM_VALID && ready_enable;
    logic [31:0] MEM_ADDR;
    logic        MEM_WRITE;
    logic [31:0] MEM_WDATA;
    logic [3:0]  MEM_BYTE_ENABLE;
    logic        MEM_CODE;
    logic        MEM_PRIVILEGED;
    logic        MEM_LOCK;
    logic        MEM_SEQUENTIAL;
    logic        MEM_MORE;
    logic [31:0] MEM_RDATA;

    logic CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI;
    logic DBG_STEP_READY, DBG_STEP_RSP_VALID;
    logic DBG_STEP_TDO, DBG_STEP_TDO_OE;
    logic DBGACK, DBGnEXEC, DBGINSTRVALID;
    logic [1:0] DBGRNG;
    logic DBGCOMMTX, DBGCOMMRX;

    arm7tdmi_mister u_dut (
        .CLK,
        .RESET_N,
        .CPU_CE,
        .IRQ_ASYNC             (1'b0),
        .FIQ_ASYNC             (1'b0),
        .MEM_VALID,
        .MEM_READY,
        .MEM_ADDR,
        .MEM_WRITE,
        .MEM_WDATA,
        .MEM_BYTE_ENABLE,
        .MEM_CODE,
        .MEM_PRIVILEGED,
        .MEM_LOCK,
        .MEM_SEQUENTIAL,
        .MEM_MORE,
        .MEM_RDATA,
        .MEM_ERROR             (1'b0),
        .CPnMREQ,
        .CPSEQ,
        .CPnTRANS,
        .CPnOPC,
        .CPTBIT,
        .CPnI,
        .CPA                   (1'b1),
        .CPB                   (1'b1),
        .DEBUG_ENABLE_ASYNC    (1'b0),
        .DBGRQ_ASYNC           (1'b0),
        .DBGBREAK_ASYNC        (1'b0),
        .DBGEXT_ASYNC          (2'b00),
        .DBG_STEP_VALID        (1'b0),
        .DBG_STEP_READY,
        .DBG_STEP_TMS          (1'b0),
        .DBG_STEP_TDI          (1'b0),
        .DBG_STEP_RSP_VALID,
        .DBG_STEP_RSP_READY    (1'b1),
        .DBG_STEP_TDO,
        .DBG_STEP_TDO_OE,
        .DBGACK,
        .DBGnEXEC,
        .DBGINSTRVALID,
        .DBGRNG,
        .DBGCOMMTX,
        .DBGCOMMRX,
        .STATE_REQUEST,
        .STATE_READY,
        .STATE_WRITE,
        .STATE_INDEX,
        .STATE_WDATA,
        .STATE_RDATA
    );

    logic [31:0] memory [0:255];
    assign MEM_RDATA = memory[MEM_ADDR[9:2]];

    always_ff @(posedge CLK) begin
        if (RESET_N && MEM_VALID && MEM_READY && MEM_WRITE) begin
            for (int lane = 0; lane < 4; lane++) begin
                if (MEM_BYTE_ENABLE[lane])
                    memory[MEM_ADDR[9:2]][lane * 8 +: 8]
                        <= MEM_WDATA[lane * 8 +: 8];
            end
        end
    end

    logic [31:0] snapshot [0:STATE_WORDS-1];
    logic [31:0] mutated [0:STATE_WORDS-1];
    logic [REQUEST_WIDTH-1:0] trace_first [0:TRACE_LENGTH-1];
    logic [REQUEST_WIDTH-1:0] trace_second [0:TRACE_LENGTH-1];
    wire [REQUEST_WIDTH-1:0] request_payload = {
        MEM_ADDR,
        MEM_WRITE,
        MEM_WDATA,
        MEM_BYTE_ENABLE,
        MEM_CODE,
        MEM_PRIVILEGED,
        MEM_LOCK,
        MEM_SEQUENTIAL,
        MEM_MORE
    };

    task automatic state_read(
        input  logic [5:0] index,
        output logic [31:0] value
    );
        @(negedge CLK);
        STATE_INDEX = 6'(index);
        #1;
        value = STATE_RDATA;
    endtask

    task automatic state_write(
        input logic [5:0] index,
        input logic [31:0] value
    );
        @(negedge CLK);
        STATE_INDEX = 6'(index);
        STATE_WDATA = value;
        STATE_WRITE = 1'b1;
        @(posedge CLK);
        #1;
        STATE_WRITE = 1'b0;
    endtask

    task automatic capture_trace(
        output logic [REQUEST_WIDTH-1:0] trace [0:TRACE_LENGTH-1]
    );
        int accepted;
        accepted = 0;
        while (accepted < TRACE_LENGTH) begin
            @(posedge CLK);
            #1;
            if (MEM_VALID && MEM_READY) begin
                trace[accepted] = request_payload;
                accepted++;
            end
        end
    endtask

    task automatic request_quiescence;
        @(negedge CLK);
        STATE_REQUEST = 1'b1;
        wait (STATE_READY);
        #1;
        if (MEM_VALID)
            $fatal(1, "[mister_savestate] READY with a live request");
    endtask

    task automatic resume;
        @(negedge CLK);
        STATE_REQUEST = 1'b0;
        @(posedge CLK);
        #1;
        if (STATE_READY)
            $fatal(1, "[mister_savestate] READY survived resume edge");
    endtask

    initial begin
        logic [31:0] saved_memory;
        logic [31:0] first_end_memory;
        logic [31:0] observed;
        logic saw_thumb_target;

        RESET_N      = 1'b0;
        CPU_CE       = 1'b1;
        ready_enable = 1'b1;
        STATE_REQUEST = 1'b0;
        STATE_WRITE   = 1'b0;
        STATE_INDEX   = 6'h00;
        STATE_WDATA   = 32'h0000_0000;

        for (int word = 0; word < 256; word++)
            memory[word] = 32'heaff_fffe;

        // Increment [0x100], perturb r2, and repeat.
        memory[0] = 32'he3a0_0c01; // MOV r0,#0x100
        memory[1] = 32'he590_1000; // LDR r1,[r0]
        memory[2] = 32'he281_1001; // ADD r1,r1,#1
        memory[3] = 32'he580_1000; // STR r1,[r0]
        memory[4] = 32'he282_2003; // ADD r2,r2,#3
        memory[5] = 32'heaff_fffa; // B 0x4
        memory[64] = 32'h0000_0010;

        // A legal imported snapshot between Thumb BL prefix and suffix:
        // User/SVC LR=0x84, CPSR.T=1, next PC=0x82. Suffix imm11=0x1e
        // must branch to 0xc0 and replace LR with 0x85.
        memory[32] = {16'hf81e, 16'hf000};
        memory[48] = {16'he7fe, 16'h2505};

        repeat (5) @(posedge CLK);
        @(negedge CLK);
        RESET_N = 1'b1;

        wait (MEM_VALID && MEM_WRITE && MEM_ADDR == 32'h0000_0100);
        @(negedge CLK);
        ready_enable  = 1'b0;
        STATE_REQUEST = 1'b1;
        repeat (5) begin
            @(posedge CLK);
            #1;
            if (STATE_READY)
                $fatal(1,
                       "[mister_savestate] quiesced before stalled write");
        end
        @(negedge CLK);
        CPU_CE      = 1'b0;
        ready_enable = 1'b1;
        repeat (5) begin
            @(posedge CLK);
            #1;
            if (STATE_READY)
                $fatal(1,
                       "[mister_savestate] quiesced while CPU_CE was low");
        end
        @(negedge CLK);
        CPU_CE = 1'b1;
        wait (STATE_READY);
        #1;
        if (MEM_VALID)
            $fatal(1, "[mister_savestate] request survived quiescence");

        saved_memory = memory[64];
        for (int index = 0; index < STATE_WORDS; index++)
            state_read(6'(index), snapshot[index]);
        if (snapshot[30] != 32'h0000_0010)
            $fatal(1, "[mister_savestate] wrong restart PC %08x",
                   snapshot[30]);

        // Prove that every physical bank, PC, CPSR, and SPSR word has an
        // independent read/write path while quiescent.
        for (int index = 0; index < STATE_WORDS; index++) begin
            if (index < 30)
                mutated[index] = 32'h5100_0000 + 32'(index);
            else if (index == 30)
                mutated[index] = 32'h0000_0080;
            else if (index == 31)
                mutated[index] = 32'ha000_00d3;
            else
                mutated[index] = 32'h6200_0010 + 32'(index);
            state_write(6'(index), mutated[index]);
        end
        for (int index = 0; index < STATE_WORDS; index++) begin
            state_read(6'(index), observed);
            if (observed != mutated[index])
                $fatal(1,
                       "[mister_savestate] word %0d expected %08x got %08x",
                       index, mutated[index], observed);
        end
        for (int index = 0; index < STATE_WORDS; index++)
            state_write(6'(index), snapshot[index]);

        resume();
        capture_trace(trace_first);
        first_end_memory = memory[64];

        request_quiescence();
        memory[64] = saved_memory;
        for (int index = 0; index < STATE_WORDS; index++)
            state_write(6'(index), snapshot[index]);
        resume();
        capture_trace(trace_second);

        for (int index = 0; index < TRACE_LENGTH; index++) begin
            if (trace_second[index] != trace_first[index])
                $fatal(1,
                       "[mister_savestate] trace diverged at request %0d: expected %019x got %019x",
                       index, trace_first[index], trace_second[index]);
        end
        if (memory[64] != first_end_memory)
            $fatal(1, "[mister_savestate] restored RAM result diverged");

        // Import the exact architectural boundary between Thumb BL
        // halfwords and prove the suffix consumes/restores architectural LR.
        request_quiescence();
        for (int index = 0; index < STATE_WORDS; index++)
            state_write(6'(index), snapshot[index]);
        state_write(STATE_R14_SVC, 32'h0000_0084);
        state_write(30, THUMB_SUFFIX_PC);
        state_write(31, 32'h0000_00f3);
        resume();

        saw_thumb_target = 1'b0;
        repeat (80) begin
            @(posedge CLK);
            #1;
            if (MEM_VALID && MEM_READY && MEM_CODE
                && MEM_ADDR == 32'h0000_00c0)
                saw_thumb_target = 1'b1;
            if (saw_thumb_target)
                break;
        end
        if (!saw_thumb_target)
            $fatal(1, "[mister_savestate] Thumb BL suffix did not branch");

        request_quiescence();
        state_read(STATE_R14_SVC, observed);
        if (observed != 32'h0000_0085)
            $fatal(1, "[mister_savestate] Thumb BL restored LR was %08x",
                   observed);

        $display("[mister_savestate] PASS");
        $finish;
    end

    initial begin
        #1_000_000;
        $fatal(1, "[mister_savestate] TIMEOUT");
    end

    wire _unused_optional_outputs = &{
        1'b0, CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI,
        DBG_STEP_READY, DBG_STEP_RSP_VALID, DBG_STEP_TDO,
        DBG_STEP_TDO_OE, DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG,
        DBGCOMMTX, DBGCOMMRX
    };

endmodule
