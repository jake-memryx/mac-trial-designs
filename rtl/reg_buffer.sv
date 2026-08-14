`timescale 1ns/1ps

// Flat registered buffer: WIDTH flip-flops with an optional write enable and
// no datapath logic. Used to price the storage part of the MCore operand and
// result buffers (a 128-bit line, a 512-bit LoMem row) separately from the
// muxing and control around them.
module reg_buffer #(
    parameter int unsigned WIDTH = 512,
    // 0 - unconditional load every cycle,
    // 1 - enable-gated load, which synthesis implements as a clock gate.
    parameter bit HAS_ENABLE = 1
) (
    input  logic             clk,
    input  logic             reset,
    input  logic             enable,
    input  logic [WIDTH-1:0] d,
    output logic [WIDTH-1:0] q
);
    always_ff @(posedge clk) begin
        if (reset) begin
            q <= '0;
        end else if (!HAS_ENABLE || enable) begin
            q <= d;
        end
    end
endmodule
