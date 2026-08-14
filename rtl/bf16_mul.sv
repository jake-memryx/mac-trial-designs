`timescale 1ns/1ps

// Standalone BF16 multiplier: BF16 x BF16 -> BF16.
//
// Format is 1 sign / 8 exponent (bias 127) / 7 fraction, the same encoding the
// rest of the tree uses. This is a single self-contained instance with no
// parameters, intended for area/timing characterization of one multiplier.
//
// No subnormal support:
//   * an operand with a zero exponent field is treated as signed zero
//     regardless of its fraction (flush to zero on input),
//   * a result whose rounded exponent falls to or below zero is flushed to
//     signed zero (flush to zero on output).
//
// Rounding is round-to-nearest, ties-to-even. Infinity and NaN are handled:
// inf*0 and any NaN operand produce a quiet NaN, overflow produces infinity.
// The 8x8 significand product is exact, so there is exactly one rounding.
module bf16_mul (
    input  logic [15:0] a,
    input  logic [15:0] b,
    output logic [15:0] result
);
    localparam logic [6:0] QUIET_NAN_FRAC = 7'h40;

    logic       sign_a, sign_b;
    logic [7:0] exponent_a, exponent_b;
    logic [6:0] fraction_a, fraction_b;
    logic       zero_a, zero_b, infinite_a, infinite_b, nan_a, nan_b;
    logic [7:0] significand_a, significand_b;

    logic               result_sign;
    logic [15:0]        product;
    logic [15:0]        normalized;
    logic signed [10:0] exponent_sum;
    logic [7:0]         rounded_significand;
    logic               guard, sticky, round_up;
    logic signed [10:0] final_exponent;
    logic [6:0]         final_fraction;

    always_comb begin
        sign_a     = a[15];
        exponent_a = a[14:7];
        fraction_a = a[6:0];
        sign_b     = b[15];
        exponent_b = b[14:7];
        fraction_b = b[6:0];

        // Flush-to-zero decode: a zero exponent field is zero, never subnormal.
        zero_a     = (exponent_a == 8'h00);
        zero_b     = (exponent_b == 8'h00);
        infinite_a = (exponent_a == 8'hff) && (fraction_a == 7'h00);
        infinite_b = (exponent_b == 8'hff) && (fraction_b == 7'h00);
        nan_a      = (exponent_a == 8'hff) && (fraction_a != 7'h00);
        nan_b      = (exponent_b == 8'hff) && (fraction_b != 7'h00);

        significand_a = {1'b1, fraction_a};
        significand_b = {1'b1, fraction_b};

        result_sign = sign_a ^ sign_b;

        // Exact 16-bit product of two 8-bit significands. The leading one is
        // in bit 15 or bit 14, so at most a single left shift normalizes it.
        product    = significand_a * significand_b;
        normalized = product[15] ? product : (product << 1);

        exponent_sum = signed'({3'b0, exponent_a}) +
                       signed'({3'b0, exponent_b}) -
                       11'sd127 +
                       (product[15] ? 11'sd1 : 11'sd0);

        // {hidden, fraction} with the guard bit and the sticky below it.
        guard  = normalized[7];
        sticky = |normalized[6:0];
        // Round-to-nearest, ties-to-even.
        round_up = guard && (sticky || normalized[8]);

        rounded_significand = normalized[15:8] + {7'b0, round_up};

        // A rounding carry out of the hidden bit adds one to the exponent; the
        // fraction is then all zero, so no extra shift is needed.
        if (round_up && (rounded_significand == 8'h00)) begin
            final_exponent = exponent_sum + 11'sd1;
            final_fraction = 7'h00;
        end else begin
            final_exponent = exponent_sum;
            final_fraction = rounded_significand[6:0];
        end

        if (nan_a || nan_b || (infinite_a && zero_b) || (infinite_b && zero_a)) begin
            result = {1'b0, 8'hff, QUIET_NAN_FRAC};
        end else if (infinite_a || infinite_b) begin
            result = {result_sign, 8'hff, 7'h00};
        end else if (zero_a || zero_b) begin
            result = {result_sign, 15'h0000};
        end else if (final_exponent >= 11'sd255) begin
            result = {result_sign, 8'hff, 7'h00};       // overflow to infinity
        end else if (final_exponent <= 11'sd0) begin
            result = {result_sign, 15'h0000};           // underflow, flushed
        end else begin
            result = {result_sign, final_exponent[7:0], final_fraction};
        end
    end
endmodule
