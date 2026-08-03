`timescale 1ns/1ps

// BF16 multiplier with an FP32 result. BF16 subnormal inputs and FP32
// underflowed results are flushed to zero. Normal BF16 products are exact in
// FP32 because their product has at most 16 significant bits.
module bf16_multiplier (
    input  logic [15:0] a,
    input  logic [15:0] b,
    output logic [31:0] product
);
    logic        sign;
    logic [7:0]  exp_a, exp_b;
    logic [6:0]  frac_a, frac_b;
    logic [7:0]  sig_a, sig_b;
    logic [15:0] sig_product;
    integer      result_exp;

    always_comb begin
        sign         = a[15] ^ b[15];
        exp_a        = a[14:7];
        exp_b        = b[14:7];
        frac_a       = a[6:0];
        frac_b       = b[6:0];
        sig_a        = {1'b1, frac_a};
        sig_b        = {1'b1, frac_b};
        sig_product  = sig_a * sig_b;
        result_exp   = 0;
        product      = {sign, 31'b0};

        // NaN, or infinity multiplied by zero, produces a quiet NaN.
        if ((exp_a == 8'hff && frac_a != 0) ||
            (exp_b == 8'hff && frac_b != 0) ||
            (exp_a == 8'hff && exp_b == 0)  ||
            (exp_b == 8'hff && exp_a == 0)) begin
            product = 32'h7fc00000;
        end else if (exp_a == 8'hff || exp_b == 8'hff) begin
            product = {sign, 8'hff, 23'b0};
        end else if (exp_a == 0 || exp_b == 0) begin
            // Zero and BF16 subnormal operands are flushed to signed zero.
            product = {sign, 31'b0};
        end else begin
            result_exp = exp_a + exp_b - 127;

            if (sig_product[15]) begin
                result_exp = result_exp + 1;
                if (result_exp >= 255)
                    product = {sign, 8'hff, 23'b0};
                else if (result_exp > 0)
                    product = {sign, result_exp[7:0],
                               sig_product[14:0], 8'b0};
            end else begin
                if (result_exp >= 255)
                    product = {sign, 8'hff, 23'b0};
                else if (result_exp > 0)
                    product = {sign, result_exp[7:0],
                               sig_product[13:0], 9'b0};
            end
        end
    end
endmodule




// FP32 add, first half: decompose, resolve special values, order the operands
// by magnitude and align the smaller significand into the larger one's scale.
//
// Special-value results are resolved here and passed through on special_sum so
// the second half never has to look at the raw inputs. When special_valid is
// set the remaining outputs are don't-care.
module fp32_adder_align (
    input  logic [31:0] a,
    input  logic [31:0] b,
    output logic        special_valid,
    output logic [31:0] special_sum,
    output logic        result_sign,
    output logic [7:0]  result_exp,
    output logic [26:0] large_ext,
    output logic [26:0] aligned_small,
    output logic        add_not_sub
);
    logic        sign_a, sign_b, sign_large;
    logic [7:0]  exp_a, exp_b, exp_large, exp_small;
    logic [22:0] frac_a, frac_b;
    logic [23:0] sig_a, sig_b, sig_large, sig_small;
    logic [26:0] small_ext;
    integer      shift_amount;

    function automatic logic [26:0] shift_right_jam(
        input logic [26:0] value,
        input integer      amount
    );
        logic sticky;
        integer j;
        begin
            if (amount <= 0) begin
                shift_right_jam = value;
            end else if (amount >= 27) begin
                shift_right_jam = {26'b0, |value};
            end else begin
                sticky = 1'b0;
                // Static loop bound keeps the index in range for synthesis.
                for (j = 0; j < 27; j = j + 1)
                    if (j < amount)
                        sticky = sticky | value[j];
                shift_right_jam = value >> amount;
                shift_right_jam[0] = shift_right_jam[0] | sticky;
            end
        end
    endfunction

    always_comb begin
        sign_a        = a[31];
        sign_b        = b[31];
        exp_a         = a[30:23];
        exp_b         = b[30:23];
        frac_a        = a[22:0];
        frac_b        = b[22:0];
        sig_a         = {1'b1, frac_a};
        sig_b         = {1'b1, frac_b};
        sign_large    = 1'b0;
        exp_large     = 8'b0;
        exp_small     = 8'b0;
        sig_large     = 24'b0;
        sig_small     = 24'b0;
        small_ext     = 27'b0;
        shift_amount  = 0;

        special_valid = 1'b0;
        special_sum   = 32'b0;
        result_sign   = 1'b0;
        result_exp    = 8'b0;
        large_ext     = 27'b0;
        aligned_small = 27'b0;
        add_not_sub   = 1'b0;

        // Quiet NaN propagation and invalid infinity addition.
        if ((exp_a == 8'hff && frac_a != 0) ||
            (exp_b == 8'hff && frac_b != 0) ||
            (exp_a == 8'hff && exp_b == 8'hff && sign_a != sign_b)) begin
            special_valid = 1'b1;
            special_sum   = 32'h7fc00000;
        end else if (exp_a == 8'hff) begin
            special_valid = 1'b1;
            special_sum   = {sign_a, 8'hff, 23'b0};
        end else if (exp_b == 8'hff) begin
            special_valid = 1'b1;
            special_sum   = {sign_b, 8'hff, 23'b0};
        end else if (exp_a == 0 && exp_b == 0) begin
            // Includes flushed subnormal inputs.
            special_valid = 1'b1;
            special_sum   = {(sign_a & sign_b), 31'b0};
        end else if (exp_a == 0) begin
            special_valid = 1'b1;
            special_sum   = b;
        end else if (exp_b == 0) begin
            special_valid = 1'b1;
            special_sum   = a;
        end else begin
            // Put the larger-magnitude operand on the unshifted side.
            if ({exp_a, frac_a} >= {exp_b, frac_b}) begin
                sign_large = sign_a;
                exp_large  = exp_a;
                exp_small  = exp_b;
                sig_large  = sig_a;
                sig_small  = sig_b;
            end else begin
                sign_large = sign_b;
                exp_large  = exp_b;
                exp_small  = exp_a;
                sig_large  = sig_b;
                sig_small  = sig_a;
            end

            result_sign   = sign_large;
            result_exp    = exp_large;
            large_ext     = {sig_large, 3'b000};
            small_ext     = {sig_small, 3'b000};
            shift_amount  = exp_large - exp_small;
            aligned_small = shift_right_jam(small_ext, shift_amount);
            add_not_sub   = (sign_a == sign_b);
        end
    end
endmodule


// FP32 add, second half: add or subtract the aligned significands, renormalize
// (carry-out for addition, cancellation for subtraction), then round once with
// round-to-nearest, ties-to-even.
module fp32_adder_normalize (
    input  logic        special_valid,
    input  logic [31:0] special_sum,
    input  logic        result_sign,
    input  logic [7:0]  result_exp,
    input  logic [26:0] large_ext,
    input  logic [26:0] aligned_small,
    input  logic        add_not_sub,
    output logic [31:0] sum
);
    logic [26:0] normalized;
    logic [27:0] add_result;
    logic [26:0] sub_result;
    logic [24:0] rounded_sig;
    logic [7:0]  working_exp;
    integer      i;

    always_comb begin
        normalized  = 27'b0;
        add_result  = 28'b0;
        sub_result  = 27'b0;
        rounded_sig = 25'b0;
        working_exp = result_exp;
        sum         = 32'b0;

        if (special_valid) begin
            sum = special_sum;
        end else begin
            if (add_not_sub) begin
                add_result = {1'b0, large_ext} + {1'b0, aligned_small};
                if (add_result[27]) begin
                    normalized    = add_result[27:1];
                    normalized[0] = normalized[0] | add_result[0];
                    if (working_exp == 8'hfe)
                        working_exp = 8'hff;
                    else
                        working_exp = working_exp + 1'b1;
                end else begin
                    normalized = add_result[26:0];
                end
            end else begin
                sub_result = large_ext - aligned_small;
                normalized = sub_result;
                // Cancellation normalization. Falling below the normal range
                // flushes the result to zero.
                for (i = 0; i < 26; i = i + 1) begin
                    if (!normalized[26] && normalized != 0 &&
                        working_exp > 1) begin
                        normalized  = normalized << 1;
                        working_exp = working_exp - 1'b1;
                    end
                end
            end

            if (normalized == 0 ||
                (working_exp == 1 && !normalized[26])) begin
                sum = {result_sign, 31'b0};
            end else if (working_exp == 8'hff) begin
                sum = {result_sign, 8'hff, 23'b0};
            end else begin
                // Guard, round, and sticky bits implement ties-to-even.
                rounded_sig = {1'b0, normalized[26:3]} +
                              (normalized[2] &&
                               (normalized[1] || normalized[0] ||
                                normalized[3]));
                if (rounded_sig[24]) begin
                    if (working_exp == 8'hfe)
                        sum = {result_sign, 8'hff, 23'b0};
                    else
                        sum = {result_sign, working_exp + 1'b1,
                               rounded_sig[23:1]};
                end else begin
                    sum = {result_sign, working_exp, rounded_sig[22:0]};
                end
            end
        end
    end
endmodule


// Combinational FP32 adder. Rounding mode is round-to-nearest, ties-to-even.
// Subnormal inputs and underflowed outputs are flushed to signed zero. This is
// the two halves above wired back-to-back with no register between them.
module fp32_adder (
    input  logic [31:0] a,
    input  logic [31:0] b,
    output logic [31:0] sum
);
    logic        special_valid;
    logic [31:0] special_sum;
    logic        result_sign;
    logic [7:0]  result_exp;
    logic [26:0] large_ext;
    logic [26:0] aligned_small;
    logic        add_not_sub;

    fp32_adder_align align_half (
        .a             (a),
        .b             (b),
        .special_valid (special_valid),
        .special_sum   (special_sum),
        .result_sign   (result_sign),
        .result_exp    (result_exp),
        .large_ext     (large_ext),
        .aligned_small (aligned_small),
        .add_not_sub   (add_not_sub)
    );

    fp32_adder_normalize normalize_half (
        .special_valid (special_valid),
        .special_sum   (special_sum),
        .result_sign   (result_sign),
        .result_exp    (result_exp),
        .large_ext     (large_ext),
        .aligned_small (aligned_small),
        .add_not_sub   (add_not_sub),
        .sum           (sum)
    );
endmodule


// One FP32 accumulation is committed on every enabled rising edge.
module bf16_mac (
    input  logic        clk,
    input  logic        reset,
    input  logic        clear,
    input  logic        enable,
    input  logic [15:0] a,
    input  logic [15:0] b,
    output logic [31:0] accumulator
);
    logic [31:0] product;
    logic [31:0] next_accumulator;

    bf16_multiplier multiplier (
        .a       (a),
        .b       (b),
        .product (product)
    );

    fp32_adder adder (
        .a   (accumulator),
        .b   (product),
        .sum (next_accumulator)
    );

    always_ff @(posedge clk) begin
        if (reset || clear)
            accumulator <= 32'b0;
        else if (enable)
            accumulator <= next_accumulator;
    end
endmodule


// Parameterized bank of FP32 accumulators sharing one BF16 multiplier and one
// FP32 adder. accumulator_select chooses both the MAC destination and the value
// visible on accumulator. Reset and clear affect the entire bank.
module bf16_mam #(
    parameter int unsigned ACCUMULATORS = 4,
    parameter int unsigned SELECT_WIDTH =
        (ACCUMULATORS <= 1) ? 1 : $clog2(ACCUMULATORS)
) (
    input  logic                    clk,
    input  logic                    reset,
    input  logic                    clear,
    input  logic                    enable,
    input  logic [SELECT_WIDTH-1:0] accumulator_select,
    input  logic [15:0]             a,
    input  logic [15:0]             b,
    output logic [31:0]             accumulator
);
    logic [31:0] product;
    logic [31:0] selected_accumulator;
    logic [31:0] next_accumulator;
    logic [31:0] accumulator_bank [0:ACCUMULATORS-1];
    integer      accumulator_index;

    bf16_multiplier multiplier (
        .a       (a),
        .b       (b),
        .product (product)
    );

    fp32_adder adder (
        .a   (selected_accumulator),
        .b   (product),
        .sum (next_accumulator)
    );

    always_comb begin
        selected_accumulator = 32'b0;
        if (accumulator_select < ACCUMULATORS)
            selected_accumulator = accumulator_bank[accumulator_select];
        accumulator = selected_accumulator;
    end

    always_ff @(posedge clk) begin
        if (reset || clear) begin
            for (accumulator_index = 0;
                 accumulator_index < ACCUMULATORS;
                 accumulator_index = accumulator_index + 1)
                accumulator_bank[accumulator_index] <= 32'b0;
        end else if (enable && accumulator_select < ACCUMULATORS) begin
            accumulator_bank[accumulator_select] <= next_accumulator;
        end
    end
endmodule


// Multi-Accumulator MAC Array (MAMA). Each lane is an independent MAM with its
// own operands, enable, accumulator selector, and selected accumulator output.
// Reset and clear are broadcast to every MAM in the array.
module bf16_mama #(
    parameter int unsigned MAMS = 4,
    parameter int unsigned ACCUMULATORS_PER_MAM = 4,
    parameter int unsigned SELECT_WIDTH =
        (ACCUMULATORS_PER_MAM <= 1) ? 1 : $clog2(ACCUMULATORS_PER_MAM)
) (
    input  logic                         clk,
    input  logic                         reset,
    input  logic                         clear,
    input  logic [MAMS-1:0]              enable,
    input  logic [SELECT_WIDTH-1:0]      accumulator_select [0:MAMS-1],
    input  logic [15:0]                  a                  [0:MAMS-1],
    input  logic [15:0]                  b                  [0:MAMS-1],
    output logic [31:0]                  accumulator        [0:MAMS-1]
);
    genvar mam_index;

    generate
        for (mam_index = 0; mam_index < MAMS; mam_index = mam_index + 1) begin : g_mam
            bf16_mam #(
                .ACCUMULATORS (ACCUMULATORS_PER_MAM),
                .SELECT_WIDTH (SELECT_WIDTH)
            ) mam (
                .clk                (clk),
                .reset              (reset),
                .clear              (clear),
                .enable             (enable[mam_index]),
                .accumulator_select (accumulator_select[mam_index]),
                .a                  (a[mam_index]),
                .b                  (b[mam_index]),
                .accumulator        (accumulator[mam_index])
            );
        end
    endgenerate
endmodule
