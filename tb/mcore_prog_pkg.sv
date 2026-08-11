`timescale 1ns/1ps

// Testbench-side assembler for the 64-bit MCore instruction encoding defined
// in mcore_pkg. Each function returns one instruction word; SetStream returns
// its four words through an output array.
package mcore_prog_pkg;
    import mcore_pkg::*;

    function automatic instr_t enc_base(opcode_e op);
        instr_t w;
        w = '0;
        w[63:60] = op;
        return w;
    endfunction

    // imm_is_reg = 0: literal. imm_is_reg = 1: value is a register index.
    function automatic instr_t enc_int_value(instr_t w,
                                             logic is_reg,
                                             logic signed [INT_WIDTH-1:0] value);
        instr_t r;
        r = w;
        r[33]   = is_reg;
        r[31:0] = value;
        return r;
    endfunction

    function automatic instr_t asm_load_imm(logic [3:0] rd,
                                            logic signed [INT_WIDTH-1:0] imm);
        instr_t w;
        w = enc_base(OP_LOAD_IMM);
        w[59:56] = rd;
        return enc_int_value(w, 1'b0, imm);
    endfunction

    function automatic instr_t asm_add_imm(logic [3:0] rd,
                                           logic [3:0] rs,
                                           logic signed [INT_WIDTH-1:0] imm);
        instr_t w;
        w = enc_base(OP_ADD_IMM);
        w[59:56] = rd;
        w[55:52] = rs;
        return enc_int_value(w, 1'b0, imm);
    endfunction

    function automatic instr_t asm_loop_imm(logic signed [INT_WIDTH-1:0] count);
        return enc_int_value(enc_base(OP_LOOP), 1'b0, count);
    endfunction

    function automatic instr_t asm_loop_reg(logic [3:0] rs);
        return enc_int_value(enc_base(OP_LOOP), 1'b1, INT_WIDTH'(rs));
    endfunction

    function automatic instr_t asm_end_loop();
        return enc_base(OP_END_LOOP);
    endfunction

    function automatic instr_t asm_branch(opcode_e op,
                                          logic [3:0] rs,
                                          logic is_reg,
                                          logic signed [INT_WIDTH-1:0] bound,
                                          logic signed [BRANCH_OFFSET_WIDTH-1:0] offset);
        instr_t w;
        w = enc_base(op);
        w[55:52] = rs;
        w[45:34] = offset;
        return enc_int_value(w, is_reg, bound);
    endfunction

    function automatic instr_t asm_reset_accumulators();
        return enc_base(OP_RESET_ACCUMULATORS);
    endfunction

    function automatic instr_t asm_load_accumulators(
        logic [STREAM_ID_WIDTH-1:0]  stream,
        logic [ACC_SELECT_WIDTH-1:0] acc_index
    );
        instr_t w;
        w = enc_base(OP_LOAD_ACCUMULATORS);
        w[51:49] = stream;
        w[38:35] = acc_index;
        return w;
    endfunction

    function automatic instr_t asm_broadcast_mac(
        logic [STREAM_ID_WIDTH-1:0]     stream_a,
        logic [STREAM_ID_WIDTH-1:0]     stream_b,
        logic [VALID_COLUMNS_WIDTH-1:0] valid_columns
    );
        instr_t w;
        w = enc_base(OP_BROADCAST_MAC);
        w[51:49] = stream_a;
        w[48:46] = stream_b;
        w[45:39] = valid_columns;
        return w;
    endfunction

    function automatic instr_t asm_multi_mac(
        logic [STREAM_ID_WIDTH-1:0]     stream_a,
        logic [STREAM_ID_WIDTH-1:0]     stream_b,
        logic [VALID_COLUMNS_WIDTH-1:0] valid_count
    );
        instr_t w;
        w = enc_base(OP_MULTI_MAC);
        w[51:49] = stream_a;
        w[48:46] = stream_b;
        w[45:39] = valid_count;
        return w;
    endfunction

    function automatic instr_t asm_write_accumulators(
        logic [STREAM_ID_WIDTH-1:0]     stream,
        logic [VALID_COLUMNS_WIDTH-1:0] valid_columns
    );
        instr_t w;
        w = enc_base(OP_WRITE_ACCUMULATORS);
        w[51:49] = stream;
        w[45:39] = valid_columns;
        return w;
    endfunction

    function automatic instr_t asm_halt();
        return enc_base(OP_HALT);
    endfunction

    // Four-word SetStream. All fields are literals here; reg_select can be
    // set by the caller for register-sourced fields.
    function automatic void asm_set_stream(
        output instr_t words [SETSTREAM_WORDS],
        input  logic [STREAM_ID_WIDTH-1:0]  stream,
        input  mem_domain_e                 domain,
        input  layout_e                     layout,
        input  logic [MEM_ADDR_WIDTH-1:0]   base_row,
        input  logic signed [INT_WIDTH-1:0] offset,
        input  logic signed [INT_WIDTH-1:0] inner_count,
        input  logic signed [INT_WIDTH-1:0] outer_count,
        input  logic signed [INT_WIDTH-1:0] inner_stride,
        input  logic                        has_outer_stride,
        input  logic signed [INT_WIDTH-1:0] outer_stride,
        input  logic [4:0]                  reg_select
    );
        instr_t w0;
        w0 = enc_base(OP_SET_STREAM);
        w0[59:57] = stream;
        w0[56]    = domain;
        w0[55:54] = layout;
        w0[53:38] = base_row;
        w0[37]    = has_outer_stride;
        w0[36:32] = reg_select;
        words[0] = w0;
        words[1] = {offset, inner_count};
        words[2] = {outer_count, inner_stride};
        words[3] = {outer_stride, 32'b0};
    endfunction
endpackage
