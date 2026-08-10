`timescale 1ns/1ps

// Pure shift register: data enters the top and walks one stage per enabled
// cycle. There is no addressing, so there is no read mux and no write decoder
// - the cost is entirely flops and their clock network.
//
// OUTPUT_TAP selects which stage drives the output, so latency and storage
// depth are independent: DEPTH=8, OUTPUT_TAP=4 keeps eight entries live while
// presenting the value four cycles after it entered.
module shift_reg #(
    parameter int unsigned DEPTH      = 8,
    parameter int unsigned WIDTH      = 128,
    parameter int unsigned OUTPUT_TAP = 4
) (
    input  logic             clk,
    input  logic             reset,
    input  logic             enable,
    input  logic [WIDTH-1:0] data_in,
    output logic [WIDTH-1:0] data_out
);
    logic [WIDTH-1:0] stages [0:DEPTH-1];

    always_ff @(posedge clk) begin
        if (reset) begin
            for (int unsigned s = 0; s < DEPTH; s++)
                stages[s] <= '0;
        end else if (enable) begin
            stages[0] <= data_in;
            for (int unsigned s = 1; s < DEPTH; s++)
                stages[s] <= stages[s-1];
        end
    end

    assign data_out = stages[OUTPUT_TAP-1];
endmodule
