`timescale 1ns/1ps

// Exhaustive verification of the dual-format multiplier.
//
// E4M3 has only 256 encodings, so all 65536 input pairs are checked against a
// real-valued reference, covering every subnormal, NaN, zero and the 448 max
// normal. The BF16 mode is checked for bit-exact equivalence against the
// original bf16_multiplier on directed specials plus random vectors.
module fp8_mac_tb;
    logic [15:0] bf16_a, bf16_b;
    logic [7:0]  fp8_a, fp8_b;
    logic        mode;

    logic [31:0] fp8_only_product;
    logic [31:0] dual_product;
    logic [31:0] reference_bf16_product;

    int failures = 0;
    int checked  = 0;

    // FP8-only lane: BF16 decode folds away, emits zero in BF16 mode.
    mac_multiplier #(.SUPPORT_BF16(0)) dut_fp8 (
        .mode    (mode),
        .bf16_a  (16'b0),
        .bf16_b  (16'b0),
        .fp8_a   (fp8_a),
        .fp8_b   (fp8_b),
        .product (fp8_only_product)
    );

    // Dual-format lane.
    mac_multiplier #(.SUPPORT_BF16(1)) dut_dual (
        .mode    (mode),
        .bf16_a  (bf16_a),
        .bf16_b  (bf16_b),
        .fp8_a   (fp8_a),
        .fp8_b   (fp8_b),
        .product (dual_product)
    );

    // Golden model for BF16 mode.
    bf16_multiplier reference_multiplier (
        .a       (bf16_a),
        .b       (bf16_b),
        .product (reference_bf16_product)
    );

    // OCP E4M3: bias 7, no infinity, NaN only at S.1111.111.
    function automatic bit e4m3_is_nan(input logic [7:0] value);
        return (value[6:3] == 4'hf) && (value[2:0] == 3'h7);
    endfunction

    function automatic real e4m3_to_real(input logic [7:0] value);
        logic [3:0] exponent_field;
        logic [2:0] mantissa;
        real        magnitude;
        begin
            exponent_field = value[6:3];
            mantissa       = value[2:0];
            if (exponent_field == 4'h0)
                magnitude = (real'(mantissa) / 8.0) * (2.0 ** -6.0);
            else
                magnitude = (1.0 + real'(mantissa) / 8.0) *
                            (2.0 ** (real'(exponent_field) - 7.0));
            return value[7] ? -magnitude : magnitude;
        end
    endfunction

    task automatic check_fp8(input logic [7:0] va, input logic [7:0] vb);
        real         expected;
        logic [31:0] expected_bits;
        logic        expected_sign;
        begin
            checked++;
            if (e4m3_is_nan(va) || e4m3_is_nan(vb)) begin
                if (fp8_only_product !== 32'h7fc00000) begin
                    $error("E4M3 %02h * %02h: expected quiet NaN, got %08h",
                           va, vb, fp8_only_product);
                    failures++;
                end
                return;
            end

            expected      = e4m3_to_real(va) * e4m3_to_real(vb);
            expected_sign = va[7] ^ vb[7];

            if (expected == 0.0) begin
                // Signed zero: magnitude must be zero, sign must be the xor.
                if (fp8_only_product[30:0] !== 31'b0 ||
                    fp8_only_product[31] !== expected_sign) begin
                    $error("E4M3 %02h * %02h: expected signed zero (s=%0b), got %08h",
                           va, vb, expected_sign, fp8_only_product);
                    failures++;
                end
                return;
            end

            // A product of two E4M3 values has at most 8 significant bits and
            // an exponent well inside the FP32 range, so it is exact.
            expected_bits = $shortrealtobits(shortreal'(expected));
            if (fp8_only_product !== expected_bits) begin
                $error("E4M3 %02h * %02h: expected %08h (%f), got %08h",
                       va, vb, expected_bits, expected, fp8_only_product);
                failures++;
            end
        end
    endtask

    task automatic check_bf16(input logic [15:0] va, input logic [15:0] vb);
        begin
            checked++;
            if (dual_product !== reference_bf16_product) begin
                $error("BF16 %04h * %04h: reference %08h, dual-mode %08h",
                       va, vb, reference_bf16_product, dual_product);
                failures++;
            end
        end
    endtask

    initial begin
        mode   = 1'b1;
        bf16_a = 16'b0;
        bf16_b = 16'b0;

        // Exhaustive E4M3 x E4M3.
        for (int ia = 0; ia < 256; ia++) begin
            for (int ib = 0; ib < 256; ib++) begin
                fp8_a = ia[7:0];
                fp8_b = ib[7:0];
                #1;
                check_fp8(fp8_a, fp8_b);
                // The dual-format lane must agree with the FP8-only lane.
                if (dual_product !== fp8_only_product) begin
                    $error("E4M3 %02h * %02h: fp8-only %08h, dual %08h",
                           fp8_a, fp8_b, fp8_only_product, dual_product);
                    failures++;
                end
            end
        end
        $display("PASS: exhaustive E4M3 multiply (%0d pairs)", 256 * 256);

        // An FP8-only lane must be silent in BF16 mode.
        mode = 1'b0;
        for (int ia = 0; ia < 256; ia += 7) begin
            fp8_a = ia[7:0];
            fp8_b = 8'h3c;
            #1;
            if (fp8_only_product !== 32'b0) begin
                $error("FP8-only lane not idle in BF16 mode: got %08h",
                       fp8_only_product);
                failures++;
            end
        end
        $display("PASS: FP8-only lane idles in BF16 mode");

        // BF16 equivalence: directed specials.
        begin
            logic [15:0] specials [0:11];
            specials = '{16'h0000, 16'h8000, 16'h3f80, 16'hbf80,
                         16'h4000, 16'h7f80, 16'hff80, 16'h7fc0,
                         16'h0001, 16'h007f, 16'h7f7f, 16'hff7f};
            for (int ia = 0; ia < 12; ia++) begin
                for (int ib = 0; ib < 12; ib++) begin
                    bf16_a = specials[ia];
                    bf16_b = specials[ib];
                    #1;
                    check_bf16(bf16_a, bf16_b);
                end
            end
        end
        $display("PASS: BF16 directed special values");

        // BF16 equivalence: random vectors.
        for (int n = 0; n < 20000; n++) begin
            bf16_a = $urandom();
            bf16_b = $urandom();
            #1;
            check_bf16(bf16_a, bf16_b);
        end
        $display("PASS: BF16 random equivalence (20000 pairs)");

        if (failures == 0) begin
            $display("\nFP8 MAC TEST PASSED (%0d checks)", checked);
            $finish;
        end
        $fatal(1, "FP8 MAC TEST FAILED with %0d failure(s)", failures);
    end

    initial begin
        #5000000;
        $fatal(1, "FP8 MAC TEST FAILED: timeout");
    end
endmodule
