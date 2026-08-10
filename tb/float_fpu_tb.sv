`timescale 1ns/1ps

`ifndef ENABLE_DIV_SQRT
`define ENABLE_DIV_SQRT 1
`endif
`ifndef MANTISSA_BITS
`define MANTISSA_BITS 7
`endif

// Format-generic FPU verification against a double-precision reference.
//
// Works for any mantissa width over the 8-bit exponent field: BF16 is
// MANTISSA_BITS=7, BF19 (TensorFloat-32 layout) is MANTISSA_BITS=10. The exact
// result of add, sub and multiply on operands with <=11-bit significands is
// representable in a double, so the reference rounding is exact. Divide and
// sqrt are double-rounded, which can differ from direct rounding only for
// near-tie cases at probability around 2^-42 per vector.
module float_fpu_tb;
    localparam int unsigned M     = `MANTISSA_BITS;
    localparam int unsigned WIDTH = M + 9;
    localparam bit ENABLE_DIV_SQRT = `ENABLE_DIV_SQRT;
    localparam real MANTISSA_SCALE = real'(2 ** M);

    localparam logic [3:0] OP_ADD      = 4'd0;
    localparam logic [3:0] OP_SUB      = 4'd1;
    localparam logic [3:0] OP_MUL      = 4'd2;
    localparam logic [3:0] OP_MIN      = 4'd3;
    localparam logic [3:0] OP_MAX      = 4'd4;
    localparam logic [3:0] OP_ABS      = 4'd5;
    localparam logic [3:0] OP_NEG      = 4'd6;
    localparam logic [3:0] OP_COPYSIGN = 4'd7;
    localparam logic [3:0] OP_LT       = 4'd8;
    localparam logic [3:0] OP_EQ       = 4'd10;
    localparam logic [3:0] OP_DIV      = 4'd11;
    localparam logic [3:0] OP_SQRT     = 4'd12;

    logic             clk, reset, valid_in;
    logic [3:0]       opcode;
    logic [WIDTH-1:0] a, b, result;
    logic             valid_out, busy;
    logic [4:0]       flags;

    int failures = 0;
    int checked  = 0;

    float_fpu #(
        .MANTISSA_BITS   (M),
        .ENABLE_DIV_SQRT (ENABLE_DIV_SQRT)
    ) dut (.*);

    initial clk = 1'b0;
    always #5 clk = ~clk;

    function automatic logic [WIDTH-1:0] make(input logic sign,
                                              input logic [7:0] exponent,
                                              input logic [M-1:0] fraction);
        return {sign, exponent, fraction};
    endfunction

    function automatic bit is_nan(input logic [WIDTH-1:0] v);
        return (v[WIDTH-2 -: 8] == 8'hff) && (v[M-1:0] != 0);
    endfunction

    function automatic bit is_inf(input logic [WIDTH-1:0] v);
        return (v[WIDTH-2 -: 8] == 8'hff) && (v[M-1:0] == 0);
    endfunction

    function automatic bit is_zero(input logic [WIDTH-1:0] v);
        return (v[WIDTH-2:0] == '0);
    endfunction

    function automatic logic [WIDTH-1:0] quiet_nan();
        return {1'b0, 8'hff, 1'b1, {(M-1){1'b0}}};
    endfunction

    function automatic real fp_to_real(input logic [WIDTH-1:0] v);
        real        magnitude;
        logic [7:0] exponent;
        begin
            exponent = v[WIDTH-2 -: 8];
            if (exponent == 8'h00)
                magnitude = (real'(v[M-1:0]) / MANTISSA_SCALE) *
                            (2.0 ** -126.0);
            else
                magnitude = (1.0 + real'(v[M-1:0]) / MANTISSA_SCALE) *
                            (2.0 ** (real'(exponent) - 127.0));
            return v[WIDTH-1] ? -magnitude : magnitude;
        end
    endfunction

    // Round a real to the format with round-to-nearest, ties-to-even.
    function automatic logic [WIDTH-1:0] real_to_fp(input real value);
        real    magnitude, scaled, floor_value, fraction;
        int     exponent;
        longint mantissa;
        logic   sign;
        begin
            sign      = (value < 0.0);
            magnitude = sign ? -value : value;
            if (magnitude == 0.0)
                return {sign, {(WIDTH-1){1'b0}}};

            exponent = 0;
            while (magnitude >= 2.0 ** (real'(exponent) + 1.0))
                exponent = exponent + 1;
            while (magnitude < 2.0 ** real'(exponent))
                exponent = exponent - 1;

            if (exponent >= -126) begin
                scaled = magnitude / (2.0 ** real'(exponent)) * MANTISSA_SCALE;
            end else begin
                scaled   = magnitude / (2.0 ** -126.0) * MANTISSA_SCALE;
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
                if (mantissa >= longint'(2 ** M))
                    return make(sign, 8'd1, '0);
                return make(sign, 8'd0, mantissa[M-1:0]);
            end

            if (mantissa >= longint'(2 ** (M + 1))) begin
                mantissa = mantissa / 2;
                exponent = exponent + 1;
            end
            if (exponent + 127 >= 255)
                return make(sign, 8'hff, '0);
            return make(sign, 8'((exponent + 127)), mantissa[M-1:0]);
        end
    endfunction

    function automatic logic [WIDTH-1:0] expected_arith(
            input logic [3:0] op,
            input logic [WIDTH-1:0] x,
            input logic [WIDTH-1:0] y_raw);
        logic             sign_x, sign_y, sign_r;
        logic [WIDTH-1:0] y;
        begin
            y = (op == OP_SUB) ? {~y_raw[WIDTH-1], y_raw[WIDTH-2:0]} : y_raw;
            sign_x = x[WIDTH-1];
            sign_y = y[WIDTH-1];

            if (op == OP_SQRT) begin
                if (is_nan(x))  return quiet_nan();
                if (is_zero(x)) return {sign_x, {(WIDTH-1){1'b0}}};
                if (sign_x)     return quiet_nan();
                if (is_inf(x))  return make(1'b0, 8'hff, '0);
                return real_to_fp($sqrt(fp_to_real(x)));
            end

            if (is_nan(x) || is_nan(y)) return quiet_nan();
            sign_r = sign_x ^ sign_y;

            case (op)
                OP_ADD, OP_SUB: begin
                    if (is_inf(x) && is_inf(y)) begin
                        if (sign_x != sign_y) return quiet_nan();
                        return make(sign_x, 8'hff, '0);
                    end
                    if (is_inf(x)) return make(sign_x, 8'hff, '0);
                    if (is_inf(y)) return make(sign_y, 8'hff, '0);
                    if (is_zero(x) && is_zero(y))
                        return {sign_x & sign_y, {(WIDTH-1){1'b0}}};
                    return real_to_fp(fp_to_real(x) + fp_to_real(y));
                end
                OP_MUL: begin
                    if ((is_inf(x) && is_zero(y)) || (is_inf(y) && is_zero(x)))
                        return quiet_nan();
                    if (is_inf(x) || is_inf(y)) return make(sign_r, 8'hff, '0);
                    if (is_zero(x) || is_zero(y))
                        return {sign_r, {(WIDTH-1){1'b0}}};
                    return real_to_fp(fp_to_real(x) * fp_to_real(y));
                end
                OP_DIV: begin
                    if ((is_zero(x) && is_zero(y)) || (is_inf(x) && is_inf(y)))
                        return quiet_nan();
                    if (is_zero(y)) return make(sign_r, 8'hff, '0);
                    if (is_inf(x))  return make(sign_r, 8'hff, '0);
                    if (is_inf(y) || is_zero(x))
                        return {sign_r, {(WIDTH-1){1'b0}}};
                    return real_to_fp(fp_to_real(x) / fp_to_real(y));
                end
                default: return '0;
            endcase
        end
    endfunction

    task automatic run_op(input logic [3:0] op,
                          input logic [WIDTH-1:0] x,
                          input logic [WIDTH-1:0] y,
                          output logic [WIDTH-1:0] observed);
        begin
            @(negedge clk);
            opcode = op; a = x; b = y; valid_in = 1'b1;
            @(posedge clk);
            @(negedge clk);
            valid_in = 1'b0;
            while (!valid_out) @(posedge clk);
            observed = result;
            @(negedge clk);
        end
    endtask

    task automatic check_arith(input logic [3:0] op,
                               input logic [WIDTH-1:0] x,
                               input logic [WIDTH-1:0] y,
                               input string name);
        logic [WIDTH-1:0] observed, expected;
        begin
            run_op(op, x, y, observed);
            expected = expected_arith(op, x, y);
            checked++;
            if (is_nan(expected) && is_nan(observed)) return;
            if (observed !== expected) begin
                if (failures < 15)
                    $error("%s(%0h, %0h): expected %0h, got %0h",
                           name, x, y, expected, observed);
                failures++;
            end
        end
    endtask

    logic [WIDTH-1:0] corners [];

    initial begin
        // Structural corners built for whatever the format is.
        corners = new[24];
        corners[0]  = make(1'b0, 8'h00, '0);                   // +0
        corners[1]  = make(1'b1, 8'h00, '0);                   // -0
        corners[2]  = make(1'b0, 8'h00, 1);                    // min subnormal
        corners[3]  = make(1'b1, 8'h00, 1);
        corners[4]  = make(1'b0, 8'h00, '1);                   // max subnormal
        corners[5]  = make(1'b1, 8'h00, '1);
        corners[6]  = make(1'b0, 8'h01, '0);                   // min normal
        corners[7]  = make(1'b1, 8'h01, '0);
        corners[8]  = make(1'b0, 8'h7f, '0);                   // 1.0
        corners[9]  = make(1'b1, 8'h7f, '0);
        corners[10] = make(1'b0, 8'h80, '0);                   // 2.0
        corners[11] = make(1'b1, 8'h80, '0);
        corners[12] = make(1'b0, 8'h7e, '0);                   // 0.5
        corners[13] = make(1'b1, 8'h7e, '0);
        corners[14] = make(1'b0, 8'hfe, '1);                   // max normal
        corners[15] = make(1'b1, 8'hfe, '1);
        corners[16] = make(1'b0, 8'hff, '0);                   // +inf
        corners[17] = make(1'b1, 8'hff, '0);                   // -inf
        corners[18] = quiet_nan();
        corners[19] = {1'b1, 8'hff, 1'b1, {(M-1){1'b0}}};      // -NaN
        corners[20] = make(1'b0, 8'h80, M'(2 ** (M - 1)));     // 3.0
        corners[21] = make(1'b1, 8'h80, M'(2 ** (M - 1)));
        corners[22] = make(1'b0, 8'h7f, 1);                    // 1.0 + ulp
        corners[23] = make(1'b0, 8'h00, M'(2 ** (M - 1)));     // mid subnormal

        reset = 1'b1; valid_in = 1'b0; opcode = OP_ADD; a = '0; b = '0;
        repeat (3) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        foreach (corners[i]) foreach (corners[j]) begin
            check_arith(OP_ADD, corners[i], corners[j], "add");
            check_arith(OP_SUB, corners[i], corners[j], "sub");
            check_arith(OP_MUL, corners[i], corners[j], "mul");
            if (ENABLE_DIV_SQRT)
                check_arith(OP_DIV, corners[i], corners[j], "div");
        end
        $display("PASS: corner cross product (%0d checks)", checked);

        for (int n = 0; n < 4000; n++) begin
            logic [WIDTH-1:0] x, y;
            x = $urandom();
            y = $urandom();
            check_arith(OP_ADD, x, y, "add");
            check_arith(OP_SUB, x, y, "sub");
            check_arith(OP_MUL, x, y, "mul");
            if (ENABLE_DIV_SQRT)
                check_arith(OP_DIV, x, y, "div");
        end
        $display("PASS: random add/sub/mul%s", ENABLE_DIV_SQRT ? "/div" : "");

        if (ENABLE_DIV_SQRT) begin
            for (int v = 0; v < (1 << WIDTH); v = v + 37)
                check_arith(OP_SQRT, WIDTH'(v), '0, "sqrt");
            foreach (corners[i])
                check_arith(OP_SQRT, corners[i], '0, "sqrt");
            $display("PASS: sqrt sweep");
        end

        foreach (corners[i]) foreach (corners[j]) begin
            logic [WIDTH-1:0] x, y, observed;
            real rx, ry;
            bit  unordered;
            x = corners[i]; y = corners[j];
            unordered = is_nan(x) || is_nan(y);
            rx = fp_to_real(x); ry = fp_to_real(y);

            run_op(OP_LT, x, y, observed);
            checked++;
            if (observed[0] !== (unordered ? 1'b0 : (rx < ry))) begin
                $error("lt(%0h,%0h): got %0b", x, y, observed[0]);
                failures++;
            end

            run_op(OP_EQ, x, y, observed);
            checked++;
            if (observed[0] !== (unordered ? 1'b0 : (rx == ry))) begin
                $error("eq(%0h,%0h): got %0b", x, y, observed[0]);
                failures++;
            end

            run_op(OP_MIN, x, y, observed);
            checked++;
            if (!unordered && !is_zero(x) && !is_zero(y))
                if (fp_to_real(observed) !== ((rx < ry) ? rx : ry)) begin
                    $error("min(%0h,%0h): got %0h", x, y, observed);
                    failures++;
                end

            run_op(OP_MAX, x, y, observed);
            checked++;
            if (!unordered && !is_zero(x) && !is_zero(y))
                if (fp_to_real(observed) !== ((rx > ry) ? rx : ry)) begin
                    $error("max(%0h,%0h): got %0h", x, y, observed);
                    failures++;
                end

            run_op(OP_ABS, x, y, observed);
            checked++;
            if (observed !== {1'b0, x[WIDTH-2:0]}) begin
                $error("abs(%0h): got %0h", x, observed);
                failures++;
            end

            run_op(OP_NEG, x, y, observed);
            checked++;
            if (observed !== {~x[WIDTH-1], x[WIDTH-2:0]}) begin
                $error("neg(%0h): got %0h", x, observed);
                failures++;
            end

            run_op(OP_COPYSIGN, x, y, observed);
            checked++;
            if (observed !== {y[WIDTH-1], x[WIDTH-2:0]}) begin
                $error("copysign(%0h,%0h): got %0h", x, y, observed);
                failures++;
            end
        end
        $display("PASS: compare / min / max / sign");

        if (failures == 0) begin
            $display("\nFLOAT FPU TEST PASSED (M=%0d, %0d checks, div/sqrt=%0d)",
                     M, checked, ENABLE_DIV_SQRT);
            $finish;
        end
        $fatal(1, "FLOAT FPU TEST FAILED with %0d failure(s)", failures);
    end

    initial begin
        #100000000;
        $fatal(1, "FLOAT FPU TEST FAILED: timeout");
    end
endmodule
