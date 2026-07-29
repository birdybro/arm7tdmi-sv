// Test-only serializers for the physical ARM7TDMI-S scan-chain cell order.
//
// The IR, IDCODE, and SCAN_N registers shift LSB-first. INTEST chains 1 and
// 2 do not map to a packed logical vector in that order: their TRM-defined
// cells run from TDI toward TDO. These helpers keep integration tests honest
// about the external wire protocol while presenting logical fields to checks.

package arm7tdmis_jtag_tb_pkg;

    function automatic logic [37:0] chain1_serial_in(
        input logic [31:0] data,
        input logic        dbgbreak
    );
        logic [37:0] serial_bits;
        serial_bits = '0;
        serial_bits[0] = dbgbreak;
        for (int i = 0; i < 32; i++)
            serial_bits[i + 1] = data[31 - i];
        return serial_bits;
    endfunction

    function automatic logic [31:0] chain1_parallel_data(
        input logic [37:0] serial_bits
    );
        logic [31:0] data;
        for (int i = 0; i < 32; i++)
            data[31 - i] = serial_bits[i + 1];
        return data;
    endfunction

    function automatic logic [37:0] chain2_serial_in(
        input logic        write,
        input logic [4:0]  address,
        input logic [31:0] data
    );
        logic [37:0] serial_bits;
        serial_bits = '0;
        for (int i = 0; i < 32; i++)
            serial_bits[i] = data[31 - i];
        for (int i = 0; i < 5; i++)
            serial_bits[32 + i] = address[i];
        serial_bits[37] = write;
        return serial_bits;
    endfunction

    function automatic logic [37:0] chain2_parallel_out(
        input logic [37:0] serial_bits
    );
        logic        write;
        logic [4:0]  address;
        logic [31:0] data;
        write = serial_bits[37];
        for (int i = 0; i < 5; i++)
            address[i] = serial_bits[32 + i];
        for (int i = 0; i < 32; i++)
            data[31 - i] = serial_bits[i];
        return {write, address, data};
    endfunction

endpackage
