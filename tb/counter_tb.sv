`timescale 1ns/1ps

module counter_tb;
    logic       clk;
    logic       reset;
    logic       enable;
    logic [7:0] count;

    int failures = 0;

    counter8 dut (
        .clk    (clk),
        .reset  (reset),
        .enable (enable),
        .count  (count)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    task automatic expect_count(input logic [7:0] expected,
                                input string      test_name);
        if (count !== expected) begin
            $error("%s: expected count=0x%02h, got 0x%02h",
                   test_name, expected, count);
            failures++;
        end else begin
            $display("PASS: %-24s count=0x%02h", test_name, count);
        end
    endtask

    initial begin
        reset  = 1'b1;
        enable = 1'b0;

        // Reset the counter.
        repeat (2) @(posedge clk);
        @(negedge clk);
        expect_count(8'h00, "synchronous reset");

        // Count ten enabled clock cycles.
        reset  = 1'b0;
        enable = 1'b1;
        repeat (10) @(posedge clk);
        @(negedge clk);
        expect_count(8'd10, "enabled counting");

        // Disable counting and verify that the register holds its value.
        enable = 1'b0;
        repeat (4) @(posedge clk);
        @(negedge clk);
        expect_count(8'd10, "enable low holds count");

        // Resume for 246 cycles: 10 + 246 = 256, which wraps to zero.
        enable = 1'b1;
        repeat (246) @(posedge clk);
        @(negedge clk);
        expect_count(8'h00, "eight-bit wraparound");

        // Confirm that reset wins when reset and enable are both asserted.
        reset = 1'b1;
        repeat (1) @(posedge clk);
        @(negedge clk);
        expect_count(8'h00, "reset priority");

        if (failures == 0) begin
            $display("\nTEST PASSED");
            $finish;
        end

        $fatal(1, "TEST FAILED with %0d failure(s)", failures);
    end

    // A hung simulation should fail instead of running indefinitely.
    initial begin
        #5000;
        $fatal(1, "TEST FAILED: timeout");
    end

endmodule

