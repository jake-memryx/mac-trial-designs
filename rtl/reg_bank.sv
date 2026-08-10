`timescale 1ns/1ps

// Randomly addressed register bank: one write port, one combinational read
// port. Every entry shares the write data bus and is selected by its own
// enable, which synthesis turns into a per-entry clock gate. The read side is
// an ENTRIES-to-1 mux, which is what dominates the timing.
//
// ENTRIES need not be a power of two; out-of-range addresses are ignored on
// write and read as zero.
module reg_bank #(
    parameter int unsigned ENTRIES = 8,
    parameter int unsigned WIDTH   = 128,
    parameter int unsigned ADDR_W  = (ENTRIES <= 1) ? 1 : $clog2(ENTRIES)
) (
    input  logic              clk,
    input  logic              reset,
    input  logic              write_enable,
    input  logic [ADDR_W-1:0] write_address,
    input  logic [WIDTH-1:0]  write_data,
    input  logic [ADDR_W-1:0] read_address,
    output logic [WIDTH-1:0]  read_data
);
    logic [WIDTH-1:0] entries [0:ENTRIES-1];

    always_ff @(posedge clk) begin
        if (reset) begin
            for (int unsigned e = 0; e < ENTRIES; e++)
                entries[e] <= '0;
        end else if (write_enable && write_address < ENTRIES) begin
            entries[write_address] <= write_data;
        end
    end

    always_comb begin
        read_data = '0;
        if (read_address < ENTRIES)
            read_data = entries[read_address];
    end
endmodule
