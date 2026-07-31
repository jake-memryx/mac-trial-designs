`timescale 1ns/1ps

// C[32] = A[1024] x B[1024][32] on a 8-MAM x 4-accumulator MAMA (32
// accumulators). One A element is broadcast to all eight MAMs; each MAM owns
// four output columns. Every A element therefore takes four cycles, one per
// accumulator select, to fold into all 32 partial sums.
module bf16_mama_gemv_tb;
    localparam int unsigned MAMS                 = 8;
    localparam int unsigned ACCUMULATORS_PER_MAM = 4;
    localparam int unsigned SELECT_WIDTH         = $clog2(ACCUMULATORS_PER_MAM);
    localparam int unsigned COLUMNS              = MAMS * ACCUMULATORS_PER_MAM;
    localparam int unsigned DEPTH                = 1024;
    localparam real         SIGMA                = 10.0;
    localparam real         TOLERANCE            = 1.0e-3;

    logic                    clk;
    logic                    reset;
    logic                    clear;
    logic [MAMS-1:0]         enable;
    logic [SELECT_WIDTH-1:0] accumulator_select [0:MAMS-1];
    logic [15:0]             a                  [0:MAMS-1];
    logic [15:0]             b                  [0:MAMS-1];
    logic [31:0]             accumulator        [0:MAMS-1];

    logic [15:0] a_vector [0:DEPTH-1];
    logic [15:0] b_matrix [0:DEPTH-1][0:COLUMNS-1];
    real         reference [0:COLUMNS-1];
    real         magnitude [0:COLUMNS-1];
    int          failures = 0;

    bf16_mama #(
        .MAMS                 (MAMS),
        .ACCUMULATORS_PER_MAM (ACCUMULATORS_PER_MAM)
    ) dut (.*);

    initial clk = 1'b0;
    always #5 clk = ~clk;

    // Optional switching-activity dump for power analysis (+dump_vcd).
    initial begin
        if ($test$plusargs("dump_vcd")) begin
            $dumpfile("build/vcd/bf16_mama_gemv.vcd");
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
        for (int j = 0; j < COLUMNS; j++) begin
            reference[j] = 0.0;
            magnitude[j] = 0.0;
        end
        for (int k = 0; k < DEPTH; k++) begin
            a_vector[k] = real_to_bf16(normal_sample());
            a_real      = bf16_to_real(a_vector[k]);
            for (int j = 0; j < COLUMNS; j++) begin
                b_matrix[k][j] = real_to_bf16(normal_sample());
                b_real         = bf16_to_real(b_matrix[k][j]);
                reference[j]   = reference[j] + a_real * b_real;
                magnitude[j]   = magnitude[j] + (a_real * b_real >= 0.0 ?
                                                 a_real * b_real :
                                                -a_real * b_real);
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
        reset  = 1'b1;
        clear  = 1'b0;
        enable = '0;
        for (int m = 0; m < MAMS; m++) begin
            a[m]                  = '0;
            b[m]                  = '0;
            accumulator_select[m] = '0;
        end
        build_stimulus();

        repeat (2) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        // Stationary output columns, streaming A and B. Four cycles per A
        // element cover all 32 accumulators.
        for (int k = 0; k < DEPTH; k++) begin
            for (int c = 0; c < ACCUMULATORS_PER_MAM; c++) begin
                @(negedge clk);
                for (int m = 0; m < MAMS; m++) begin
                    a[m]                  = a_vector[k];
                    b[m]                  = b_matrix[k][m*ACCUMULATORS_PER_MAM + c];
                    accumulator_select[m] = c[SELECT_WIDTH-1:0];
                end
                enable = '1;
                @(posedge clk);
            end
        end

        @(negedge clk);
        enable = '0;

        for (int c = 0; c < ACCUMULATORS_PER_MAM; c++) begin
            for (int m = 0; m < MAMS; m++)
                accumulator_select[m] = c[SELECT_WIDTH-1:0];
            #1;
            for (int m = 0; m < MAMS; m++)
                check_column(m*ACCUMULATORS_PER_MAM + c, accumulator[m]);
        end

        if (failures == 0) begin
            $display("\nBF16 MAMA GEMV TEST PASSED (%0dx%0d dot products)",
                     DEPTH, COLUMNS);
            $finish;
        end
        $fatal(1, "BF16 MAMA GEMV TEST FAILED with %0d failure(s)", failures);
    end

    initial begin
        #500000;
        $fatal(1, "BF16 MAMA GEMV TEST FAILED: timeout");
    end
endmodule
