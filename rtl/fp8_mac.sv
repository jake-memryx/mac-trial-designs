`timescale 1ns/1ps

// Dual-format multiplier: BF16 or E4M3 (OCP FP8) in, FP32-encoded product out.
//
// Both formats share one significand datapath. A BF16 significand is
// {1'b1, frac[6:0]}, an integer equal to value * 2^7. Left-justifying the
// 3-bit E4M3 mantissa as {1'b1, mant[2:0], 4'b0} gives exactly the same
// scaling, so the 8x8 multiply, the normalize-on-bit-15 test and the FP32
// result encoding are bit-identical in both modes. Only the exponent bias
// differs:
//
//   BF16 : result_exp = exp_a + exp_b - 127
//   E4M3 : result_exp = exp_a + exp_b + 113
//
// Derivation for E4M3: the encoded value is 2^(result_exp-127) *
// sig_product/2^15 and the true product is sig_product * 2^(ea+eb-28), so
// result_exp = ea + eb + 114 after the +1 applied on normalize.
//
// E4M3 products land in [115,143] in the FP32 exponent field, so they can
// neither overflow nor underflow it. The saturation and underflow guards below
// are therefore dead in FP8 mode and only serve the BF16 path.
//
// E4M3 follows the OCP FP8 spec: no infinity, NaN is only S.1111.111, the
// largest finite value is 448, and subnormals (exp==0, mant!=0) are normalized
// properly rather than flushed.

module mac_multiplier #(
    // Set 0 for lanes that only ever carry FP8. The BF16 decode folds away and
    // the lane emits zero in BF16 mode.
    parameter bit SUPPORT_BF16 = 1
) (
    input  logic        mode,      // 0 = BF16, 1 = E4M3
    input  logic [15:0] bf16_a,
    input  logic [15:0] bf16_b,
    input  logic [7:0]  fp8_a,
    input  logic [7:0]  fp8_b,
    output logic [31:0] product
);
    typedef struct packed {
        logic               sign;
        logic signed [9:0]  exponent;
        logic [7:0]         significand;
        logic               is_zero;
        logic               is_nan;
        logic               is_inf;
    } operand_t;

    // E4M3: 1 sign, 4 exponent (bias 7), 3 mantissa.
    function automatic operand_t decode_e4m3(input logic [7:0] value);
        operand_t   out;
        logic [3:0] exponent_field;
        logic [2:0] mantissa;
        logic [2:0] normalized_mantissa;
        logic [1:0] leading_one;
        logic [2:0] shift_amount;
        begin
            exponent_field = value[6:3];
            mantissa       = value[2:0];

            out.sign        = value[7];
            out.exponent    = '0;
            out.significand = '0;
            out.is_zero     = 1'b0;
            out.is_nan      = 1'b0;
            out.is_inf      = 1'b0;   // E4M3 has no infinity encoding.

            if (exponent_field == 4'hf && mantissa == 3'h7) begin
                out.is_nan = 1'b1;
            end else if (exponent_field == 4'h0 && mantissa == 3'h0) begin
                out.is_zero = 1'b1;
            end else if (exponent_field == 4'h0) begin
                // Subnormal: value = 2^-6 * mantissa/8 = 2^(k-9) * 1.frac,
                // where k is the position of the leading one. In the normal
                // form 2^(e-7) * 1.frac that is e = k - 2.
                leading_one  = mantissa[2] ? 2'd2 : (mantissa[1] ? 2'd1 : 2'd0);
                shift_amount = 3'd3 - {1'b0, leading_one};
                normalized_mantissa = mantissa << shift_amount;
                out.exponent    = signed'({8'b0, leading_one}) - 10'sd2;
                out.significand = {1'b1, normalized_mantissa, 4'b0};
            end else begin
                out.exponent    = signed'({6'b0, exponent_field});
                out.significand = {1'b1, mantissa, 4'b0};
            end
            return out;
        end
    endfunction

    // BF16: 1 sign, 8 exponent (bias 127), 7 mantissa. Subnormals flush to
    // zero, matching bf16_multiplier.
    function automatic operand_t decode_bf16(input logic [15:0] value);
        operand_t   out;
        logic [7:0] exponent_field;
        logic [6:0] mantissa;
        begin
            exponent_field = value[14:7];
            mantissa       = value[6:0];

            out.sign        = value[15];
            out.exponent    = '0;
            out.significand = '0;
            out.is_zero     = 1'b0;
            out.is_nan      = 1'b0;
            out.is_inf      = 1'b0;

            if (exponent_field == 8'hff && mantissa != 0) begin
                out.is_nan = 1'b1;
            end else if (exponent_field == 8'hff) begin
                out.is_inf = 1'b1;
            end else if (exponent_field == 8'h00) begin
                out.is_zero = 1'b1;
            end else begin
                out.exponent    = signed'({2'b0, exponent_field});
                out.significand = {1'b1, mantissa};
            end
            return out;
        end
    endfunction

    operand_t    operand_a, operand_b;
    logic        sign;
    logic [15:0] significand_product;
    integer      result_exponent;

    always_comb begin
        if (SUPPORT_BF16 && !mode) begin
            operand_a = decode_bf16(bf16_a);
            operand_b = decode_bf16(bf16_b);
        end else begin
            operand_a = decode_e4m3(fp8_a);
            operand_b = decode_e4m3(fp8_b);
        end

        sign                = operand_a.sign ^ operand_b.sign;
        significand_product = operand_a.significand * operand_b.significand;
        result_exponent     = 0;
        product             = {sign, 31'b0};

        if (!SUPPORT_BF16 && !mode) begin
            // FP8-only lane idles during BF16 operation. A zero product
            // contributes nothing to the reduction tree.
            product = 32'b0;
        end else if (operand_a.is_nan || operand_b.is_nan ||
                     (operand_a.is_inf && operand_b.is_zero) ||
                     (operand_b.is_inf && operand_a.is_zero)) begin
            product = 32'h7fc00000;
        end else if (operand_a.is_inf || operand_b.is_inf) begin
            product = {sign, 8'hff, 23'b0};
        end else if (operand_a.is_zero || operand_b.is_zero) begin
            product = {sign, 31'b0};
        end else begin
            result_exponent = operand_a.exponent + operand_b.exponent +
                              (mode ? 113 : -127);

            if (significand_product[15]) begin
                result_exponent = result_exponent + 1;
                if (result_exponent >= 255)
                    product = {sign, 8'hff, 23'b0};
                else if (result_exponent > 0)
                    product = {sign, result_exponent[7:0],
                               significand_product[14:0], 8'b0};
            end else begin
                if (result_exponent >= 255)
                    product = {sign, 8'hff, 23'b0};
                else if (result_exponent > 0)
                    product = {sign, result_exponent[7:0],
                               significand_product[13:0], 9'b0};
            end
        end
    end
endmodule
