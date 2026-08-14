`timescale 1ns/1ps

// Standalone BF16 adder: BF16 + BF16 -> BF16.
//
// Format is 1 sign / 8 exponent (bias 127) / 7 fraction. This is a single
// self-contained instance with no parameters, intended for area/timing
// characterization of one adder.
//
// No subnormal support:
//   * an operand with a zero exponent field is treated as signed zero
//     regardless of its fraction (flush to zero on input),
//   * a result whose normalized exponent falls to or below zero is flushed to
//     signed zero (flush to zero on output).
//
// Rounding is round-to-nearest, ties-to-even, applied once at the end. Guard,
// round and sticky bits are carried through alignment and normalization so the
// pre-rounding value is the correctly truncated infinite-precision sum.
//
// Subtraction is addition with the sign bit of b inverted, which the caller
// does; there is no separate subtract control.
module bf16_add (
    input  logic [15:0] a,
    input  logic [15:0] b,
    output logic [15:0] result
);
    // {hidden, fraction[6:0], guard, round, sticky}
    localparam int unsigned ROUND_W = 11;
    localparam logic [6:0]  QUIET_NAN_FRAC = 7'h40;

    logic       sign_a, sign_b;
    logic [7:0] exponent_a, exponent_b;
    logic [6:0] fraction_a, fraction_b;
    logic       zero_a, zero_b, infinite_a, infinite_b, nan_a, nan_b;
    logic [7:0] significand_a, significand_b;

    logic               a_is_larger;
    logic               large_sign;
    logic [7:0]         large_exponent, small_exponent;
    logic [7:0]         large_significand, small_significand;
    logic [7:0]         shift_amount;
    logic [ROUND_W-1:0] large_extended, small_extended, small_shifted;
    logic               align_sticky;
    logic               effective_subtract;
    logic [ROUND_W:0]   sum;
    logic [ROUND_W-1:0] difference;
    logic [3:0]         leading_zeros;

    logic               result_sign;
    logic signed [10:0] result_exponent;
    logic [ROUND_W-1:0] result_significand;
    logic               result_sticky;
    logic               exact_zero;

    logic               guard, sticky, round_up;
    logic [7:0]         rounded_significand;
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

        // Order by magnitude so the smaller operand is the one shifted right.
        // Because both operands are normal here, the raw magnitude field is a
        // monotone key.
        a_is_larger       = (a[14:0] >= b[14:0]);
        large_sign        = a_is_larger ? sign_a : sign_b;
        large_exponent    = a_is_larger ? exponent_a : exponent_b;
        small_exponent    = a_is_larger ? exponent_b : exponent_a;
        large_significand = a_is_larger ? significand_a : significand_b;
        small_significand = a_is_larger ? significand_b : significand_a;

        effective_subtract = sign_a ^ sign_b;

        large_extended = {large_significand, 3'b000};
        small_extended = {small_significand, 3'b000};
        shift_amount   = large_exponent - small_exponent;

        // Align, folding everything shifted past the sticky position into it.
        align_sticky = 1'b0;
        if (shift_amount >= 8'(ROUND_W)) begin
            align_sticky  = |small_extended;
            small_shifted = '0;
        end else begin
            for (int unsigned s = 0; s < ROUND_W; s++) begin
                if (s < {24'b0, shift_amount}) begin
                    align_sticky = align_sticky | small_extended[s];
                end
            end
            small_shifted = small_extended >> shift_amount[3:0];
        end

        sum = {1'b0, large_extended} + {1'b0, small_shifted};
        // Borrowing the sticky makes the difference the floor of the true
        // result, which is what round-to-nearest expects.
        difference = large_extended - small_shifted -
                     {{(ROUND_W-1){1'b0}}, align_sticky};

        result_sign        = large_sign;
        result_exponent    = signed'({3'b0, large_exponent});
        result_significand = '0;
        result_sticky      = align_sticky;
        exact_zero         = 1'b0;
        leading_zeros      = 4'd0;

        if (!effective_subtract) begin
            if (sum[ROUND_W]) begin
                // Carry out: shift right one and fold the lost bit into sticky.
                result_significand = sum[ROUND_W:1];
                result_sticky      = align_sticky | sum[0];
                result_exponent    = result_exponent + 11'sd1;
            end else begin
                result_significand = sum[ROUND_W-1:0];
            end
        end else begin
            // Cancellation can only be severe when the exponents were close,
            // in which case nothing was shifted out and the sticky is zero.
            leading_zeros = 4'(ROUND_W);
            for (int unsigned j = 0; j < ROUND_W; j++) begin
                if (difference[j]) begin
                    leading_zeros = 4'(ROUND_W - 1 - j);
                end
            end
            if (leading_zeros == 4'(ROUND_W)) begin
                exact_zero  = 1'b1;
                result_sign = 1'b0;                 // exact cancellation is +0
            end else begin
                result_significand = difference << leading_zeros;
                result_exponent    = result_exponent -
                                     signed'({7'b0, leading_zeros});
            end
        end

        // Single rounding point: round-to-nearest, ties-to-even.
        guard    = result_significand[2];
        sticky   = result_significand[1] | result_significand[0] | result_sticky;
        round_up = guard && (sticky || result_significand[3]);

        rounded_significand = result_significand[ROUND_W-1:3] + {7'b0, round_up};

        if (round_up && (rounded_significand == 8'h00)) begin
            final_exponent = result_exponent + 11'sd1;
            final_fraction = 7'h00;
        end else begin
            final_exponent = result_exponent;
            final_fraction = rounded_significand[6:0];
        end

        if (nan_a || nan_b ||
            (infinite_a && infinite_b && (sign_a != sign_b))) begin
            result = {1'b0, 8'hff, QUIET_NAN_FRAC};
        end else if (infinite_a) begin
            result = {sign_a, 8'hff, 7'h00};
        end else if (infinite_b) begin
            result = {sign_b, 8'hff, 7'h00};
        end else if (zero_a && zero_b) begin
            // Signed zero: -0 only when both operands are negative zero.
            result = {sign_a & sign_b, 15'h0000};
        end else if (zero_a) begin
            result = {sign_b, exponent_b, fraction_b};
        end else if (zero_b) begin
            result = {sign_a, exponent_a, fraction_a};
        end else if (exact_zero) begin
            result = 16'h0000;
        end else if (final_exponent >= 11'sd255) begin
            result = {result_sign, 8'hff, 7'h00};       // overflow to infinity
        end else if (final_exponent <= 11'sd0) begin
            result = {result_sign, 15'h0000};           // underflow, flushed
        end else begin
            result = {result_sign, final_exponent[7:0], final_fraction};
        end
    end
endmodule
