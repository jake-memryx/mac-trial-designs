`timescale 1ns/1ps

// BF16 multi-MAC with replicated reduction trees on a multi-cycle path.
//
// Externally this is the same block as bf16_multi_mac_tree: MULTIPLIERS BF16
// MAC operations are issued every cycle and folded into one of ACCUMULATORS
// FP32 accumulators. Internally the accumulator mux is moved from the output
// of the tree to its input:
//
//   * The bank is split into LANES slices of ACCUMULATORS/LANES entries. The
//     upper bits of accumulator_select choose the lane, the lower bits index
//     within it.
//   * Each lane owns a private set of multipliers, reduction tree and FP32
//     accumulate adder, so the multiply/align/reduce/normalize cone only sees
//     a new operand set every LANE_CYCLES cycles.
//   * Lane operand registers therefore hold their value for LANE_CYCLES
//     cycles, making the whole cone a genuine LANE_CYCLES-cycle path that is
//     declared to synthesis with set_multicycle_path.
//
// ACCUMULATE_STAGES additionally splits the accumulate read-modify-write into
// a registered bank read followed by the FP32 add and write-back, turning the
// one long single-cycle loop into two short ones. Because a lane only retires
// an operation every LANE_CYCLES cycles, the read can be overlapped with the
// last cycle of the tree segment, so this costs no extra latency and creates
// no read-after-write hazard: a lane's next read happens one cycle after its
// previous write. Throughput, numerics and the observable interface are
// identical to bf16_multi_mac_tree.
//
// Issue contract: consecutive enabled operations must target different lanes.
// A lane can only accept a new operation every LANE_CYCLES cycles, so a driver
// that issues back-to-back operations into the same accumulator half would
// corrupt the in-flight operation. GEMV drivers satisfy this by interleaving
// the output-column order (0, 16, 1, 17, ...); the assertion below checks it.
module bf16_dual_mac_tree #(
    parameter int unsigned MULTIPLIERS = 8,
    parameter int unsigned ACCUMULATORS = 32,
    parameter int unsigned LANES = 2,
    parameter int unsigned REDUCTION_GUARD_BITS = 4,
    parameter int unsigned PIPELINE_STAGES = 0,
    // Clock cycles allowed for each register-to-register segment of a lane.
    parameter int unsigned LANE_CYCLES = 2,
    // 0 - bank read, FP32 add and bank write all in the cycle that commits.
    // 1 - the bank read is registered one cycle ahead of the add and write, so
    //     the accumulate loop becomes two single-cycle paths instead of one.
    //     This costs no extra latency: the read is overlapped with the last
    //     cycle of the lane's multi-cycle tree segment.
    parameter int unsigned ACCUMULATE_STAGES = 1,
    parameter int unsigned SELECT_WIDTH =
        (ACCUMULATORS <= 1) ? 1 : $clog2(ACCUMULATORS),
    parameter int unsigned LANE_DEPTH = ACCUMULATORS / LANES,
    parameter int unsigned LANE_SELECT_WIDTH =
        (LANE_DEPTH <= 1) ? 1 : $clog2(LANE_DEPTH),
    parameter int unsigned LANE_INDEX_WIDTH = (LANES <= 1) ? 1 : $clog2(LANES),
    parameter int unsigned TREE_LEVELS =
        (MULTIPLIERS <= 1) ? 0 : $clog2(MULTIPLIERS),
    parameter int unsigned TREE_LEAVES = 1 << TREE_LEVELS,
    parameter int unsigned MAGNITUDE_WIDTH = 16 + REDUCTION_GUARD_BITS,
    parameter int unsigned SUM_WIDTH = MAGNITUDE_WIDTH + TREE_LEVELS + 1,
    // Cycles from an operation being issued to its accumulator update.
    parameter int unsigned LATENCY = LANE_CYCLES * (PIPELINE_STAGES + 1)
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
    // Input-side demux: the upper select bits pick the lane.
    logic [LANE_INDEX_WIDTH-1:0]  issue_lane;
    logic [LANE_SELECT_WIDTH-1:0] issue_select;
    logic [LANE_INDEX_WIDTH-1:0]  readout_lane;
    logic [LANE_SELECT_WIDTH-1:0] readout_select;

    assign issue_lane     = accumulator_select[SELECT_WIDTH-1 -: LANE_INDEX_WIDTH];
    assign issue_select   = accumulator_select[LANE_SELECT_WIDTH-1:0];
    assign readout_lane   = issue_lane;
    assign readout_select = issue_select;

    // Lane operand registers. These are the launch points of the multi-cycle
    // tree path, so they only update when their lane is issued to.
    logic [15:0] lane_a [0:LANES-1][0:MULTIPLIERS-1];
    logic [15:0] lane_b [0:LANES-1][0:MULTIPLIERS-1];
    logic        lane_capture [0:LANES-1];

    // Per-lane tree signals.
    logic [7:0]  lane_maximum_exponent [0:LANES-1];
    logic signed [SUM_WIDTH-1:0]
                 lane_leaf_value [0:LANES-1][0:TREE_LEAVES-1];
    logic        lane_positive_infinity [0:LANES-1];
    logic        lane_negative_infinity [0:LANES-1];
    logic        lane_invalid_result [0:LANES-1];

    logic [7:0]  stage1_maximum_exponent [0:LANES-1];
    logic signed [SUM_WIDTH-1:0]
                 stage1_leaf_value [0:LANES-1][0:TREE_LEAVES-1];
    logic        stage1_positive_infinity [0:LANES-1];
    logic        stage1_negative_infinity [0:LANES-1];
    logic        stage1_invalid_result [0:LANES-1];

    logic [31:0] lane_result [0:LANES-1];
    logic [31:0] stage2_result [0:LANES-1];

    // Accumulator bank slices and their adders.
    logic [31:0] bank [0:LANES-1][0:LANE_DEPTH-1];
    logic [31:0] bank_read [0:LANES-1];
    logic [31:0] selected_accumulator [0:LANES-1];
    logic [31:0] next_accumulator [0:LANES-1];

    // Valid/select shift register. Tap LANE_CYCLES-1 marks the end of the
    // first multi-cycle segment, 2*LANE_CYCLES-1 the second, and so on.
    logic                         issue_valid [0:LANES-1][0:LATENCY-1];
    logic [LANE_SELECT_WIDTH-1:0] issue_sel   [0:LANES-1][0:LATENCY-1];

    genvar lane;
    generate
        for (lane = 0; lane < LANES; lane = lane + 1) begin : g_lane
            assign lane_capture[lane] =
                enable && (issue_lane == lane[LANE_INDEX_WIDTH-1:0]);

            always_ff @(posedge clk) begin
                if (reset) begin
                    for (int unsigned m = 0; m < MULTIPLIERS; m++) begin
                        lane_a[lane][m] <= 16'b0;
                        lane_b[lane][m] <= 16'b0;
                    end
                end else if (lane_capture[lane]) begin
                    for (int unsigned m = 0; m < MULTIPLIERS; m++) begin
                        lane_a[lane][m] <= a[m];
                        lane_b[lane][m] <= b[m];
                    end
                end
            end

            bf16_mac_tree_align #(
                .MULTIPLIERS          (MULTIPLIERS),
                .REDUCTION_GUARD_BITS (REDUCTION_GUARD_BITS)
            ) align_stage (
                .a                 (lane_a[lane]),
                .b                 (lane_b[lane]),
                .maximum_exponent  (lane_maximum_exponent[lane]),
                .leaf_value        (lane_leaf_value[lane]),
                .positive_infinity (lane_positive_infinity[lane]),
                .negative_infinity (lane_negative_infinity[lane]),
                .invalid_result    (lane_invalid_result[lane])
            );

            // Stage 1 boundary. Its enable is the issue valid delayed by one
            // multi-cycle segment so the capture stays aligned with the data.
            if (PIPELINE_STAGES >= 2) begin : g_stage1_registered
                always_ff @(posedge clk) begin
                    if (reset) begin
                        stage1_maximum_exponent[lane]  <= 8'b0;
                        stage1_positive_infinity[lane] <= 1'b0;
                        stage1_negative_infinity[lane] <= 1'b0;
                        stage1_invalid_result[lane]    <= 1'b0;
                        for (int unsigned s1 = 0; s1 < TREE_LEAVES; s1++)
                            stage1_leaf_value[lane][s1] <= '0;
                    end else if (issue_valid[lane][LANE_CYCLES-1]) begin
                        stage1_maximum_exponent[lane]  <=
                            lane_maximum_exponent[lane];
                        stage1_positive_infinity[lane] <=
                            lane_positive_infinity[lane];
                        stage1_negative_infinity[lane] <=
                            lane_negative_infinity[lane];
                        stage1_invalid_result[lane]    <=
                            lane_invalid_result[lane];
                        for (int unsigned s1 = 0; s1 < TREE_LEAVES; s1++)
                            stage1_leaf_value[lane][s1] <=
                                lane_leaf_value[lane][s1];
                    end
                end
            end else begin : g_stage1_bypassed
                always_comb begin
                    stage1_maximum_exponent[lane]  =
                        lane_maximum_exponent[lane];
                    stage1_positive_infinity[lane] =
                        lane_positive_infinity[lane];
                    stage1_negative_infinity[lane] =
                        lane_negative_infinity[lane];
                    stage1_invalid_result[lane]    =
                        lane_invalid_result[lane];
                    for (int unsigned s1 = 0; s1 < TREE_LEAVES; s1++)
                        stage1_leaf_value[lane][s1] =
                            lane_leaf_value[lane][s1];
                end
            end

            bf16_mac_tree_normalize #(
                .MULTIPLIERS          (MULTIPLIERS),
                .REDUCTION_GUARD_BITS (REDUCTION_GUARD_BITS)
            ) normalize_stage (
                .maximum_exponent  (stage1_maximum_exponent[lane]),
                .leaf_value        (stage1_leaf_value[lane]),
                .positive_infinity (stage1_positive_infinity[lane]),
                .negative_infinity (stage1_negative_infinity[lane]),
                .invalid_result    (stage1_invalid_result[lane]),
                .result            (lane_result[lane])
            );

            // Stage 2 boundary, one segment ahead of the accumulate stage.
            if (PIPELINE_STAGES >= 1) begin : g_stage2_registered
                always_ff @(posedge clk) begin
                    if (reset)
                        stage2_result[lane] <= 32'b0;
                    else if (issue_valid[lane]
                                        [LANE_CYCLES*PIPELINE_STAGES-1])
                        stage2_result[lane] <= lane_result[lane];
                end
            end else begin : g_stage2_bypassed
                always_comb stage2_result[lane] = lane_result[lane];
            end

            // Issue valid/select pipeline for this lane.
            always_ff @(posedge clk) begin
                if (reset) begin
                    for (int unsigned d = 0; d < LATENCY; d++) begin
                        issue_valid[lane][d] <= 1'b0;
                        issue_sel[lane][d]   <= '0;
                    end
                end else begin
                    issue_valid[lane][0] <= lane_capture[lane];
                    issue_sel[lane][0]   <= issue_select;
                    for (int unsigned d = 1; d < LATENCY; d++) begin
                        issue_valid[lane][d] <= issue_valid[lane][d-1];
                        issue_sel[lane][d]   <= issue_sel[lane][d-1];
                    end
                end
            end

            // Accumulate operand read. With ACCUMULATE_STAGES the mux output
            // is registered one cycle ahead of the commit, so the read address
            // path and the adder path become separate single-cycle paths.
            if (ACCUMULATE_STAGES >= 1) begin : g_read_registered
                always_comb bank_read[lane] =
                    bank[lane][issue_sel[lane][LATENCY-2]];

                always_ff @(posedge clk) begin
                    if (reset)
                        selected_accumulator[lane] <= 32'b0;
                    else if (issue_valid[lane][LATENCY-2])
                        selected_accumulator[lane] <= bank_read[lane];
                end
            end else begin : g_read_direct
                always_comb begin
                    bank_read[lane]            = 32'b0;
                    selected_accumulator[lane] =
                        bank[lane][issue_sel[lane][LATENCY-1]];
                end
            end

            // Only this final feedback operation uses the full FP32 adder, and
            // it remains a single-cycle path.
            fp32_adder accumulator_adder (
                .a   (selected_accumulator[lane]),
                .b   (stage2_result[lane]),
                .sum (next_accumulator[lane])
            );

            always_ff @(posedge clk) begin
                if (reset || clear) begin
                    for (int unsigned e = 0; e < LANE_DEPTH; e++)
                        bank[lane][e] <= 32'b0;
                end else if (issue_valid[lane][LATENCY-1]) begin
                    bank[lane][issue_sel[lane][LATENCY-1]] <=
                        next_accumulator[lane];
                end
            end
        end
    endgenerate

    // Readout is unpipelined so the selected accumulator can be observed
    // directly, matching bf16_multi_mac_tree.
    always_comb accumulator = bank[readout_lane][readout_select];

`ifndef SYNTHESIS
    // Issue contract: back-to-back operations must alternate lanes.
    logic                        past_enable;
    logic [LANE_INDEX_WIDTH-1:0] past_lane;

    always_ff @(posedge clk) begin
        if (reset) begin
            past_enable <= 1'b0;
            past_lane   <= '0;
        end else begin
            past_enable <= enable;
            past_lane   <= issue_lane;
        end
    end

    always_ff @(posedge clk) begin
        if (!reset && enable && past_enable && issue_lane == past_lane)
            $error("bf16_dual_mac_tree: consecutive issues to lane %0d",
                   issue_lane);
    end
`endif
endmodule
