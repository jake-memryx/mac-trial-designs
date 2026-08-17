`timescale 1ns/1ps

// Bounded FIFO used on every stage command and data channel.
//
// DEPTH must be a power of two and at least two. The read side is a
// combinational mux on the storage array, so a producer and a consumer can move
// the same entry in and out on consecutive cycles. flush empties the queue
// without touching the data, which is what the core's abort path needs.
module mcore_fifo #(
    parameter type         T         = logic [7:0],
    parameter int unsigned DEPTH     = 2,
    parameter int unsigned PTR_WIDTH = $clog2(DEPTH)
) (
    input  logic clk,
    input  logic reset,
    input  logic flush,
    input  logic in_valid,
    output logic in_ready,
    input  T     in_data,
    output logic out_valid,
    input  logic out_ready,
    output T     out_data,
    output logic empty,
    output logic full
);
    T                 storage [0:DEPTH-1];
    logic [PTR_WIDTH:0] write_pointer;
    logic [PTR_WIDTH:0] read_pointer;

    assign empty = (write_pointer == read_pointer);
    assign full  = (write_pointer[PTR_WIDTH] != read_pointer[PTR_WIDTH]) &&
                   (write_pointer[PTR_WIDTH-1:0] == read_pointer[PTR_WIDTH-1:0]);

    assign in_ready  = !full;
    assign out_valid = !empty;
    assign out_data  = storage[read_pointer[PTR_WIDTH-1:0]];

    always_ff @(posedge clk) begin
        if (reset || flush) begin
            write_pointer <= '0;
            read_pointer  <= '0;
        end else begin
            if (in_valid && in_ready)
                write_pointer <= write_pointer + 1'b1;
            if (out_valid && out_ready)
                read_pointer <= read_pointer + 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (in_valid && in_ready)
            storage[write_pointer[PTR_WIDTH-1:0]] <= in_data;
    end

    // Elaboration-time check rather than an initial block, so it holds when the
    // design is built as well as when it is simulated.
    if (DEPTH < 2 || (DEPTH & (DEPTH - 1)) != 0)
        $error("mcore_fifo: DEPTH must be a power of two >= 2");
endmodule
