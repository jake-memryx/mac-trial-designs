`timescale 1ns/1ps

// Override at compile time with -define ACCUMULATE_STAGES=<0|1|2> to run the
// same directed checks against a pipelined accumulate loop.
`ifndef ACCUMULATE_STAGES
`define ACCUMULATE_STAGES 0
`endif

module bf16_multi_mac_tree_tb;
    localparam int unsigned MULTIPLIERS = 4;
    localparam int unsigned ACCUMULATORS = 2;
    localparam int unsigned PIPELINE_STAGES = 0;
    localparam int unsigned ACCUMULATE_STAGES = `ACCUMULATE_STAGES;
    localparam int unsigned LATENCY = PIPELINE_STAGES + ACCUMULATE_STAGES;
    localparam int unsigned SELECT_WIDTH = $clog2(ACCUMULATORS);

    logic                    clk;
    logic                    reset;
    logic                    clear;
    logic                    enable;
    logic                    mode;
    logic [SELECT_WIDTH-1:0] accumulator_select;
    logic [15:0]             a [0:MULTIPLIERS-1];
    logic [15:0]             b [0:MULTIPLIERS-1];
    logic [31:0]             accumulator;
    int                      failures = 0;

    bf16_multi_mac_tree #(
        .MULTIPLIERS          (MULTIPLIERS),
        .ACCUMULATORS         (ACCUMULATORS),
        .REDUCTION_GUARD_BITS (4),
        .PIPELINE_STAGES      (PIPELINE_STAGES),
        .ACCUMULATE_STAGES    (ACCUMULATE_STAGES)
    ) dut (.*);

    initial clk = 1'b0;
    always #5 clk = ~clk;

    task automatic run_tree_mac(input logic [SELECT_WIDTH-1:0] select);
        @(negedge clk);
        accumulator_select = select;
        enable             = 1'b1;
        @(posedge clk);
        @(negedge clk);
        enable = 1'b0;
        // Let the accumulate pipeline commit before the value is inspected.
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

    initial begin
        reset              = 1'b1;
        clear              = 1'b0;
        enable             = 1'b0;
        mode               = 1'b0;
        accumulator_select = '0;
        for (int i = 0; i < MULTIPLIERS; i++) begin
            a[i] = '0;
            b[i] = '0;
        end

        repeat (2) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;
        expect_acc(1'd0, 32'h00000000, "reset accumulator 0");
        expect_acc(1'd1, 32'h00000000, "reset accumulator 1");

        // Tree: (1*2 + 3*4) + (-2*4 + 0.5*0.5) = 6.25.
        a[0] = 16'h3f80; b[0] = 16'h4000;
        a[1] = 16'h4040; b[1] = 16'h4080;
        a[2] = 16'hc000; b[2] = 16'h4080;
        a[3] = 16'h3f00; b[3] = 16'h3f00;
        run_tree_mac(1'd0);
        expect_acc(1'd0, 32'h40c80000, "four-product reduction");
        expect_acc(1'd1, 32'h00000000, "destination isolation");

        // Four products of one accumulate to four in accumulator 1.
        for (int i = 0; i < MULTIPLIERS; i++) begin
            a[i] = 16'h3f80;
            b[i] = 16'h3f80;
        end
        run_tree_mac(1'd1);
        expect_acc(1'd0, 32'h40c80000, "accumulator 0 preserved");
        expect_acc(1'd1, 32'h40800000, "select accumulator 1");

        // Four 0.5*0.5 products reduce to one, then accumulate: 6.25+1=7.25.
        for (int i = 0; i < MULTIPLIERS; i++) begin
            a[i] = 16'h3f00;
            b[i] = 16'h3f00;
        end
        run_tree_mac(1'd0);
        expect_acc(1'd0, 32'h40e80000, "add tree sum to prior acc");
        expect_acc(1'd1, 32'h40800000, "second accumulator held");

        // Enable low must leave the selected accumulator unchanged.
        @(negedge clk);
        accumulator_select = 1'd1;
        for (int i = 0; i < MULTIPLIERS; i++) begin
            a[i] = 16'h42c8;
            b[i] = 16'h42c8;
        end
        enable = 1'b0;
        repeat (LATENCY + 1) @(posedge clk);
        @(negedge clk);
        expect_acc(1'd1, 32'h40800000, "enable holds accumulator");

        // The block reduction keeps a 16-bit product significand plus four
        // guard bits. A product 20 exponents below the maximum is therefore
        // intentionally truncated: 1.0 + 2^-20 reduces to 1.0 here.
        clear = 1'b1;
        @(posedge clk);
        @(negedge clk);
        clear = 1'b0;
        a[0] = 16'h3f80; b[0] = 16'h3f80; // 1.0
        a[1] = 16'h3580; b[1] = 16'h3f80; // 2^-20
        a[2] = 16'h0000; b[2] = 16'h0000;
        a[3] = 16'h0000; b[3] = 16'h0000;
        run_tree_mac(1'd0);
        expect_acc(1'd0, 32'h3f800000, "guard-window truncation");

        clear = 1'b1;
        @(posedge clk);
        @(negedge clk);
        clear = 1'b0;
        expect_acc(1'd0, 32'h00000000, "clear accumulator 0");
        expect_acc(1'd1, 32'h00000000, "clear accumulator 1");

        if (failures == 0) begin
            $display("\nBF16 MULTI-MAC TREE TEST PASSED");
            $finish;
        end
        $fatal(1, "BF16 MULTI-MAC TREE TEST FAILED with %0d failure(s)",
               failures);
    end

    initial begin
        #5000;
        $fatal(1, "BF16 MULTI-MAC TREE TEST FAILED: timeout");
    end
endmodule
