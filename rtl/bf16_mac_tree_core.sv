`timescale 1ns/1ps

// Combinational halves of the BF16 block-floating-point reduction tree.
//
// The tree is split at the natural pipeline boundary so a wrapper can either
// register the boundary or bypass it:
//
//   bf16_mac_tree_align     : a[], b[]        -> shared exponent, signed leaves
//   bf16_mac_tree_normalize : leaves, exponent -> one rounded FP32 result
//
// Both modules are purely combinational; all sequencing, accumulator banking
// and pipeline control lives in the wrapper.

// Multiply stage, maximum-exponent tree, shared-exponent alignment and
// special-value detection.
module bf16_mac_tree_align #(
    parameter int unsigned MULTIPLIERS = 4,
    parameter int unsigned REDUCTION_GUARD_BITS = 4,
    parameter int unsigned TREE_LEVELS =
        (MULTIPLIERS <= 1) ? 0 : $clog2(MULTIPLIERS),
    parameter int unsigned TREE_LEAVES = 1 << TREE_LEVELS,
    parameter int unsigned MAGNITUDE_WIDTH = 16 + REDUCTION_GUARD_BITS,
    parameter int unsigned SUM_WIDTH = MAGNITUDE_WIDTH + TREE_LEVELS + 1
) (
    input  logic [15:0] a [0:MULTIPLIERS-1],
    input  logic [15:0] b [0:MULTIPLIERS-1],
    output logic [7:0]  maximum_exponent,
    output logic signed [SUM_WIDTH-1:0] leaf_value [0:TREE_LEAVES-1],
    output logic        positive_infinity,
    output logic        negative_infinity,
    output logic        invalid_result
);
    logic [31:0] product [0:TREE_LEAVES-1];
    logic [7:0]  exponent_tree [0:TREE_LEVELS][0:TREE_LEAVES-1];
    logic [MAGNITUDE_WIDTH-1:0] aligned_magnitude [0:TREE_LEAVES-1];

    integer align_shift;
    integer align_term_index;
    integer special_term_index;

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
            leaf_value[align_term_index]        = '0;

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
                    leaf_value[align_term_index] =
                        -$signed({1'b0,
                                  aligned_magnitude[align_term_index]});
                else
                    leaf_value[align_term_index] =
                         $signed({1'b0,
                                  aligned_magnitude[align_term_index]});
            end
        end
    end

    // Special-value detection belongs to the align stage: it only depends on
    // the raw products, so it is pipelined alongside the aligned leaves.
    always_comb begin
        positive_infinity = 1'b0;
        negative_infinity = 1'b0;
        invalid_result    = 1'b0;
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
    end
endmodule

// Signed integer reduction tree followed by a single normalize and round to
// FP32 (round-to-nearest, ties-to-even).
module bf16_mac_tree_normalize #(
    parameter int unsigned MULTIPLIERS = 4,
    parameter int unsigned REDUCTION_GUARD_BITS = 4,
    parameter int unsigned TREE_LEVELS =
        (MULTIPLIERS <= 1) ? 0 : $clog2(MULTIPLIERS),
    parameter int unsigned TREE_LEAVES = 1 << TREE_LEVELS,
    parameter int unsigned MAGNITUDE_WIDTH = 16 + REDUCTION_GUARD_BITS,
    parameter int unsigned SUM_WIDTH = MAGNITUDE_WIDTH + TREE_LEVELS + 1
) (
    input  logic [7:0]  maximum_exponent,
    input  logic signed [SUM_WIDTH-1:0] leaf_value [0:TREE_LEAVES-1],
    input  logic        positive_infinity,
    input  logic        negative_infinity,
    input  logic        invalid_result,
    output logic [31:0] result
);
    logic signed [SUM_WIDTH-1:0]
                 sum_tree [0:TREE_LEVELS][0:TREE_LEAVES-1];
    logic signed [SUM_WIDTH-1:0] reduction_sum;
    logic [SUM_WIDTH-1:0] reduction_magnitude;
    logic [26:0] normalized;
    logic [24:0] rounded_significand;
    logic        reduction_sign;
    logic        discarded_bits;

    integer leading_one;
    integer normalize_shift;
    integer result_exponent;
    integer bit_index;

    genvar tree_leaf;
    generate
        for (tree_leaf = 0; tree_leaf < TREE_LEAVES;
             tree_leaf = tree_leaf + 1) begin : g_tree_input
            assign sum_tree[0][tree_leaf] = leaf_value[tree_leaf];
        end
    endgenerate

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

    always_comb begin
        reduction_sign      = reduction_sum[SUM_WIDTH-1];
        reduction_magnitude = reduction_sign ? -reduction_sum : reduction_sum;
        normalized          = 27'b0;
        rounded_significand = 25'b0;
        result              = 32'b0;
        discarded_bits      = 1'b0;
        leading_one         = -1;
        normalize_shift     = 0;
        result_exponent     = 0;

        if (invalid_result) begin
            result = 32'h7fc00000;
        end else if (positive_infinity) begin
            result = 32'h7f800000;
        end else if (negative_infinity) begin
            result = 32'hff800000;
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
                result = {reduction_sign, 8'hff, 23'b0};
            else if (result_exponent > 0)
                result = {reduction_sign,
                          result_exponent[7:0],
                          rounded_significand[22:0]};
        end
    end
endmodule
