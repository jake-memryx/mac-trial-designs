`timescale 1ns/1ps

module bf16_mac_tb;
    logic        clk;
    logic        reset;
    logic        clear;
    logic        enable;
    logic [15:0] a;
    logic [15:0] b;
    logic [31:0] accumulator;
    int          failures = 0;

    bf16_mac dut (.*);

    initial clk = 1'b0;
    always #5 clk = ~clk;

    task automatic mac(input logic [15:0] operand_a,
                       input logic [15:0] operand_b);
        @(negedge clk);
        a      = operand_a;
        b      = operand_b;
        enable = 1'b1;
        @(posedge clk);
        @(negedge clk);
        enable = 1'b0;
    endtask

    task automatic expect_acc(input logic [31:0] expected,
                              input string       test_name);
        if (accumulator !== expected) begin
            $error("%s: expected 0x%08h, got 0x%08h",
                   test_name, expected, accumulator);
            failures++;
        end else begin
            $display("PASS: %-28s accumulator=0x%08h",
                     test_name, accumulator);
        end
    endtask

    task automatic clear_accumulator;
        @(negedge clk);
        clear = 1'b1;
        @(posedge clk);
        @(negedge clk);
        clear = 1'b0;
    endtask

    initial begin
        reset  = 1'b1;
        clear  = 1'b0;
        enable = 1'b0;
        a      = 16'b0;
        b      = 16'b0;

        repeat (2) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;
        expect_acc(32'h00000000, "reset");

        // 1*2 + 3*4 - 2*4 = 6.
        mac(16'h3f80, 16'h4000); // 1.0 * 2.0
        expect_acc(32'h40000000, "1 * 2");
        mac(16'h4040, 16'h4080); // 3.0 * 4.0
        expect_acc(32'h41600000, "+ 3 * 4");
        mac(16'hc000, 16'h4080); // -2.0 * 4.0
        expect_acc(32'h40c00000, "+ -2 * 4");

        clear_accumulator();
        expect_acc(32'h00000000, "clear");

        mac(16'h3fc0, 16'h4000); // 1.5 * 2.0
        expect_acc(32'h40400000, "fractional product");
        mac(16'h3f00, 16'h3f00); // +0.5 * 0.5
        expect_acc(32'h40500000, "fractional accumulation");

        // A half-ULP tie at 1.0 rounds to the even mantissa (1.0).
        clear_accumulator();
        mac(16'h3f80, 16'h3f80); // 1.0
        mac(16'h3f80, 16'h3380); // +2^-24
        expect_acc(32'h3f800000, "ties-to-even rounding");
        mac(16'h3f80, 16'h3400); // +2^-23
        expect_acc(32'h3f800001, "one ULP addition");

        // BF16 subnormal operands are intentionally flushed to zero.
        mac(16'h0001, 16'h3f80);
        expect_acc(32'h3f800001, "subnormal flush-to-zero");

        // Exercise infinity and invalid infinity cancellation.
        clear_accumulator();
        mac(16'h7f80, 16'h3f80);
        expect_acc(32'h7f800000, "positive infinity");
        mac(16'hff80, 16'h3f80);
        expect_acc(32'h7fc00000, "infinity cancellation NaN");

        if (failures == 0) begin
            $display("\nBF16 MAC TEST PASSED");
            $finish;
        end
        $fatal(1, "BF16 MAC TEST FAILED with %0d failure(s)", failures);
    end

    initial begin
        #5000;
        $fatal(1, "BF16 MAC TEST FAILED: timeout");
    end
endmodule

