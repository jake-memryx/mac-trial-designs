`timescale 1ns/1ps

// Self-checking testbench for the standalone BF16 adder and multiplier.
//
// Both units are instantiated once. The reference model evaluates the operation
// in double precision and then rounds once to BF16 with round-to-nearest,
// ties-to-even and flush-to-zero, which is exactly the DUT contract: a double
// holds every BF16 sum and product with enough headroom that rounding the
// double and rounding the infinitely precise result agree.
module bf16_arith_tb;
    logic [15:0] a, b;
    logic [15:0] add_result;
    logic [15:0] mul_result;

    int unsigned errors = 0;
    int unsigned checks = 0;

    bf16_add u_add (.a(a), .b(b), .result(add_result));
    bf16_mul u_mul (.a(a), .b(b), .result(mul_result));

    // ------------------------------------------------------------------
    // Reference model
    // ------------------------------------------------------------------
    function automatic bit bf16_is_nan(logic [15:0] v);
        return (v[14:7] == 8'hff) && (v[6:0] != 7'h00);
    endfunction

    function automatic bit bf16_is_inf(logic [15:0] v);
        return (v[14:7] == 8'hff) && (v[6:0] == 7'h00);
    endfunction

    // Flush-to-zero decode: a zero exponent field is zero, never subnormal.
    function automatic real bf16_to_real(logic [15:0] v);
        logic [63:0] bits;
        if (v[14:7] == 8'h00) begin
            return 0.0;
        end
        // BF16 shares the FP32 exponent range, so widening is exact.
        bits = {v[15], 3'b0, v[14:7], 44'b0};
        if (v[14:7] != 8'h00) begin
            bits[62:52] = 11'd1023 + {3'b0, v[14:7]} - 11'd127;
            bits[51:45] = v[6:0];
            bits[44:0]  = '0;
            bits[63]    = v[15];
        end
        return $bitstoreal(bits);
    endfunction

    // Round a double to BF16: round-to-nearest ties-to-even, overflow to
    // infinity, underflow flushed to signed zero.
    function automatic logic [15:0] real_to_bf16(real r);
        logic [63:0]        bits;
        logic               sign;
        logic [10:0]        exponent_field;
        logic [51:0]        fraction;
        logic signed [12:0] exponent;
        logic [7:0]         significand;
        logic               guard, sticky, round_up;

        bits           = $realtobits(r);
        sign           = bits[63];
        exponent_field = bits[62:52];
        fraction       = bits[51:0];

        if (exponent_field == 11'h7ff) begin
            // Infinity or NaN.
            return (fraction == '0) ? {sign, 8'hff, 7'h00} : {1'b0, 8'hff, 7'h40};
        end
        if (exponent_field == 11'h000) begin
            // Zero or a double subnormal, both far below the BF16 range.
            return {sign, 15'h0000};
        end

        exponent    = signed'({2'b0, exponent_field}) - 13'sd1023 + 13'sd127;
        significand = {1'b1, fraction[51:45]};
        guard       = fraction[44];
        sticky      = |fraction[43:0];
        round_up    = guard && (sticky || fraction[45]);

        significand = significand + {7'b0, round_up};
        if (round_up && (significand == 8'h00)) begin
            exponent    = exponent + 13'sd1;
            significand = 8'h80;
        end

        if (exponent >= 13'sd255) begin
            return {sign, 8'hff, 7'h00};
        end
        if (exponent <= 13'sd0) begin
            return {sign, 15'h0000};
        end
        return {sign, exponent[7:0], significand[6:0]};
    endfunction

    function automatic logic [15:0] reference_add(logic [15:0] x, logic [15:0] y);
        logic sx, sy;
        sx = x[15];
        sy = y[15];
        if (bf16_is_nan(x) || bf16_is_nan(y)) return {1'b0, 8'hff, 7'h40};
        if (bf16_is_inf(x) && bf16_is_inf(y)) begin
            return (sx != sy) ? {1'b0, 8'hff, 7'h40} : {sx, 8'hff, 7'h00};
        end
        if (bf16_is_inf(x)) return {sx, 8'hff, 7'h00};
        if (bf16_is_inf(y)) return {sy, 8'hff, 7'h00};
        // Signed zero cases are not distinguishable through a double sum.
        if ((x[14:7] == 8'h00) && (y[14:7] == 8'h00)) return {sx & sy, 15'h0000};
        if (x[14:7] == 8'h00) return {sy, y[14:7], y[6:0]};
        if (y[14:7] == 8'h00) return {sx, x[14:7], x[6:0]};
        if ((x[14:0] == y[14:0]) && (sx != sy)) return 16'h0000;
        return real_to_bf16(bf16_to_real(x) + bf16_to_real(y));
    endfunction

    function automatic logic [15:0] reference_mul(logic [15:0] x, logic [15:0] y);
        logic sign;
        sign = x[15] ^ y[15];
        if (bf16_is_nan(x) || bf16_is_nan(y)) return {1'b0, 8'hff, 7'h40};
        if (bf16_is_inf(x) && (y[14:7] == 8'h00)) return {1'b0, 8'hff, 7'h40};
        if (bf16_is_inf(y) && (x[14:7] == 8'h00)) return {1'b0, 8'hff, 7'h40};
        if (bf16_is_inf(x) || bf16_is_inf(y)) return {sign, 8'hff, 7'h00};
        if ((x[14:7] == 8'h00) || (y[14:7] == 8'h00)) return {sign, 15'h0000};
        return real_to_bf16(bf16_to_real(x) * bf16_to_real(y));
    endfunction

    // ------------------------------------------------------------------
    // Checking
    // ------------------------------------------------------------------
    task automatic apply(logic [15:0] x, logic [15:0] y);
        logic [15:0] expected_add;
        logic [15:0] expected_mul;
        a = x;
        b = y;
        #1;
        expected_add = reference_add(x, y);
        expected_mul = reference_mul(x, y);
        checks += 2;
        if (add_result !== expected_add) begin
            errors++;
            if (errors < 20) begin
                $display("FAIL add: a=%04h b=%04h got=%04h exp=%04h",
                         x, y, add_result, expected_add);
            end
        end
        if (mul_result !== expected_mul) begin
            errors++;
            if (errors < 20) begin
                $display("FAIL mul: a=%04h b=%04h got=%04h exp=%04h",
                         x, y, mul_result, expected_mul);
            end
        end
    endtask

    // A spread of interesting encodings: zeros, one, powers of two, all-ones
    // fractions, the exponent extremes, infinities and NaNs.
    logic [15:0] corner [] = '{
        16'h0000, 16'h8000,                     // +0, -0
        16'h3f80, 16'hbf80,                     // +1, -1
        16'h4000, 16'hc000,                     // +2, -2
        16'h3f00, 16'h3f7f,                     // 0.5, just below 1
        16'h4180, 16'h41ff,                     // 16, 31.875
        16'h0080, 16'h8080,                     // smallest normal +/-
        16'h7f00, 16'hff00,                     // largest exponent, frac 0
        16'h7f7f, 16'hff7f,                     // largest finite +/-
        16'h7f80, 16'hff80,                     // +inf, -inf
        16'h7fc0, 16'hffc0,                     // quiet NaN +/-
        16'h0001, 16'h807f,                     // subnormal encodings (FTZ)
        16'h3fff, 16'h4001                      // odd fractions
    };

    // Random normal encoding with an exponent in [lo, hi].
    function automatic logic [15:0] random_normal(int unsigned lo, int unsigned hi);
        logic       sign;
        logic [7:0] exponent;
        logic [6:0] fraction;
        sign     = 1'($urandom_range(0, 1));
        exponent = 8'($urandom_range(lo, hi));
        fraction = 7'($urandom_range(0, 127));
        return {sign, exponent, fraction};
    endfunction

    // Random normal encoding with a fixed exponent.
    function automatic logic [15:0] random_at_exponent(logic [7:0] exponent);
        logic       sign;
        logic [6:0] fraction;
        sign     = 1'($urandom_range(0, 1));
        fraction = 7'($urandom_range(0, 127));
        return {sign, exponent, fraction};
    endfunction

    initial begin
        // Directed corner cross-product.
        foreach (corner[i]) begin
            foreach (corner[j]) begin
                apply(corner[i], corner[j]);
            end
        end

        // Random normals, which exercise alignment, cancellation and rounding.
        for (int unsigned n = 0; n < 200000; n++) begin
            apply(random_normal(1, 254), random_normal(1, 254));
        end

        // Near-cancellation and near-equal exponents, where the adder's
        // normalization and sticky handling are hardest.
        for (int unsigned n = 0; n < 200000; n++) begin
            logic [15:0] x;
            logic [7:0]  exponent;
            exponent = 8'($urandom_range(2, 253));
            x = random_at_exponent(exponent);
            // Same exponent, or one step either side.
            apply(x, random_at_exponent(
                      8'(exponent + 8'($urandom_range(0, 2)) - 8'd1)));
            // Exact cancellation and exact doubling of the same magnitude.
            apply(x, {~x[15], x[14:0]});
            apply(x, x);
        end

        // Overflow and underflow pressure at the exponent extremes.
        for (int unsigned n = 0; n < 50000; n++) begin
            apply(random_normal(248, 254), random_normal(248, 254));
            apply(random_normal(1, 8), random_normal(1, 8));
            // Wide exponent separation, where alignment drops the whole small
            // operand into the sticky bit.
            apply(random_normal(200, 254), random_normal(1, 40));
        end

        if (errors == 0) begin
            $display("bf16_arith_tb: PASS (%0d checks)", checks);
        end else begin
            $display("bf16_arith_tb: FAIL (%0d errors of %0d checks)", errors, checks);
        end
        $finish;
    end
endmodule
