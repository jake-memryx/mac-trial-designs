`timescale 1ns/1ps

module bf16_mama_tb;
    localparam int unsigned MAMS = 2;
    localparam int unsigned ACCUMULATORS_PER_MAM = 2;
    localparam int unsigned SELECT_WIDTH = $clog2(ACCUMULATORS_PER_MAM);

    logic                         clk;
    logic                         reset;
    logic                         clear;
    logic [MAMS-1:0]              enable;
    logic [SELECT_WIDTH-1:0]      accumulator_select [0:MAMS-1];
    logic [15:0]                  a                  [0:MAMS-1];
    logic [15:0]                  b                  [0:MAMS-1];
    logic [31:0]                  accumulator        [0:MAMS-1];
    int                           failures = 0;

    bf16_mama #(
        .MAMS                 (MAMS),
        .ACCUMULATORS_PER_MAM (ACCUMULATORS_PER_MAM)
    ) dut (.*);

    initial clk = 1'b0;
    always #5 clk = ~clk;

    task automatic mac(input int                          mam,
                       input logic [SELECT_WIDTH-1:0]      select,
                       input logic [15:0]                  operand_a,
                       input logic [15:0]                  operand_b);
        @(negedge clk);
        accumulator_select[mam] = select;
        a[mam]                   = operand_a;
        b[mam]                   = operand_b;
        enable[mam]              = 1'b1;
        @(posedge clk);
        @(negedge clk);
        enable[mam] = 1'b0;
    endtask

    task automatic expect_acc(input int                     mam,
                              input logic [SELECT_WIDTH-1:0] select,
                              input logic [31:0]             expected,
                              input string                   test_name);
        accumulator_select[mam] = select;
        #1;
        if (accumulator[mam] !== expected) begin
            $error("%s: MAM %0d acc[%0d] expected 0x%08h, got 0x%08h",
                   test_name, mam, select, expected, accumulator[mam]);
            failures++;
        end else begin
            $display("PASS: %-22s MAM[%0d].acc[%0d]=0x%08h",
                     test_name, mam, select, accumulator[mam]);
        end
    endtask

    initial begin
        reset  = 1'b1;
        clear  = 1'b0;
        enable = '0;
        for (int i = 0; i < MAMS; i++) begin
            accumulator_select[i] = '0;
            a[i]                  = '0;
            b[i]                  = '0;
        end

        repeat (2) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        expect_acc(0, 1'd0, 32'h00000000, "reset lane 0");
        expect_acc(1, 1'd0, 32'h00000000, "reset lane 1");

        // Populate independent accumulators in each MAM lane.
        mac(0, 1'd0, 16'h3f80, 16'h4000); // MAM 0 acc 0 = 2
        mac(0, 1'd1, 16'h4040, 16'h4080); // MAM 0 acc 1 = 12
        mac(1, 1'd0, 16'h4000, 16'h4040); // MAM 1 acc 0 = 6
        mac(1, 1'd1, 16'hbf80, 16'h40a0); // MAM 1 acc 1 = -5

        expect_acc(0, 1'd0, 32'h40000000, "lane 0 accumulator 0");
        expect_acc(0, 1'd1, 32'h41400000, "lane 0 accumulator 1");
        expect_acc(1, 1'd0, 32'h40c00000, "lane 1 accumulator 0");
        expect_acc(1, 1'd1, 32'hc0a00000, "lane 1 accumulator 1");

        // Both lanes can commit a MAC on the same clock edge.
        @(negedge clk);
        accumulator_select[0] = 1'd0;
        accumulator_select[1] = 1'd0;
        a[0] = 16'h3f80; b[0] = 16'h3f80; // +1
        a[1] = 16'h4000; b[1] = 16'h4000; // +4
        enable = 2'b11;
        @(posedge clk);
        @(negedge clk);
        enable = '0;

        expect_acc(0, 1'd0, 32'h40400000, "parallel lane 0 MAC");
        expect_acc(1, 1'd0, 32'h41200000, "parallel lane 1 MAC");
        expect_acc(0, 1'd1, 32'h41400000, "parallel isolation 0");
        expect_acc(1, 1'd1, 32'hc0a00000, "parallel isolation 1");

        // Broadcast clear resets every accumulator in every MAM.
        clear = 1'b1;
        @(posedge clk);
        @(negedge clk);
        clear = 1'b0;
        expect_acc(0, 1'd0, 32'h00000000, "clear lane 0 acc 0");
        expect_acc(0, 1'd1, 32'h00000000, "clear lane 0 acc 1");
        expect_acc(1, 1'd0, 32'h00000000, "clear lane 1 acc 0");
        expect_acc(1, 1'd1, 32'h00000000, "clear lane 1 acc 1");

        if (failures == 0) begin
            $display("\nBF16 MAMA TEST PASSED");
            $finish;
        end
        $fatal(1, "BF16 MAMA TEST FAILED with %0d failure(s)", failures);
    end

    initial begin
        #5000;
        $fatal(1, "BF16 MAMA TEST FAILED: timeout");
    end
endmodule

