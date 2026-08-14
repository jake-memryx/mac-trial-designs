`timescale 1ns/1ps

// One Matrix Core TreeMAC lane: MULTIPLIERS BF16 multiplies reduced under a
// shared exponent and accumulated into one of ACCUMULATORS FP32 registers.
//
// The datapath is the one bf16_multi_mac_tree uses, assembled from the same
// submodules:
//
//   bf16_multiplier x MULTIPLIERS -> exact FP32 products
//   bf16_mac_tree_align           -> shared exponent, signed integer leaves
//   bf16_mac_tree_normalize       -> one normalize and round to FP32
//   fp32_adder                    -> accumulate into the selected register
//
// It differs from bf16_multi_mac_tree only in the accumulator bank, which the
// Matrix Core needs three extra views of (matrix_core.md section 10):
//
//   * write_enable  loads an arbitrary FP32 value  (load_accumulators),
//   * clear         zeroes the whole bank          (acc_reset),
//   * read_index    reads any register combinationally for the Compute->WB
//                   snapshot, while accumulation continues.
//
// The accumulate loop is flat: bank read, add and write-back in one cycle. That
// keeps it correct for any accumulator order, which multi_mac and the
// elementwise operations need because they revisit accumulator 0 on
// consecutive cycles.
//
// Subnormal operands and underflowed results are flushed to zero, and products
// more than REDUCTION_GUARD_BITS below the largest product of the same cycle
// are truncated, both inherited from the reused arithmetic.
module mcore_treemac #(
    parameter int unsigned MULTIPLIERS = 8,
    parameter int unsigned ACCUMULATORS = 16,
    parameter int unsigned REDUCTION_GUARD_BITS = 4,
    parameter int unsigned SELECT_WIDTH =
        (ACCUMULATORS <= 1) ? 1 : $clog2(ACCUMULATORS),
    parameter int unsigned TREE_LEVELS =
        (MULTIPLIERS <= 1) ? 0 : $clog2(MULTIPLIERS),
    parameter int unsigned TREE_LEAVES = 1 << TREE_LEVELS,
    parameter int unsigned MAGNITUDE_WIDTH = 16 + REDUCTION_GUARD_BITS,
    parameter int unsigned SUM_WIDTH = MAGNITUDE_WIDTH + TREE_LEVELS + 1
) (
    input  logic                    clk,
    input  logic                    reset,
    // Zeroes every accumulator. Takes priority over the other write sources.
    input  logic                    clear,
    // Commits acc[accumulator_select] += reduce(a * b) on this rising edge.
    input  logic                    enable,
    input  logic [SELECT_WIDTH-1:0] accumulator_select,
    input  logic [15:0]             a [0:MULTIPLIERS-1],
    input  logic [15:0]             b [0:MULTIPLIERS-1],
    // Direct FP32 load, used for accumulator preload. Overrides enable.
    input  logic                    write_enable,
    input  logic [SELECT_WIDTH-1:0] write_index,
    input  logic [31:0]             write_data,
    // Combinational snapshot port.
    input  logic [SELECT_WIDTH-1:0] read_index,
    output logic [31:0]             read_data
);
    logic [31:0] product [0:TREE_LEAVES-1];
    logic [7:0]  maximum_exponent;
    logic signed [SUM_WIDTH-1:0] leaf_value [0:TREE_LEAVES-1];
    logic        positive_infinity, negative_infinity, invalid_result;
    logic [31:0] reduced_result;
    logic [31:0] accumulator_bank [0:ACCUMULATORS-1];
    logic [31:0] selected_accumulator;
    logic [31:0] next_accumulator;

    // Exact FP32 products. Leaves beyond MULTIPLIERS exist only when the lane
    // count is not a power of two and contribute zero.
    genvar leaf;
    generate
        for (leaf = 0; leaf < TREE_LEAVES; leaf = leaf + 1) begin : g_product
            if (leaf < MULTIPLIERS) begin : g_active
                bf16_multiplier multiplier (
                    .a       (a[leaf]),
                    .b       (b[leaf]),
                    .product (product[leaf])
                );
            end else begin : g_padding
                assign product[leaf] = 32'b0;
            end
        end
    endgenerate

    bf16_mac_tree_align #(
        .MULTIPLIERS          (MULTIPLIERS),
        .REDUCTION_GUARD_BITS (REDUCTION_GUARD_BITS),
        .SIGNIFICAND_BITS     (16)
    ) align_stage (
        .product           (product),
        .maximum_exponent  (maximum_exponent),
        .leaf_value        (leaf_value),
        .positive_infinity (positive_infinity),
        .negative_infinity (negative_infinity),
        .invalid_result    (invalid_result)
    );

    bf16_mac_tree_normalize #(
        .MULTIPLIERS          (MULTIPLIERS),
        .REDUCTION_GUARD_BITS (REDUCTION_GUARD_BITS),
        .SIGNIFICAND_BITS     (16)
    ) normalize_stage (
        .maximum_exponent  (maximum_exponent),
        .leaf_value        (leaf_value),
        .positive_infinity (positive_infinity),
        .negative_infinity (negative_infinity),
        .invalid_result    (invalid_result),
        .result            (reduced_result)
    );

    assign selected_accumulator = accumulator_bank[accumulator_select];

    fp32_adder accumulate_adder (
        .a   (selected_accumulator),
        .b   (reduced_result),
        .sum (next_accumulator)
    );

    always_ff @(posedge clk) begin
        if (reset || clear) begin
            for (int unsigned e = 0; e < ACCUMULATORS; e++)
                accumulator_bank[e] <= 32'b0;
        end else if (write_enable) begin
            accumulator_bank[write_index] <= write_data;
        end else if (enable) begin
            accumulator_bank[accumulator_select] <= next_accumulator;
        end
    end

    assign read_data = accumulator_bank[read_index];
endmodule
