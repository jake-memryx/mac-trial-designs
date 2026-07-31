`timescale 1ns/1ps

module bf16_mam_tb;
    localparam int unsigned ACCUMULATORS = 4;
    localparam int unsigned SELECT_WIDTH = $clog2(ACCUMULATORS);

    logic                    clk;
    logic                    reset;
    logic                    clear;
    logic                    enable;
    logic [SELECT_WIDTH-1:0] accumulator_select;
    logic [15:0]             a;
    logic [15:0]             b;
    logic [31:0]             accumulator;
    int                      failures = 0;

    bf16_mam #(
        .ACCUMULATORS (ACCUMULATORS)
    ) dut (.*);

    initial clk = 1'b0;
    always #5 clk = ~clk;

    task automatic mac(input logic [SELECT_WIDTH-1:0] select,
                       input logic [15:0]             operand_a,
                       input logic [15:0]             operand_b);
        @(negedge clk);
        accumulator_select = select;
        a                   = operand_a;
        b                   = operand_b;
        enable              = 1'b1;
        @(posedge clk);
        @(negedge clk);
        enable = 1'b0;
    endtask

    task automatic expect_acc(input logic [SELECT_WIDTH-1:0] select,
                              input logic [31:0]             expected,
                              input string                   test_name);
        accumulator_select = select;
        #1;
        if (accumulator !== expected) begin
            $error("%s: accumulator %0d expected 0x%08h, got 0x%08h",
                   test_name, select, expected, accumulator);
            failures++;
        end else begin
            $display("PASS: %-24s acc[%0d]=0x%08h",
                     test_name, select, accumulator);
        end
    endtask

    initial begin
        reset              = 1'b1;
        clear              = 1'b0;
        enable             = 1'b0;
        accumulator_select = '0;
        a                  = 16'b0;
        b                  = 16'b0;

        repeat (2) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        expect_acc(2'd0, 32'h00000000, "reset accumulator 0");
        expect_acc(2'd1, 32'h00000000, "reset accumulator 1");
        expect_acc(2'd2, 32'h00000000, "reset accumulator 2");
        expect_acc(2'd3, 32'h00000000, "reset accumulator 3");

        // Direct operations to different destinations.
        mac(2'd0, 16'h3f80, 16'h4000); // acc[0] += 1 * 2 = 2
        mac(2'd1, 16'h4040, 16'h4080); // acc[1] += 3 * 4 = 12
        mac(2'd0, 16'h4000, 16'h4000); // acc[0] += 2 * 2 = 6
        mac(2'd3, 16'hbf80, 16'h40a0); // acc[3] += -1 * 5 = -5

        expect_acc(2'd0, 32'h40c00000, "independent accumulation");
        expect_acc(2'd1, 32'h41400000, "selected destination");
        expect_acc(2'd2, 32'h00000000, "untouched accumulator");
        expect_acc(2'd3, 32'hc0a00000, "negative accumulation");

        // With enable low, changing operands and selection must not write.
        @(negedge clk);
        accumulator_select = 2'd1;
        a                   = 16'h42c8; // 100.0
        b                   = 16'h42c8;
        enable              = 1'b0;
        @(posedge clk);
        @(negedge clk);
        expect_acc(2'd1, 32'h41400000, "enable holds bank");

        // Clear resets all accumulators together.
        clear = 1'b1;
        @(posedge clk);
        @(negedge clk);
        clear = 1'b0;
        expect_acc(2'd0, 32'h00000000, "clear accumulator 0");
        expect_acc(2'd1, 32'h00000000, "clear accumulator 1");
        expect_acc(2'd2, 32'h00000000, "clear accumulator 2");
        expect_acc(2'd3, 32'h00000000, "clear accumulator 3");

        if (failures == 0) begin
            $display("\nMULTI-ACCUMULATOR BF16 MAC TEST PASSED");
            $finish;
        end
        $fatal(1, "MULTI-ACCUMULATOR BF16 MAC TEST FAILED with %0d failure(s)",
               failures);
    end

    initial begin
        #5000;
        $fatal(1, "MULTI-ACCUMULATOR BF16 MAC TEST FAILED: timeout");
    end
endmodule
