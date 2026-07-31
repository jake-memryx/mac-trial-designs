`timescale 1ns/1ps

// Parallel BF16 multi-MAC with a block-floating-point reduction tree.
//
// Instead of using a complete FP32 adder at every reduction node, the tree:
//   1. computes exact 16-bit BF16 product significands,
//   2. finds the largest product exponent,
//   3. aligns each product into a shared fixed-point format,
//   4. reduces the signed values with narrow integer adders, and
//   5. normalizes and rounds once to FP32.
//
// The reduced FP32 result is then added to one selected FP32 accumulator using
// a full FP32 adder. Products below the guard-bit window are truncated. As with
// the other MAC modules, subnormal operands and results are flushed to zero.
module bf16_multi_mac_tree #(
    parameter int unsigned MULTIPLIERS = 4,
    parameter int unsigned ACCUMULATORS = 4,
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
    input  logic                    clear,
    input  logic                    enable,
    input  logic [SELECT_WIDTH-1:0] accumulator_select,
    input  logic [15:0]             a [0:MULTIPLIERS-1],
    input  logic [15:0]             b [0:MULTIPLIERS-1],
    output logic [31:0]             accumulator
);
    logic [31:0] product [0:TREE_LEAVES-1];
    logic [7:0]  exponent_tree [0:TREE_LEVELS][0:TREE_LEAVES-1];
    logic signed [SUM_WIDTH-1:0]
                 sum_tree [0:TREE_LEVELS][0:TREE_LEAVES-1];
    logic [MAGNITUDE_WIDTH-1:0] aligned_magnitude [0:TREE_LEAVES-1];

    logic [7:0]  maximum_exponent;
    logic signed [SUM_WIDTH-1:0] reduction_sum;
    logic [SUM_WIDTH-1:0] reduction_magnitude;
    logic [26:0] normalized;
    logic [24:0] rounded_significand;
    logic [31:0] reduced_product_sum;
    logic [31:0] accumulator_bank [0:ACCUMULATORS-1];
    logic [31:0] selected_accumulator;
    logic [31:0] next_accumulator;

    logic reduction_sign;
    logic positive_infinity;
    logic negative_infinity;
    logic invalid_result;
    logic discarded_bits;
    integer leading_one;
    integer normalize_shift;
    integer result_exponent;
    integer align_shift;
    integer accumulator_index;
    integer align_term_index;
    integer special_term_index;
    integer bit_index;

    genvar leaf;
    generate
        for (leaf = 0; leaf < TREE_LEAVES; leaf = leaf + 1) begin : g_leaf
            if (leaf < MULTIPLIERS) begin : g_product
                bf16_multiplier multiplier (
                    .a       (a[leaf]),
                    .b       (b[leaf]),
                    .product (product[leaf])
                );
            end else begin : g_padding
                assign product[leaf] = 32'b0;
            end

            // Special values are handled separately, so they contribute zero
            // to the finite exponent and significand trees.
            assign exponent_tree[0][leaf] =
                (product[leaf][30:23] == 8'hff) ? 8'b0 :
                                                  product[leaf][30:23];
        end
    endgenerate

    // Maximum-exponent tree. This establishes the shared fixed-point scale.
    genvar exponent_level;
    genvar exponent_node;
    generate
        for (exponent_level = 0;
             exponent_level < TREE_LEVELS;
             exponent_level = exponent_level + 1) begin : g_exponent_level
            for (exponent_node = 0;
                 exponent_node < TREE_LEAVES;
                 exponent_node = exponent_node + 1) begin : g_exponent_node
                if (exponent_node <
                    (TREE_LEAVES >> (exponent_level + 1))) begin : g_max
                    assign exponent_tree[exponent_level+1][exponent_node] =
                        (exponent_tree[exponent_level][2*exponent_node] >=
                         exponent_tree[exponent_level][2*exponent_node+1]) ?
                         exponent_tree[exponent_level][2*exponent_node] :
                         exponent_tree[exponent_level][2*exponent_node+1];
                end else begin : g_unused
                    assign exponent_tree[exponent_level+1][exponent_node] = 8'b0;
                end
            end
        end
    endgenerate

    assign maximum_exponent = exponent_tree[TREE_LEVELS][0];

    // Convert each finite product to a signed shared-exponent integer. A BF16
    // product has only 16 significant bits even though it is FP32 encoded.
    always_comb begin
        align_shift = 0;
        for (align_term_index = 0; align_term_index < TREE_LEAVES;
             align_term_index = align_term_index + 1) begin
            aligned_magnitude[align_term_index] = '0;
            sum_tree[0][align_term_index]       = '0;

            if (product[align_term_index][30:23] != 0 &&
                product[align_term_index][30:23] != 8'hff) begin
                align_shift = maximum_exponent -
                              product[align_term_index][30:23];
                if (align_shift < MAGNITUDE_WIDTH) begin
                    aligned_magnitude[align_term_index] =
                        {{1'b1, product[align_term_index][22:8]},
                         {REDUCTION_GUARD_BITS{1'b0}}} >> align_shift;
                end

                if (product[align_term_index][31])
                    sum_tree[0][align_term_index] =
                        -$signed({1'b0,
                                  aligned_magnitude[align_term_index]});
                else
                    sum_tree[0][align_term_index] =
                         $signed({1'b0,
                                  aligned_magnitude[align_term_index]});
            end
        end
    end

    // Balanced signed integer reduction tree. SUM_WIDTH includes one sign bit
    // and TREE_LEVELS carry-growth bits, so no intermediate sum overflows.
    genvar sum_level;
    genvar sum_node;
    generate
        for (sum_level = 0; sum_level < TREE_LEVELS;
             sum_level = sum_level + 1) begin : g_sum_level
            for (sum_node = 0; sum_node < TREE_LEAVES;
                 sum_node = sum_node + 1) begin : g_sum_node
                if (sum_node < (TREE_LEAVES >> (sum_level + 1))) begin : g_add
                    assign sum_tree[sum_level+1][sum_node] =
                        sum_tree[sum_level][2*sum_node] +
                        sum_tree[sum_level][2*sum_node+1];
                end else begin : g_unused
                    assign sum_tree[sum_level+1][sum_node] = '0;
                end
            end
        end
    endgenerate

    assign reduction_sum = sum_tree[TREE_LEVELS][0];

    // Normalize the shared-exponent integer and round once to FP32 using
    // round-to-nearest, ties-to-even.
    always_comb begin
        reduction_sign      = reduction_sum[SUM_WIDTH-1];
        reduction_magnitude = reduction_sign ? -reduction_sum : reduction_sum;
        normalized          = 27'b0;
        rounded_significand = 25'b0;
        reduced_product_sum = 32'b0;
        positive_infinity   = 1'b0;
        negative_infinity   = 1'b0;
        invalid_result      = 1'b0;
        discarded_bits      = 1'b0;
        leading_one         = -1;
        normalize_shift     = 0;
        result_exponent     = 0;

        for (special_term_index = 0; special_term_index < TREE_LEAVES;
             special_term_index = special_term_index + 1) begin
            if (product[special_term_index][30:23] == 8'hff) begin
                if (product[special_term_index][22:0] != 0)
                    invalid_result = 1'b1;
                else if (product[special_term_index][31])
                    negative_infinity = 1'b1;
                else
                    positive_infinity = 1'b1;
            end
        end
        if (positive_infinity && negative_infinity)
            invalid_result = 1'b1;

        if (invalid_result) begin
            reduced_product_sum = 32'h7fc00000;
        end else if (positive_infinity) begin
            reduced_product_sum = 32'h7f800000;
        end else if (negative_infinity) begin
            reduced_product_sum = 32'hff800000;
        end else if (reduction_magnitude != 0) begin
            for (bit_index = 0; bit_index < SUM_WIDTH;
                 bit_index = bit_index + 1) begin
                if (reduction_magnitude[bit_index])
                    leading_one = bit_index;
            end

            result_exponent = maximum_exponent + leading_one -
                              (15 + REDUCTION_GUARD_BITS);

            if (leading_one > 26) begin
                normalize_shift = leading_one - 26;
                normalized = reduction_magnitude >> normalize_shift;
                discarded_bits = 1'b0;
                for (bit_index = 0; bit_index < SUM_WIDTH;
                     bit_index = bit_index + 1) begin
                    if (bit_index < normalize_shift)
                        discarded_bits = discarded_bits |
                                         reduction_magnitude[bit_index];
                end
                normalized[0] = normalized[0] | discarded_bits;
            end else begin
                normalized = reduction_magnitude << (26 - leading_one);
            end

            rounded_significand = {1'b0, normalized[26:3]} +
                                  (normalized[2] &&
                                   (normalized[1] || normalized[0] ||
                                    normalized[3]));
            if (rounded_significand[24]) begin
                rounded_significand = rounded_significand >> 1;
                result_exponent = result_exponent + 1;
            end

            if (result_exponent >= 255)
                reduced_product_sum = {reduction_sign, 8'hff, 23'b0};
            else if (result_exponent > 0)
                reduced_product_sum = {reduction_sign,
                                       result_exponent[7:0],
                                       rounded_significand[22:0]};
        end
    end

    always_comb begin
        selected_accumulator = 32'b0;
        if (accumulator_select < ACCUMULATORS)
            selected_accumulator = accumulator_bank[accumulator_select];
        accumulator = selected_accumulator;
    end

    // Only this final feedback operation uses the full FP32 adder.
    fp32_adder accumulator_adder (
        .a   (selected_accumulator),
        .b   (reduced_product_sum),
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
