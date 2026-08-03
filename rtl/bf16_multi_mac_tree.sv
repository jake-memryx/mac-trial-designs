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
    // Pipeline depth of the accumulate read-modify-write loop. Legal because
    // accumulators are selected round-robin, so an accumulator is not revisited
    // for ACCUMULATORS cycles:
    //   0 - bank read, FP32 add and write-back in one cycle,
    //   1 - registered bank read, then the full FP32 adder,
    //   2 - registered bank read, then FP32 align, then normalize and round.
    parameter int unsigned ACCUMULATE_STAGES = 0,
    parameter int unsigned CONTROL_DEPTH = PIPELINE_STAGES + ACCUMULATE_STAGES,
    parameter int unsigned READ_TAP = PIPELINE_STAGES,
    parameter int unsigned WRITE_TAP = PIPELINE_STAGES + ACCUMULATE_STAGES,
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
    logic [31:0] bank_read;
    logic [31:0] selected_accumulator;
    logic [31:0] accumulate_operand;
    logic [31:0] next_accumulator;

    // ctrl_*_q[d] is the control delayed by d+1 cycles. Tap 0 is the live input,
    // so taps are read through read_*/mid_*/accumulate_* below.
    localparam int unsigned CHAIN_DEPTH =
        (CONTROL_DEPTH == 0) ? 1 : CONTROL_DEPTH;
    // Index of the tap one cycle past the bank read, used only by the split
    // adder. Clamped so the array reference stays in range otherwise.
    localparam int unsigned MID_INDEX =
        (ACCUMULATE_STAGES >= 2) ? READ_TAP : 0;

    logic                    ctrl_valid_q [0:CHAIN_DEPTH-1];
    logic [SELECT_WIDTH-1:0] ctrl_sel_q   [0:CHAIN_DEPTH-1];

    logic                    read_valid;
    logic [SELECT_WIDTH-1:0] read_select;
    logic                    mid_valid;

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

    // enable and the destination selector travel with the product data so each
    // stage acts on the operation that produced its operand. ctrl_*[k] is the
    // control delayed by exactly k cycles, so the read and write stages simply
    // take different taps of the same chain.
    generate
        if (CONTROL_DEPTH > 0) begin : g_control_delay
            always_ff @(posedge clk) begin
                if (reset) begin
                    for (int unsigned d = 0; d < CONTROL_DEPTH; d++) begin
                        ctrl_valid_q[d] <= 1'b0;
                        ctrl_sel_q[d]   <= '0;
                    end
                end else begin
                    ctrl_valid_q[0] <= enable;
                    ctrl_sel_q[0]   <= accumulator_select;
                    for (int unsigned d = 1; d < CONTROL_DEPTH; d++) begin
                        ctrl_valid_q[d] <= ctrl_valid_q[d-1];
                        ctrl_sel_q[d]   <= ctrl_sel_q[d-1];
                    end
                end
            end
        end else begin : g_control_unused
            always_comb begin
                ctrl_valid_q[0] = 1'b0;
                ctrl_sel_q[0]   = '0;
            end
        end
    endgenerate

    always_comb begin
        read_valid  = (READ_TAP == 0) ? enable : ctrl_valid_q[READ_TAP-1];
        read_select = (READ_TAP == 0) ? accumulator_select
                                     : ctrl_sel_q[READ_TAP-1];
        mid_valid   = ctrl_valid_q[MID_INDEX];

        accumulate_enable = (WRITE_TAP == 0) ? enable
                                             : ctrl_valid_q[WRITE_TAP-1];
        accumulate_select = (WRITE_TAP == 0) ? accumulator_select
                                             : ctrl_sel_q[WRITE_TAP-1];
    end

    // Readout is unpipelined so the selected accumulator can be observed
    // directly.
    always_comb begin
        accumulator = 32'b0;
        if (accumulator_select < ACCUMULATORS)
            accumulator = accumulator_bank[accumulator_select];
    end

    // Accumulate stage. Round-robin selection means an accumulator is not
    // revisited for ACCUMULATORS cycles, so this read-modify-write loop carries
    // no read-after-write hazard and can be cut into short pipeline segments.
    generate
        if (ACCUMULATE_STAGES == 0) begin : g_accumulate_flat
            // Bank read, FP32 add and write-back all in the committing cycle.
            always_comb begin
                selected_accumulator = 32'b0;
                if (accumulate_select < ACCUMULATORS)
                    selected_accumulator =
                        accumulator_bank[accumulate_select];
            end

            always_comb accumulate_operand = stage2_reduced_product_sum;

            fp32_adder accumulator_adder (
                .a   (selected_accumulator),
                .b   (accumulate_operand),
                .sum (next_accumulator)
            );
        end else begin : g_accumulate_pipelined
            // The read address is a tap of the control chain, so the bank mux
            // gets a cycle of its own. The tree result is held alongside it so
            // both adder operands arrive in the same cycle.
            always_comb begin
                bank_read = 32'b0;
                if (read_select < ACCUMULATORS)
                    bank_read = accumulator_bank[read_select];
            end

            always_ff @(posedge clk) begin
                if (reset) begin
                    selected_accumulator <= 32'b0;
                    accumulate_operand   <= 32'b0;
                end else if (read_valid) begin
                    selected_accumulator <= bank_read;
                    accumulate_operand   <= stage2_reduced_product_sum;
                end
            end

            if (ACCUMULATE_STAGES == 1) begin : g_adder_flat
                fp32_adder accumulator_adder (
                    .a   (selected_accumulator),
                    .b   (accumulate_operand),
                    .sum (next_accumulator)
                );
            end else begin : g_adder_split
                // Align in one cycle, add/normalize/round in the next.
                logic        add_special_valid, add_special_valid_q;
                logic [31:0] add_special_sum,   add_special_sum_q;
                logic        add_sign,          add_sign_q;
                logic [7:0]  add_exp,           add_exp_q;
                logic [26:0] add_large_ext,     add_large_ext_q;
                logic [26:0] add_aligned_small, add_aligned_small_q;
                logic        add_not_sub,       add_not_sub_q;

                fp32_adder_align align_half (
                    .a             (selected_accumulator),
                    .b             (accumulate_operand),
                    .special_valid (add_special_valid),
                    .special_sum   (add_special_sum),
                    .result_sign   (add_sign),
                    .result_exp    (add_exp),
                    .large_ext     (add_large_ext),
                    .aligned_small (add_aligned_small),
                    .add_not_sub   (add_not_sub)
                );

                always_ff @(posedge clk) begin
                    if (reset) begin
                        add_special_valid_q <= 1'b0;
                        add_special_sum_q   <= 32'b0;
                        add_sign_q          <= 1'b0;
                        add_exp_q           <= 8'b0;
                        add_large_ext_q     <= 27'b0;
                        add_aligned_small_q <= 27'b0;
                        add_not_sub_q       <= 1'b0;
                    end else if (mid_valid) begin
                        add_special_valid_q <= add_special_valid;
                        add_special_sum_q   <= add_special_sum;
                        add_sign_q          <= add_sign;
                        add_exp_q           <= add_exp;
                        add_large_ext_q     <= add_large_ext;
                        add_aligned_small_q <= add_aligned_small;
                        add_not_sub_q       <= add_not_sub;
                    end
                end

                fp32_adder_normalize normalize_half (
                    .special_valid (add_special_valid_q),
                    .special_sum   (add_special_sum_q),
                    .result_sign   (add_sign_q),
                    .result_exp    (add_exp_q),
                    .large_ext     (add_large_ext_q),
                    .aligned_small (add_aligned_small_q),
                    .add_not_sub   (add_not_sub_q),
                    .sum           (next_accumulator)
                );
            end
        end
    endgenerate

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

`ifndef SYNTHESIS
    // Issue contract for a pipelined accumulate loop: an accumulator that is
    // still in flight must not be re-issued, or its read would miss the
    // in-flight update. Round-robin selection over ACCUMULATORS entries
    // satisfies this for any ACCUMULATE_STAGES < ACCUMULATORS.
    always_ff @(posedge clk) begin
        if (!reset && enable) begin
            for (int unsigned d = 0; d < CONTROL_DEPTH; d++) begin
                if ((d + 1) > READ_TAP && ctrl_valid_q[d] &&
                    ctrl_sel_q[d] == accumulator_select)
                    $error({"bf16_multi_mac_tree: accumulator %0d re-issued ",
                            "while still in flight (%0d cycles behind)"},
                           accumulator_select, d + 1);
            end
        end
    end
`endif
endmodule
