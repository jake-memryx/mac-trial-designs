`timescale 1ns/1ps

// Matrix Core Command stage: the control processor.
//
// It sits beside the dataflow rather than inside it. Every cycle it decodes one
// instruction word, resolves its immediates and stream views, and either
// executes it locally (control flow, registers, stream descriptors) or expands
// it into stage commands. Dispatch is atomic: a command that needs two stages
// enqueues into both in the same cycle or not at all, so the PC never advances
// on a partially issued instruction (matrix_core.md section 14).
//
// Everything a queued command needs is captured at issue: resolved immediates,
// the stream descriptor, and the cursor position it will start from. The
// cursors are owned here and advanced at issue, so a later set_stream or
// register write cannot disturb work already in flight (section 15).
//
// Memory ordering is enforced by a range reservation table rather than by
// waiting for stages to go idle. A conflicting instruction simply does not
// issue and retries with the PC unchanged (section 19).
module mcore_cmd
    import mcore_pkg::*;
(
    input  logic                        clk,
    input  logic                        reset,
    input  logic                        start,
    output logic                        done,
    output logic                        error,
    output logic [PROG_ADDR_WIDTH-1:0]  prog_addr,
    input  instr_t                      prog_data,
    output logic                        fetch_cmd_valid,
    input  logic                        fetch_cmd_ready,
    output fetch_cmd_t                  fetch_cmd,
    output logic                        compute_cmd_valid,
    input  logic                        compute_cmd_ready,
    output compute_cmd_t                compute_cmd,
    output logic                        wb_cmd_valid,
    input  logic                        wb_cmd_ready,
    output writeback_cmd_t              wb_cmd,
    input  logic                        fetch_idle,
    input  logic                        compute_idle,
    input  logic                        writeback_idle,
    input  logic                        fetch_done_valid,
    input  logic [SEQ_WIDTH-1:0]        fetch_done_seq,
    input  logic                        wb_done_valid,
    input  logic [SEQ_WIDTH-1:0]        wb_done_seq,
    // No memory request is outstanding at either port.
    input  logic                        mem_quiet,
    // Why the stage is not issuing, separated so a testbench can tell a queue
    // full apart from a real dependency (section 19).
    output logic                        structural_stall,
    output logic                        dependency_stall
);
    typedef enum logic [2:0] {
        CP_IDLE      = 3'd0,
        CP_RUN       = 3'd1,
        CP_STREAM_W1 = 3'd2,
        CP_STREAM_W2 = 3'd3,
        CP_STREAM_W3 = 3'd4,
        CP_SKIP_LOOP = 3'd5,
        CP_DRAIN     = 3'd6
    } cmd_state_e;

    cmd_state_e state, next_state;

    localparam int unsigned SLOT_WIDTH = $clog2(STREAM_SLOTS);
    localparam int unsigned SP_WIDTH   = $clog2(LOOP_STACK_DEPTH+1);

    logic [PROG_ADDR_WIDTH-1:0]  pc;
    logic signed [INT_WIDTH-1:0] int_rf [0:INT_REGISTERS-1];
    logic [INT_REGISTERS-1:0]    rf_valid;
    stream_desc_t                stream_desc [0:STREAM_SLOTS-1];
    logic signed [INT_WIDTH-1:0] inner_cursor [0:STREAM_SLOTS-1];
    logic signed [INT_WIDTH-1:0] outer_cursor [0:STREAM_SLOTS-1];
    logic signed [INT_WIDTH-1:0] loop_remaining [0:LOOP_STACK_DEPTH-1];
    logic [PROG_ADDR_WIDTH-1:0]  loop_body_pc [0:LOOP_STACK_DEPTH-1];
    logic [$clog2(LOOP_STACK_DEPTH+1)-1:0] loop_sp;
    logic [$clog2(LOOP_STACK_DEPTH+1)-1:0] skip_depth;
    logic [SEQ_WIDTH-1:0]        seq_counter;
    logic                        error_q;

    // set_stream staging across its four words.
    logic [STREAM_ID_WIDTH-1:0]  ss_id;
    mem_domain_e                 ss_domain;
    layout_e                     ss_layout;
    logic [MEM_ROW_WIDTH-1:0]    ss_base_row;
    logic                        ss_has_outer_stride;
    logic [4:0]                  ss_reg_select;
    logic signed [INT_WIDTH-1:0] ss_offset, ss_inner_count;
    logic signed [INT_WIDTH-1:0] ss_outer_count, ss_inner_stride;

    // Reservation table.
    logic [RESERVATIONS-1:0]         res_valid;
    logic [SEQ_WIDTH-1:0]            res_seq   [0:RESERVATIONS-1];
    mem_domain_e                     res_domain [0:RESERVATIONS-1];
    logic [RESERVATIONS-1:0]         res_write;
    logic [RESERVATIONS-1:0]         res_owner_wb;
    logic [MEM_ROW_WIDTH-1:0]        res_low   [0:RESERVATIONS-1];
    logic [MEM_ROW_WIDTH-1:0]        res_high  [0:RESERVATIONS-1];

    // ------------------------------------------------------------ instruction
    instr_t                      word;
    opcode_e                     opcode;
    logic [STREAM_ID_WIDTH-1:0]  sid_a, sid_b;
    logic signed [INT_WIDTH-1:0] imm_value;
    logic                        imm_reg_missing;
    logic [PROG_ADDR_WIDTH-1:0]  sequential_pc;
    logic [PROG_ADDR_WIDTH-1:0]  branch_pc;
    logic                        branch_taken;
    logic [COUNT_WIDTH-1:0]      count;
    logic [3:0]                  out_lines;
    logic [1:0]                  scale_rows;

    stream_view_t                view_a, view_b;
    logic                        stream_a_ok, stream_b_ok;

    logic                        need_fetch, need_compute, need_wb;
    logic                        decode_error;
    logic                        all_ready;
    logic                        issue_ok;

    assign word          = prog_data;
    assign opcode        = instr_opcode(word);
    assign sid_a         = instr_stream_a(word);
    assign sid_b         = instr_stream_b(word);
    assign count         = instr_count(word);
    assign sequential_pc = pc + 1'b1;
    assign branch_pc     = sequential_pc +
                           $unsigned(instr_offset(word));
    assign out_lines     = 4'((count + 7'd7) >> 3);
    assign scale_rows    = 2'((count + 7'd31) >> 5);

    // An IntValue is either a literal or a register read; reading a register
    // that was never written is an illegal program (section 20).
    always_comb begin
        if (instr_imm_is_reg(word)) begin
            imm_value       = int_rf[instr_imm(word)[REG_IDX_WIDTH-1:0]];
            imm_reg_missing = !rf_valid[instr_imm(word)[REG_IDX_WIDTH-1:0]];
        end else begin
            imm_value       = instr_imm(word);
            imm_reg_missing = 1'b0;
        end
    end

    assign stream_a_ok = (sid_a < STREAM_ID_WIDTH'(STREAM_SLOTS)) &&
                         stream_desc[sid_a[$clog2(STREAM_SLOTS)-1:0]].valid;
    assign stream_b_ok = (sid_b < STREAM_ID_WIDTH'(STREAM_SLOTS)) &&
                         stream_desc[sid_b[$clog2(STREAM_SLOTS)-1:0]].valid;

    always_comb begin
        view_a.desc         = stream_desc[sid_a[$clog2(STREAM_SLOTS)-1:0]];
        view_a.inner_cursor = inner_cursor[sid_a[$clog2(STREAM_SLOTS)-1:0]];
        view_a.outer_cursor = outer_cursor[sid_a[$clog2(STREAM_SLOTS)-1:0]];
        view_b.desc         = stream_desc[sid_b[$clog2(STREAM_SLOTS)-1:0]];
        view_b.inner_cursor = inner_cursor[sid_b[$clog2(STREAM_SLOTS)-1:0]];
        view_b.outer_cursor = outer_cursor[sid_b[$clog2(STREAM_SLOTS)-1:0]];
    end

    always_comb begin
        branch_taken = 1'b0;
        if (opcode == OP_BLT)
            branch_taken = int_rf[instr_rs(word)] < imm_value;
        else if (opcode == OP_BGE)
            branch_taken = int_rf[instr_rs(word)] >= imm_value;
    end

    // ------------------------------------------------------- stage expansion
    logic [SEQ_WIDTH-1:0] issue_seq;
    assign issue_seq = (seq_counter == '0) ? SEQ_WIDTH'(1) : seq_counter;

    always_comb begin
        need_fetch   = 1'b0;
        need_compute = 1'b0;
        need_wb      = 1'b0;
        decode_error = 1'b0;

        fetch_cmd                   = '0;
        fetch_cmd.seq               = issue_seq;
        fetch_cmd.count             = count;
        fetch_cmd.accumulator_index = instr_acc_index(word);
        fetch_cmd.view_a            = view_a;
        fetch_cmd.view_b            = view_b;

        compute_cmd       = '0;
        compute_cmd.seq   = issue_seq;
        compute_cmd.count = count;

        wb_cmd            = '0;
        wb_cmd.seq        = issue_seq;
        wb_cmd.count      = count;
        wb_cmd.buffer_idx = instr_buffer_idx(word);
        wb_cmd.view_out   = view_a;
        wb_cmd.view_scale = view_a;

        case (opcode)
            OP_LI, OP_ADDI, OP_LOOP, OP_ENDLOOP, OP_JUMP, OP_BLT, OP_BGE,
            OP_SET_STREAM, OP_HALT: begin
                decode_error = imm_reg_missing;
                if (opcode == OP_ADDI || opcode == OP_BLT || opcode == OP_BGE)
                    decode_error = decode_error || !rf_valid[instr_rs(word)];
                if (opcode == OP_ENDLOOP)
                    decode_error = decode_error || (loop_sp == '0);
                if (opcode == OP_LOOP)
                    decode_error = decode_error ||
                        ((imm_value > 0) &&
                         (loop_sp == $clog2(LOOP_STACK_DEPTH+1)'(LOOP_STACK_DEPTH)));
            end
            OP_ACC_RESET: begin
                need_compute    = 1'b1;
                compute_cmd.op  = COMPUTE_RESET;
            end
            OP_LOAD_ACCUMULATORS: begin
                need_fetch     = 1'b1;
                need_compute   = 1'b1;
                fetch_cmd.op   = FETCH_ACC_LOAD;
                compute_cmd.op = COMPUTE_LOAD_ACC;
                decode_error   = !stream_a_ok ||
                                 (view_a.desc.domain != DOMAIN_LOMEM) ||
                                 (view_a.desc.layout != LAYOUT_ROW_MAJOR_FP32);
            end
            OP_BROADCAST_MAC: begin
                need_fetch     = 1'b1;
                need_compute   = 1'b1;
                fetch_cmd.op   = FETCH_BROADCAST;
                compute_cmd.op = COMPUTE_MAC;
                decode_error   = !stream_a_ok || !stream_b_ok ||
                                 (count == '0) || (count > 7'd64) ||
                                 (view_a.desc.layout != LAYOUT_ROW_MAJOR) ||
                                 (view_b.desc.domain != DOMAIN_LOMEM) ||
                                 !((view_b.desc.layout == LAYOUT_MATMUL_B) ||
                                   (view_b.desc.layout == LAYOUT_MATMUL_B_INT8));
            end
            OP_MULTI_MAC: begin
                need_fetch     = 1'b1;
                need_compute   = 1'b1;
                fetch_cmd.op   = FETCH_MULTI;
                compute_cmd.op = COMPUTE_MAC;
                decode_error   = !stream_a_ok || !stream_b_ok ||
                                 (count == '0) || (count > 7'd64) ||
                                 (view_a.desc.domain != DOMAIN_LOMEM) ||
                                 (view_b.desc.domain != DOMAIN_LOMEM) ||
                                 (view_a.desc.layout != LAYOUT_ROW_MAJOR) ||
                                 (view_b.desc.layout != LAYOUT_ROW_MAJOR);
            end
            OP_ELEMENTWISE_ADD, OP_ELEMENTWISE_MUL: begin
                need_fetch              = 1'b1;
                need_compute            = 1'b1;
                fetch_cmd.op            = FETCH_ELEMENTWISE;
                fetch_cmd.add_not_mul   = (opcode == OP_ELEMENTWISE_ADD);
                compute_cmd.op          = COMPUTE_MAC;
                decode_error            = !stream_a_ok || !stream_b_ok ||
                                          (count == '0) || (count > 7'd64) ||
                                          (view_a.desc.layout != LAYOUT_ROW_MAJOR) ||
                                          (view_b.desc.layout != LAYOUT_ROW_MAJOR);
            end
            OP_REDUCE_ACCUMULATORS: begin
                need_compute   = 1'b1;
                need_wb        = 1'b1;
                compute_cmd.op = COMPUTE_SNAPSHOT;
                wb_cmd.op      = WB_REDUCE;
                decode_error   = (count == '0) || (count > 7'd64);
            end
            OP_SCALE_ACCUMULATORS: begin
                need_compute      = 1'b1;
                need_wb           = 1'b1;
                compute_cmd.op    = COMPUTE_SNAPSHOT;
                wb_cmd.op         = WB_SCALE;
                wb_cmd.view_scale = view_a;
                wb_cmd.view_out   = view_b;
                decode_error      = !stream_a_ok || !stream_b_ok ||
                                    (count == '0) || (count > 7'd64) ||
                                    (view_a.desc.domain != DOMAIN_LOMEM) ||
                                    (view_a.desc.layout != LAYOUT_ROW_MAJOR) ||
                                    (view_b.desc.layout != LAYOUT_ROW_MAJOR);
            end
            OP_WRITE_ACCUMULATORS: begin
                need_compute   = 1'b1;
                need_wb        = 1'b1;
                compute_cmd.op = COMPUTE_SNAPSHOT;
                wb_cmd.op      = WB_WRITE_ACC;
                decode_error   = !stream_a_ok || (count == '0) ||
                                 (count > 7'd64) ||
                                 (view_a.desc.layout != LAYOUT_ROW_MAJOR);
            end
            OP_WRITE_BUF: begin
                need_wb      = 1'b1;
                wb_cmd.op    = WB_WRITE_BUF;
                wb_cmd.count = COUNT_WIDTH'(OUTPUT_BUFFER_SLOTS);
                decode_error = !stream_a_ok ||
                               (view_a.desc.layout != LAYOUT_ROW_MAJOR);
            end
            default: decode_error = 1'b1;
        endcase
    end

    // --------------------------------------------------- range reservations
    // Ranges are conservative: whole rows, and for a stream consumed to
    // exhaustion the whole remaining descriptor extent. Negative strides are
    // handled by taking the smaller of the first and last row as the low bound.
    function automatic logic [MEM_ROW_WIDTH-1:0] range_first(
            stream_view_t v, logic wide);
        return stream_row(v.desc, stream_index(v), wide);
    endfunction

    function automatic logic [MEM_ROW_WIDTH-1:0] range_last_n(
            stream_view_t v, logic wide, int unsigned n);
        return stream_row(v.desc, stream_index_ahead(v, n - 1), wide);
    endfunction

    function automatic logic [MEM_ROW_WIDTH-1:0] range_last_all(
            stream_view_t v, logic wide);
        stream_view_t last;
        last              = v;
        last.inner_cursor = v.desc.inner_count - 32'sd1;
        last.outer_cursor = v.desc.outer_count - 32'sd1;
        return stream_row(last.desc, stream_index(last), wide);
    endfunction

    logic                     res_need_a, res_need_b;
    logic                     res_a_write, res_b_write;
    logic                     res_a_owner_wb, res_b_owner_wb;
    mem_domain_e              res_a_domain, res_b_domain;
    logic [MEM_ROW_WIDTH-1:0] res_a_first, res_a_last;
    logic [MEM_ROW_WIDTH-1:0] res_b_first, res_b_last;
    logic [MEM_ROW_WIDTH-1:0] res_a_low, res_a_high;
    logic [MEM_ROW_WIDTH-1:0] res_b_low, res_b_high;

    always_comb begin
        res_need_a     = 1'b0;
        res_need_b     = 1'b0;
        res_a_write    = 1'b0;
        res_b_write    = 1'b0;
        res_a_owner_wb = 1'b0;
        res_b_owner_wb = 1'b0;
        res_a_domain   = view_a.desc.domain;
        res_b_domain   = view_b.desc.domain;
        res_a_first    = range_first(view_a, 1'b0);
        res_a_last     = res_a_first;
        res_b_first    = range_first(view_b, 1'b0);
        res_b_last     = res_b_first;

        case (opcode)
            OP_LOAD_ACCUMULATORS: begin
                res_need_a = 1'b1;
            end
            OP_BROADCAST_MAC: begin
                res_need_a = 1'b1;
                res_need_b = 1'b1;
                res_a_last = range_last_all(view_a, 1'b0);
                res_b_last = range_last_all(view_b, 1'b0);
            end
            OP_MULTI_MAC: begin
                res_need_a  = 1'b1;
                res_need_b  = 1'b1;
                res_a_first = range_first(view_a, 1'b1);
                res_b_first = range_first(view_b, 1'b1);
                res_a_last  = range_last_n(view_a, 1'b1, 32'(scale_rows));
                res_b_last  = range_last_n(view_b, 1'b1, 32'(scale_rows));
            end
            OP_ELEMENTWISE_ADD, OP_ELEMENTWISE_MUL: begin
                res_need_a = 1'b1;
                res_need_b = 1'b1;
                res_a_last = range_last_n(view_a, 1'b0, 32'(out_lines));
                res_b_last = range_last_n(view_b, 1'b0, 32'(out_lines));
            end
            OP_SCALE_ACCUMULATORS: begin
                res_need_a     = 1'b1;
                res_need_b     = 1'b1;
                res_a_owner_wb = 1'b1;
                res_b_owner_wb = 1'b1;
                res_b_write    = 1'b1;
                res_a_first    = range_first(view_a, 1'b1);
                res_a_last     = range_last_n(view_a, 1'b1, 32'(scale_rows));
                res_b_last     = range_last_n(view_b, 1'b0, 32'(out_lines));
            end
            OP_WRITE_ACCUMULATORS: begin
                res_need_a     = 1'b1;
                res_a_write    = 1'b1;
                res_a_owner_wb = 1'b1;
                res_a_last     = range_last_n(view_a, 1'b0, 32'(out_lines));
            end
            OP_WRITE_BUF: begin
                res_need_a     = 1'b1;
                res_a_write    = 1'b1;
                res_a_owner_wb = 1'b1;
            end
            OP_SET_STREAM, OP_LI, OP_ADDI, OP_LOOP, OP_ENDLOOP, OP_JUMP,
            OP_BLT, OP_BGE, OP_ACC_RESET, OP_REDUCE_ACCUMULATORS,
            OP_HALT: res_need_a = 1'b0;
            default: res_need_a = 1'b0;
        endcase

        res_a_low  = (res_a_first <= res_a_last) ? res_a_first : res_a_last;
        res_a_high = (res_a_first <= res_a_last) ? res_a_last : res_a_first;
        res_b_low  = (res_b_first <= res_b_last) ? res_b_first : res_b_last;
        res_b_high = (res_b_first <= res_b_last) ? res_b_last : res_b_first;
    end

    // A new read conflicts with an older write and a new write with an older
    // read; write-write pairs are ordered by the WB command FIFO.
    function automatic logic conflicts(
            logic entry_valid, mem_domain_e entry_domain, logic entry_write,
            logic [MEM_ROW_WIDTH-1:0] entry_low,
            logic [MEM_ROW_WIDTH-1:0] entry_high,
            mem_domain_e new_domain, logic new_write,
            logic [MEM_ROW_WIDTH-1:0] new_low,
            logic [MEM_ROW_WIDTH-1:0] new_high);
        return entry_valid && (entry_domain == new_domain) &&
               (entry_write != new_write) &&
               (new_low <= entry_high) && (entry_low <= new_high);
    endfunction

    logic                                res_conflict;
    logic [$clog2(RESERVATIONS+1)-1:0]    res_free_count;
    logic [$clog2(RESERVATIONS+1)-1:0]    res_need_count;
    logic                                res_space_ok;
    logic [$clog2(RESERVATIONS)-1:0]      res_slot_a, res_slot_b;

    always_comb begin
        res_conflict   = 1'b0;
        res_free_count = '0;
        res_slot_a     = '0;
        res_slot_b     = '0;
        for (int unsigned e = 0; e < RESERVATIONS; e++) begin
            if (res_need_a)
                res_conflict = res_conflict ||
                    conflicts(res_valid[e], res_domain[e], res_write[e],
                              res_low[e], res_high[e], res_a_domain,
                              res_a_write, res_a_low, res_a_high);
            if (res_need_b)
                res_conflict = res_conflict ||
                    conflicts(res_valid[e], res_domain[e], res_write[e],
                              res_low[e], res_high[e], res_b_domain,
                              res_b_write, res_b_low, res_b_high);
        end
        // Lowest two free slots, scanned from the top so the lowest wins.
        for (int unsigned e = RESERVATIONS; e > 0; e--) begin
            if (!res_valid[e-1]) begin
                res_free_count = res_free_count + 1'b1;
                res_slot_b     = res_slot_a;
                res_slot_a     = $clog2(RESERVATIONS)'(e - 1);
            end
        end
        res_need_count = $clog2(RESERVATIONS+1)'({1'b0, res_need_a} +
                                                {1'b0, res_need_b});
        res_space_ok   = (res_free_count >= res_need_count);
    end

    // ---------------------------------------------------------------- issue
    logic can_issue;

    assign all_ready = (!need_fetch   || fetch_cmd_ready) &&
                       (!need_compute || compute_cmd_ready) &&
                       (!need_wb      || wb_cmd_ready);
    assign can_issue = (state == CP_RUN) && !decode_error && !res_conflict &&
                       res_space_ok;
    assign issue_ok  = can_issue && all_ready;

    // Atomic dispatch: a stage sees valid only when every other stage this
    // instruction needs can accept in the same cycle.
    assign fetch_cmd_valid   = need_fetch   && can_issue && all_ready;
    assign compute_cmd_valid = need_compute && can_issue && all_ready;
    assign wb_cmd_valid      = need_wb      && can_issue && all_ready;

    assign structural_stall = (state == CP_RUN) && !decode_error &&
                              !res_conflict && res_space_ok && !all_ready;
    assign dependency_stall = (state == CP_RUN) && !decode_error &&
                              (res_conflict || !res_space_ok);

    assign prog_addr = pc;
    assign error     = error_q;
    assign done      = (state == CP_DRAIN) && fetch_idle && compute_idle &&
                       writeback_idle && mem_quiet && (res_valid == '0);

    always_comb begin
        next_state = state;
        case (state)
            CP_IDLE: begin
                if (start)
                    next_state = CP_RUN;
            end
            CP_RUN: begin
                if (decode_error)
                    next_state = CP_DRAIN;
                else if (issue_ok) begin
                    if (opcode == OP_SET_STREAM)
                        next_state = CP_STREAM_W1;
                    else if ((opcode == OP_LOOP) && (imm_value <= 0))
                        next_state = CP_SKIP_LOOP;
                    else if (opcode == OP_HALT)
                        next_state = CP_DRAIN;
                end
            end
            CP_STREAM_W1: next_state = CP_STREAM_W2;
            CP_STREAM_W2: next_state = CP_STREAM_W3;
            CP_STREAM_W3: next_state = CP_RUN;
            CP_SKIP_LOOP: begin
                if ((opcode == OP_ENDLOOP) && (skip_depth == SP_WIDTH'(1'b1)))
                    next_state = CP_RUN;
            end
            CP_DRAIN: begin
                if (done && !start)
                    next_state = CP_IDLE;
            end
            default: next_state = CP_IDLE;
        endcase
    end

    // ------------------------------------------------------------ execution
    logic [SLOT_WIDTH-1:0] slot_a, slot_b;
    logic [1:0]            loop_top;
    logic                  ss_field_missing;
    logic signed [INT_WIDTH-1:0] ss_word_high, ss_word_low;

    assign slot_a   = sid_a[SLOT_WIDTH-1:0];
    assign slot_b   = sid_b[SLOT_WIDTH-1:0];
    assign loop_top = 2'(loop_sp - SP_WIDTH'(1'b1));

    // A set_stream field selected by reg_select carries a register index in the
    // low bits of its word instead of a literal.
    function automatic logic signed [INT_WIDTH-1:0] ss_resolve(
            logic selected, logic signed [INT_WIDTH-1:0] slot_value);
        return selected ? int_rf[slot_value[REG_IDX_WIDTH-1:0]] : slot_value;
    endfunction

    function automatic logic ss_missing(
            logic selected, logic signed [INT_WIDTH-1:0] slot_value);
        return selected && !rf_valid[slot_value[REG_IDX_WIDTH-1:0]];
    endfunction

    assign ss_word_high = instr_high_word(word);
    assign ss_word_low  = instr_low_word(word);

    always_comb begin
        ss_field_missing = 1'b0;
        if (state == CP_STREAM_W1)
            ss_field_missing = ss_missing(ss_reg_select[4], ss_word_high) ||
                               ss_missing(ss_reg_select[3], ss_word_low);
        else if (state == CP_STREAM_W2)
            ss_field_missing = ss_missing(ss_reg_select[2], ss_word_high) ||
                               ss_missing(ss_reg_select[1], ss_word_low);
        else if (state == CP_STREAM_W3)
            ss_field_missing = ss_missing(ss_reg_select[0], ss_word_high);
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            state       <= CP_IDLE;
            pc          <= '0;
            rf_valid    <= '0;
            loop_sp     <= '0;
            skip_depth  <= '0;
            seq_counter <= SEQ_WIDTH'(1);
            error_q     <= 1'b0;
            res_valid   <= '0;
            for (int unsigned r = 0; r < INT_REGISTERS; r++)
                int_rf[r] <= '0;
            for (int unsigned s = 0; s < STREAM_SLOTS; s++) begin
                stream_desc[s]  <= '0;
                inner_cursor[s] <= '0;
                outer_cursor[s] <= '0;
            end
        end else begin
            state <= next_state;

            // A stage that reports completion releases its reservations.
            for (int unsigned e = 0; e < RESERVATIONS; e++) begin
                if (res_valid[e] &&
                    ((fetch_done_valid && !res_owner_wb[e] &&
                      (res_seq[e] == fetch_done_seq)) ||
                     (wb_done_valid && res_owner_wb[e] &&
                      (res_seq[e] == wb_done_seq))))
                    res_valid[e] <= 1'b0;
            end

            case (state)
                CP_IDLE: begin
                    if (start) begin
                        // A new program clears control state but not the
                        // accumulators or the integer register contents
                        // (section 21).
                        pc          <= '0;
                        rf_valid    <= '0;
                        loop_sp     <= '0;
                        skip_depth  <= '0;
                        seq_counter <= SEQ_WIDTH'(1);
                        error_q     <= 1'b0;
                        for (int unsigned s = 0; s < STREAM_SLOTS; s++) begin
                            stream_desc[s].valid <= 1'b0;
                            inner_cursor[s]      <= '0;
                            outer_cursor[s]      <= '0;
                        end
                    end
                end

                CP_RUN: begin
                    if (decode_error) begin
                        error_q <= 1'b1;
                    end else if (issue_ok) begin
                        pc <= sequential_pc;

                        if (need_fetch || need_compute || need_wb)
                            seq_counter <= (issue_seq == {SEQ_WIDTH{1'b1}}) ?
                                           SEQ_WIDTH'(1) : issue_seq + 1'b1;

                        if (res_need_a) begin
                            res_valid[res_slot_a]    <= 1'b1;
                            res_seq[res_slot_a]      <= issue_seq;
                            res_domain[res_slot_a]   <= res_a_domain;
                            res_write[res_slot_a]    <= res_a_write;
                            res_owner_wb[res_slot_a] <= res_a_owner_wb;
                            res_low[res_slot_a]      <= res_a_low;
                            res_high[res_slot_a]     <= res_a_high;
                        end
                        if (res_need_b) begin
                            res_valid[res_slot_b]    <= 1'b1;
                            res_seq[res_slot_b]      <= issue_seq;
                            res_domain[res_slot_b]   <= res_b_domain;
                            res_write[res_slot_b]    <= res_b_write;
                            res_owner_wb[res_slot_b] <= res_b_owner_wb;
                            res_low[res_slot_b]      <= res_b_low;
                            res_high[res_slot_b]     <= res_b_high;
                        end

                        case (opcode)
                            OP_LI: begin
                                int_rf[instr_rd(word)]   <= imm_value;
                                rf_valid[instr_rd(word)] <= 1'b1;
                            end
                            OP_ADDI: begin
                                int_rf[instr_rd(word)]   <=
                                    int_rf[instr_rs(word)] + imm_value;
                                rf_valid[instr_rd(word)] <= 1'b1;
                            end
                            OP_LOOP: begin
                                if (imm_value > 0) begin
                                    loop_remaining[loop_sp[1:0]] <= imm_value;
                                    loop_body_pc[loop_sp[1:0]]   <= sequential_pc;
                                    loop_sp                      <= loop_sp + 1'b1;
                                end else begin
                                    skip_depth <= SP_WIDTH'(1);
                                end
                            end
                            OP_ENDLOOP: begin
                                if (loop_remaining[loop_top] > 32'sd1) begin
                                    loop_remaining[loop_top] <=
                                        loop_remaining[loop_top] - 32'sd1;
                                    pc <= loop_body_pc[loop_top];
                                end else begin
                                    loop_sp <= loop_sp - 1'b1;
                                end
                            end
                            OP_JUMP: pc <= branch_pc;
                            OP_BLT, OP_BGE: begin
                                if (branch_taken)
                                    pc <= branch_pc;
                            end
                            OP_SET_STREAM: begin
                                ss_id               <= setstream_id(word);
                                ss_domain           <= setstream_domain(word);
                                ss_layout           <= setstream_layout(word);
                                ss_base_row         <= setstream_base_row(word);
                                ss_has_outer_stride <=
                                    setstream_has_outer_stride(word);
                                ss_reg_select       <= setstream_reg_select(word);
                                if (setstream_id(word) >=
                                    STREAM_ID_WIDTH'(STREAM_SLOTS))
                                    error_q <= 1'b1;
                            end
                            OP_LOAD_ACCUMULATORS: begin
                                inner_cursor[slot_a] <=
                                    stream_advance(view_a, 1).inner_cursor;
                                outer_cursor[slot_a] <=
                                    stream_advance(view_a, 1).outer_cursor;
                            end
                            OP_BROADCAST_MAC, OP_MULTI_MAC: begin
                                inner_cursor[slot_a] <=
                                    stream_exhaust(view_a).inner_cursor;
                                outer_cursor[slot_a] <=
                                    stream_exhaust(view_a).outer_cursor;
                                inner_cursor[slot_b] <=
                                    stream_exhaust(view_b).inner_cursor;
                                outer_cursor[slot_b] <=
                                    stream_exhaust(view_b).outer_cursor;
                            end
                            OP_ELEMENTWISE_ADD, OP_ELEMENTWISE_MUL: begin
                                inner_cursor[slot_a] <=
                                    stream_advance(view_a, 32'(out_lines)).inner_cursor;
                                outer_cursor[slot_a] <=
                                    stream_advance(view_a, 32'(out_lines)).outer_cursor;
                                inner_cursor[slot_b] <=
                                    stream_advance(view_b, 32'(out_lines)).inner_cursor;
                                outer_cursor[slot_b] <=
                                    stream_advance(view_b, 32'(out_lines)).outer_cursor;
                            end
                            OP_SCALE_ACCUMULATORS: begin
                                inner_cursor[slot_a] <=
                                    stream_advance(view_a, 32'(scale_rows)).inner_cursor;
                                outer_cursor[slot_a] <=
                                    stream_advance(view_a, 32'(scale_rows)).outer_cursor;
                                inner_cursor[slot_b] <=
                                    stream_advance(view_b, 32'(out_lines)).inner_cursor;
                                outer_cursor[slot_b] <=
                                    stream_advance(view_b, 32'(out_lines)).outer_cursor;
                            end
                            OP_WRITE_ACCUMULATORS: begin
                                inner_cursor[slot_a] <=
                                    stream_advance(view_a, 32'(out_lines)).inner_cursor;
                                outer_cursor[slot_a] <=
                                    stream_advance(view_a, 32'(out_lines)).outer_cursor;
                            end
                            OP_WRITE_BUF: begin
                                inner_cursor[slot_a] <=
                                    stream_advance(view_a, 1).inner_cursor;
                                outer_cursor[slot_a] <=
                                    stream_advance(view_a, 1).outer_cursor;
                            end
                            OP_HALT: pc <= pc;
                            OP_ACC_RESET, OP_REDUCE_ACCUMULATORS: ;
                            default: ;
                        endcase
                    end
                end

                CP_STREAM_W1: begin
                    pc             <= sequential_pc;
                    ss_offset      <= ss_resolve(ss_reg_select[4], ss_word_high);
                    ss_inner_count <= ss_resolve(ss_reg_select[3], ss_word_low);
                    if (ss_field_missing)
                        error_q <= 1'b1;
                end
                CP_STREAM_W2: begin
                    pc              <= sequential_pc;
                    ss_outer_count  <= ss_resolve(ss_reg_select[2], ss_word_high);
                    ss_inner_stride <= ss_resolve(ss_reg_select[1], ss_word_low);
                    if (ss_field_missing)
                        error_q <= 1'b1;
                end
                CP_STREAM_W3: begin
                    pc <= sequential_pc;
                    stream_desc[ss_id[SLOT_WIDTH-1:0]].valid        <= 1'b1;
                    stream_desc[ss_id[SLOT_WIDTH-1:0]].domain       <= ss_domain;
                    stream_desc[ss_id[SLOT_WIDTH-1:0]].layout       <= ss_layout;
                    stream_desc[ss_id[SLOT_WIDTH-1:0]].base_row     <= ss_base_row;
                    stream_desc[ss_id[SLOT_WIDTH-1:0]].offset       <= ss_offset;
                    stream_desc[ss_id[SLOT_WIDTH-1:0]].inner_count  <= ss_inner_count;
                    stream_desc[ss_id[SLOT_WIDTH-1:0]].outer_count  <= ss_outer_count;
                    stream_desc[ss_id[SLOT_WIDTH-1:0]].inner_stride <= ss_inner_stride;
                    stream_desc[ss_id[SLOT_WIDTH-1:0]].outer_stride <=
                        ss_has_outer_stride ?
                        ss_resolve(ss_reg_select[0], ss_word_high) :
                        (ss_inner_count * ss_inner_stride);
                    inner_cursor[ss_id[SLOT_WIDTH-1:0]] <= '0;
                    outer_cursor[ss_id[SLOT_WIDTH-1:0]] <= '0;
                    if (ss_field_missing || (ss_inner_count <= 0) ||
                        (ss_outer_count <= 0))
                        error_q <= 1'b1;
                end

                CP_SKIP_LOOP: begin
                    // The body of a zero-count loop is stepped over without
                    // decoding it, so its set_stream payload words are skipped
                    // as data.
                    if (opcode == OP_SET_STREAM)
                        pc <= pc + PROG_ADDR_WIDTH'(SETSTREAM_WORDS);
                    else
                        pc <= sequential_pc;
                    if (opcode == OP_LOOP)
                        skip_depth <= skip_depth + 1'b1;
                    else if (opcode == OP_ENDLOOP)
                        skip_depth <= skip_depth - 1'b1;
                end

                CP_DRAIN: ;
                default: ;
            endcase
        end
    end
endmodule
