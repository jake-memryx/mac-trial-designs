`timescale 1ns/1ps

// Matrix Core shared declarations: architectural constants, the instruction
// encoding, the stage command and data packet formats, and the small pure
// functions the stages share (stream address generation, format conversion).
//
// Section numbers in comments refer to matrix_core.md.
package mcore_pkg;

    // ---------------------------------------------------------------- section 1
    // Architectural constants. These are frozen by the specification.
    parameter int unsigned TREEMACS             = 4;
    parameter int unsigned TREEMAC_MULTIPLIERS  = 8;
    parameter int unsigned TREEMAC_ACCUMULATORS = 16;
    parameter int unsigned TOTAL_MULTIPLIERS    = TREEMACS * TREEMAC_MULTIPLIERS;
    parameter int unsigned TOTAL_ACCUMULATORS   = TREEMACS * TREEMAC_ACCUMULATORS;

    parameter int unsigned LINE_WIDTH    = 128;
    parameter int unsigned LOMEM_LANES   = 4;
    parameter int unsigned LOMEM_WIDTH   = LOMEM_LANES * LINE_WIDTH;
    parameter int unsigned COMEM_WIDTH   = LINE_WIDTH;
    parameter int unsigned BF16_PER_LINE = LINE_WIDTH / 16;
    parameter int unsigned FP32_PER_LINE = LINE_WIDTH / 32;
    parameter int unsigned INT8_PER_LINE = LINE_WIDTH / 8;
    parameter int unsigned BF16_PER_ROW  = LOMEM_WIDTH / 16;

    parameter int unsigned INT_REGISTERS      = 16;
    parameter int unsigned INT_WIDTH          = 32;
    parameter int unsigned OUTPUT_BUFFER_SLOTS = 8;

    // ---------------------------------------------------------------- section 11
    // Implementation parameters.
    parameter int unsigned SCALE_BUFFER_ENTRIES = 32;
    parameter int unsigned COMMAND_Q_DEPTH      = 4;
    parameter int unsigned DATA_Q_DEPTH         = 2;
    parameter int unsigned MEMORY_Q_DEPTH       = 12;
    parameter int unsigned FETCH_BUFFER_DEPTH   = 4;
    parameter int unsigned LOOP_STACK_DEPTH     = 4;
    parameter int unsigned STREAM_SLOTS         = 4;
    parameter int unsigned REDUCTION_GUARD_BITS = 4;
    parameter int unsigned MEM_ROW_WIDTH        = 16;
    parameter int unsigned PROG_ADDR_WIDTH      = 12;
    parameter int unsigned INSTR_WIDTH          = 64;
    parameter int unsigned SEQ_WIDTH            = 6;
    parameter int unsigned TICKET_WIDTH         = 5;
    parameter int unsigned RESERVATIONS         = 4;
    parameter int unsigned COUNT_WIDTH          = 7;
    parameter int unsigned SETSTREAM_WORDS      = 4;

    // Widest access count a single command advances a stream by: eight 128-bit
    // lines cover the 64 values of write_accumulators and scale_accumulators.
    parameter int unsigned MAX_STREAM_ACCESSES = 8;

    // A memory ticket is {source, requester tag}: source 0 = Fetch, 1 = WB.
    parameter int unsigned TAG_WIDTH        = TICKET_WIDTH - 1;
    parameter int unsigned ACC_SELECT_WIDTH  = $clog2(TREEMAC_ACCUMULATORS);
    parameter int unsigned LANE_SELECT_WIDTH = $clog2(TREEMACS);
    parameter int unsigned STREAM_ID_WIDTH   = 3;
    parameter int unsigned BUFFER_IDX_WIDTH  = $clog2(OUTPUT_BUFFER_SLOTS);
    parameter int unsigned SCALE_IDX_WIDTH   = $clog2(SCALE_BUFFER_ENTRIES);
    parameter int unsigned REG_IDX_WIDTH     = $clog2(INT_REGISTERS);
    parameter int unsigned BRANCH_OFFSET_WIDTH = 12;

    // BF16 bit patterns the datapath needs as literals.
    parameter logic [15:0] BF16_ZERO = 16'h0000;
    parameter logic [15:0] BF16_ONE  = 16'h3f80;

    // ---------------------------------------------------------------- encodings
    typedef enum logic [0:0] {
        DOMAIN_LOMEM = 1'b0,
        DOMAIN_COMEM = 1'b1
    } mem_domain_e;

    typedef enum logic [1:0] {
        LAYOUT_ROW_MAJOR      = 2'd0,
        LAYOUT_ROW_MAJOR_FP32 = 2'd1,
        LAYOUT_MATMUL_B       = 2'd2,
        LAYOUT_MATMUL_B_INT8  = 2'd3
    } layout_e;

    typedef enum logic [4:0] {
        OP_SET_STREAM          = 5'd0,
        OP_LI                  = 5'd1,
        OP_ADDI                = 5'd2,
        OP_LOOP                = 5'd3,
        OP_ENDLOOP             = 5'd4,
        OP_JUMP                = 5'd5,
        OP_BLT                 = 5'd6,
        OP_BGE                 = 5'd7,
        OP_ACC_RESET           = 5'd8,
        OP_LOAD_ACCUMULATORS   = 5'd9,
        OP_BROADCAST_MAC       = 5'd10,
        OP_MULTI_MAC           = 5'd11,
        OP_ELEMENTWISE_ADD     = 5'd12,
        OP_ELEMENTWISE_MUL     = 5'd13,
        OP_REDUCE_ACCUMULATORS = 5'd14,
        OP_SCALE_ACCUMULATORS  = 5'd15,
        OP_WRITE_ACCUMULATORS  = 5'd16,
        OP_WRITE_BUF           = 5'd17,
        OP_HALT                = 5'd18
    } opcode_e;

    typedef enum logic [2:0] {
        FETCH_ACC_LOAD    = 3'd0,
        FETCH_BROADCAST   = 3'd1,
        FETCH_MULTI       = 3'd2,
        FETCH_ELEMENTWISE = 3'd3
    } fetch_op_e;

    typedef enum logic [1:0] {
        COMPUTE_RESET    = 2'd0,
        COMPUTE_LOAD_ACC = 2'd1,
        COMPUTE_MAC      = 2'd2,
        COMPUTE_SNAPSHOT = 2'd3
    } compute_op_e;

    typedef enum logic [1:0] {
        WB_REDUCE    = 2'd0,
        WB_SCALE     = 2'd1,
        WB_WRITE_ACC = 2'd2,
        WB_WRITE_BUF = 2'd3
    } wb_op_e;

    typedef logic [INSTR_WIDTH-1:0] instr_t;

    // ------------------------------------------------- section 12: field access
    function automatic opcode_e instr_opcode(instr_t w);
        return opcode_e'(w[63:59]);
    endfunction

    function automatic logic [REG_IDX_WIDTH-1:0] instr_rd(instr_t w);
        return w[58:55];
    endfunction

    function automatic logic [REG_IDX_WIDTH-1:0] instr_rs(instr_t w);
        return w[54:51];
    endfunction

    function automatic logic [STREAM_ID_WIDTH-1:0] instr_stream_a(instr_t w);
        return w[50:48];
    endfunction

    function automatic logic [STREAM_ID_WIDTH-1:0] instr_stream_b(instr_t w);
        return w[47:45];
    endfunction

    // valid_columns or valid_elements, 1..64.
    function automatic logic [COUNT_WIDTH-1:0] instr_count(instr_t w);
        return w[44:38];
    endfunction

    function automatic logic [ACC_SELECT_WIDTH-1:0] instr_acc_index(instr_t w);
        return w[37:34];
    endfunction

    // reduce_accumulators reuses the stream_a field as the buffer slot.
    function automatic logic [BUFFER_IDX_WIDTH-1:0] instr_buffer_idx(instr_t w);
        return w[50:48];
    endfunction

    // Branches and jump alias the count and acc_index fields.
    function automatic logic signed [BRANCH_OFFSET_WIDTH-1:0]
            instr_offset(instr_t w);
        return $signed(w[44:33]);
    endfunction

    function automatic logic instr_imm_is_reg(instr_t w);
        return w[32];
    endfunction

    function automatic logic signed [INT_WIDTH-1:0] instr_imm(instr_t w);
        return $signed(w[31:0]);
    endfunction

    function automatic logic [STREAM_ID_WIDTH-1:0] setstream_id(instr_t w);
        return w[58:56];
    endfunction

    function automatic mem_domain_e setstream_domain(instr_t w);
        return mem_domain_e'(w[55]);
    endfunction

    function automatic layout_e setstream_layout(instr_t w);
        return layout_e'(w[54:53]);
    endfunction

    function automatic logic [MEM_ROW_WIDTH-1:0] setstream_base_row(instr_t w);
        return w[52:37];
    endfunction

    function automatic logic setstream_has_outer_stride(instr_t w);
        return w[36];
    endfunction

    // Bit 4 = offset, 3 = inner_count, 2 = outer_count, 1 = inner_stride,
    // 0 = outer_stride. A selected field carries a register index instead of a
    // literal.
    function automatic logic [4:0] setstream_reg_select(instr_t w);
        return w[35:31];
    endfunction

    function automatic logic signed [INT_WIDTH-1:0] instr_high_word(instr_t w);
        return $signed(w[63:32]);
    endfunction

    function automatic logic signed [INT_WIDTH-1:0] instr_low_word(instr_t w);
        return $signed(w[31:0]);
    endfunction

    // ------------------------------------------------- section 15: stream state
    typedef struct packed {
        logic                        valid;
        mem_domain_e                 domain;
        layout_e                     layout;
        logic [MEM_ROW_WIDTH-1:0]    base_row;
        logic signed [INT_WIDTH-1:0] offset;
        logic signed [INT_WIDTH-1:0] inner_count;
        logic signed [INT_WIDTH-1:0] outer_count;
        logic signed [INT_WIDTH-1:0] inner_stride;
        logic signed [INT_WIDTH-1:0] outer_stride;
    } stream_desc_t;

    typedef struct packed {
        stream_desc_t                desc;
        logic signed [INT_WIDTH-1:0] inner_cursor;
        logic signed [INT_WIDTH-1:0] outer_cursor;
    } stream_view_t;

    // Logical index of the access the cursors currently point at.
    function automatic logic signed [INT_WIDTH-1:0] stream_index(
            stream_view_t v);
        return v.desc.offset +
               v.outer_cursor * v.desc.outer_stride +
               v.inner_cursor * v.desc.inner_stride;
    endfunction

    // Logical index of an access n steps ahead of the cursors, used to size a
    // range reservation without walking the cursors.
    function automatic logic signed [INT_WIDTH-1:0] stream_index_ahead(
            stream_view_t v, int unsigned n);
        stream_view_t walk;
        walk = v;
        for (int unsigned s = 0; s < MAX_STREAM_ACCESSES; s++) begin
            if (s < n) begin
                walk.inner_cursor = walk.inner_cursor + 1;
                if (walk.inner_cursor >= walk.desc.inner_count) begin
                    walk.inner_cursor = '0;
                    walk.outer_cursor = walk.outer_cursor + 1;
                end
            end
        end
        return stream_index(walk);
    endfunction

    // One consumption advances the inner cursor and wraps into the outer one.
    function automatic stream_view_t stream_advance(stream_view_t v,
                                                    int unsigned accesses);
        stream_view_t next;
        next = v;
        for (int unsigned s = 0; s < MAX_STREAM_ACCESSES; s++) begin
            if (s < accesses) begin
                next.inner_cursor = next.inner_cursor + 1;
                if (next.inner_cursor >= next.desc.inner_count) begin
                    next.inner_cursor = '0;
                    next.outer_cursor = next.outer_cursor + 1;
                end
            end
        end
        return next;
    endfunction

    // broadcast_mac and multi_mac consume their streams completely.
    function automatic stream_view_t stream_exhaust(stream_view_t v);
        stream_view_t next;
        next = v;
        next.inner_cursor = '0;
        next.outer_cursor = next.desc.outer_count;
        return next;
    endfunction

    // Physical row for a logical index. wide_row selects the 512-bit-row
    // indexing multi_mac and scale_accumulators use on a ROW_MAJOR LoMem
    // stream; otherwise LoMem is indexed in 128-bit lines, four to a row.
    function automatic logic [MEM_ROW_WIDTH-1:0] stream_row(
            stream_desc_t d, logic signed [INT_WIDTH-1:0] q, logic wide_row);
        logic [MEM_ROW_WIDTH-1:0] step;
        if (d.domain == DOMAIN_COMEM)
            step = q[MEM_ROW_WIDTH-1:0];
        else if (wide_row || d.layout == LAYOUT_MATMUL_B ||
                 d.layout == LAYOUT_MATMUL_B_INT8)
            step = q[MEM_ROW_WIDTH-1:0];
        else
            step = q[MEM_ROW_WIDTH+1:2];
        return d.base_row + step;
    endfunction

    // Lane within a 512-bit LoMem row for a 128-bit line access.
    function automatic logic [LANE_SELECT_WIDTH-1:0] stream_lane(
            stream_desc_t d, logic signed [INT_WIDTH-1:0] q, logic wide_row);
        if (d.domain == DOMAIN_COMEM || wide_row ||
            d.layout == LAYOUT_MATMUL_B || d.layout == LAYOUT_MATMUL_B_INT8)
            return '0;
        else
            return q[LANE_SELECT_WIDTH-1:0];
    endfunction

    // ------------------------------------------------ section 14: stage commands
    typedef struct packed {
        logic [SEQ_WIDTH-1:0]        seq;
        fetch_op_e                   op;
        stream_view_t                view_a;
        stream_view_t                view_b;
        logic [COUNT_WIDTH-1:0]      count;
        logic [ACC_SELECT_WIDTH-1:0] accumulator_index;
        // FETCH_ELEMENTWISE: 1 routes A*1 + B*1, 0 routes A*B.
        logic                        add_not_mul;
    } fetch_cmd_t;

    typedef struct packed {
        logic [SEQ_WIDTH-1:0]   seq;
        compute_op_e            op;
        logic [COUNT_WIDTH-1:0] count;
    } compute_cmd_t;

    typedef struct packed {
        logic [SEQ_WIDTH-1:0]         seq;
        wb_op_e                       op;
        stream_view_t                 view_out;
        stream_view_t                 view_scale;
        logic [COUNT_WIDTH-1:0]       count;
        logic [BUFFER_IDX_WIDTH-1:0]  buffer_idx;
    } writeback_cmd_t;

    // -------------------------------------------------- section 6: data packets
    typedef struct packed {
        logic [SEQ_WIDTH-1:0]                                  seq;
        logic [TREEMACS-1:0][TREEMAC_MULTIPLIERS-1:0][15:0]     lhs;
        logic [TREEMACS-1:0][TREEMAC_MULTIPLIERS-1:0][15:0]     rhs;
        logic [TREEMACS-1:0][31:0]                              preload;
        logic                                                   preload_valid;
        logic [ACC_SELECT_WIDTH-1:0]                            accumulator_index;
        logic [TREEMACS-1:0]                                    active_lanes;
        // Set on the final packet of a command so Compute needs no packet count.
        logic                                                   last;
    } operand_pkt_t;

    typedef struct packed {
        logic [SEQ_WIDTH-1:0]                seq;
        logic [TOTAL_ACCUMULATORS-1:0][15:0] values;
        logic [COUNT_WIDTH-1:0]              count;
    } result_pkt_t;

    // ------------------------------------------------ section 4: format changes
    // FP32 to BF16, round-to-nearest ties-to-even. Subnormal inputs and
    // underflowed results are flushed to signed zero, matching the arithmetic
    // the compute datapath reuses.
    function automatic logic [15:0] fp32_to_bf16(logic [31:0] v);
        logic        sign;
        logic [7:0]  exponent;
        logic [22:0] fraction;
        logic        round_up;
        logic [7:0]  significand;
        logic [8:0]  exponent_up;

        sign     = v[31];
        exponent = v[30:23];
        fraction = v[22:0];

        if (exponent == 8'hff)
            return (fraction != '0) ? {sign, 8'hff, 7'h40} : {sign, 8'hff, 7'h00};
        if (exponent == 8'h00)
            return {sign, 15'b0};

        round_up    = fraction[15] & (|fraction[14:0] | fraction[16]);
        significand = {1'b0, fraction[22:16]} + {7'b0, round_up};
        exponent_up = {1'b0, exponent} + {8'b0, significand[7]};

        if (exponent_up >= 9'd255)
            return {sign, 8'hff, 7'h00};
        return {sign, exponent_up[7:0], significand[6:0]};
    endfunction

    // Signed INT8 to BF16. Every INT8 magnitude fits in the eight significant
    // bits of BF16, so the conversion is exact.
    function automatic logic [15:0] int8_to_bf16(logic signed [7:0] v);
        logic [7:0]  raw;
        logic [7:0]  magnitude;
        logic [3:0]  leading;
        logic [7:0]  normalized;

        if (v == '0)
            return BF16_ZERO;
        raw       = $unsigned(v);
        magnitude = v[7] ? (8'b0 - raw) : raw;
        leading   = 4'd0;
        for (int unsigned b = 0; b < 8; b++)
            if (magnitude[b])
                leading = b[3:0];
        normalized = magnitude << (4'd7 - leading);
        return {v[7], 8'd127 + {4'b0, leading}, normalized[6:0]};
    endfunction

endpackage
