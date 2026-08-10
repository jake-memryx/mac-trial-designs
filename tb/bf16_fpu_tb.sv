`timescale 1ns/1ps

`ifndef ENABLE_DIV_SQRT
`define ENABLE_DIV_SQRT 1
`endif

// BF16 FPU verification against a double-precision reference.
//
// BF16 operands carry 8-bit significands, so the exact result of add, sub and
// multiply is representable in a double and the reference rounding is exact.
// Divide and sqrt are double-rounded (53 bits then 8), which can theoretically
// differ from direct rounding, but only for near-tie cases with probability
// around 2^-45 per vector.
module bf16_fpu_tb;
    localparam bit ENABLE_DIV_SQRT = `ENABLE_DIV_SQRT;

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

    logic        clk, reset, valid_in;
    logic [3:0]  opcode;
    logic [15:0] a, b;
    logic [15:0] result;
    logic        valid_out, busy;
    logic [4:0]  flags;

    int failures = 0;
    int checked  = 0;

    bf16_fpu #(.ENABLE_DIV_SQRT(ENABLE_DIV_SQRT)) dut (.*);

    initial clk = 1'b0;
    always #5 clk = ~clk;

    function automatic bit is_nan(input logic [15:0] v);
        return (v[14:7] == 8'hff) && (v[6:0] != 0);
    endfunction

    function automatic bit is_inf(input logic [15:0] v);
        return (v[14:7] == 8'hff) && (v[6:0] == 0);
    endfunction

    function automatic bit is_zero(input logic [15:0] v);
        return (v[14:0] == 15'b0);
    endfunction

    function automatic real bf16_to_real(input logic [15:0] v);
        real magnitude;
        begin
            if (v[14:7] == 8'h00)
                magnitude = (real'(v[6:0]) / 128.0) * (2.0 ** -126.0);
            else
                magnitude = (1.0 + real'(v[6:0]) / 128.0) *
                            (2.0 ** (real'(v[14:7]) - 127.0));
            return v[15] ? -magnitude : magnitude;
        end
    endfunction

    // Round a real to BF16 with round-to-nearest, ties-to-even.
    function automatic logic [15:0] real_to_bf16(input real value);
        real        magnitude, scaled, floor_value, fraction;
        int         exponent;
        longint     mantissa;
        logic       sign;
        begin
            sign = (value < 0.0);
            magnitude = sign ? -value : value;
            if (magnitude == 0.0)
                return {sign, 15'b0};

            exponent = 0;
            while (magnitude >= 2.0 ** (real'(exponent) + 1.0))
                exponent = exponent + 1;
            while (magnitude < 2.0 ** real'(exponent))
                exponent = exponent - 1;

            if (exponent >= -126) begin
                scaled = magnitude / (2.0 ** real'(exponent)) * 128.0;
            end else begin
                // Subnormal: scale relative to the fixed 2^-126 step.
                scaled   = magnitude / (2.0 ** -126.0) * 128.0;
                exponent = -127;
            end

            floor_value = $floor(scaled);
            fraction    = scaled - floor_value;
            mantissa    = longint'(floor_value);
            if (fraction > 0.5)
                mantissa = mantissa + 1;
            else if (fraction == 0.5 && (mantissa % 2 != 0))
                mantissa = mantissa + 1;

            if (exponent == -127) begin
                // Rounding up out of the subnormal range gives 2^-126.
                if (mantissa >= 128)
                    return {sign, 8'd1, 7'b0};
                return {sign, 8'd0, mantissa[6:0]};
            end

            if (mantissa >= 256) begin
                mantissa = mantissa / 2;
                exponent = exponent + 1;
            end
            if (exponent + 127 >= 255)
                return {sign, 8'hff, 7'b0};
            return {sign, 8'((exponent + 127)), mantissa[6:0]};
        end
    endfunction

    // Reference result for the arithmetic operations, specials first.
    function automatic logic [15:0] expected_arith(input logic [3:0] op,
                                                   input logic [15:0] x,
                                                   input logic [15:0] y_raw);
        logic sign_x, sign_y, sign_r;
        logic [15:0] y;
        begin
            // Subtract is add with the sign of the second operand inverted.
            y = (op == OP_SUB) ? {~y_raw[15], y_raw[14:0]} : y_raw;
            sign_x = x[15];
            sign_y = y[15];

            if (op == OP_SQRT) begin
                if (is_nan(x))                    return 16'h7fc0;
                if (is_zero(x))                   return {sign_x, 15'b0};
                if (sign_x)                       return 16'h7fc0;
                if (is_inf(x))                    return 16'h7f80;
                return real_to_bf16($sqrt(bf16_to_real(x)));
            end

            if (is_nan(x) || is_nan(y))           return 16'h7fc0;
            sign_r = sign_x ^ sign_y;

            case (op)
                OP_ADD, OP_SUB: begin
                    if (is_inf(x) && is_inf(y)) begin
                        if (sign_x != sign_y)     return 16'h7fc0;
                        return {sign_x, 8'hff, 7'b0};
                    end
                    if (is_inf(x))                return {sign_x, 8'hff, 7'b0};
                    if (is_inf(y))                return {sign_y, 8'hff, 7'b0};
                    if (is_zero(x) && is_zero(y)) return {sign_x & sign_y, 15'b0};
                    return real_to_bf16(bf16_to_real(x) + bf16_to_real(y));
                end
                OP_MUL: begin
                    if ((is_inf(x) && is_zero(y)) || (is_inf(y) && is_zero(x)))
                        return 16'h7fc0;
                    if (is_inf(x) || is_inf(y))   return {sign_r, 8'hff, 7'b0};
                    if (is_zero(x) || is_zero(y)) return {sign_r, 15'b0};
                    return real_to_bf16(bf16_to_real(x) * bf16_to_real(y));
                end
                OP_DIV: begin
                    if ((is_zero(x) && is_zero(y)) || (is_inf(x) && is_inf(y)))
                        return 16'h7fc0;
                    if (is_zero(y))               return {sign_r, 8'hff, 7'b0};
                    if (is_inf(x))                return {sign_r, 8'hff, 7'b0};
                    if (is_inf(y) || is_zero(x))  return {sign_r, 15'b0};
                    return real_to_bf16(bf16_to_real(x) / bf16_to_real(y));
                end
                default: return 16'h0000;
            endcase
        end
    endfunction

    // Drive one operation and wait for its result.
    task automatic run_op(input logic [3:0] op,
                          input logic [15:0] x,
                          input logic [15:0] y,
                          output logic [15:0] observed);
        begin
            @(negedge clk);
            opcode   = op;
            a        = x;
            b        = y;
            valid_in = 1'b1;
            @(posedge clk);
            @(negedge clk);
            valid_in = 1'b0;
            while (!valid_out) @(posedge clk);
            observed = result;
            @(negedge clk);
        end
    endtask

    task automatic check_arith(input logic [3:0] op,
                               input logic [15:0] x,
                               input logic [15:0] y,
                               input string name);
        logic [15:0] observed, expected;
        begin
            run_op(op, x, y, observed);
            expected = expected_arith(op, x, y);
            checked++;
            // Any NaN payload is acceptable.
            if (is_nan(expected) && is_nan(observed))
                return;
            if (observed !== expected) begin
                if (failures < 15)
                    $error("%s(%04h, %04h): expected %04h, got %04h",
                           name, x, y, expected, observed);
                failures++;
            end
        end
    endtask

    // Representative corner encodings.
    logic [15:0] corners [];

    initial begin
        corners = new[24];
        corners = '{16'h0000, 16'h8000,   // +0 -0
                    16'h0001, 16'h8001,   // smallest subnormal
                    16'h007f, 16'h807f,   // largest subnormal
                    16'h0080, 16'h8080,   // smallest normal
                    16'h3f80, 16'hbf80,   // +/-1.0
                    16'h4000, 16'hc000,   // +/-2.0
                    16'h3f00, 16'hbf00,   // +/-0.5
                    16'h7f7f, 16'hff7f,   // +/-max normal
                    16'h7f80, 16'hff80,   // +/-inf
                    16'h7fc0, 16'hffc0,   // NaN
                    16'h4049, 16'hc049,   // ~3.14
                    16'h0040, 16'h3f81};  // subnormal, 1.0+ulp

        reset    = 1'b1;
        valid_in = 1'b0;
        opcode   = OP_ADD;
        a        = 16'b0;
        b        = 16'b0;
        repeat (3) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        // Exhaustive over the corner cross product.
        foreach (corners[i]) foreach (corners[j]) begin
            check_arith(OP_ADD, corners[i], corners[j], "add");
            check_arith(OP_SUB, corners[i], corners[j], "sub");
            check_arith(OP_MUL, corners[i], corners[j], "mul");
            if (ENABLE_DIV_SQRT)
                check_arith(OP_DIV, corners[i], corners[j], "div");
        end
        $display("PASS: corner cross product (%0d checks)", checked);

        // Random vectors.
        for (int n = 0; n < 4000; n++) begin
            logic [15:0] x, y;
            x = $urandom();
            y = $urandom();
            check_arith(OP_ADD, x, y, "add");
            check_arith(OP_SUB, x, y, "sub");
            check_arith(OP_MUL, x, y, "mul");
            if (ENABLE_DIV_SQRT)
                check_arith(OP_DIV, x, y, "div");
        end
        $display("PASS: random add/sub/mul%s", ENABLE_DIV_SQRT ? "/div" : "");

        // Square root over a wide sweep of encodings.
        if (ENABLE_DIV_SQRT) begin
            for (int v = 0; v < 65536; v = v + 7) begin
                check_arith(OP_SQRT, v[15:0], 16'b0, "sqrt");
            end
            foreach (corners[i])
                check_arith(OP_SQRT, corners[i], 16'b0, "sqrt");
            $display("PASS: sqrt sweep");
        end

        // Compare, min/max and sign operations.
        foreach (corners[i]) foreach (corners[j]) begin
            logic [15:0] x, y, observed;
            real         rx, ry;
            bit          unordered;
            x = corners[i];
            y = corners[j];
            unordered = is_nan(x) || is_nan(y);
            rx = bf16_to_real(x);
            ry = bf16_to_real(y);

            run_op(OP_LT, x, y, observed);
            checked++;
            if (observed[0] !== (unordered ? 1'b0 : (rx < ry))) begin
                $error("lt(%04h,%04h): got %0b", x, y, observed[0]);
                failures++;
            end

            run_op(OP_EQ, x, y, observed);
            checked++;
            if (observed[0] !== (unordered ? 1'b0 : (rx == ry))) begin
                $error("eq(%04h,%04h): got %0b", x, y, observed[0]);
                failures++;
            end

            run_op(OP_MIN, x, y, observed);
            checked++;
            if (!unordered && !is_zero(x) && !is_zero(y)) begin
                if (bf16_to_real(observed) !== ((rx < ry) ? rx : ry)) begin
                    $error("min(%04h,%04h): got %04h", x, y, observed);
                    failures++;
                end
            end

            run_op(OP_MAX, x, y, observed);
            checked++;
            if (!unordered && !is_zero(x) && !is_zero(y)) begin
                if (bf16_to_real(observed) !== ((rx > ry) ? rx : ry)) begin
                    $error("max(%04h,%04h): got %04h", x, y, observed);
                    failures++;
                end
            end

            run_op(OP_ABS, x, y, observed);
            checked++;
            if (observed !== {1'b0, x[14:0]}) begin
                $error("abs(%04h): got %04h", x, observed);
                failures++;
            end

            run_op(OP_NEG, x, y, observed);
            checked++;
            if (observed !== {~x[15], x[14:0]}) begin
                $error("neg(%04h): got %04h", x, observed);
                failures++;
            end

            run_op(OP_COPYSIGN, x, y, observed);
            checked++;
            if (observed !== {y[15], x[14:0]}) begin
                $error("copysign(%04h,%04h): got %04h", x, y, observed);
                failures++;
            end
        end
        $display("PASS: compare / min / max / sign");

        if (failures == 0) begin
            $display("\nBF16 FPU TEST PASSED (%0d checks, div/sqrt=%0d)",
                     checked, ENABLE_DIV_SQRT);
            $finish;
        end
        $fatal(1, "BF16 FPU TEST FAILED with %0d failure(s)", failures);
    end

    initial begin
        #50000000;
        $fatal(1, "BF16 FPU TEST FAILED: timeout");
    end
endmodule
