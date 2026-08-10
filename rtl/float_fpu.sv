`timescale 1ns/1ps

// General-purpose binary floating point FPU with full subnormal support,
// parameterized by mantissa width over an 8-bit exponent field (bias 127).
//
//   MANTISSA_BITS = 7   -> BF16  (1/8/7,  16 bits)  see bf16_fpu below
//   MANTISSA_BITS = 10  -> BF19  (1/8/10, 19 bits)  TensorFloat-32 layout
//
// Operations: add, sub, mul, min, max, abs, neg, copysign, compare, and
// optionally divide and square root (ENABLE_DIV_SQRT).
//
// Both formats share FP32's exponent range, so only the significand datapath
// scales with MANTISSA_BITS. Subnormals are decoded by normalizing them into
// the shared internal form and re-denormalized on the way out, rather than
// being flushed as the MAC datapath does.
//
// Internally every operand becomes a sign, a signed exponent and a
// MANTISSA_BITS+1 significand with the hidden bit explicit. Results are carried
// in a {hidden, frac, guard, round, sticky} field so one rounding block serves
// every operation.
//
// Rounding is round-to-nearest, ties-to-even throughout.

// Decode an encoding into the shared internal form. Subnormals are normalized:
// their leading one is shifted up to the hidden-bit position and the exponent
// is adjusted to match.
module float_fpu_decode #(
    parameter int unsigned MANTISSA_BITS = 7,
    parameter int unsigned WIDTH = MANTISSA_BITS + 9,
    parameter int unsigned SIG   = MANTISSA_BITS + 1
) (
    input  logic [WIDTH-1:0]  value,
    output logic              sign,
    output logic signed [9:0] exponent,      // value = 2^(exponent-127) * 1.frac
    output logic [SIG-1:0]    significand,   // {hidden, frac}, hidden = 1
    output logic              is_zero,
    output logic              is_inf,
    output logic              is_nan
);
    logic [7:0]              exponent_field;
    logic [MANTISSA_BITS-1:0] fraction;
    logic [4:0]              leading_zeros;
    logic [SIG-1:0]          shifted;

    always_comb begin
        exponent_field = value[WIDTH-2 -: 8];
        fraction       = value[MANTISSA_BITS-1:0];

        sign        = value[WIDTH-1];
        exponent    = '0;
        significand = '0;
        is_zero     = 1'b0;
        is_inf      = 1'b0;
        is_nan      = 1'b0;
        leading_zeros = 5'd0;
        shifted       = '0;

        if (exponent_field == 8'hff) begin
            if (fraction != 0)
                is_nan = 1'b1;
            else
                is_inf = 1'b1;
        end else if (exponent_field == 8'h00) begin
            if (fraction == 0) begin
                is_zero = 1'b1;
            end else begin
                // Subnormal. With the leading one k places below the top of the
                // fraction field, normalizing costs k of exponent range.
                // Iterating downwards leaves the smallest matching index.
                for (int unsigned j = 0; j < MANTISSA_BITS; j++)
                    if (fraction[j])
                        leading_zeros = 5'(MANTISSA_BITS - 1 - j);
                shifted       = {1'b0, fraction} << (leading_zeros + 5'd1);
                significand   = shifted;
                exponent      = -signed'({5'b0, leading_zeros});
            end
        end else begin
            exponent    = signed'({2'b0, exponent_field});
            significand = {1'b1, fraction};
        end
    end
endmodule


// Multiply. The SIGxSIG significand product is exact, so the only rounding
// happens in the shared rounder.
module float_fpu_mul #(
    parameter int unsigned MANTISSA_BITS = 7,
    parameter int unsigned WIDTH   = MANTISSA_BITS + 9,
    parameter int unsigned SIG     = MANTISSA_BITS + 1,
    parameter int unsigned ROUND_W = MANTISSA_BITS + 4,
    parameter int unsigned PROD_W  = 2 * SIG
) (
    input  logic              sign_a,
    input  logic signed [9:0] exponent_a,
    input  logic [SIG-1:0]    significand_a,
    input  logic              zero_a, inf_a, nan_a,
    input  logic              sign_b,
    input  logic signed [9:0] exponent_b,
    input  logic [SIG-1:0]    significand_b,
    input  logic              zero_b, inf_b, nan_b,
    output logic              special_valid,
    output logic [WIDTH-1:0]  special_result,
    output logic              result_sign,
    output logic signed [11:0] result_exponent,
    output logic [ROUND_W-1:0] result_significand,
    output logic              result_sticky,
    output logic              invalid
);
    logic [PROD_W-1:0] product;
    logic [PROD_W-1:0] normalized;

    always_comb begin
        result_sign        = sign_a ^ sign_b;
        product            = significand_a * significand_b;
        normalized         = product[PROD_W-1] ? product : (product << 1);
        result_exponent    = signed'({{2{exponent_a[9]}}, exponent_a}) +
                             signed'({{2{exponent_b[9]}}, exponent_b}) -
                             12'sd127 +
                             (product[PROD_W-1] ? 12'sd1 : 12'sd0);
        // {hidden, frac, guard, round, sticky}
        result_significand = {normalized[PROD_W-1],
                              normalized[PROD_W-2 -: MANTISSA_BITS],
                              normalized[PROD_W-2-MANTISSA_BITS],
                              normalized[PROD_W-3-MANTISSA_BITS],
                              1'b0};
        result_sticky      = |normalized[PROD_W-4-MANTISSA_BITS:0];

        special_valid  = 1'b0;
        special_result = '0;
        invalid        = 1'b0;

        if (nan_a || nan_b || (inf_a && zero_b) || (inf_b && zero_a)) begin
            special_valid  = 1'b1;
            special_result = {1'b0, 8'hff, 1'b1,
                              {(MANTISSA_BITS-1){1'b0}}};   // quiet NaN
            invalid        = !(nan_a || nan_b);
        end else if (inf_a || inf_b) begin
            special_valid  = 1'b1;
            special_result = {result_sign, 8'hff, {MANTISSA_BITS{1'b0}}};
        end else if (zero_a || zero_b) begin
            special_valid  = 1'b1;
            special_result = {result_sign, {(WIDTH-1){1'b0}}};
        end
    end
endmodule


// Add and subtract. Subtraction is addition with the sign of b inverted,
// which the top level does before calling this.
module float_fpu_add #(
    parameter int unsigned MANTISSA_BITS = 7,
    parameter int unsigned WIDTH   = MANTISSA_BITS + 9,
    parameter int unsigned SIG     = MANTISSA_BITS + 1,
    parameter int unsigned ROUND_W = MANTISSA_BITS + 4
) (
    input  logic              sign_a,
    input  logic signed [9:0] exponent_a,
    input  logic [SIG-1:0]    significand_a,
    input  logic              zero_a, inf_a, nan_a,
    input  logic              sign_b,
    input  logic signed [9:0] exponent_b,
    input  logic [SIG-1:0]    significand_b,
    input  logic              zero_b, inf_b, nan_b,
    // Raw encodings, needed to pass an operand through unchanged when the
    // other is zero. The decoded fields cannot be used for that because
    // subnormals have been normalized.
    input  logic [WIDTH-1:0]  raw_a,
    input  logic [WIDTH-1:0]  raw_b,
    output logic              special_valid,
    output logic [WIDTH-1:0]  special_result,
    output logic              result_sign,
    output logic signed [11:0] result_exponent,
    output logic [ROUND_W-1:0] result_significand,
    output logic              result_sticky,
    output logic              invalid
);
    logic               a_is_larger;
    logic               large_sign;
    logic signed [9:0]  large_exponent, small_exponent;
    logic [SIG-1:0]     large_significand, small_significand;
    logic signed [11:0] shift_amount;
    logic [ROUND_W-1:0] large_extended, small_extended, small_shifted;
    logic               align_sticky;
    logic               effective_subtract;
    logic [ROUND_W:0]   sum;
    logic [ROUND_W-1:0] difference;
    logic [4:0]         leading_zeros;
    logic [4:0]         align_shift;

    always_comb begin
        // Order the operands by magnitude so the smaller one is the one that
        // gets shifted right.
        a_is_larger = (exponent_a > exponent_b) ||
                      ((exponent_a == exponent_b) &&
                       (significand_a >= significand_b));

        large_sign        = a_is_larger ? sign_a : sign_b;
        large_exponent    = a_is_larger ? exponent_a : exponent_b;
        small_exponent    = a_is_larger ? exponent_b : exponent_a;
        large_significand = a_is_larger ? significand_a : significand_b;
        small_significand = a_is_larger ? significand_b : significand_a;

        effective_subtract = sign_a ^ sign_b;

        large_extended = {large_significand, 3'b000};
        small_extended = {small_significand, 3'b000};

        shift_amount = signed'({{2{large_exponent[9]}}, large_exponent}) -
                       signed'({{2{small_exponent[9]}}, small_exponent});

        // Align, folding everything shifted past the sticky position into it.
        align_sticky  = 1'b0;
        align_shift   = 5'd0;
        leading_zeros = 5'd0;
        if (shift_amount >= signed'(12'(ROUND_W))) begin
            align_sticky  = |small_extended;
            small_shifted = '0;
        end else begin
            align_shift = shift_amount[4:0];
            for (int unsigned s = 0; s < ROUND_W; s++)
                if (s < {27'b0, align_shift})
                    align_sticky = align_sticky | small_extended[s];
            small_shifted = small_extended >> align_shift;
        end

        sum        = {1'b0, large_extended} + {1'b0, small_shifted};
        // Borrowing the sticky makes the difference the floor of the true
        // result, which is what round-to-nearest expects.
        difference = large_extended - small_shifted -
                     {{(ROUND_W-1){1'b0}}, align_sticky};

        result_sign        = large_sign;
        result_exponent    = signed'({{2{large_exponent[9]}}, large_exponent});
        result_significand = '0;
        result_sticky      = align_sticky;

        if (!effective_subtract) begin
            if (sum[ROUND_W]) begin
                result_significand = sum[ROUND_W:1];
                result_sticky      = align_sticky | sum[0];
                result_exponent    = result_exponent + 12'sd1;
            end else begin
                result_significand = sum[ROUND_W-1:0];
            end
        end else begin
            // Cancellation can only be severe when the exponents were close,
            // in which case nothing was shifted out and the sticky is zero.
            leading_zeros = 5'(ROUND_W);
            for (int unsigned j = 0; j < ROUND_W; j++)
                if (difference[j])
                    leading_zeros = 5'(ROUND_W - 1 - j);
            if (leading_zeros == 5'(ROUND_W)) begin
                result_significand = '0;
                result_exponent    = 12'sd0;
                result_sign        = 1'b0;          // exact zero is +0
            end else begin
                result_significand = difference << leading_zeros;
                result_exponent    = result_exponent -
                                     signed'({7'b0, leading_zeros});
            end
        end

        special_valid  = 1'b0;
        special_result = '0;
        invalid        = 1'b0;

        if (nan_a || nan_b || (inf_a && inf_b && (sign_a != sign_b))) begin
            special_valid  = 1'b1;
            special_result = {1'b0, 8'hff, 1'b1, {(MANTISSA_BITS-1){1'b0}}};
            invalid        = !(nan_a || nan_b);
        end else if (inf_a) begin
            special_valid  = 1'b1;
            special_result = {sign_a, 8'hff, {MANTISSA_BITS{1'b0}}};
        end else if (inf_b) begin
            special_valid  = 1'b1;
            special_result = {sign_b, 8'hff, {MANTISSA_BITS{1'b0}}};
        end else if (zero_a && zero_b) begin
            special_valid  = 1'b1;
            special_result = {sign_a & sign_b, {(WIDTH-1){1'b0}}};
        end else if (zero_a) begin
            special_valid  = 1'b1;
            special_result = raw_b;
        end else if (zero_b) begin
            special_valid  = 1'b1;
            special_result = raw_a;
        end
    end
endmodule


// Comparison, min/max and sign manipulation. All of these are integer work on
// the sign-magnitude encoding, which is why they cost so little next to the
// arithmetic blocks.
module float_fpu_compare #(
    parameter int unsigned MANTISSA_BITS = 7,
    parameter int unsigned WIDTH = MANTISSA_BITS + 9
) (
    input  logic [WIDTH-1:0] a,
    input  logic [WIDTH-1:0] b,
    input  logic        nan_a,
    input  logic        nan_b,
    output logic        less_than,
    output logic        equal,
    output logic        unordered,
    output logic [WIDTH-1:0] minimum,
    output logic [WIDTH-1:0] maximum
);
    logic [WIDTH-1:0] key_a, key_b;
    logic             a_below_b;
    logic [WIDTH-1:0] sign_mask, magnitude_mask, quiet_nan;

    always_comb begin
        sign_mask      = {1'b1, {(WIDTH-1){1'b0}}};
        magnitude_mask = {1'b0, {(WIDTH-1){1'b1}}};
        quiet_nan      = {1'b0, 8'hff, 1'b1, {(MANTISSA_BITS-1){1'b0}}};

        // Monotonic integer key: flip everything for negatives, set the top
        // bit for positives, so an unsigned compare orders the floats.
        key_a = a[WIDTH-1] ? ~a : (a | sign_mask);
        key_b = b[WIDTH-1] ? ~b : (b | sign_mask);

        unordered = nan_a | nan_b;
        // +0 and -0 must compare equal.
        equal     = !unordered &&
                    ((a == b) || (((a | b) & magnitude_mask) == '0));
        a_below_b = key_a < key_b;
        less_than = !unordered && !equal && a_below_b;

        // IEEE minNum/maxNum: a NaN operand is ignored unless both are NaN.
        if (nan_a && nan_b) begin
            minimum = quiet_nan;
            maximum = quiet_nan;
        end else if (nan_a) begin
            minimum = b;
            maximum = b;
        end else if (nan_b) begin
            minimum = a;
            maximum = a;
        end else if (equal && (a != b)) begin
            // Signed zeros: min picks -0, max picks +0.
            minimum = a[WIDTH-1] ? a : b;
            maximum = a[WIDTH-1] ? b : a;
        end else begin
            minimum = a_below_b ? a : b;
            maximum = a_below_b ? b : a;
        end
    end
endmodule


// Iterative divide and square root sharing one recurrence datapath.
//
// Both are restoring digit-recurrence: divide retires one quotient bit per
// cycle, square root one root bit per cycle consuming two radicand bits at a
// time, over ROUND_W cycles either way. This is the small, slow choice, which
// suits a unit where divide and sqrt are rare next to multiply and add.
module float_fpu_divsqrt #(
    parameter int unsigned MANTISSA_BITS = 7,
    parameter int unsigned WIDTH   = MANTISSA_BITS + 9,
    parameter int unsigned SIG     = MANTISSA_BITS + 1,
    parameter int unsigned ROUND_W = MANTISSA_BITS + 4
) (
    input  logic              clk,
    input  logic              reset,
    input  logic              start,
    input  logic              is_sqrt,
    input  logic              sign_a,
    input  logic signed [9:0] exponent_a,
    input  logic [SIG-1:0]    significand_a,
    input  logic              zero_a, inf_a, nan_a,
    input  logic              sign_b,
    input  logic signed [9:0] exponent_b,
    input  logic [SIG-1:0]    significand_b,
    input  logic              zero_b, inf_b, nan_b,
    output logic              busy,
    output logic              done,
    output logic              special_valid,
    output logic [WIDTH-1:0]  special_result,
    output logic              result_sign,
    output logic signed [11:0] result_exponent,
    output logic [ROUND_W-1:0] result_significand,
    output logic              result_sticky,
    output logic              invalid,
    output logic              divide_by_zero
);
    localparam int unsigned ITERATIONS  = ROUND_W;
    // The radicand is consumed two bits per iteration.
    localparam int unsigned RADICAND_W  = 2 * ROUND_W;
    // Partial remainder is bounded by 2*root+1, with headroom for the two
    // radicand bits appended each step.
    localparam int unsigned SQRT_REM_W  = ROUND_W + 5;
    localparam int unsigned SQRT_PAD    = RADICAND_W - (SIG + 1);

    logic [4:0]  counter;
    logic        active;
    logic        sqrt_mode;

    logic [SIG+1:0]  remainder;        // divide partial remainder
    logic [ROUND_W:0] quotient;
    logic [SIG-1:0]  divisor;

    logic [SQRT_REM_W-1:0] sqrt_remainder;
    logic [ROUND_W-1:0]    root;
    logic [RADICAND_W-1:0] radicand;

    logic              latched_sign;
    logic signed [11:0] latched_exponent;
    logic              latched_special_valid;
    logic [WIDTH-1:0]  latched_special_result;
    logic              latched_invalid;
    logic              latched_divide_by_zero;

    logic [SIG+1:0]        shifted_remainder;
    logic [SQRT_REM_W-1:0] sqrt_trial;
    logic [SQRT_REM_W-1:0] sqrt_shifted;

    logic signed [11:0] exponent_a_wide, exponent_b_wide;
    logic signed [11:0] unbiased;
    logic               odd_exponent;
    logic [SIG:0]       sqrt_input;
    logic [WIDTH-1:0]   quiet_nan;

    assign quiet_nan = {1'b0, 8'hff, 1'b1, {(MANTISSA_BITS-1){1'b0}}};

    assign exponent_a_wide = signed'({{2{exponent_a[9]}}, exponent_a});
    assign exponent_b_wide = signed'({{2{exponent_b[9]}}, exponent_b});
    assign unbiased        = exponent_a_wide - 12'sd127;
    assign odd_exponent    = unbiased[0];
    assign sqrt_input      = odd_exponent ? {significand_a, 1'b0}
                                          : {1'b0, significand_a};

    assign busy = active;

    // One recurrence step for each mode.
    assign shifted_remainder = {remainder[SIG:0], 1'b0};
    assign sqrt_shifted      = {sqrt_remainder[SQRT_REM_W-3:0],
                                radicand[RADICAND_W-1 -: 2]};
    assign sqrt_trial        = {{(SQRT_REM_W-ROUND_W-2){1'b0}}, root, 2'b01};

    always_ff @(posedge clk) begin
        if (reset) begin
            active   <= 1'b0;
            done     <= 1'b0;
            counter  <= 5'd0;
        end else begin
            done <= 1'b0;
            if (start && !active) begin
                sqrt_mode              <= is_sqrt;
                latched_sign           <= is_sqrt ? sign_a : (sign_a ^ sign_b);
                counter                <= 5'd0;
                divisor                <= significand_b;
                // Both significands are normalized, so the quotient is in
                // (0.5, 2) and one conditional subtract up front retires the
                // integer bit. Restoring division needs the remainder to stay
                // below the divisor, which this establishes.
                if (significand_a >= significand_b) begin
                    remainder <= {2'b0, significand_a} - {2'b0, significand_b};
                    quotient  <= {{ROUND_W{1'b0}}, 1'b1};
                end else begin
                    remainder <= {2'b0, significand_a};
                    quotient  <= '0;
                end
                sqrt_remainder         <= '0;
                root                   <= '0;
                radicand               <= {sqrt_input, {SQRT_PAD{1'b0}}};
                latched_exponent       <= is_sqrt
                                          ? ((unbiased >>> 1) + 12'sd127)
                                          : (exponent_a_wide - exponent_b_wide
                                             + 12'sd127);

                // Special cases are resolved up front so the recurrence only
                // ever sees finite normalized operands.
                latched_special_valid  <= 1'b0;
                latched_special_result <= '0;
                latched_invalid        <= 1'b0;
                latched_divide_by_zero <= 1'b0;
                if (is_sqrt) begin
                    if (nan_a) begin
                        latched_special_valid  <= 1'b1;
                        latched_special_result <= quiet_nan;
                    end else if (zero_a) begin
                        latched_special_valid  <= 1'b1;
                        latched_special_result <= {sign_a, {(WIDTH-1){1'b0}}};
                    end else if (sign_a) begin
                        latched_special_valid  <= 1'b1;
                        latched_special_result <= quiet_nan;
                        latched_invalid        <= 1'b1;
                    end else if (inf_a) begin
                        latched_special_valid  <= 1'b1;
                        latched_special_result <= {1'b0, 8'hff, {MANTISSA_BITS{1'b0}}};
                    end
                end else begin
                    if (nan_a || nan_b || (inf_a && inf_b) ||
                        (zero_a && zero_b)) begin
                        latched_special_valid  <= 1'b1;
                        latched_special_result <= quiet_nan;
                        latched_invalid        <= !(nan_a || nan_b);
                    end else if (zero_b) begin
                        latched_special_valid  <= 1'b1;
                        latched_special_result <= {sign_a ^ sign_b, 8'hff,
                                                   {MANTISSA_BITS{1'b0}}};
                        latched_divide_by_zero <= 1'b1;
                    end else if (inf_a) begin
                        latched_special_valid  <= 1'b1;
                        latched_special_result <= {sign_a ^ sign_b, 8'hff,
                                                   {MANTISSA_BITS{1'b0}}};
                    end else if (inf_b || zero_a) begin
                        latched_special_valid  <= 1'b1;
                        latched_special_result <= {sign_a ^ sign_b, {(WIDTH-1){1'b0}}};
                    end
                end
                active <= 1'b1;
            end else if (active) begin
                if (sqrt_mode) begin
                    radicand <= {radicand[RADICAND_W-3:0], 2'b00};
                    if (sqrt_shifted >= sqrt_trial) begin
                        sqrt_remainder <= sqrt_shifted - sqrt_trial;
                        root           <= {root[ROUND_W-2:0], 1'b1};
                    end else begin
                        sqrt_remainder <= sqrt_shifted;
                        root           <= {root[ROUND_W-2:0], 1'b0};
                    end
                end else begin
                    if (shifted_remainder >= {2'b0, divisor}) begin
                        remainder <= shifted_remainder - {2'b0, divisor};
                        quotient  <= {quotient[ROUND_W-1:0], 1'b1};
                    end else begin
                        remainder <= shifted_remainder;
                        quotient  <= {quotient[ROUND_W-1:0], 1'b0};
                    end
                end

                if (counter == 5'(ITERATIONS) - 5'd1) begin
                    active <= 1'b0;
                    done   <= 1'b1;
                end
                counter <= counter + 5'd1;
            end
        end
    end

    // Normalize the recurrence output into the shared round format.
    always_comb begin
        special_valid  = latched_special_valid;
        special_result = latched_special_result;
        invalid        = latched_invalid;
        divide_by_zero = latched_divide_by_zero;
        result_sign    = latched_sign;

        if (sqrt_mode) begin
            // root already has the hidden bit at the top.
            result_significand = root;
            result_sticky      = |sqrt_remainder;
            result_exponent    = latched_exponent;
        end else if (quotient[ROUND_W]) begin
            result_significand = quotient[ROUND_W:1];
            result_sticky      = quotient[0] | (|remainder);
            result_exponent    = latched_exponent;
        end else begin
            result_significand = quotient[ROUND_W-1:0];
            result_sticky      = |remainder;
            result_exponent    = latched_exponent - 12'sd1;
        end
    end
endmodule


// Top level. Multiply, add and divide/sqrt all feed one shared rounder, since
// rounding is identical for every operation once the result is in the internal
// form. Divide and sqrt are multi-cycle and raise `busy`; everything else
// completes in one cycle.
module float_fpu #(
    parameter int unsigned MANTISSA_BITS = 7,
    parameter bit          ENABLE_DIV_SQRT = 0,
    parameter int unsigned WIDTH   = MANTISSA_BITS + 9,
    parameter int unsigned SIG     = MANTISSA_BITS + 1,
    parameter int unsigned ROUND_W = MANTISSA_BITS + 4
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        valid_in,
    input  logic [3:0]  opcode,
    input  logic [WIDTH-1:0] a,
    input  logic [WIDTH-1:0] b,
    output logic [WIDTH-1:0] result,
    output logic        valid_out,
    output logic        busy,
    output logic [4:0]  flags        // {invalid, div_by_zero, of, uf, inexact}
);
    localparam logic [3:0] OP_ADD      = 4'd0;
    localparam logic [3:0] OP_SUB      = 4'd1;
    localparam logic [3:0] OP_MUL      = 4'd2;
    localparam logic [3:0] OP_MIN      = 4'd3;
    localparam logic [3:0] OP_MAX      = 4'd4;
    localparam logic [3:0] OP_ABS      = 4'd5;
    localparam logic [3:0] OP_NEG      = 4'd6;
    localparam logic [3:0] OP_COPYSIGN = 4'd7;
    localparam logic [3:0] OP_LT       = 4'd8;
    localparam logic [3:0] OP_LE       = 4'd9;
    localparam logic [3:0] OP_EQ       = 4'd10;
    localparam logic [3:0] OP_DIV      = 4'd11;
    localparam logic [3:0] OP_SQRT     = 4'd12;

    // Subtract is add with the sign of b inverted.
    logic [WIDTH-1:0] b_effective;
    assign b_effective = (opcode == OP_SUB)
                         ? {~b[WIDTH-1], b[WIDTH-2:0]} : b;

    logic              sign_a, zero_a, inf_a, nan_a;
    logic signed [9:0] exponent_a;
    logic [SIG-1:0]    significand_a;
    logic              sign_b, zero_b, inf_b, nan_b;
    logic signed [9:0] exponent_b;
    logic [SIG-1:0]    significand_b;

    float_fpu_decode #(.MANTISSA_BITS(MANTISSA_BITS)) decode_a (
        .value (a), .sign (sign_a), .exponent (exponent_a),
        .significand (significand_a), .is_zero (zero_a),
        .is_inf (inf_a), .is_nan (nan_a)
    );

    float_fpu_decode #(.MANTISSA_BITS(MANTISSA_BITS)) decode_b (
        .value (b_effective), .sign (sign_b), .exponent (exponent_b),
        .significand (significand_b), .is_zero (zero_b),
        .is_inf (inf_b), .is_nan (nan_b)
    );

    logic               mul_special_valid, mul_invalid;
    logic [WIDTH-1:0]   mul_special_result;
    logic               mul_sign, mul_sticky;
    logic signed [11:0] mul_exponent;
    logic [ROUND_W-1:0] mul_significand;

    float_fpu_mul #(.MANTISSA_BITS(MANTISSA_BITS)) multiply (
        .sign_a (sign_a), .exponent_a (exponent_a),
        .significand_a (significand_a),
        .zero_a (zero_a), .inf_a (inf_a), .nan_a (nan_a),
        .sign_b (sign_b), .exponent_b (exponent_b),
        .significand_b (significand_b),
        .zero_b (zero_b), .inf_b (inf_b), .nan_b (nan_b),
        .special_valid (mul_special_valid),
        .special_result (mul_special_result),
        .result_sign (mul_sign), .result_exponent (mul_exponent),
        .result_significand (mul_significand), .result_sticky (mul_sticky),
        .invalid (mul_invalid)
    );

    logic               add_special_valid, add_invalid;
    logic [WIDTH-1:0]   add_special_result;
    logic               add_sign, add_sticky;
    logic signed [11:0] add_exponent;
    logic [ROUND_W-1:0] add_significand;

    float_fpu_add #(.MANTISSA_BITS(MANTISSA_BITS)) adder (
        .sign_a (sign_a), .exponent_a (exponent_a),
        .significand_a (significand_a),
        .zero_a (zero_a), .inf_a (inf_a), .nan_a (nan_a),
        .sign_b (sign_b), .exponent_b (exponent_b),
        .significand_b (significand_b),
        .zero_b (zero_b), .inf_b (inf_b), .nan_b (nan_b),
        .raw_a (a), .raw_b (b_effective),
        .special_valid (add_special_valid),
        .special_result (add_special_result),
        .result_sign (add_sign), .result_exponent (add_exponent),
        .result_significand (add_significand), .result_sticky (add_sticky),
        .invalid (add_invalid)
    );

    logic        compare_less, compare_equal;
    logic [WIDTH-1:0] compare_minimum, compare_maximum;

    float_fpu_compare #(.MANTISSA_BITS(MANTISSA_BITS)) comparator (
        .a (a), .b (b), .nan_a (nan_a), .nan_b (nan_b),
        .less_than (compare_less), .equal (compare_equal),
        .unordered (),
        .minimum (compare_minimum), .maximum (compare_maximum)
    );

    logic               divsqrt_busy, divsqrt_done;
    logic               divsqrt_special_valid, divsqrt_invalid, divsqrt_dbz;
    logic [WIDTH-1:0]   divsqrt_special_result;
    logic               divsqrt_sign, divsqrt_sticky;
    logic signed [11:0] divsqrt_exponent;
    logic [ROUND_W-1:0] divsqrt_significand;
    logic               divsqrt_start;

    assign divsqrt_start = ENABLE_DIV_SQRT && valid_in && !divsqrt_busy &&
                           ((opcode == OP_DIV) || (opcode == OP_SQRT));

    generate
        if (ENABLE_DIV_SQRT) begin : g_divsqrt
            float_fpu_divsqrt #(.MANTISSA_BITS(MANTISSA_BITS)) divider (
                .clk (clk), .reset (reset),
                .start (divsqrt_start), .is_sqrt (opcode == OP_SQRT),
                .sign_a (sign_a), .exponent_a (exponent_a),
                .significand_a (significand_a),
                .zero_a (zero_a), .inf_a (inf_a), .nan_a (nan_a),
                .sign_b (sign_b), .exponent_b (exponent_b),
                .significand_b (significand_b),
                .zero_b (zero_b), .inf_b (inf_b), .nan_b (nan_b),
                .busy (divsqrt_busy), .done (divsqrt_done),
                .special_valid (divsqrt_special_valid),
                .special_result (divsqrt_special_result),
                .result_sign (divsqrt_sign),
                .result_exponent (divsqrt_exponent),
                .result_significand (divsqrt_significand),
                .result_sticky (divsqrt_sticky),
                .invalid (divsqrt_invalid),
                .divide_by_zero (divsqrt_dbz)
            );
        end else begin : g_no_divsqrt
            always_comb begin
                divsqrt_busy           = 1'b0;
                divsqrt_done           = 1'b0;
                divsqrt_special_valid  = 1'b0;
                divsqrt_special_result = '0;
                divsqrt_sign           = 1'b0;
                divsqrt_exponent       = 12'sd0;
                divsqrt_significand    = '0;
                divsqrt_sticky         = 1'b0;
                divsqrt_invalid        = 1'b0;
                divsqrt_dbz            = 1'b0;
            end
        end
    endgenerate

    // One rounder shared by every arithmetic path.
    logic               round_sign, round_sticky;
    logic signed [11:0] round_exponent;
    logic [ROUND_W-1:0] round_significand;
    logic [WIDTH-1:0]   rounded;
    logic               round_overflow, round_underflow, round_inexact;
    logic               use_divsqrt;

    assign use_divsqrt = ENABLE_DIV_SQRT &&
                         ((opcode == OP_DIV) || (opcode == OP_SQRT));

    always_comb begin
        if (use_divsqrt) begin
            round_sign        = divsqrt_sign;
            round_exponent    = divsqrt_exponent;
            round_significand = divsqrt_significand;
            round_sticky      = divsqrt_sticky;
        end else if (opcode == OP_MUL) begin
            round_sign        = mul_sign;
            round_exponent    = mul_exponent;
            round_significand = mul_significand;
            round_sticky      = mul_sticky;
        end else begin
            round_sign        = add_sign;
            round_exponent    = add_exponent;
            round_significand = add_significand;
            round_sticky      = add_sticky;
        end
    end

    float_fpu_round #(.MANTISSA_BITS(MANTISSA_BITS)) rounder (
        .sign (round_sign), .exponent (round_exponent),
        .significand (round_significand), .sticky_in (round_sticky),
        .result (rounded), .overflow (round_overflow),
        .underflow (round_underflow), .inexact (round_inexact)
    );

    logic [WIDTH-1:0] operation_result;
    logic        operation_invalid;
    logic        operation_dbz;
    logic        arithmetic_special;
    logic [WIDTH-1:0] arithmetic_special_result;

    always_comb begin
        arithmetic_special        = use_divsqrt ? divsqrt_special_valid
                                  : (opcode == OP_MUL) ? mul_special_valid
                                  : add_special_valid;
        arithmetic_special_result = use_divsqrt ? divsqrt_special_result
                                  : (opcode == OP_MUL) ? mul_special_result
                                  : add_special_result;

        operation_invalid = 1'b0;
        operation_dbz     = 1'b0;
        operation_result  = arithmetic_special ? arithmetic_special_result
                                               : rounded;

        case (opcode)
            OP_ADD, OP_SUB: operation_invalid = add_invalid;
            OP_MUL:         operation_invalid = mul_invalid;
            OP_MIN:         operation_result  = compare_minimum;
            OP_MAX:         operation_result  = compare_maximum;
            OP_ABS:         operation_result  = {1'b0, a[WIDTH-2:0]};
            OP_NEG:         operation_result  = {~a[WIDTH-1], a[WIDTH-2:0]};
            OP_COPYSIGN:    operation_result  = {b[WIDTH-1], a[WIDTH-2:0]};
            OP_LT:          operation_result  = {{(WIDTH-1){1'b0}}, compare_less};
            OP_LE:          operation_result  = {{(WIDTH-1){1'b0}},
                                                 compare_less | compare_equal};
            OP_EQ:          operation_result  = {{(WIDTH-1){1'b0}}, compare_equal};
            OP_DIV, OP_SQRT: begin
                operation_invalid = divsqrt_invalid;
                operation_dbz     = divsqrt_dbz;
            end
            default: ;
        endcase
    end

    logic result_is_arithmetic;
    assign result_is_arithmetic = (opcode == OP_ADD) || (opcode == OP_SUB) ||
                                  (opcode == OP_MUL) || use_divsqrt;

    always_ff @(posedge clk) begin
        if (reset) begin
            result    <= '0;
            valid_out <= 1'b0;
            flags     <= 5'b0;
        end else begin
            valid_out <= 1'b0;
            if (use_divsqrt) begin
                if (divsqrt_done) begin
                    result    <= operation_result;
                    valid_out <= 1'b1;
                    flags     <= {operation_invalid, operation_dbz,
                                  arithmetic_special ? 1'b0 : round_overflow,
                                  arithmetic_special ? 1'b0 : round_underflow,
                                  arithmetic_special ? 1'b0 : round_inexact};
                end
            end else if (valid_in) begin
                result    <= operation_result;
                valid_out <= 1'b1;
                flags     <= {operation_invalid, 1'b0,
                              (result_is_arithmetic && !arithmetic_special)
                                  ? round_overflow : 1'b0,
                              (result_is_arithmetic && !arithmetic_special)
                                  ? round_underflow : 1'b0,
                              (result_is_arithmetic && !arithmetic_special)
                                  ? round_inexact : 1'b0};
            end
        end
    end

    assign busy = divsqrt_busy;
endmodule


// Round the shared internal form back to a BF16 encoding.
//
// significand carries {hidden, frac[6:0], guard, round, sticky} with the hidden
// bit at position 10. An exponent at or below zero produces a subnormal: the
// significand is denormalized by shifting right, accumulating anything shifted
// out into the sticky bit, so the result is still correctly rounded.
module float_fpu_round #(
    parameter int unsigned MANTISSA_BITS = 7,
    parameter int unsigned WIDTH   = MANTISSA_BITS + 9,
    parameter int unsigned ROUND_W = MANTISSA_BITS + 4
) (
    input  logic               sign,
    input  logic signed [11:0] exponent,
    input  logic [ROUND_W-1:0] significand,
    input  logic               sticky_in,
    output logic [WIDTH-1:0]   result,
    output logic               overflow,
    output logic               underflow,
    output logic               inexact
);
    logic signed [11:0] effective_exponent;
    logic signed [11:0] shift_signed;
    logic [4:0]         shift_amount;
    logic [ROUND_W-1:0] shifted;
    logic               shifted_sticky;
    logic               guard, round_bit, sticky, lsb, round_up;
    logic [MANTISSA_BITS:0] rounded;
    logic signed [11:0] final_exponent;

    always_comb begin
        shifted        = significand;
        shifted_sticky = sticky_in;
        shift_amount   = 5'd0;
        shift_signed   = 12'sd0;

        if (exponent <= 0) begin
            // Denormalize into the subnormal range.
            shift_signed = 12'sd1 - exponent;
            if (shift_signed >= signed'(12'(ROUND_W))) begin
                shifted_sticky = sticky_in | (|significand);
                shifted        = '0;
            end else begin
                shift_amount   = shift_signed[4:0];
                shifted_sticky = sticky_in;
                for (int unsigned s = 0; s < ROUND_W; s++)
                    if (s < {27'b0, shift_amount})
                        shifted_sticky = shifted_sticky | significand[s];
                shifted = significand >> shift_amount;
            end
            effective_exponent = 12'sd0;
        end else begin
            effective_exponent = exponent;
        end

        guard     = shifted[2];
        round_bit = shifted[1];
        sticky    = shifted[0] | shifted_sticky;
        lsb       = shifted[3];
        round_up  = guard & (round_bit | sticky | lsb);

        rounded = {1'b0, shifted[ROUND_W-2:3]} +
                  {{MANTISSA_BITS{1'b0}}, round_up};

        // A carry out of the fraction bumps the exponent; from the subnormal
        // range that promotes the result to the smallest normal.
        final_exponent = rounded[MANTISSA_BITS]
                         ? effective_exponent + 12'sd1 : effective_exponent;

        inexact   = guard | round_bit | sticky;
        overflow  = 1'b0;
        underflow = 1'b0;

        if (final_exponent >= 12'sd255) begin
            result   = {sign, 8'hff, {MANTISSA_BITS{1'b0}}};
            overflow = 1'b1;
            inexact  = 1'b1;
        end else begin
            result = {sign, final_exponent[7:0], rounded[MANTISSA_BITS-1:0]};
            if (final_exponent == 0) begin
                underflow = inexact;
                if (rounded[MANTISSA_BITS-1:0] == '0)
                    result = {sign, {(WIDTH-1){1'b0}}};
            end
        end
    end
endmodule


// BF16: 1 sign / 8 exponent / 7 mantissa, 16 bits.
module bf16_fpu #(
    parameter bit ENABLE_DIV_SQRT = 0
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        valid_in,
    input  logic [3:0]  opcode,
    input  logic [15:0] a,
    input  logic [15:0] b,
    output logic [15:0] result,
    output logic        valid_out,
    output logic        busy,
    output logic [4:0]  flags
);
    float_fpu #(
        .MANTISSA_BITS   (7),
        .ENABLE_DIV_SQRT (ENABLE_DIV_SQRT)
    ) core (.*);
endmodule


// BF19: 1 sign / 8 exponent / 10 mantissa, 19 bits. This is the TensorFloat-32
// value layout, which NVIDIA stores inside a 32-bit container; here it is
// carried in its natural 19 bits.
module bf19_fpu #(
    parameter bit ENABLE_DIV_SQRT = 0
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        valid_in,
    input  logic [3:0]  opcode,
    input  logic [18:0] a,
    input  logic [18:0] b,
    output logic [18:0] result,
    output logic        valid_out,
    output logic        busy,
    output logic [4:0]  flags
);
    float_fpu #(
        .MANTISSA_BITS   (10),
        .ENABLE_DIV_SQRT (ENABLE_DIV_SQRT)
    ) core (.*);
endmodule
