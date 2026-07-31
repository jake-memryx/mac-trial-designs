`timescale 1ns/1ps

// Eight-bit unsigned up-counter.
// Reset is synchronous and has priority over the enable input.
module counter8 (
    input  wire       clk,
    input  wire       reset,
    input  wire       enable,
    output reg  [7:0] count
);

    always @(posedge clk) begin
        if (reset)
            count <= 8'h00;
        else if (enable)
            count <= count + 8'h01;
    end

endmodule

