`timescale 1ns/1ps

// Directed tests for the dual-lane tree MAC. ACCUMULATORS=4 with LANES=2 puts
// accumulators 0 and 1 in lane 0 and accumulators 2 and 3 in lane 1, so
// selects 0 and 2 exercise the two independent trees.
module bf16_dual_mac_tree_tb;
    localparam int unsigned MULTIPLIERS  = 4;
    localparam int unsigned ACCUMULATORS = 4;
    localparam int unsigned LANES        = 2;
    localparam int unsigned LANE_CYCLES  = 2;
    localparam int unsigned PIPELINE_STAGES = 0;
    localparam int unsigned ACCUMULATE_STAGES = 1;
    localparam int unsigned SELECT_WIDTH = $clog2(ACCUMULATORS);
    localparam int unsigned LATENCY      = LANE_CYCLES * (PIPELINE_STAGES + 1);

    logic                    clk;
    logic                    reset;
    logic                    clear;
    logic                    enable;
    logic [SELECT_WIDTH-1:0] accumulator_select;
    logic [15:0]             a [0:MULTIPLIERS-1];
    logic [15:0]             b [0:MULTIPLIERS-1];
    logic [31:0]             accumulator;
    int                      failures = 0;

    bf16_dual_mac_tree #(
        .MULTIPLIERS          (MULTIPLIERS),
        .ACCUMULATORS         (ACCUMULATORS),
        .LANES                (LANES),
        .REDUCTION_GUARD_BITS (4),
        .PIPELINE_STAGES      (PIPELINE_STAGES),
        .LANE_CYCLES          (LANE_CYCLES),
        .ACCUMULATE_STAGES    (ACCUMULATE_STAGES)
    ) dut (.*);

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // Issue one operation and wait for it to reach the accumulator bank.
    task automatic run_tree_mac(input logic [SELECT_WIDTH-1:0] select);
        @(negedge clk);
        accumulator_select = select;
        enable             = 1'b1;
        @(posedge clk);
        @(negedge clk);
        enable = 1'b0;
        repeat (LATENCY) @(posedge clk);
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
            $display("PASS: %-25s acc[%0d]=0x%08h",
                     test_name, select, accumulator);
        end
    endtask

    task automatic pulse_clear();
        clear = 1'b1;
        @(posedge clk);
        @(negedge clk);
        clear = 1'b0;
    endtask

    initial begin
        reset              = 1'b1;
        clear              = 1'b0;
        enable             = 1'b0;
        accumulator_select = '0;
        for (int i = 0; i < MULTIPLIERS; i++) begin
            a[i] = '0;
            b[i] = '0;
        end

        repeat (2) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;
        expect_acc(2'd0, 32'h00000000, "reset accumulator 0");
        expect_acc(2'd2, 32'h00000000, "reset accumulator 2");

        // Tree: (1*2 + 3*4) + (-2*4 + 0.5*0.5) = 6.25.
        a[0] = 16'h3f80; b[0] = 16'h4000;
        a[1] = 16'h4040; b[1] = 16'h4080;
        a[2] = 16'hc000; b[2] = 16'h4080;
        a[3] = 16'h3f00; b[3] = 16'h3f00;
        run_tree_mac(2'd0);
        expect_acc(2'd0, 32'h40c80000, "lane 0 reduction");
        expect_acc(2'd1, 32'h00000000, "same-lane isolation");
        expect_acc(2'd2, 32'h00000000, "cross-lane isolation");

        // Four products of one accumulate to four in accumulator 2 (lane 1).
        for (int i = 0; i < MULTIPLIERS; i++) begin
            a[i] = 16'h3f80;
            b[i] = 16'h3f80;
        end
        run_tree_mac(2'd2);
        expect_acc(2'd0, 32'h40c80000, "accumulator 0 preserved");
        expect_acc(2'd2, 32'h40800000, "lane 1 reduction");

        // Four 0.5*0.5 products reduce to one, then accumulate: 6.25+1=7.25.
        for (int i = 0; i < MULTIPLIERS; i++) begin
            a[i] = 16'h3f00;
            b[i] = 16'h3f00;
        end
        run_tree_mac(2'd0);
        expect_acc(2'd0, 32'h40e80000, "add tree sum to prior acc");
        expect_acc(2'd2, 32'h40800000, "lane 1 accumulator held");

        // Enable low must leave the selected accumulator unchanged.
        @(negedge clk);
        accumulator_select = 2'd2;
        for (int i = 0; i < MULTIPLIERS; i++) begin
            a[i] = 16'h42c8;
            b[i] = 16'h42c8;
        end
        enable = 1'b0;
        repeat (LATENCY + 1) @(posedge clk);
        @(negedge clk);
        expect_acc(2'd2, 32'h40800000, "enable holds accumulator");

        // Full-rate issue: alternating lanes every cycle must retire every
        // operation even though each lane is a LANE_CYCLES-cycle path.
        pulse_clear();
        for (int i = 0; i < MULTIPLIERS; i++) begin
            a[i] = 16'h3f80;
            b[i] = 16'h3f80;
        end
        for (int n = 0; n < 4; n++) begin
            @(negedge clk);
            accumulator_select = (n % 2 == 0) ? 2'd0 : 2'd2;
            enable             = 1'b1;
            @(posedge clk);
        end
        @(negedge clk);
        enable = 1'b0;
        repeat (LATENCY) @(posedge clk);
        @(negedge clk);
        expect_acc(2'd0, 32'h41000000, "back-to-back lane 0 (8.0)");
        expect_acc(2'd2, 32'h41000000, "back-to-back lane 1 (8.0)");

        // The block reduction keeps a 16-bit product significand plus four
        // guard bits. A product 20 exponents below the maximum is therefore
        // intentionally truncated: 1.0 + 2^-20 reduces to 1.0 here.
        pulse_clear();
        a[0] = 16'h3f80; b[0] = 16'h3f80; // 1.0
        a[1] = 16'h3580; b[1] = 16'h3f80; // 2^-20
        a[2] = 16'h0000; b[2] = 16'h0000;
        a[3] = 16'h0000; b[3] = 16'h0000;
        run_tree_mac(2'd0);
        expect_acc(2'd0, 32'h3f800000, "guard-window truncation");

        pulse_clear();
        expect_acc(2'd0, 32'h00000000, "clear accumulator 0");
        expect_acc(2'd2, 32'h00000000, "clear accumulator 2");

        if (failures == 0) begin
            $display("\nBF16 DUAL-MAC TREE TEST PASSED");
            $finish;
        end
        $fatal(1, "BF16 DUAL-MAC TREE TEST FAILED with %0d failure(s)",
               failures);
    end

    initial begin
        #5000;
        $fatal(1, "BF16 DUAL-MAC TREE TEST FAILED: timeout");
    end
endmodule
