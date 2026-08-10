`timescale 1ns/1ps

// Override at compile time with -define PIPELINE_STAGES=<0|1|2>.
`ifndef PIPELINE_STAGES
`define PIPELINE_STAGES 0
`endif

// Override at compile time with -define ACCUMULATE_STAGES=<0|1|2>.
`ifndef ACCUMULATE_STAGES
`define ACCUMULATE_STAGES 0
`endif

// Override with -define FP8_ENABLE=1 to exercise BF16 mode on the dual-format
// build, which is also how the BF16-mode power dump is taken.
`ifndef FP8_ENABLE
`define FP8_ENABLE 0
`endif

// C[32] = A[1024] x B[1024][32] on a tree MAC with 8 multipliers and 32
// accumulators. Eight A elements are held stationary while 32 cycles walk the
// output columns: cycle j reduces the eight products A[k+i]*B[k+i][j] and folds
// the result into accumulator j. Each group of eight A elements therefore takes
// 32 cycles, and 128 groups cover the full 1024-deep dot products.
module bf16_multi_mac_tree_gemv_tb;
    localparam int unsigned MULTIPLIERS  = 8;
    localparam int unsigned ACCUMULATORS = 32;
    localparam int unsigned SELECT_WIDTH = $clog2(ACCUMULATORS);
    localparam int unsigned DEPTH        = 1024;
    localparam int unsigned GROUPS       = DEPTH / MULTIPLIERS;
    localparam int unsigned PIPELINE_STAGES = `PIPELINE_STAGES;
    localparam int unsigned ACCUMULATE_STAGES = `ACCUMULATE_STAGES;
    localparam int unsigned LATENCY = PIPELINE_STAGES + ACCUMULATE_STAGES;
    localparam real         SIGMA        = 10.0;
    localparam real         TOLERANCE    = 1.0e-3;

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

    logic [15:0] a_vector [0:DEPTH-1];
    logic [15:0] b_matrix [0:DEPTH-1][0:ACCUMULATORS-1];
    real         reference [0:ACCUMULATORS-1];
    real         magnitude [0:ACCUMULATORS-1];
    int          failures = 0;

    bf16_multi_mac_tree #(
        .MULTIPLIERS          (MULTIPLIERS),
        .ACCUMULATORS         (ACCUMULATORS),
        .REDUCTION_GUARD_BITS (4),
        .FP8_ENABLE           (`FP8_ENABLE),
        .PIPELINE_STAGES      (PIPELINE_STAGES),
        .ACCUMULATE_STAGES    (ACCUMULATE_STAGES)
    ) dut (.*);

    // Clock period in ns, overridable with +period=<ns> so a switching-activity
    // dump can be taken at the same frequency the netlist is constrained to.
    function automatic real plusarg_half_period();
        real period;
        if ($value$plusargs("period=%f", period))
            return period / 2.0;
        return 5.0;
    endfunction

    real clock_half_period = plusarg_half_period();

    initial clk = 1'b0;
    always #(clock_half_period) clk = ~clk;

    // Optional switching-activity dump for power analysis (+dump_vcd).
    initial begin
        if ($test$plusargs("dump_vcd")) begin
            $dumpfile($sformatf(
                "build/vcd/bf16_multi_mac_tree_gemv%s_p%0da%0d_%0dps.vcd",
                (`FP8_ENABLE) ? "_dual" : "",
                PIPELINE_STAGES, ACCUMULATE_STAGES,
                int'(clock_half_period * 2000.0)));
            $dumpvars(0, dut);
        end
    end

    // Round an FP32 value to BF16 with round-to-nearest, ties-to-even.
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

    // Box-Muller transform: zero-mean normal samples with standard deviation
    // SIGMA, built from two uniform (0,1) draws.
    function automatic real normal_sample();
        real uniform_a;
        real uniform_b;
        uniform_a = (real'($urandom()) + 1.0) / 4294967297.0;
        uniform_b = (real'($urandom()) + 1.0) / 4294967297.0;
        return SIGMA * $sqrt(-2.0 * $ln(uniform_a)) *
               $cos(2.0 * 3.14159265358979323846 * uniform_b);
    endfunction

    task automatic build_stimulus();
        real a_real;
        real b_real;
        real term;
        for (int j = 0; j < ACCUMULATORS; j++) begin
            reference[j] = 0.0;
            magnitude[j] = 0.0;
        end
        for (int k = 0; k < DEPTH; k++) begin
            a_vector[k] = real_to_bf16(normal_sample());
            a_real      = bf16_to_real(a_vector[k]);
            for (int j = 0; j < ACCUMULATORS; j++) begin
                b_matrix[k][j] = real_to_bf16(normal_sample());
                b_real         = bf16_to_real(b_matrix[k][j]);
                term           = a_real * b_real;
                reference[j]   = reference[j] + term;
                magnitude[j]   = magnitude[j] + (term >= 0.0 ? term : -term);
            end
        end
    endtask

    task automatic check_column(input int          column,
                                input logic [31:0] observed);
        real value;
        real error;
        value = $bitstoshortreal(observed);
        error = value - reference[column];
        if (error < 0.0)
            error = -error;
        if (error > TOLERANCE * magnitude[column]) begin
            $error("C[%0d]: expected %f, got %f (error %f > %f)",
                   column, reference[column], value, error,
                   TOLERANCE * magnitude[column]);
            failures++;
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
        for (int i = 0; i < MULTIPLIERS; i++) begin
            a[i] = '0;
            b[i] = '0;
        end
        build_stimulus();

        repeat (2) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        // A-stationary: load eight A elements, then sweep all 32 columns.
        for (int g = 0; g < GROUPS; g++) begin
            for (int j = 0; j < ACCUMULATORS; j++) begin
                @(negedge clk);
                for (int i = 0; i < MULTIPLIERS; i++) begin
                    a[i] = a_vector[g*MULTIPLIERS + i];
                    b[i] = b_matrix[g*MULTIPLIERS + i][j];
                end
                accumulator_select = j[SELECT_WIDTH-1:0];
                enable             = 1'b1;
                @(posedge clk);
            end
        end

        @(negedge clk);
        enable = 1'b0;

        // Drain the product and accumulate pipelines before reading out.
        repeat (LATENCY + 1) @(posedge clk);
        @(negedge clk);

        for (int j = 0; j < ACCUMULATORS; j++) begin
            accumulator_select = j[SELECT_WIDTH-1:0];
            #1;
            check_column(j, accumulator);
        end

        if (failures == 0) begin
            $display("\nBF16 MULTI-MAC TREE GEMV TEST PASSED (%0dx%0d dot products)",
                     DEPTH, ACCUMULATORS);
            $finish;
        end
        $fatal(1, "BF16 MULTI-MAC TREE GEMV TEST FAILED with %0d failure(s)",
               failures);
    end

    initial begin
        #500000;
        $fatal(1, "BF16 MULTI-MAC TREE GEMV TEST FAILED: timeout");
    end
endmodule
