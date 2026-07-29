// VAL-003 adapter for the pinned MIT-licensed jsmolka/gba-suite CPU ROMs.
//
// The runner preserves every payload byte except the manifest-recorded
// branches over ARM3-only or ARMv4T UNPREDICTABLE policy cases. This bench
// supplies only the reset handoff, little-endian GBA memory regions used by
// the CPU exercisers, a deterministic DISPSTAT vblank source, and a
// public-retirement scoreboard. It does not emulate a GBA system or inspect
// CPU hierarchy.

`timescale 1ns/1ps

`ifndef ARM7TDMIS_VERIFICATION
    `error "public_suite requires ARM7TDMIS_VERIFICATION"
`endif

module arm7tdmis_public_suite_tb
    import arm7tdmis_bus_pkg::*;
;

    localparam int ROM_WORDS_MAX = 4096;
    localparam int EWRAM_WORDS = 65536;
    localparam int IWRAM_WORDS = 8192;
    localparam int IO_WORDS = 256;
    localparam int PALETTE_WORDS = 256;
    localparam int VRAM_WORDS = 32768;
    localparam int VISIBLE_VRAM_WORDS = 9600;
    localparam logic [31:0] REG_DISPSTAT = 32'h0400_0004;

    logic CLK;
    initial CLK = 1'b0;
    always #5 CLK = ~CLK;

    logic nRESET;
    logic [31:0] ADDR;
    logic        WRITE;
    logic [1:0]  SIZE;
    logic [1:0]  PROT;
    logic        LOCK;
    logic [1:0]  TRANS;
    logic [31:0] WDATA;
    logic [31:0] RDATA;
    logic        ABORT;
    logic CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI;
    logic DBGACK, DBGnEXEC, DBGINSTRVALID;
    logic [1:0] DBGRNG;
    logic DBGCOMMTX, DBGCOMMRX, DBGTDO, DBGnTDOEN, DMORE;

    logic         VER_RETIRE_VALID;
    logic [31:0]  VER_RETIRE_PC;
    logic [31:0]  VER_RETIRE_OPCODE;
    logic         VER_RETIRE_THUMB;
    logic         VER_RETIRE_CONDITION_PASS;
    logic         VER_RETIRE_INJECTED;
    logic         VER_RETIRE_EXCEPTION_VALID;
    logic [2:0]   VER_RETIRE_EXCEPTION;
    logic [991:0] VER_RETIRE_GPRS;
    logic [31:0]  VER_RETIRE_CPSR;
    logic [159:0] VER_RETIRE_SPSRS;

    arm7tdmis_top u_dut (
        .CLK, .CLKEN(1'b1), .nRESET, .CFGBIGEND(1'b0),
        .nIRQ(1'b1), .nFIQ(1'b1), .ABORT,
        .ADDR, .WRITE, .SIZE, .PROT, .LOCK, .TRANS, .WDATA, .RDATA,
        .CPnMREQ, .CPSEQ, .CPnTRANS, .CPnOPC, .CPTBIT, .CPnI,
        .CPA(1'b1), .CPB(1'b1),
        .DBGEN(1'b0), .DBGRQ(1'b0), .DBGBREAK(1'b0),
        .DBGACK, .DBGnEXEC, .DBGINSTRVALID, .DBGEXT(2'b00),
        .DBGRNG, .DBGCOMMTX, .DBGCOMMRX,
        .DBGTCKEN(1'b0), .DBGTMS(1'b0), .DBGTDI(1'b0),
        .DBGTDO, .DBGnTRST(1'b1), .DBGnTDOEN, .DMORE,
        .VER_RETIRE_VALID, .VER_RETIRE_PC, .VER_RETIRE_OPCODE,
        .VER_RETIRE_THUMB, .VER_RETIRE_CONDITION_PASS,
        .VER_RETIRE_INJECTED, .VER_RETIRE_EXCEPTION_VALID,
        .VER_RETIRE_EXCEPTION, .VER_RETIRE_GPRS, .VER_RETIRE_CPSR,
        .VER_RETIRE_SPSRS
    );

    logic [31:0] boot_words [0:3];
    logic [31:0] rom [0:ROM_WORDS_MAX-1];
    logic [31:0] ewram [0:EWRAM_WORDS-1];
    logic [31:0] iwram [0:IWRAM_WORDS-1];
    logic [31:0] io [0:IO_WORDS-1];
    logic [31:0] palette [0:PALETTE_WORDS-1];
    logic [31:0] vram [0:VRAM_WORDS-1];

    logic [31:0] addr_q;
    logic        write_q;
    logic [1:0]  size_q;
    logic [1:0]  trans_q;
    logic        vblank;
    logic [5:0]  vblank_counter;

    wire active_q = trans_q inside {2'(TRANS_N), 2'(TRANS_S)};
    assign ABORT = 1'b0;

    function automatic logic [31:0] region_word(
        input logic [31:0] address
    );
        if (address < 32'h0000_0010)
            return boot_words[address[3:2]];
        unique case (address[27:24])
            4'h2: return ewram[address[17:2]];
            4'h3: return iwram[address[14:2]];
            4'h4: begin
                if ({address[31:2], 2'b00} == REG_DISPSTAT)
                    return {io[address[9:2]][31:1], vblank};
                return io[address[9:2]];
            end
            4'h5: return palette[address[9:2]];
            4'h6: return vram[address[16:2]];
            4'h8, 4'ha, 4'hc: return rom[address[13:2]];
            default: return 32'h0000_0000;
        endcase
    endfunction

    function automatic logic [31:0] lane_read(
        input logic [31:0] address,
        input logic [1:0] access_size
    );
        logic [31:0] word;
        word = region_word(address);
        unique case (access_size)
            2'(SIZE_WORD): return word;
            2'(SIZE_HALFWORD):
                return address[1] ? {word[31:16], 16'h0000}
                                  : {16'h0000, word[15:0]};
            2'(SIZE_BYTE):
                unique case (address[1:0])
                    2'd0: return {24'h0, word[7:0]};
                    2'd1: return {16'h0, word[15:8], 8'h0};
                    2'd2: return {8'h0, word[23:16], 16'h0};
                    2'd3: return {word[31:24], 24'h0};
                endcase
            default: return 32'h0000_0000;
        endcase
    endfunction

    always_comb begin
        RDATA = 32'h0000_0000;
        if (active_q && !write_q)
            RDATA = lane_read(addr_q, size_q);
    end

    task automatic merge_write(
        ref logic [31:0] target,
        input logic [1:0] address_low,
        input logic [1:0] access_size,
        input logic [31:0] write_data
    );
        unique case (access_size)
            2'(SIZE_WORD): target = write_data;
            2'(SIZE_HALFWORD): begin
                if (address_low[1])
                    target[31:16] = write_data[31:16];
                else
                    target[15:0] = write_data[15:0];
            end
            2'(SIZE_BYTE):
                unique case (address_low)
                    2'd0: target[7:0] = write_data[7:0];
                    2'd1: target[15:8] = write_data[15:8];
                    2'd2: target[23:16] = write_data[23:16];
                    2'd3: target[31:24] = write_data[31:24];
                endcase
            default: ;
        endcase
    endtask

    int unsigned vram_writes;
    always_ff @(posedge CLK) begin
        if (!nRESET) begin
            addr_q <= 32'h0;
            write_q <= 1'b0;
            size_q <= 2'(SIZE_WORD);
            trans_q <= 2'(TRANS_I);
            vblank <= 1'b0;
            vblank_counter <= 6'd0;
            vram_writes <= 0;
        end else begin
            addr_q <= ADDR;
            write_q <= WRITE;
            size_q <= SIZE;
            trans_q <= TRANS;
            vblank_counter <= vblank_counter + 6'd1;
            if (vblank_counter == 6'd63)
                vblank <= ~vblank;
            if (active_q && write_q) begin
                unique case (addr_q[27:24])
                    4'h2: merge_write(
                        ewram[addr_q[17:2]], addr_q[1:0], size_q, WDATA);
                    4'h3: merge_write(
                        iwram[addr_q[14:2]], addr_q[1:0], size_q, WDATA);
                    4'h4: merge_write(
                        io[addr_q[9:2]], addr_q[1:0], size_q, WDATA);
                    4'h5: merge_write(
                        palette[addr_q[9:2]], addr_q[1:0], size_q, WDATA);
                    4'h6: begin
                        merge_write(
                            vram[addr_q[16:2]], addr_q[1:0], size_q, WDATA);
                        vram_writes <= vram_writes + 1;
                    end
                    default: ;
                endcase
            end
        end
    end

    int unsigned rom_words;
    int unsigned idle_pc_arg;
    int unsigned result_register;
    int unsigned expected_vram_signature;
    int unsigned minimum_retirements;
    int unsigned retirements;
    int unsigned arm_retirements;
    int unsigned thumb_retirements;
    string rom_hex;

    function automatic logic [31:0] physical_gpr(
        input int register_number
    );
        return VER_RETIRE_GPRS[(register_number * 32) +: 32];
    endfunction

    function automatic logic [31:0] vram_signature;
        logic [31:0] signature;
        signature = 32'h811c_9dc5;
        for (int word = 0; word < VISIBLE_VRAM_WORDS; word++)
            signature = (signature ^ vram[word]) * 32'h0100_0193;
        return signature;
    endfunction

    task automatic fail(input string reason);
        $fatal(1, "[public_suite] FAIL pc=%08x retirements=%0d: %s",
               VER_RETIRE_PC, retirements, reason);
    endtask

    always @(posedge CLK) begin
        logic [31:0] signature;
        #1;
        if (VER_RETIRE_EXCEPTION_VALID)
            fail($sformatf(
                "unexpected exception %0d, upstream result r%0d=%08x",
                VER_RETIRE_EXCEPTION, result_register,
                physical_gpr(result_register)
            ));
        if (VER_RETIRE_VALID) begin
            retirements <= retirements + 1;
            if (VER_RETIRE_THUMB)
                thumb_retirements <= thumb_retirements + 1;
            else
                arm_retirements <= arm_retirements + 1;
            if (VER_RETIRE_INJECTED)
                fail("suite instruction was reported as debug-injected");
            if (VER_RETIRE_PC == idle_pc_arg) begin
                if (physical_gpr(result_register) != 32'h0000_0000)
                    fail($sformatf(
                        "upstream test result r%0d=%08x",
                        result_register, physical_gpr(result_register)
                    ));
                if (retirements < minimum_retirements)
                    fail("idle milestone arrived before the suite ran");
                if (vram_writes < 32)
                    fail("upstream pass text did not reach VRAM");
                signature = vram_signature();
                if (expected_vram_signature != 0
                    && signature != expected_vram_signature)
                    fail($sformatf(
                        "VRAM signature expected %08x got %08x",
                        expected_vram_signature, signature
                    ));
                $display(
                    "[public_suite] PASS retirements=%0d arm=%0d thumb=%0d vram_signature=%08x idle_pc=%08x",
                    retirements, arm_retirements, thumb_retirements,
                    signature, idle_pc_arg
                );
                $finish;
            end
        end
    end

    initial begin
        nRESET = 1'b0;
        retirements = 0;
        arm_retirements = 0;
        thumb_retirements = 0;
        if (!$value$plusargs("ROM_HEX=%s", rom_hex))
            $fatal(1, "[public_suite] missing +ROM_HEX");
        if (!$value$plusargs("ROM_WORDS=%d", rom_words))
            $fatal(1, "[public_suite] missing +ROM_WORDS");
        if (!$value$plusargs("IDLE_PC=%h", idle_pc_arg))
            $fatal(1, "[public_suite] missing +IDLE_PC");
        if (!$value$plusargs("RESULT_REGISTER=%d", result_register))
            $fatal(1, "[public_suite] missing +RESULT_REGISTER");
        if (!$value$plusargs(
                "EXPECTED_VRAM_SIGNATURE=%h", expected_vram_signature))
            $fatal(1, "[public_suite] missing +EXPECTED_VRAM_SIGNATURE");
        if (!$value$plusargs(
                "MINIMUM_RETIREMENTS=%d", minimum_retirements))
            $fatal(1, "[public_suite] missing +MINIMUM_RETIREMENTS");
        if (rom_words == 0 || rom_words > ROM_WORDS_MAX)
            $fatal(1, "[public_suite] invalid ROM_WORDS=%0d", rom_words);
        if (result_register > 12)
            $fatal(1, "[public_suite] invalid RESULT_REGISTER=%0d",
                   result_register);

        boot_words[0] = 32'he59f_d000; // ldr sp, [pc, #0]
        boot_words[1] = 32'he59f_f000; // ldr pc, [pc, #0]
        boot_words[2] = 32'h0300_7f00;
        boot_words[3] = 32'h0800_0000;
        for (int word = 0; word < ROM_WORDS_MAX; word++)
            rom[word] = 32'h0000_0000;
        for (int word = 0; word < EWRAM_WORDS; word++)
            ewram[word] = 32'h0000_0000;
        for (int word = 0; word < IWRAM_WORDS; word++)
            iwram[word] = 32'h0000_0000;
        for (int word = 0; word < IO_WORDS; word++)
            io[word] = 32'h0000_0000;
        for (int word = 0; word < PALETTE_WORDS; word++)
            palette[word] = 32'h0000_0000;
        for (int word = 0; word < VRAM_WORDS; word++)
            vram[word] = 32'h0000_0000;
        $readmemh(rom_hex, rom);
        repeat (4) @(posedge CLK);
        @(negedge CLK);
        nRESET = 1'b1;
    end

    initial begin
        repeat (2_000_000) @(posedge CLK);
        $fatal(1, "[public_suite] TIMEOUT after %0d retirements",
               retirements);
    end

    wire _unused_status = &{1'b0,
        CPnMREQ, CPSEQ, CPnTRANS, CPnOPC, CPTBIT, CPnI,
        DBGACK, DBGnEXEC, DBGINSTRVALID, DBGRNG,
        DBGCOMMTX, DBGCOMMRX, DBGTDO, DBGnTDOEN, DMORE,
        VER_RETIRE_OPCODE, VER_RETIRE_CONDITION_PASS,
        VER_RETIRE_CPSR, VER_RETIRE_SPSRS,
        PROT, LOCK, rom_words};

endmodule
