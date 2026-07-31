`timescale 1ns/1ps

// Eight-bit unsigned up-counter.
// Reset is synchronous and has priority over the enable input.
module counter8 (
    input  logic       clk,
    input  logic       reset,
    input  logic       enable,
    output logic [7:0] count
);

    always_ff @(posedge clk) begin
        if (reset)
            count <= 8'h00;
        else if (enable)
            count <= count + 8'h01;
    end

endmodule
