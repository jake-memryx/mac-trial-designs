`timescale 1ns/1ps

// V1 Matrix Core architectural constants and command/dataflow types.
//
// Frozen by matrix_core_high_level_hardware_spec_rev03.md section 1.2:
//   4 TreeMAC lanes, 8 BF16 multipliers each, 16 FP32 accumulators each,
//   128-bit base line, 512-bit LoMem row, 128-bit CoMem row,
//   16 signed int32 control registers.
//
// Everything listed as TBD in the specification (instruction encoding, queue
// depths, memory handshake, error reporting) is deliberately left as a
// parameter or an explicitly incomplete type here rather than frozen.
package mcore_pkg;

    // ------------------------------------------------------------------
    // Section 2.1 fixed V1 parameters
    // ------------------------------------------------------------------
    parameter int unsigned TREEMACS            = 4;
    parameter int unsigned TREEMAC_MULTIPLIERS = 8;
    parameter int unsigned TREEMAC_ACCUMULATORS = 16;
    parameter int unsigned TOTAL_MULTIPLIERS   = TREEMACS * TREEMAC_MULTIPLIERS;
    parameter int unsigned TOTAL_ACCUMULATORS  = TREEMACS * TREEMAC_ACCUMULATORS;

    parameter int unsigned LINE_WIDTH   = 128;
    parameter int unsigned LOMEM_LANES  = 4;
    parameter int unsigned LOMEM_WIDTH  = LOMEM_LANES * LINE_WIDTH;
    parameter int unsigned COMEM_WIDTH  = LINE_WIDTH;

    parameter int unsigned BF16_PER_LINE = LINE_WIDTH / 16;
    parameter int unsigned FP32_PER_LINE = LINE_WIDTH / 32;
    parameter int unsigned INT8_PER_LINE = LINE_WIDTH / 8;

    parameter int unsigned INT_REGISTERS = 16;
    parameter int unsigned INT_WIDTH     = 32;

    parameter int unsigned ACC_SELECT_WIDTH = $clog2(TREEMAC_ACCUMULATORS);
    parameter int unsigned LANE_SELECT_WIDTH = $clog2(TREEMACS);
    // valid_columns is 1..64 (section 42), so 7 bits are needed.
    parameter int unsigned VALID_COLUMNS_WIDTH = $clog2(TOTAL_ACCUMULATORS + 1);

    // ------------------------------------------------------------------
    // Implementation parameters (section 57 open decisions)
    // ------------------------------------------------------------------
    parameter int unsigned MEM_ADDR_WIDTH   = 16;
    parameter int unsigned PROG_ADDR_WIDTH  = 12;
    parameter int unsigned STREAM_SLOTS     = 8;
    parameter int unsigned STREAM_ID_WIDTH  = $clog2(STREAM_SLOTS);
    parameter int unsigned LOOP_STACK_DEPTH = 4;

    // ------------------------------------------------------------------
    // Section 19/20 layouts and memory domains
    // ------------------------------------------------------------------
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

    // ------------------------------------------------------------------
    // Section 40 instruction set. Binary encoding is TBD; this enum only
    // fixes the semantic opcode space used by the decoder.
    // ------------------------------------------------------------------
    typedef enum logic [3:0] {
        OP_SET_STREAM             = 4'd0,
        OP_LOAD_IMM               = 4'd1,
        OP_ADD_IMM                = 4'd2,
        OP_LOOP                   = 4'd3,
        OP_END_LOOP               = 4'd4,
        OP_BRANCH_IF_LESS         = 4'd5,
        OP_BRANCH_IF_GREATER_EQ   = 4'd6,
        OP_RESET_ACCUMULATORS     = 4'd7,
        OP_LOAD_ACCUMULATORS      = 4'd8,
        OP_BROADCAST_MAC          = 4'd9,
        OP_MULTI_MAC              = 4'd10,
        OP_WRITE_ACCUMULATORS     = 4'd11,
        OP_HALT                   = 4'd12
    } opcode_e;

    // ------------------------------------------------------------------
    // 64-bit instruction encoding
    //
    // All instructions are one 64-bit word except SetStream, which is a
    // four-word instruction (one opcode word plus three payload words).
    // Program memory is read combinationally: prog_data reflects prog_addr in
    // the same cycle.
    //
    // Common single-word layout:
    //   [63:60] opcode
    //   [59:56] rd            destination integer register
    //   [55:52] rs            source integer register
    //   [51:49] stream_a      primary stream id (A / seed / writeback target)
    //   [48:46] stream_b      secondary stream id (packed B operand)
    //   [45:39] valid_columns literal 1..64 (MultiMAC: valid element count)
    //   [45:34] branch_offset signed, branches only (aliases the two fields
    //                         above, which no branch uses)
    //   [38:35] acc_index     accumulator index 0..15
    //   [34]    reserved
    //   [33]    imm_is_reg    0 = imm32 is a literal, 1 = imm32[3:0] is a
    //                         register index (section 35 IntValue)
    //   [32]    reserved
    //   [31:0]  imm32         literal, register index, or branch bound
    //
    // SetStream word 0:
    //   [63:60] opcode
    //   [59:57] stream id
    //   [56]    domain
    //   [55:54] layout
    //   [53:38] base_row
    //   [37]    has_outer_stride (0 => outer_stride = inner_count*inner_stride)
    //   [36:32] IntValue register-select bits for, from MSB to LSB:
    //           offset, inner_count, outer_count, inner_stride, outer_stride
    // SetStream word 1: [63:32] offset,       [31:0] inner_count
    // SetStream word 2: [63:32] outer_count,  [31:0] inner_stride
    // SetStream word 3: [63:32] outer_stride, [31:0] reserved
    //
    // A register-form SetStream field carries its register index in the low
    // four bits of its 32-bit slot.
    // ------------------------------------------------------------------
    parameter int unsigned INSTR_WIDTH = 64;
    parameter int unsigned BRANCH_OFFSET_WIDTH = 12;
    parameter int unsigned SETSTREAM_WORDS = 4;

    typedef logic [INSTR_WIDTH-1:0] instr_t;

    function automatic opcode_e instr_opcode(instr_t w);
        return opcode_e'(w[63:60]);
    endfunction

    function automatic logic [3:0] instr_rd(instr_t w);
        return w[59:56];
    endfunction

    function automatic logic [3:0] instr_rs(instr_t w);
        return w[55:52];
    endfunction

    function automatic logic [STREAM_ID_WIDTH-1:0] instr_stream_a(instr_t w);
        return w[51:49];
    endfunction

    function automatic logic [STREAM_ID_WIDTH-1:0] instr_stream_b(instr_t w);
        return w[48:46];
    endfunction

    function automatic logic [VALID_COLUMNS_WIDTH-1:0] instr_valid_columns(instr_t w);
        return w[45:39];
    endfunction

    function automatic logic signed [BRANCH_OFFSET_WIDTH-1:0] instr_branch_offset(instr_t w);
        return w[45:34];
    endfunction

    function automatic logic [ACC_SELECT_WIDTH-1:0] instr_acc_index(instr_t w);
        return w[38:35];
    endfunction

    function automatic logic instr_imm_is_reg(instr_t w);
        return w[33];
    endfunction

    function automatic logic signed [INT_WIDTH-1:0] instr_imm(instr_t w);
        return w[31:0];
    endfunction

    // SetStream word 0 fields.
    function automatic logic [STREAM_ID_WIDTH-1:0] setstream_id(instr_t w);
        return w[59:57];
    endfunction

    function automatic mem_domain_e setstream_domain(instr_t w);
        return mem_domain_e'(w[56]);
    endfunction

    function automatic layout_e setstream_layout(instr_t w);
        return layout_e'(w[55:54]);
    endfunction

    function automatic logic [MEM_ADDR_WIDTH-1:0] setstream_base_row(instr_t w);
        return w[53:38];
    endfunction

    function automatic logic setstream_has_outer_stride(instr_t w);
        return w[37];
    endfunction

    // Bit 4 = offset, 3 = inner_count, 2 = outer_count, 1 = inner_stride,
    // 0 = outer_stride.
    function automatic logic [4:0] setstream_reg_select(instr_t w);
        return w[36:32];
    endfunction

    // True when the SetStream field selected by bit index `field` is a
    // register reference rather than a literal.
    function automatic logic setstream_reg_select_bit(
        logic [4:0]    select,
        logic [2:0]    field
    );
        return select[field];
    endfunction

    function automatic logic signed [INT_WIDTH-1:0] instr_high_word(instr_t w);
        return w[63:32];
    endfunction

    function automatic logic signed [INT_WIDTH-1:0] instr_low_word(instr_t w);
        return w[31:0];
    endfunction

    // ------------------------------------------------------------------
    // Section 28 stream state. Cursors live in the CP issue-side copy; a
    // dispatched command carries the resolved snapshot (section 3.6).
    // ------------------------------------------------------------------
    typedef struct packed {
        logic                        valid;
        mem_domain_e                 domain;
        layout_e                     layout;
        logic [MEM_ADDR_WIDTH-1:0]   base_row;
        logic signed [INT_WIDTH-1:0] offset;
        logic signed [INT_WIDTH-1:0] inner_count;
        logic signed [INT_WIDTH-1:0] outer_count;
        logic signed [INT_WIDTH-1:0] inner_stride;
        logic signed [INT_WIDTH-1:0] outer_stride;
    } stream_desc_t;

    // Immutable per-command view of a stream: descriptor plus the cursor
    // position reserved for this command at issue time.
    typedef struct packed {
        stream_desc_t                desc;
        logic signed [INT_WIDTH-1:0] inner_cursor;
        logic signed [INT_WIDTH-1:0] outer_cursor;
    } stream_view_t;

    // Section 29 cursor advance, applied ACCESSES times. The static bound of
    // eight covers the widest single command (a 64-column writeback packs
    // eight 128-bit lines).
    parameter int unsigned MAX_STREAM_ACCESSES = 8;

    function automatic stream_view_t stream_advance(
        stream_view_t view,
        logic [3:0]   accesses
    );
        stream_view_t result;
        result = view;
        for (int unsigned i = 0; i < MAX_STREAM_ACCESSES; i++) begin
            if (i < accesses) begin
                result.inner_cursor = result.inner_cursor + 1;
                if (result.inner_cursor == result.desc.inner_count) begin
                    result.inner_cursor = '0;
                    result.outer_cursor = result.outer_cursor + 1;
                end
            end
        end
        return result;
    endfunction

    // A command that consumes a whole configured stream leaves it exhausted.
    function automatic stream_view_t stream_exhaust(stream_view_t view);
        stream_view_t result;
        result = view;
        result.inner_cursor = '0;
        result.outer_cursor = view.desc.outer_count;
        return result;
    endfunction

    // ------------------------------------------------------------------
    // Stage command payloads (section 41). Program commands expand into one
    // or more of these and are dispatched atomically.
    // ------------------------------------------------------------------
    typedef enum logic [1:0] {
        FETCH_ACC_SEED   = 2'd0,  // LoadAccumulators FP32 line
        FETCH_BROADCAST  = 2'd1,  // A line + packed B rows
        FETCH_MULTI      = 2'd2   // wide A/B operand groups
    } fetch_op_e;

    typedef struct packed {
        fetch_op_e                       op;
        stream_view_t                    stream_a;
        stream_view_t                    stream_b;
        logic [VALID_COLUMNS_WIDTH-1:0]  valid_columns;
        logic [ACC_SELECT_WIDTH-1:0]     accumulator_index;
    } fetch_cmd_t;

    typedef enum logic [1:0] {
        COMPUTE_RESET_ACC = 2'd0,
        COMPUTE_LOAD_ACC  = 2'd1,
        COMPUTE_BROADCAST = 2'd2,
        COMPUTE_MULTI     = 2'd3
    } compute_op_e;

    typedef struct packed {
        compute_op_e                    op;
        logic [ACC_SELECT_WIDTH-1:0]    accumulator_index;
        logic [VALID_COLUMNS_WIDTH-1:0] valid_columns;
        // Set for the Compute half of WriteAccumulators: snapshot the bank in
        // queue order and forward a result packet to Writeback.
        logic                           snapshot;
    } compute_cmd_t;

    typedef struct packed {
        stream_view_t                   stream;
        logic [VALID_COLUMNS_WIDTH-1:0] valid_columns;
    } writeback_cmd_t;

    // ------------------------------------------------------------------
    // Inter-stage data packets (section 3.4)
    // ------------------------------------------------------------------
    typedef struct packed {
        logic [LINE_WIDTH-1:0]  a_line;   // 8 BF16, broadcast to all lanes
        logic [LOMEM_WIDTH-1:0] b_row;    // 4 x 128-bit lane, BF16 after unpack
        logic [TREEMACS-1:0]    lane_en;  // tail masking
    } operand_pkt_t;

    // One accumulator-major/lane-minor snapshot of the bank.
    typedef struct packed {
        logic [TOTAL_ACCUMULATORS-1:0][31:0] value;
        logic [VALID_COLUMNS_WIDTH-1:0]      valid_columns;
    } result_pkt_t;

endpackage
