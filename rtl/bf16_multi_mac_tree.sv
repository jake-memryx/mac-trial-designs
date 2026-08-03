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
//
// PIPELINE_STAGES inserts registers ahead of the accumulate stage:
//   0 - multiply, align, reduce, normalize and accumulate in one cycle,
//   1 - registers the normalized FP32 tree result,
//   2 - also registers the aligned tree leaves, shared exponent and the
//       special-value flags.
// The accumulate stage always reads and writes the bank in the same cycle, so
// pipelining only adds PIPELINE_STAGES cycles of latency; no operand forwarding
// is needed even when consecutive operations target the same accumulator.
module bf16_multi_mac_tree #(
    parameter int unsigned MULTIPLIERS = 4,
    parameter int unsigned ACCUMULATORS = 4,
    parameter int unsigned REDUCTION_GUARD_BITS = 4,
    parameter int unsigned PIPELINE_STAGES = 0,
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
    logic [7:0]  maximum_exponent;
    logic [7:0]  stage1_maximum_exponent;
    logic signed [SUM_WIDTH-1:0] leaf_value [0:TREE_LEAVES-1];
    logic signed [SUM_WIDTH-1:0] stage1_leaf_value [0:TREE_LEAVES-1];
    logic [31:0] reduced_product_sum;
    logic [31:0] stage2_reduced_product_sum;
    logic [31:0] accumulator_bank [0:ACCUMULATORS-1];
    logic [31:0] selected_accumulator;
    logic [31:0] next_accumulator;

    logic positive_infinity;
    logic negative_infinity;
    logic invalid_result;
    logic stage1_positive_infinity;
    logic stage1_negative_infinity;
    logic stage1_invalid_result;
    logic                    accumulate_enable;
    logic [SELECT_WIDTH-1:0] accumulate_select;
    integer accumulator_index;

    // Multiply, shared-exponent alignment and special-value detection.
    bf16_mac_tree_align #(
        .MULTIPLIERS          (MULTIPLIERS),
        .REDUCTION_GUARD_BITS (REDUCTION_GUARD_BITS)
    ) align_stage (
        .a                 (a),
        .b                 (b),
        .maximum_exponent  (maximum_exponent),
        .leaf_value        (leaf_value),
        .positive_infinity (positive_infinity),
        .negative_infinity (negative_infinity),
        .invalid_result    (invalid_result)
    );


    // Stage 1 boundary: registered only when two pipeline stages are used.
    generate
        if (PIPELINE_STAGES >= 2) begin : g_stage1_registered
            always_ff @(posedge clk) begin
                if (reset) begin
                    stage1_maximum_exponent  <= 8'b0;
                    stage1_positive_infinity <= 1'b0;
                    stage1_negative_infinity <= 1'b0;
                    stage1_invalid_result    <= 1'b0;
                    for (int unsigned s1 = 0; s1 < TREE_LEAVES; s1++)
                        stage1_leaf_value[s1] <= '0;
                end else begin
                    stage1_maximum_exponent  <= maximum_exponent;
                    stage1_positive_infinity <= positive_infinity;
                    stage1_negative_infinity <= negative_infinity;
                    stage1_invalid_result    <= invalid_result;
                    for (int unsigned s1 = 0; s1 < TREE_LEAVES; s1++)
                        stage1_leaf_value[s1] <= leaf_value[s1];
                end
            end
        end else begin : g_stage1_bypassed
            always_comb begin
                stage1_maximum_exponent  = maximum_exponent;
                stage1_positive_infinity = positive_infinity;
                stage1_negative_infinity = negative_infinity;
                stage1_invalid_result    = invalid_result;
                for (int unsigned s1 = 0; s1 < TREE_LEAVES; s1++)
                    stage1_leaf_value[s1] = leaf_value[s1];
            end
        end
    endgenerate

    // Signed reduction tree plus the single normalize and round to FP32.
    bf16_mac_tree_normalize #(
        .MULTIPLIERS          (MULTIPLIERS),
        .REDUCTION_GUARD_BITS (REDUCTION_GUARD_BITS)
    ) normalize_stage (
        .maximum_exponent  (stage1_maximum_exponent),
        .leaf_value        (stage1_leaf_value),
        .positive_infinity (stage1_positive_infinity),
        .negative_infinity (stage1_negative_infinity),
        .invalid_result    (stage1_invalid_result),
        .result            (reduced_product_sum)
    );

    // Stage 2 boundary: the normalized FP32 tree result feeding the adder.
    generate
        if (PIPELINE_STAGES >= 1) begin : g_stage2_registered
            always_ff @(posedge clk) begin
                if (reset)
                    stage2_reduced_product_sum <= 32'b0;
                else
                    stage2_reduced_product_sum <= reduced_product_sum;
            end
        end else begin : g_stage2_bypassed
            always_comb stage2_reduced_product_sum = reduced_product_sum;
        end
    endgenerate

    // enable and the destination selector travel with the product data so the
    // accumulate stage commits the operation that produced its operand.
    generate
        if (PIPELINE_STAGES == 0) begin : g_control_direct
            always_comb begin
                accumulate_enable = enable;
                accumulate_select = accumulator_select;
            end
        end else begin : g_control_delayed
            logic                    enable_delay [0:PIPELINE_STAGES-1];
            logic [SELECT_WIDTH-1:0] select_delay [0:PIPELINE_STAGES-1];

            always_ff @(posedge clk) begin
                if (reset) begin
                    for (int unsigned d = 0; d < PIPELINE_STAGES; d++) begin
                        enable_delay[d] <= 1'b0;
                        select_delay[d] <= '0;
                    end
                end else begin
                    enable_delay[0] <= enable;
                    select_delay[0] <= accumulator_select;
                    for (int unsigned d = 1; d < PIPELINE_STAGES; d++) begin
                        enable_delay[d] <= enable_delay[d-1];
                        select_delay[d] <= select_delay[d-1];
                    end
                end
            end

            always_comb begin
                accumulate_enable = enable_delay[PIPELINE_STAGES-1];
                accumulate_select = select_delay[PIPELINE_STAGES-1];
            end
        end
    endgenerate

    always_comb begin
        selected_accumulator = 32'b0;
        if (accumulate_select < ACCUMULATORS)
            selected_accumulator = accumulator_bank[accumulate_select];

        // Readout is unpipelined so the selected accumulator can be observed
        // directly.
        accumulator = 32'b0;
        if (accumulator_select < ACCUMULATORS)
            accumulator = accumulator_bank[accumulator_select];
    end

    // Only this final feedback operation uses the full FP32 adder.
    fp32_adder accumulator_adder (
        .a   (selected_accumulator),
        .b   (stage2_reduced_product_sum),
        .sum (next_accumulator)
    );

    always_ff @(posedge clk) begin
        if (reset || clear) begin
            for (accumulator_index = 0;
                 accumulator_index < ACCUMULATORS;
                 accumulator_index = accumulator_index + 1)
                accumulator_bank[accumulator_index] <= 32'b0;
        end else if (accumulate_enable && accumulate_select < ACCUMULATORS) begin
            accumulator_bank[accumulate_select] <= next_accumulator;
        end
    end
endmodule
