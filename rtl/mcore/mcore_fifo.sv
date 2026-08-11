`timescale 1ns/1ps

// Generic synchronous FIFO used for the per-stage command queues and the
// inter-stage data channels. Ready/valid on both sides, lossless.
// DEPTH must be a power of two and at least 2.
module mcore_fifo #(
    parameter type T = logic [7:0],
    parameter int unsigned DEPTH = 2,
    parameter int unsigned PTR_WIDTH = $clog2(DEPTH)
) (
    input  logic clk,
    input  logic reset,
    // Synchronous flush, used by reset/abort and program restart.
    input  logic flush,

    input  logic in_valid,
    output logic in_ready,
    input  T     in_data,

    output logic out_valid,
    input  logic out_ready,
    output T     out_data,

    output logic empty
);
    T                 storage [DEPTH];
    logic [PTR_WIDTH:0] write_pointer;
    logic [PTR_WIDTH:0] read_pointer;

    logic full;
    logic write_enable;
    logic read_enable;

    assign full      = (write_pointer[PTR_WIDTH] != read_pointer[PTR_WIDTH]) &&
                       (write_pointer[PTR_WIDTH-1:0] == read_pointer[PTR_WIDTH-1:0]);
    assign empty     = (write_pointer == read_pointer);
    assign in_ready  = !full;
    assign out_valid = !empty;
    assign out_data  = storage[read_pointer[PTR_WIDTH-1:0]];

    assign write_enable = in_valid && in_ready;
    assign read_enable  = out_valid && out_ready;

    always_ff @(posedge clk) begin
        if (reset || flush) begin
            write_pointer <= '0;
            read_pointer  <= '0;
        end else begin
            if (write_enable) begin
                storage[write_pointer[PTR_WIDTH-1:0]] <= in_data;
                write_pointer <= write_pointer + 1'b1;
            end
            if (read_enable) begin
                read_pointer <= read_pointer + 1'b1;
            end
        end
    end
endmodule
