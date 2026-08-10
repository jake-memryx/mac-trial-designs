`timescale 1ns/1ps

// Two chained TreeMAC units folding a neighbour's accumulator.
//
// The full 512-deep GEMV is split by depth: unit A computes the first half,
// unit B the second. Unit A's registered chain_out (a copy of its accumulator
// 0) drives unit B's external_operand, and B issues a single external
// accumulate to fold it in. Accumulator 0 of unit B must then match the
// full-depth reference, while every other accumulator must still hold only
// B's half - proving the chain moved exactly one value.
module bf16_multi_mac_tree_chain_tb;
    localparam int unsigned MULTIPLIERS  = 8;
    localparam int unsigned ACCUMULATORS = 32;
    localparam int unsigned SELECT_WIDTH = $clog2(ACCUMULATORS);
    localparam int unsigned DEPTH        = 512;
    localparam int unsigned HALF         = DEPTH / 2;
    localparam int unsigned GROUPS       = HALF / MULTIPLIERS;
    localparam int unsigned PIPELINE_STAGES = 2;
    localparam int unsigned ACCUMULATE_STAGES = 2;
    localparam int unsigned LATENCY = PIPELINE_STAGES + ACCUMULATE_STAGES;
    localparam real         SIGMA        = 10.0;
    localparam real         TOLERANCE    = 1.0e-3;

    logic clk;
    logic reset;
    logic clear;

    // Unit A drives the low half of the depth.
    logic                    a_enable, a_mode, a_external_select;
    logic [SELECT_WIDTH-1:0] a_select;
    logic [15:0]             a_a [0:MULTIPLIERS-1];
    logic [15:0]             a_b [0:MULTIPLIERS-1];
    logic [31:0]             a_external_operand;
    logic [31:0]             a_chain_out, a_accumulator;

    // Unit B drives the high half and receives the chain.
    logic                    b_enable, b_mode, b_external_select;
    logic [SELECT_WIDTH-1:0] b_select;
    logic [15:0]             b_a [0:MULTIPLIERS-1];
    logic [15:0]             b_b [0:MULTIPLIERS-1];
    logic [31:0]             b_chain_out, b_accumulator;

    logic [15:0] a_vector [0:DEPTH-1];
    logic [15:0] b_matrix [0:DEPTH-1][0:ACCUMULATORS-1];
    real         reference_low  [0:ACCUMULATORS-1];
    real         reference_high [0:ACCUMULATORS-1];
    real         magnitude      [0:ACCUMULATORS-1];
    int          failures = 0;

    bf16_multi_mac_tree #(
        .MULTIPLIERS          (MULTIPLIERS),
        .ACCUMULATORS         (ACCUMULATORS),
        .REDUCTION_GUARD_BITS (4),
        .EXTERNAL_ACCUMULATE  (1),
        .PIPELINE_STAGES      (PIPELINE_STAGES),
        .ACCUMULATE_STAGES    (ACCUMULATE_STAGES)
    ) unit_a (
        .clk                (clk),
        .reset              (reset),
        .clear              (clear),
        .enable             (a_enable),
        .mode               (a_mode),
        .accumulator_select (a_select),
        .a                  (a_a),
        .b                  (a_b),
        .external_select    (a_external_select),
        .external_operand   (a_external_operand),
        .chain_out          (a_chain_out),
        .accumulator        (a_accumulator)
    );

    // The chain: A's registered accumulator 0 feeds B's external operand.
    bf16_multi_mac_tree #(
        .MULTIPLIERS          (MULTIPLIERS),
        .ACCUMULATORS         (ACCUMULATORS),
        .REDUCTION_GUARD_BITS (4),
        .EXTERNAL_ACCUMULATE  (1),
        .PIPELINE_STAGES      (PIPELINE_STAGES),
        .ACCUMULATE_STAGES    (ACCUMULATE_STAGES)
    ) unit_b (
        .clk                (clk),
        .reset              (reset),
        .clear              (clear),
        .enable             (b_enable),
        .mode               (b_mode),
        .accumulator_select (b_select),
        .a                  (b_a),
        .b                  (b_b),
        .external_select    (b_external_select),
        .external_operand   (a_chain_out),
        .chain_out          (b_chain_out),
        .accumulator        (b_accumulator)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    function automatic logic [15:0] real_to_bf16(input real value);
        logic [31:0] bits;
        logic [15:0] truncated;
        bits      = $shortrealtobits(shortreal'(value));
        truncated = bits[31:16];
        if (bits[15] && (|bits[14:0] || bits[16]))
            truncated = truncated + 16'b1;
        return truncated;
    endfunction

    function automatic real bf16_to_real(input logic [15:0] value);
        return $bitstoshortreal({value, 16'b0});
    endfunction

    function automatic real normal_sample();
        real uniform_a;
        real uniform_b;
        uniform_a = (real'($urandom()) + 1.0) / 4294967297.0;
        uniform_b = (real'($urandom()) + 1.0) / 4294967297.0;
        return SIGMA * $sqrt(-2.0 * $ln(uniform_a)) *
               $cos(2.0 * 3.14159265358979323846 * uniform_b);
    endfunction

    task automatic build_stimulus();
        real a_real, b_real, term;
        for (int j = 0; j < ACCUMULATORS; j++) begin
            reference_low[j]  = 0.0;
            reference_high[j] = 0.0;
            magnitude[j]      = 0.0;
        end
        for (int k = 0; k < DEPTH; k++) begin
            a_vector[k] = real_to_bf16(normal_sample());
            a_real      = bf16_to_real(a_vector[k]);
            for (int j = 0; j < ACCUMULATORS; j++) begin
                b_matrix[k][j] = real_to_bf16(normal_sample());
                b_real         = bf16_to_real(b_matrix[k][j]);
                term           = a_real * b_real;
                if (k < HALF)
                    reference_low[j] = reference_low[j] + term;
                else
                    reference_high[j] = reference_high[j] + term;
                magnitude[j] = magnitude[j] + (term >= 0.0 ? term : -term);
            end
        end
    endtask

    task automatic check(input string          name,
                         input int             column,
                         input real            expected,
                         input logic [31:0]    observed);
        real value, error;
        value = $bitstoshortreal(observed);
        error = value - expected;
        if (error < 0.0)
            error = -error;
        if (error > TOLERANCE * magnitude[column]) begin
            $error("%s C[%0d]: expected %f, got %f (error %f > %f)",
                   name, column, expected, value, error,
                   TOLERANCE * magnitude[column]);
            failures++;
        end
    endtask

    initial begin
        reset              = 1'b1;
        clear              = 1'b0;
        a_enable           = 1'b0;
        b_enable           = 1'b0;
        a_mode             = 1'b0;
        b_mode             = 1'b0;
        a_external_select  = 1'b0;
        b_external_select  = 1'b0;
        a_external_operand = 32'b0;
        a_select           = '0;
        b_select           = '0;
        for (int i = 0; i < MULTIPLIERS; i++) begin
            a_a[i] = '0; a_b[i] = '0;
            b_a[i] = '0; b_b[i] = '0;
        end
        build_stimulus();

        repeat (2) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        // Both units run their half of the depth concurrently, round-robin
        // over the 32 output columns.
        for (int g = 0; g < GROUPS; g++) begin
            for (int j = 0; j < ACCUMULATORS; j++) begin
                @(negedge clk);
                for (int i = 0; i < MULTIPLIERS; i++) begin
                    a_a[i] = a_vector[g*MULTIPLIERS + i];
                    a_b[i] = b_matrix[g*MULTIPLIERS + i][j];
                    b_a[i] = a_vector[HALF + g*MULTIPLIERS + i];
                    b_b[i] = b_matrix[HALF + g*MULTIPLIERS + i][j];
                end
                a_select = j[SELECT_WIDTH-1:0];
                b_select = j[SELECT_WIDTH-1:0];
                a_enable = 1'b1;
                b_enable = 1'b1;
                @(posedge clk);
            end
        end

        @(negedge clk);
        a_enable = 1'b0;
        b_enable = 1'b0;
        repeat (LATENCY + 1) @(posedge clk);
        @(negedge clk);

        // Each unit holds its own partial sums.
        for (int j = 0; j < ACCUMULATORS; j++) begin
            a_select = j[SELECT_WIDTH-1:0];
            b_select = j[SELECT_WIDTH-1:0];
            #1;
            check("unit A partial", j, reference_low[j],  a_accumulator);
            check("unit B partial", j, reference_high[j], b_accumulator);
        end
        $display("PASS: both units hold their depth half");

        // Fold A's accumulator 0 into B with one external accumulate.
        @(negedge clk);
        b_select          = '0;
        b_external_select = 1'b1;
        b_enable          = 1'b1;
        @(posedge clk);
        @(negedge clk);
        b_enable          = 1'b0;
        b_external_select = 1'b0;
        repeat (LATENCY + 1) @(posedge clk);
        @(negedge clk);

        // Accumulator 0 is now the full-depth dot product.
        b_select = '0;
        #1;
        check("chained", 0, reference_low[0] + reference_high[0], b_accumulator);
        $display("PASS: accumulator 0 folded across units");

        // Every other accumulator must be untouched by the chain.
        for (int j = 1; j < ACCUMULATORS; j++) begin
            b_select = j[SELECT_WIDTH-1:0];
            #1;
            check("unchained", j, reference_high[j], b_accumulator);
        end
        $display("PASS: other accumulators untouched by the chain");

        // Unit A must be unchanged by having been read.
        a_select = '0;
        #1;
        check("source intact", 0, reference_low[0], a_accumulator);
        $display("PASS: source accumulator intact");

        if (failures == 0) begin
            $display("\nBF16 MULTI-MAC TREE CHAIN TEST PASSED (2 units, %0d deep)",
                     DEPTH);
            $finish;
        end
        $fatal(1, "BF16 MULTI-MAC TREE CHAIN TEST FAILED with %0d failure(s)",
               failures);
    end

    initial begin
        #500000;
        $fatal(1, "BF16 MULTI-MAC TREE CHAIN TEST FAILED: timeout");
    end
endmodule
