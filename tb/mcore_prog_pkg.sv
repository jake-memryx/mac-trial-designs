`timescale 1ns/1ps

// Matrix Core program assembler for testbenches. Every function here builds
// one 64-bit instruction word (four for set_stream) and is the exact inverse
// of the matching mcore_pkg accessor, so a program built with this package
// decodes back to the arguments it was written with.
//
// Section numbers in comments refer to matrix_core.md.
//
// Single-word form, section 12:
//
//   [63:59] opcode      [58:55] rd          [54:51] rs
//   [50:48] stream_a    [47:45] stream_b    [44:38] count
//   [37:34] acc_index   [33]    reserved    [32]    imm_is_reg
//   [31:0]  imm
//
// stream_a doubles as buffer_idx for reduce_accumulators. jump and the
// branches alias a signed 12-bit PC-relative displacement over [44:33],
// overlapping count, acc_index and the reserved bit, and carry their compare
// bound in imm. imm_is_reg turns imm[3:0] into an integer register index
// instead of a literal.
//
// set_stream form, section 12:
//
//   word0 [63:59] opcode    [58:56] id            [55]    domain
//         [54:53] layout    [52:37] base_row      [36]    has_outer_stride
//         [35:31] reg_select                      [30:0]  reserved
//   word1 [63:32] offset       [31:0] inner_count
//   word2 [63:32] outer_count  [31:0] inner_stride
//   word3 [63:32] outer_stride [31:0] reserved
//
// Scalar arguments are plain ints so call sites stay free of width casts; the
// narrowing to each field width happens here.
package mcore_prog_pkg;
    import mcore_pkg::*;

    // ------------------------------------------------------- field assembly
    // The single-word fields tile all 64 bits, so one concatenation covers
    // every instruction that does not alias the offset field.
    function automatic instr_t asm_fields(
            input opcode_e                     op,
            input logic [REG_IDX_WIDTH-1:0]    rd,
            input logic [REG_IDX_WIDTH-1:0]    rs,
            input logic [STREAM_ID_WIDTH-1:0]  stream_a,
            input logic [STREAM_ID_WIDTH-1:0]  stream_b,
            input logic [COUNT_WIDTH-1:0]      count,
            input logic [ACC_SELECT_WIDTH-1:0] acc_index,
            input logic                        imm_is_reg,
            input logic [INT_WIDTH-1:0]        imm);
        return {op, rd, rs, stream_a, stream_b, count, acc_index,
                1'b0, imm_is_reg, imm};
    endfunction

    // Offset-aliasing form: the 12-bit displacement replaces count,
    // acc_index and the reserved bit.
    function automatic instr_t asm_offset_fields(
            input opcode_e                            op,
            input logic [REG_IDX_WIDTH-1:0]           rs,
            input logic [BRANCH_OFFSET_WIDTH-1:0]     offset,
            input logic                               imm_is_reg,
            input logic [INT_WIDTH-1:0]               imm);
        return {op, {REG_IDX_WIDTH{1'b0}}, rs,
                {STREAM_ID_WIDTH{1'b0}}, {STREAM_ID_WIDTH{1'b0}},
                offset, imm_is_reg, imm};
    endfunction

    function automatic logic [REG_IDX_WIDTH-1:0] asm_reg(input int unsigned r);
        return REG_IDX_WIDTH'(r);
    endfunction

    function automatic logic [STREAM_ID_WIDTH-1:0] asm_stream(
            input int unsigned s);
        return STREAM_ID_WIDTH'(s);
    endfunction

    function automatic logic [COUNT_WIDTH-1:0] asm_count(input int unsigned c);
        return COUNT_WIDTH'(c);
    endfunction

    function automatic logic [INT_WIDTH-1:0] asm_imm(input int value);
        return $unsigned(value);
    endfunction

    // --------------------------------------------- section 7.1: integer ALU
    function automatic instr_t asm_li(input int unsigned rd, input int imm);
        return asm_fields(OP_LI, asm_reg(rd), '0, '0, '0, '0, '0, 1'b0,
                          asm_imm(imm));
    endfunction

    function automatic instr_t asm_addi(input int unsigned rd,
                                        input int unsigned rs,
                                        input int          imm);
        return asm_fields(OP_ADDI, asm_reg(rd), asm_reg(rs), '0, '0, '0, '0,
                          1'b0, asm_imm(imm));
    endfunction

    // ----------------------------------------------- section 7.1: control
    // A literal trip count rides in imm; the register form names the register
    // in imm[3:0] and leaves the rs field zero, as imm_is_reg already says
    // where the count comes from.
    function automatic instr_t asm_loop_imm(input int unsigned count);
        return asm_fields(OP_LOOP, '0, '0, '0, '0, '0, '0, 1'b0,
                          asm_imm(int'(count)));
    endfunction

    function automatic instr_t asm_loop_reg(input int unsigned rs);
        return asm_fields(OP_LOOP, '0, '0, '0, '0, '0, '0, 1'b1,
                          asm_imm(int'(rs)));
    endfunction

    function automatic instr_t asm_endloop();
        return asm_fields(OP_ENDLOOP, '0, '0, '0, '0, '0, '0, 1'b0, '0);
    endfunction

    // offset is relative to the sequential PC, so 0 falls through and -1
    // re-executes the branch itself.
    function automatic instr_t asm_jump(input int offset);
        return asm_offset_fields(OP_JUMP, '0,
                                 BRANCH_OFFSET_WIDTH'($unsigned(offset)),
                                 1'b0, '0);
    endfunction

    // bound is a literal when is_reg is 0 and a register index when it is 1.
    function automatic instr_t asm_blt(input int unsigned rs,
                                       input logic        is_reg,
                                       input int          bound,
                                       input int          offset);
        return asm_offset_fields(OP_BLT, asm_reg(rs),
                                 BRANCH_OFFSET_WIDTH'($unsigned(offset)),
                                 is_reg, asm_imm(bound));
    endfunction

    function automatic instr_t asm_bge(input int unsigned rs,
                                       input logic        is_reg,
                                       input int          bound,
                                       input int          offset);
        return asm_offset_fields(OP_BGE, asm_reg(rs),
                                 BRANCH_OFFSET_WIDTH'($unsigned(offset)),
                                 is_reg, asm_imm(bound));
    endfunction

    // ------------------------------------------- section 7.2: compute ops
    function automatic instr_t asm_acc_reset();
        return asm_fields(OP_ACC_RESET, '0, '0, '0, '0, '0, '0, 1'b0, '0);
    endfunction

    function automatic instr_t asm_load_accumulators(
            input int unsigned stream, input int unsigned acc_index);
        return asm_fields(OP_LOAD_ACCUMULATORS, '0, '0, asm_stream(stream),
                          '0, '0, ACC_SELECT_WIDTH'(acc_index), 1'b0, '0);
    endfunction

    function automatic instr_t asm_broadcast_mac(input int unsigned stream_a,
                                                 input int unsigned stream_b,
                                                 input int unsigned
                                                     valid_columns);
        return asm_fields(OP_BROADCAST_MAC, '0, '0, asm_stream(stream_a),
                          asm_stream(stream_b), asm_count(valid_columns), '0,
                          1'b0, '0);
    endfunction

    function automatic instr_t asm_multi_mac(input int unsigned stream_a,
                                             input int unsigned stream_b,
                                             input int unsigned
                                                 valid_elements);
        return asm_fields(OP_MULTI_MAC, '0, '0, asm_stream(stream_a),
                          asm_stream(stream_b), asm_count(valid_elements), '0,
                          1'b0, '0);
    endfunction

    function automatic instr_t asm_elementwise_add(input int unsigned stream_a,
                                                   input int unsigned stream_b,
                                                   input int unsigned
                                                       valid_elements);
        return asm_fields(OP_ELEMENTWISE_ADD, '0, '0, asm_stream(stream_a),
                          asm_stream(stream_b), asm_count(valid_elements), '0,
                          1'b0, '0);
    endfunction

    function automatic instr_t asm_elementwise_mul(input int unsigned stream_a,
                                                   input int unsigned stream_b,
                                                   input int unsigned
                                                       valid_elements);
        return asm_fields(OP_ELEMENTWISE_MUL, '0, '0, asm_stream(stream_a),
                          asm_stream(stream_b), asm_count(valid_elements), '0,
                          1'b0, '0);
    endfunction

    // ---------------------------------------- section 7.3: writeback ops
    // The output buffer slot reuses the stream_a field (instr_buffer_idx).
    function automatic instr_t asm_reduce_accumulators(
            input int unsigned buffer_idx, input int unsigned count);
        return asm_fields(OP_REDUCE_ACCUMULATORS, '0, '0,
                          asm_stream(buffer_idx), '0, asm_count(count), '0,
                          1'b0, '0);
    endfunction

    function automatic instr_t asm_scale_accumulators(
            input int unsigned scale_stream, input int unsigned out_stream,
            input int unsigned valid_columns);
        return asm_fields(OP_SCALE_ACCUMULATORS, '0, '0,
                          asm_stream(scale_stream), asm_stream(out_stream),
                          asm_count(valid_columns), '0, 1'b0, '0);
    endfunction

    function automatic instr_t asm_write_accumulators(
            input int unsigned stream, input int unsigned valid_columns);
        return asm_fields(OP_WRITE_ACCUMULATORS, '0, '0, asm_stream(stream),
                          '0, asm_count(valid_columns), '0, 1'b0, '0);
    endfunction

    function automatic instr_t asm_write_buf(input int unsigned stream);
        return asm_fields(OP_WRITE_BUF, '0, '0, asm_stream(stream), '0, '0,
                          '0, 1'b0, '0);
    endfunction

    function automatic instr_t asm_halt();
        return asm_fields(OP_HALT, '0, '0, '0, '0, '0, '0, 1'b0, '0);
    endfunction

    // ------------------------------------------- section 12: set_stream
    // reg_select bit 4 = offset, 3 = inner_count, 2 = outer_count,
    // 1 = inner_stride, 0 = outer_stride; a selected field carries a register
    // index in the low four bits of its 32-bit slot instead of a literal.
    function automatic void asm_set_stream(
            output instr_t      words [SETSTREAM_WORDS],
            input  int unsigned id,
            input  mem_domain_e domain,
            input  layout_e     layout,
            input  int unsigned base_row,
            input  int          offset,
            input  int          inner_count,
            input  int          outer_count,
            input  int          inner_stride,
            input  logic        has_outer_stride,
            input  int          outer_stride,
            input  logic [4:0]  reg_select);
        words[0] = {OP_SET_STREAM, STREAM_ID_WIDTH'(id), domain, layout,
                    MEM_ROW_WIDTH'(base_row), has_outer_stride, reg_select,
                    31'b0};
        words[1] = {asm_imm(offset), asm_imm(inner_count)};
        words[2] = {asm_imm(outer_count), asm_imm(inner_stride)};
        words[3] = {asm_imm(outer_stride), {INT_WIDTH{1'b0}}};
    endfunction

    // ------------------------------------------ section 4: format helpers
    // Testbench-only conversions used to build stimulus and expected data.
    // real is IEEE double: sign, 11-bit exponent biased by 1023, 52-bit
    // fraction. BF16 keeps the top seven fraction bits and rounds to nearest
    // with ties to even; subnormal inputs and underflowed results flush to
    // signed zero, matching fp32_to_bf16 in mcore_pkg.
    function automatic logic [15:0] real_to_bf16(input real v);
        logic [63:0] bits;
        logic        sign;
        logic [10:0] exponent;
        logic [51:0] fraction;
        logic        round_up;
        logic [7:0]  significand;
        int          biased;

        bits     = $realtobits(v);
        sign     = bits[63];
        exponent = bits[62:52];
        fraction = bits[51:0];

        if (exponent == 11'h7ff)
            return (fraction != '0) ? {sign, 8'hff, 7'h40}
                                    : {sign, 8'hff, 7'h00};
        if (exponent == 11'h000)
            return {sign, 15'b0};

        round_up    = fraction[44] & (|fraction[43:0] | fraction[45]);
        significand = {1'b0, fraction[51:45]} + {7'b0, round_up};
        biased      = (int'({21'b0, exponent}) - 1023) + 127 +
                      int'({31'b0, significand[7]});

        if (biased <= 0)
            return {sign, 15'b0};
        if (biased >= 255)
            return {sign, 8'hff, 7'h00};
        return {sign, biased[7:0], significand[6:0]};
    endfunction

    function automatic real bf16_to_real(input logic [15:0] v);
        return real'($bitstoshortreal({v, 16'b0}));
    endfunction

    // The simulator's double-to-float narrowing already rounds to nearest
    // with ties to even, which is what the FP32 accumulators expect.
    function automatic logic [31:0] real_to_fp32(input real v);
        return $shortrealtobits(shortreal'(v));
    endfunction

    function automatic real fp32_to_real(input logic [31:0] v);
        return real'($bitstoshortreal(v));
    endfunction
endpackage
