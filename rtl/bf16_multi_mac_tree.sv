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
    // Adds a runtime-selectable E4M3 mode at double throughput. Two FP8 values
    // pack into each 16-bit operand word, so the operand bus is unchanged and
    // the lane count doubles. With FP8_ENABLE = 0 the mode input is tied off
    // and the design is identical to the BF16-only build.
    parameter bit FP8_ENABLE = 0,
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
    // BF16 reduction path: 16-bit product significands over MULTIPLIERS lanes.
    parameter int unsigned BF16_LEVELS =
        (MULTIPLIERS <= 1) ? 0 : $clog2(MULTIPLIERS),
    parameter int unsigned BF16_LEAVES = 1 << BF16_LEVELS,
    parameter int unsigned BF16_MAGNITUDE = 16 + REDUCTION_GUARD_BITS,
    parameter int unsigned BF16_SUM_WIDTH = BF16_MAGNITUDE + BF16_LEVELS + 1,
    // E4M3 reduction path: 8-bit product significands over twice the lanes.
    // Its alignment window is independent of the BF16 one, so it can be sized
    // for an 8-bit significand instead of inheriting BF16's 20 bits.
    parameter int unsigned FP8_GUARD_BITS = REDUCTION_GUARD_BITS,
    parameter int unsigned FP8_LANES = 2 * MULTIPLIERS,
    parameter int unsigned FP8_LEVELS =
        (FP8_LANES <= 1) ? 0 : $clog2(FP8_LANES),
    parameter int unsigned FP8_LEAVES = 1 << FP8_LEVELS,
    parameter int unsigned FP8_MAGNITUDE = 8 + FP8_GUARD_BITS,
    parameter int unsigned FP8_SUM_WIDTH = FP8_MAGNITUDE + FP8_LEVELS + 1
) (
    input  logic                    clk,
    input  logic                    reset,
    input  logic                    clear,
    input  logic                    enable,
    // 0 = BF16 (MULTIPLIERS MACs/cycle), 1 = E4M3 (2*MULTIPLIERS MACs/cycle).
    // Sampled with the operands; ignored unless FP8_ENABLE.
    input  logic                    mode,
    input  logic [SELECT_WIDTH-1:0] accumulator_select,
    input  logic [15:0]             a [0:MULTIPLIERS-1],
    input  logic [15:0]             b [0:MULTIPLIERS-1],
    output logic [31:0]             accumulator
);
    logic        effective_mode;

    // BF16 reduction path.
    logic [15:0] bf16_a [0:MULTIPLIERS-1];
    logic [15:0] bf16_b [0:MULTIPLIERS-1];
    logic [31:0] bf16_product [0:BF16_LEAVES-1];
    logic [7:0]  bf16_max_exponent, bf16_stage1_max_exponent;
    logic signed [BF16_SUM_WIDTH-1:0] bf16_leaf [0:BF16_LEAVES-1];
    logic signed [BF16_SUM_WIDTH-1:0] bf16_stage1_leaf [0:BF16_LEAVES-1];
    logic        bf16_pos_inf, bf16_neg_inf, bf16_invalid;
    logic        bf16_stage1_pos_inf, bf16_stage1_neg_inf, bf16_stage1_invalid;
    logic [31:0] bf16_reduced, bf16_stage2;

    // E4M3 reduction path.
    logic [7:0]  fp8_a [0:FP8_LEAVES-1];
    logic [7:0]  fp8_b [0:FP8_LEAVES-1];
    logic [31:0] fp8_product [0:FP8_LEAVES-1];
    logic [7:0]  fp8_max_exponent, fp8_stage1_max_exponent;
    logic signed [FP8_SUM_WIDTH-1:0] fp8_leaf [0:FP8_LEAVES-1];
    logic signed [FP8_SUM_WIDTH-1:0] fp8_stage1_leaf [0:FP8_LEAVES-1];
    logic        fp8_pos_inf, fp8_neg_inf, fp8_invalid;
    logic        fp8_stage1_pos_inf, fp8_stage1_neg_inf, fp8_stage1_invalid;
    logic [31:0] fp8_reduced, fp8_stage2;

    logic [31:0] reduced_result;
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
    // The mode travels with the operation, so a mode change on consecutive
    // cycles cannot disturb an operation already in flight.
    logic                    ctrl_mode_q  [0:CHAIN_DEPTH-1];

    // Mode of the operation resident in each stage: stage 1 acts on the live
    // operands, stage 2 one cycle later, and the result mux at the accumulate
    // operand register READ_TAP cycles after issue.
    logic                    stage2_mode;
    logic                    result_mode;

    logic                    read_valid;
    logic [SELECT_WIDTH-1:0] read_select;
    logic                    mid_valid;

    logic                    accumulate_enable;
    logic [SELECT_WIDTH-1:0] accumulate_select;
    integer accumulator_index;


    // Two independent reduction paths. Only the accumulate stage below is
    // shared, so the BF16 datapath is identical to a BF16-only build and pays
    // nothing for the presence of the FP8 mode.
    //
    // Both paths' operands are gated by the mode so the idle path's
    // combinational logic is static. Measured: gating only the FP8 side (to
    // keep the BF16 cone free of any added logic) is worse in both modes,
    // because FP8 operation then pays for the BF16 cone toggling and the
    // BF16 saving does not materialise.
    assign effective_mode = FP8_ENABLE ? mode : 1'b0;

    always_comb begin
        for (int unsigned m = 0; m < MULTIPLIERS; m++) begin
            bf16_a[m] = effective_mode ? 16'b0 : a[m];
            bf16_b[m] = effective_mode ? 16'b0 : b[m];
        end
        // FP8 packing: element m of the vector is the low byte of operand word
        // m, element m+MULTIPLIERS is the high byte. The reduction is a sum, so
        // the lane assignment only has to match the driver's convention.
        for (int unsigned m = 0; m < MULTIPLIERS; m++) begin
            fp8_a[m]               = effective_mode ? a[m][7:0]  : 8'b0;
            fp8_b[m]               = effective_mode ? b[m][7:0]  : 8'b0;
            fp8_a[m + MULTIPLIERS] = effective_mode ? a[m][15:8] : 8'b0;
            fp8_b[m + MULTIPLIERS] = effective_mode ? b[m][15:8] : 8'b0;
        end
    end

    // ---- BF16 path -------------------------------------------------------
    genvar leaf;
    generate
        for (leaf = 0; leaf < BF16_LEAVES; leaf = leaf + 1) begin : g_bf16_leaf
            if (leaf < MULTIPLIERS) begin : g_product
                bf16_multiplier multiplier (
                    .a       (bf16_a[leaf]),
                    .b       (bf16_b[leaf]),
                    .product (bf16_product[leaf])
                );
            end else begin : g_padding
                assign bf16_product[leaf] = 32'b0;
            end
        end
    endgenerate

    bf16_mac_tree_align #(
        .MULTIPLIERS          (MULTIPLIERS),
        .REDUCTION_GUARD_BITS (REDUCTION_GUARD_BITS),
        .SIGNIFICAND_BITS     (16)
    ) bf16_align_stage (
        .product           (bf16_product),
        .maximum_exponent  (bf16_max_exponent),
        .leaf_value        (bf16_leaf),
        .positive_infinity (bf16_pos_inf),
        .negative_infinity (bf16_neg_inf),
        .invalid_result    (bf16_invalid)
    );

    generate
        if (PIPELINE_STAGES >= 2) begin : g_bf16_stage1_registered
            always_ff @(posedge clk) begin
                if (reset) begin
                    bf16_stage1_max_exponent <= 8'b0;
                    bf16_stage1_pos_inf      <= 1'b0;
                    bf16_stage1_neg_inf      <= 1'b0;
                    bf16_stage1_invalid      <= 1'b0;
                    for (int unsigned s1 = 0; s1 < BF16_LEAVES; s1++)
                        bf16_stage1_leaf[s1] <= '0;
                end else if (!effective_mode) begin
                    bf16_stage1_max_exponent <= bf16_max_exponent;
                    bf16_stage1_pos_inf      <= bf16_pos_inf;
                    bf16_stage1_neg_inf      <= bf16_neg_inf;
                    bf16_stage1_invalid      <= bf16_invalid;
                    for (int unsigned s1 = 0; s1 < BF16_LEAVES; s1++)
                        bf16_stage1_leaf[s1] <= bf16_leaf[s1];
                end
            end
        end else begin : g_bf16_stage1_bypassed
            always_comb begin
                bf16_stage1_max_exponent = bf16_max_exponent;
                bf16_stage1_pos_inf      = bf16_pos_inf;
                bf16_stage1_neg_inf      = bf16_neg_inf;
                bf16_stage1_invalid      = bf16_invalid;
                for (int unsigned s1 = 0; s1 < BF16_LEAVES; s1++)
                    bf16_stage1_leaf[s1] = bf16_leaf[s1];
            end
        end
    endgenerate

    bf16_mac_tree_normalize #(
        .MULTIPLIERS          (MULTIPLIERS),
        .REDUCTION_GUARD_BITS (REDUCTION_GUARD_BITS),
        .SIGNIFICAND_BITS     (16)
    ) bf16_normalize_stage (
        .maximum_exponent  (bf16_stage1_max_exponent),
        .leaf_value        (bf16_stage1_leaf),
        .positive_infinity (bf16_stage1_pos_inf),
        .negative_infinity (bf16_stage1_neg_inf),
        .invalid_result    (bf16_stage1_invalid),
        .result            (bf16_reduced)
    );

    generate
        if (PIPELINE_STAGES >= 1) begin : g_bf16_stage2_registered
            always_ff @(posedge clk) begin
                if (reset)
                    bf16_stage2 <= 32'b0;
                else if (!stage2_mode)
                    bf16_stage2 <= bf16_reduced;
            end
        end else begin : g_bf16_stage2_bypassed
            always_comb bf16_stage2 = bf16_reduced;
        end
    endgenerate

    // ---- E4M3 path -------------------------------------------------------
    generate
        if (FP8_ENABLE) begin : g_fp8_path
            genvar fp8_leaf_index;
            for (fp8_leaf_index = 0; fp8_leaf_index < FP8_LEAVES;
                 fp8_leaf_index = fp8_leaf_index + 1) begin : g_fp8_leaf
                mac_multiplier #(.SUPPORT_BF16(0)) multiplier (
                    .mode    (effective_mode),
                    .bf16_a  (16'b0),
                    .bf16_b  (16'b0),
                    .fp8_a   (fp8_a[fp8_leaf_index]),
                    .fp8_b   (fp8_b[fp8_leaf_index]),
                    .product (fp8_product[fp8_leaf_index])
                );
            end

            bf16_mac_tree_align #(
                .MULTIPLIERS          (FP8_LANES),
                .REDUCTION_GUARD_BITS (FP8_GUARD_BITS),
                .SIGNIFICAND_BITS     (8)
            ) fp8_align_stage (
                .product           (fp8_product),
                .maximum_exponent  (fp8_max_exponent),
                .leaf_value        (fp8_leaf),
                .positive_infinity (fp8_pos_inf),
                .negative_infinity (fp8_neg_inf),
                .invalid_result    (fp8_invalid)
            );

            if (PIPELINE_STAGES >= 2) begin : g_fp8_stage1_registered
                always_ff @(posedge clk) begin
                    if (reset) begin
                        fp8_stage1_max_exponent <= 8'b0;
                        fp8_stage1_pos_inf      <= 1'b0;
                        fp8_stage1_neg_inf      <= 1'b0;
                        fp8_stage1_invalid      <= 1'b0;
                        for (int unsigned s1 = 0; s1 < FP8_LEAVES; s1++)
                            fp8_stage1_leaf[s1] <= '0;
                    end else if (effective_mode) begin
                        fp8_stage1_max_exponent <= fp8_max_exponent;
                        fp8_stage1_pos_inf      <= fp8_pos_inf;
                        fp8_stage1_neg_inf      <= fp8_neg_inf;
                        fp8_stage1_invalid      <= fp8_invalid;
                        for (int unsigned s1 = 0; s1 < FP8_LEAVES; s1++)
                            fp8_stage1_leaf[s1] <= fp8_leaf[s1];
                    end
                end
            end else begin : g_fp8_stage1_bypassed
                always_comb begin
                    fp8_stage1_max_exponent = fp8_max_exponent;
                    fp8_stage1_pos_inf      = fp8_pos_inf;
                    fp8_stage1_neg_inf      = fp8_neg_inf;
                    fp8_stage1_invalid      = fp8_invalid;
                    for (int unsigned s1 = 0; s1 < FP8_LEAVES; s1++)
                        fp8_stage1_leaf[s1] = fp8_leaf[s1];
                end
            end

            bf16_mac_tree_normalize #(
                .MULTIPLIERS          (FP8_LANES),
                .REDUCTION_GUARD_BITS (FP8_GUARD_BITS),
                .SIGNIFICAND_BITS     (8)
            ) fp8_normalize_stage (
                .maximum_exponent  (fp8_stage1_max_exponent),
                .leaf_value        (fp8_stage1_leaf),
                .positive_infinity (fp8_stage1_pos_inf),
                .negative_infinity (fp8_stage1_neg_inf),
                .invalid_result    (fp8_stage1_invalid),
                .result            (fp8_reduced)
            );

            if (PIPELINE_STAGES >= 1) begin : g_fp8_stage2_registered
                always_ff @(posedge clk) begin
                    if (reset)
                        fp8_stage2 <= 32'b0;
                    else if (stage2_mode)
                        fp8_stage2 <= fp8_reduced;
                end
            end else begin : g_fp8_stage2_bypassed
                always_comb fp8_stage2 = fp8_reduced;
            end
        end else begin : g_no_fp8_path
            always_comb begin
                fp8_max_exponent        = 8'b0;
                fp8_stage1_max_exponent = 8'b0;
                fp8_pos_inf             = 1'b0;
                fp8_neg_inf             = 1'b0;
                fp8_invalid             = 1'b0;
                fp8_stage1_pos_inf      = 1'b0;
                fp8_stage1_neg_inf      = 1'b0;
                fp8_stage1_invalid      = 1'b0;
                fp8_reduced             = 32'b0;
                fp8_stage2              = 32'b0;
                for (int unsigned s1 = 0; s1 < FP8_LEAVES; s1++) begin
                    fp8_product[s1]     = 32'b0;
                    fp8_leaf[s1]        = '0;
                    fp8_stage1_leaf[s1] = '0;
                end
            end
        end
    endgenerate

    // The two paths join here. Muxing into the existing operand register keeps
    // the mux out of the tree's critical path.
    assign reduced_result = result_mode ? fp8_stage2 : bf16_stage2;

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
                        ctrl_mode_q[d]  <= 1'b0;
                    end
                end else begin
                    ctrl_valid_q[0] <= enable;
                    ctrl_sel_q[0]   <= accumulator_select;
                    ctrl_mode_q[0]  <= effective_mode;
                    for (int unsigned d = 1; d < CONTROL_DEPTH; d++) begin
                        ctrl_valid_q[d] <= ctrl_valid_q[d-1];
                        ctrl_sel_q[d]   <= ctrl_sel_q[d-1];
                        ctrl_mode_q[d]  <= ctrl_mode_q[d-1];
                    end
                end
            end
        end else begin : g_control_unused
            always_comb begin
                ctrl_valid_q[0] = 1'b0;
                ctrl_sel_q[0]   = '0;
                ctrl_mode_q[0]  = 1'b0;
            end
        end
    endgenerate

    always_comb begin
        stage2_mode = (PIPELINE_STAGES >= 2) ? ctrl_mode_q[PIPELINE_STAGES-2]
                                             : effective_mode;
        result_mode = (PIPELINE_STAGES == 0) ? effective_mode
                                             : ctrl_mode_q[PIPELINE_STAGES-1];
    end

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

            always_comb accumulate_operand = reduced_result;

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
                    accumulate_operand   <= reduced_result;
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
