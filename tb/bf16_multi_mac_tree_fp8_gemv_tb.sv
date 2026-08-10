`timescale 1ns/1ps

// Override at compile time with -define PIPELINE_STAGES=<0|1|2>.
`ifndef PIPELINE_STAGES
`define PIPELINE_STAGES 2
`endif

// Override at compile time with -define ACCUMULATE_STAGES=<0|1|2>.
`ifndef ACCUMULATE_STAGES
`define ACCUMULATE_STAGES 2
`endif

// C[32] = A[1024] x B[1024][32] in E4M3 mode on the dual-format tree MAC.
//
// FP8 mode retires 16 MACs per cycle on the same 256-bit operand bus, so a
// group covers 16 depth elements instead of 8 and the sweep needs half as many
// groups as the BF16 testbench. Packing follows the RTL convention: element i
// of a group is the low byte of operand word i, element i+8 is the high byte.
//
// Accumulators are visited round-robin, which satisfies the in-flight reuse
// contract that the pipelined accumulate loop depends on.
module bf16_multi_mac_tree_fp8_gemv_tb;
    localparam int unsigned MULTIPLIERS  = 8;
    localparam int unsigned LANES        = 2 * MULTIPLIERS;
    localparam int unsigned ACCUMULATORS = 32;
    localparam int unsigned SELECT_WIDTH = $clog2(ACCUMULATORS);
    localparam int unsigned DEPTH        = 1024;
    localparam int unsigned GROUPS       = DEPTH / LANES;
    localparam int unsigned PIPELINE_STAGES = `PIPELINE_STAGES;
    localparam int unsigned ACCUMULATE_STAGES = `ACCUMULATE_STAGES;
    localparam int unsigned LATENCY = PIPELINE_STAGES + ACCUMULATE_STAGES;
    // E4M3 tops out at 448, so keep the stimulus well inside the range.
    localparam real         SIGMA        = 2.0;
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

    logic [7:0]  a_vector [0:DEPTH-1];
    logic [7:0]  b_matrix [0:DEPTH-1][0:ACCUMULATORS-1];
    real         reference [0:ACCUMULATORS-1];
    real         magnitude [0:ACCUMULATORS-1];
    int          failures = 0;

    bf16_multi_mac_tree #(
        .MULTIPLIERS          (MULTIPLIERS),
        .ACCUMULATORS         (ACCUMULATORS),
        .REDUCTION_GUARD_BITS (4),
        .FP8_ENABLE           (1),
        .PIPELINE_STAGES      (PIPELINE_STAGES),
        .ACCUMULATE_STAGES    (ACCUMULATE_STAGES)
    ) dut (.*);

    function automatic real plusarg_half_period();
        real period;
        if ($value$plusargs("period=%f", period))
            return period / 2.0;
        return 5.0;
    endfunction

    real clock_half_period = plusarg_half_period();

    initial clk = 1'b0;
    always #(clock_half_period) clk = ~clk;

    initial begin
        if ($test$plusargs("dump_vcd")) begin
            $dumpfile($sformatf(
                "build/vcd/bf16_multi_mac_tree_fp8_gemv_p%0da%0d_%0dps.vcd",
                PIPELINE_STAGES, ACCUMULATE_STAGES,
                int'(clock_half_period * 2000.0)));
            $dumpvars(0, dut);
        end
    end

    // OCP E4M3: bias 7, no infinity, NaN only at S.1111.111, max normal 448.
    function automatic bit e4m3_is_nan(input logic [7:0] value);
        return (value[6:3] == 4'hf) && (value[2:0] == 3'h7);
    endfunction

    function automatic real e4m3_to_real(input logic [7:0] value);
        logic [3:0] exponent_field;
        logic [2:0] mantissa;
        real        result;
        begin
            exponent_field = value[6:3];
            mantissa       = value[2:0];
            if (exponent_field == 4'h0)
                result = (real'(mantissa) / 8.0) * (2.0 ** -6.0);
            else
                result = (1.0 + real'(mantissa) / 8.0) *
                         (2.0 ** (real'(exponent_field) - 7.0));
            return value[7] ? -result : result;
        end
    endfunction

    // Nearest E4M3 encoding by search. The reference model is built from the
    // quantized codes, so any consistent rounding rule is valid here.
    function automatic logic [7:0] real_to_e4m3(input real value);
        real        best_error;
        real        candidate;
        real        error;
        logic [7:0] best;
        begin
            best       = 8'h00;
            best_error = 1.0e30;
            for (int i = 0; i < 256; i++) begin
                if (e4m3_is_nan(i[7:0]))
                    continue;
                candidate = e4m3_to_real(i[7:0]);
                error     = candidate - value;
                if (error < 0.0)
                    error = -error;
                if (error < best_error) begin
                    best_error = error;
                    best       = i[7:0];
                end
            end
            return best;
        end
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
        real a_real;
        real b_real;
        real term;
        for (int j = 0; j < ACCUMULATORS; j++) begin
            reference[j] = 0.0;
            magnitude[j] = 0.0;
        end
        for (int k = 0; k < DEPTH; k++) begin
            a_vector[k] = real_to_e4m3(normal_sample());
            a_real      = e4m3_to_real(a_vector[k]);
            for (int j = 0; j < ACCUMULATORS; j++) begin
                b_matrix[k][j] = real_to_e4m3(normal_sample());
                b_real         = e4m3_to_real(b_matrix[k][j]);
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
        mode               = 1'b1;   // E4M3
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

        // A-stationary: load 16 A elements, then sweep all 32 columns.
        for (int g = 0; g < GROUPS; g++) begin
            for (int j = 0; j < ACCUMULATORS; j++) begin
                @(negedge clk);
                for (int i = 0; i < MULTIPLIERS; i++) begin
                    a[i] = {a_vector[g*LANES + i + MULTIPLIERS],
                            a_vector[g*LANES + i]};
                    b[i] = {b_matrix[g*LANES + i + MULTIPLIERS][j],
                            b_matrix[g*LANES + i][j]};
                end
                accumulator_select = j[SELECT_WIDTH-1:0];
                enable             = 1'b1;
                @(posedge clk);
            end
        end

        @(negedge clk);
        enable = 1'b0;

        repeat (LATENCY + 1) @(posedge clk);
        @(negedge clk);

        for (int j = 0; j < ACCUMULATORS; j++) begin
            accumulator_select = j[SELECT_WIDTH-1:0];
            #1;
            check_column(j, accumulator);
        end

        if (failures == 0) begin
            $display("\nBF16 MULTI-MAC TREE FP8 GEMV TEST PASSED (%0dx%0d dot products, %0d MACs/cycle)",
                     DEPTH, ACCUMULATORS, LANES);
            $finish;
        end
        $fatal(1, "BF16 MULTI-MAC TREE FP8 GEMV TEST FAILED with %0d failure(s)",
               failures);
    end

    initial begin
        #500000;
        $fatal(1, "BF16 MULTI-MAC TREE FP8 GEMV TEST FAILED: timeout");
    end
endmodule
