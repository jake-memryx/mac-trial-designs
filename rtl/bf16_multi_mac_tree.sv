`timescale 1ns/1ps

// Parallel BF16 multi-MAC with a balanced FP32 reduction tree and a selectable
// FP32 accumulator bank. On each enabled rising edge:
//
//   accumulator[accumulator_select] += sum(a[i] * b[i]), i=0..MULTIPLIERS-1
//
// Tree leaves are padded with zero when MULTIPLIERS is not a power of two.
// Floating-point behavior, including flush-to-zero handling, comes from the
// bf16_multiplier and fp32_adder modules in bf16_mac.sv.
module bf16_multi_mac_tree #(
    parameter int unsigned MULTIPLIERS = 4,
    parameter int unsigned ACCUMULATORS = 4,
    parameter int unsigned SELECT_WIDTH =
        (ACCUMULATORS <= 1) ? 1 : $clog2(ACCUMULATORS),
    parameter int unsigned TREE_LEVELS =
        (MULTIPLIERS <= 1) ? 0 : $clog2(MULTIPLIERS),
    parameter int unsigned TREE_LEAVES = 1 << TREE_LEVELS
) (
    input  logic                    clk,
    input  logic                    reset,
    input  logic                    clear,
    input  logic                    enable,
    input  logic [SELECT_WIDTH-1:0] accumulator_select,
    input  logic [15:0]             a [0:MULTIPLIERS-1],
    input  logic [15:0]             b [0:MULTIPLIERS-1],
    output logic [31:0]             accumulator
);
    logic [31:0] tree [0:TREE_LEVELS][0:TREE_LEAVES-1];
    logic [31:0] accumulator_bank [0:ACCUMULATORS-1];
    logic [31:0] selected_accumulator;
    logic [31:0] next_accumulator;
    integer      accumulator_index;

    genvar leaf;
    generate
        for (leaf = 0; leaf < TREE_LEAVES; leaf = leaf + 1) begin : g_leaf
            if (leaf < MULTIPLIERS) begin : g_product
                bf16_multiplier multiplier (
                    .a       (a[leaf]),
                    .b       (b[leaf]),
                    .product (tree[0][leaf])
                );
            end else begin : g_padding
                assign tree[0][leaf] = 32'b0;
            end
        end
    endgenerate

    genvar level;
    genvar node;
    generate
        for (level = 0; level < TREE_LEVELS; level = level + 1) begin : g_level
            for (node = 0; node < TREE_LEAVES; node = node + 1) begin : g_node
                if (node < (TREE_LEAVES >> (level + 1))) begin : g_adder
                    fp32_adder tree_adder (
                        .a   (tree[level][2*node]),
                        .b   (tree[level][2*node+1]),
                        .sum (tree[level+1][node])
                    );
                end else begin : g_unused
                    assign tree[level+1][node] = 32'b0;
                end
            end
        end
    endgenerate

    always_comb begin
        selected_accumulator = 32'b0;
        if (accumulator_select < ACCUMULATORS)
            selected_accumulator = accumulator_bank[accumulator_select];
        accumulator = selected_accumulator;
    end

    fp32_adder accumulator_adder (
        .a   (selected_accumulator),
        .b   (tree[TREE_LEVELS][0]),
        .sum (next_accumulator)
    );

    always_ff @(posedge clk) begin
        if (reset || clear) begin
            for (accumulator_index = 0;
                 accumulator_index < ACCUMULATORS;
                 accumulator_index = accumulator_index + 1)
                accumulator_bank[accumulator_index] <= 32'b0;
        end else if (enable && accumulator_select < ACCUMULATORS) begin
            accumulator_bank[accumulator_select] <= next_accumulator;
        end
    end
endmodule

