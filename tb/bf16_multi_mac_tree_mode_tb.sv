`timescale 1ns/1ps

// Mode-switching tests for the dual-format tree MAC.
//
// The two reduction paths share one accumulate stage, so the mode has to travel
// with each operation through the pipeline. The critical case is a mode change
// on consecutive cycles: if a stage's enable used the live mode instead of the
// mode of the operation resident in that stage, the earlier operation would be
// dropped. That is what the back-to-back test below covers.
module bf16_multi_mac_tree_mode_tb;
    localparam int unsigned MULTIPLIERS  = 4;
    localparam int unsigned ACCUMULATORS = 8;
    localparam int unsigned PIPELINE_STAGES = 2;
    localparam int unsigned ACCUMULATE_STAGES = 2;
    localparam int unsigned LATENCY = PIPELINE_STAGES + ACCUMULATE_STAGES;
    localparam int unsigned SELECT_WIDTH = $clog2(ACCUMULATORS);

    // 4 BF16 lanes of 1.0*1.0 reduce to 4.0; 8 E4M3 lanes reduce to 8.0.
    localparam logic [15:0] BF16_ONE = 16'h3f80;
    localparam logic [7:0]  E4M3_ONE = 8'h38;   // exponent 7 (bias 7), mant 0
    localparam logic [31:0] FP32_FOUR   = 32'h40800000;
    localparam logic [31:0] FP32_EIGHT  = 32'h41000000;
    localparam logic [31:0] FP32_TWELVE = 32'h41400000;
    localparam logic [31:0] FP32_TWO    = 32'h40000000;

    logic                    clk;
    logic                    reset;
    logic                    clear;
    logic                    enable;
    logic                    mode;
    logic [SELECT_WIDTH-1:0] accumulator_select;
    logic [15:0]             a [0:MULTIPLIERS-1];
    logic [15:0]             b [0:MULTIPLIERS-1];
    logic                    external_select;
    logic [31:0]             external_operand;
    logic [31:0]             chain_out;
    logic [31:0]             accumulator;
    int                      failures = 0;

    bf16_multi_mac_tree #(
        .MULTIPLIERS          (MULTIPLIERS),
        .ACCUMULATORS         (ACCUMULATORS),
        .REDUCTION_GUARD_BITS (4),
        .FP8_ENABLE           (1),
        .EXTERNAL_ACCUMULATE  (1),
        .PIPELINE_STAGES      (PIPELINE_STAGES),
        .ACCUMULATE_STAGES    (ACCUMULATE_STAGES)
    ) dut (.*);

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // Drive all lanes with 1.0 in the requested format.
    task automatic load_ones(input bit fp8);
        for (int i = 0; i < MULTIPLIERS; i++) begin
            a[i] = fp8 ? {E4M3_ONE, E4M3_ONE} : BF16_ONE;
            b[i] = fp8 ? {E4M3_ONE, E4M3_ONE} : BF16_ONE;
        end
    endtask

    // Issue one operation on the next cycle without waiting for it to retire.
    task automatic issue(input bit fp8,
                         input logic [SELECT_WIDTH-1:0] select);
        @(negedge clk);
        load_ones(fp8);
        mode               = fp8;
        external_select    = 1'b0;
        accumulator_select = select;
        enable             = 1'b1;
        @(posedge clk);
    endtask

    // Issue an external accumulate on the next cycle.
    task automatic issue_external(input logic [31:0] value,
                                  input logic [SELECT_WIDTH-1:0] select);
        @(negedge clk);
        external_operand   = value;
        external_select    = 1'b1;
        accumulator_select = select;
        enable             = 1'b1;
        @(posedge clk);
    endtask

    task automatic pulse_clear();
        @(negedge clk);
        clear = 1'b1;
        @(posedge clk);
        @(negedge clk);
        clear = 1'b0;
    endtask

    task automatic drain();
        @(negedge clk);
        enable = 1'b0;
        repeat (LATENCY + 1) @(posedge clk);
        @(negedge clk);
    endtask

    task automatic expect_acc(input logic [SELECT_WIDTH-1:0] select,
                              input logic [31:0]             expected,
                              input string                   test_name);
        accumulator_select = select;
        #1;
        if (accumulator !== expected) begin
            $error("%s: acc[%0d] expected 0x%08h, got 0x%08h",
                   test_name, select, expected, accumulator);
            failures++;
        end else begin
            $display("PASS: %-34s acc[%0d]=0x%08h",
                     test_name, select, accumulator);
        end
    endtask

    initial begin
        reset              = 1'b1;
        clear              = 1'b0;
        enable             = 1'b0;
        mode               = 1'b0;
        external_select    = 1'b0;
        external_operand   = 32'b0;
        accumulator_select = '0;
        load_ones(0);

        repeat (2) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        // Single operation in each mode.
        issue(0, 3'd0);
        drain();
        expect_acc(3'd0, FP32_FOUR, "BF16 single (4.0)");

        issue(1, 3'd1);
        drain();
        expect_acc(3'd1, FP32_EIGHT, "E4M3 single (8.0)");

        // Back-to-back issues alternating mode every cycle. Each operation must
        // retire with its own mode, and distinct accumulators keep clear of the
        // in-flight reuse contract.
        issue(0, 3'd2);
        issue(1, 3'd3);
        issue(0, 3'd4);
        issue(1, 3'd5);
        drain();
        expect_acc(3'd2, FP32_FOUR,  "alternating BF16 (4.0)");
        expect_acc(3'd3, FP32_EIGHT, "alternating E4M3 (8.0)");
        expect_acc(3'd4, FP32_FOUR,  "alternating BF16 again (4.0)");
        expect_acc(3'd5, FP32_EIGHT, "alternating E4M3 again (8.0)");

        // Earlier results must be untouched by the later mode changes.
        expect_acc(3'd0, FP32_FOUR,  "BF16 result preserved");
        expect_acc(3'd1, FP32_EIGHT, "E4M3 result preserved");

        // Both modes accumulate into one shared accumulator: 4.0 + 8.0 = 12.0.
        issue(0, 3'd6);
        drain();
        issue(1, 3'd6);
        drain();
        expect_acc(3'd6, FP32_TWELVE, "cross-mode accumulate (12.0)");

        // Unused accumulator stays clear throughout.
        expect_acc(3'd7, 32'h00000000, "untouched accumulator");

        // External accumulates interleaved with tree operations on consecutive
        // cycles. The source select has to travel with each operation, exactly
        // as the format mode does.
        pulse_clear();
        issue(0, 3'd0);                      // BF16 tree -> 4.0
        issue_external(FP32_TWO, 3'd1);      // external  -> 2.0
        issue(1, 3'd2);                      // E4M3 tree -> 8.0
        issue_external(FP32_TWO, 3'd3);      // external  -> 2.0
        drain();
        expect_acc(3'd0, FP32_FOUR,  "interleaved BF16 (4.0)");
        expect_acc(3'd1, FP32_TWO,   "interleaved external (2.0)");
        expect_acc(3'd2, FP32_EIGHT, "interleaved E4M3 (8.0)");
        expect_acc(3'd3, FP32_TWO,   "interleaved external again (2.0)");

        // An external accumulate folds into an existing accumulator value.
        issue_external(FP32_TWO, 3'd0);
        drain();
        expect_acc(3'd0, 32'h40c00000, "external onto BF16 result (6.0)");

        if (failures == 0) begin
            $display("\nBF16 MULTI-MAC TREE MODE TEST PASSED");
            $finish;
        end
        $fatal(1, "BF16 MULTI-MAC TREE MODE TEST FAILED with %0d failure(s)",
               failures);
    end

    initial begin
        #20000;
        $fatal(1, "BF16 MULTI-MAC TREE MODE TEST FAILED: timeout");
    end
endmodule
