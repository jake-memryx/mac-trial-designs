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
    // A memory instruction takes the long path: CP_RUN captures its stream
    // views, CP_RANGE walks the cursor one access per cycle to get the exact
    // row range it will touch, and CP_ISSUE checks that range against the
    // reservation table and dispatches. Everything else issues straight from
    // CP_RUN (section 19).
    typedef enum logic [2:0] {
        CP_IDLE      = 3'd0,
        CP_RUN       = 3'd1,
        CP_STREAM_W1 = 3'd2,
        CP_RANGE     = 3'd3,
        CP_ISSUE     = 3'd4,
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
    logic [STREAM_COUNT_WIDTH-1:0]       inner_cursor [0:STREAM_SLOTS-1];
    logic [STREAM_COUNT_WIDTH-1:0]       outer_cursor [0:STREAM_SLOTS-1];
    logic signed [STREAM_ADDR_WIDTH-1:0] cursor_addr [0:STREAM_SLOTS-1];
    logic signed [STREAM_ADDR_WIDTH-1:0] cursor_base [0:STREAM_SLOTS-1];
    logic signed [INT_WIDTH-1:0] loop_remaining [0:LOOP_STACK_DEPTH-1];
    logic [PROG_ADDR_WIDTH-1:0]  loop_body_pc [0:LOOP_STACK_DEPTH-1];
    logic [$clog2(LOOP_STACK_DEPTH+1)-1:0] loop_sp;
    logic [$clog2(LOOP_STACK_DEPTH+1)-1:0] skip_depth;
    logic [SEQ_WIDTH-1:0]        seq_counter;
    logic                        error_q;

    // set_stream staging across its two words: word 0 is captured here and
    // word 1 supplies the counts and strides, so the descriptor commits in
    // CP_STREAM_W1.
    logic [STREAM_ID_WIDTH-1:0]          ss_id;
    mem_domain_e                         ss_domain;
    layout_e                             ss_layout;
    logic [MEM_ROW_WIDTH-1:0]            ss_base_row;
    logic                                ss_has_outer_stride;
    logic [4:0]                          ss_reg_select;
    logic signed [STREAM_ADDR_WIDTH-1:0] ss_offset;

    // Range walker. One stream_step and one stream_row instance walk the cursor
    // of the addressed stream, accumulating the row range as they go, so a
    // multi-access command costs one cycle per access at issue and the design
    // needs no multiplier and no parallel walk chain.
    localparam int unsigned WALK_WIDTH = $clog2(MAX_STREAM_ACCESSES+1);

    logic [WALK_WIDTH-1:0]                    walk_left;
    logic                                     walk_phase_b;
    logic                                     walk_wide;
    logic                                     walk_first;
    logic [MEM_ROW_WIDTH-1:0]                 walk_row;
    stream_view_t                             walk_view;
    logic [MEM_ROW_WIDTH-1:0]                 range_low  [0:1];
    logic [MEM_ROW_WIDTH-1:0]                 range_high [0:1];
    // The views a queued command carries: captured before the walk moves the
    // cursors, which is what makes issue-time capture exact (section 15).
    stream_view_t                             issue_view_a, issue_view_b;

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

    // Decoded fields are landed in nets before any of them is indexed. Selecting
    // a bit range directly out of a function call is legal SystemVerilog but not
    // universally supported by synthesis front ends.
    logic signed [INT_WIDTH-1:0]           imm_field;
    logic [REG_IDX_WIDTH-1:0]              imm_reg_index;
    logic [4:0]                            ss_select;
    logic signed [STREAM_ADDR_WIDTH-1:0]   ss_offset_field;
    logic [STREAM_COUNT_WIDTH-1:0]         ss_inner_count_field;
    logic [STREAM_COUNT_WIDTH-1:0]         ss_outer_count_field;
    logic signed [STREAM_STRIDE_WIDTH-1:0] ss_inner_stride_field;
    logic signed [STREAM_STRIDE_WIDTH-1:0] ss_outer_stride_field;

    assign imm_field             = instr_imm(word);
    assign imm_reg_index         = imm_field[REG_IDX_WIDTH-1:0];
    assign ss_select             = setstream_reg_select(word);
    assign ss_offset_field       = setstream_offset(word);
    assign ss_inner_count_field  = setstream_inner_count(word);
    assign ss_outer_count_field  = setstream_outer_count(word);
    assign ss_inner_stride_field = setstream_inner_stride(word);
    assign ss_outer_stride_field = setstream_outer_stride(word);

    // An IntValue is either a literal or a register read; reading a register
    // that was never written is an illegal program (section 20).
    always_comb begin
        if (instr_imm_is_reg(word)) begin
            imm_value       = int_rf[imm_reg_index];
            imm_reg_missing = !rf_valid[imm_reg_index];
        end else begin
            imm_value       = imm_field;
            imm_reg_missing = 1'b0;
        end
    end

    assign stream_a_ok = (sid_a < STREAM_ID_WIDTH'(STREAM_SLOTS)) &&
                         stream_desc[sid_a[$clog2(STREAM_SLOTS)-1:0]].valid;
    assign stream_b_ok = (sid_b < STREAM_ID_WIDTH'(STREAM_SLOTS)) &&
                         stream_desc[sid_b[$clog2(STREAM_SLOTS)-1:0]].valid;

    always_comb begin
        view_a.desc         = stream_desc[sid_a[SLOT_WIDTH-1:0]];
        view_a.inner_cursor = inner_cursor[sid_a[SLOT_WIDTH-1:0]];
        view_a.outer_cursor = outer_cursor[sid_a[SLOT_WIDTH-1:0]];
        view_a.addr         = cursor_addr[sid_a[SLOT_WIDTH-1:0]];
        view_a.outer_base   = cursor_base[sid_a[SLOT_WIDTH-1:0]];
        view_b.desc         = stream_desc[sid_b[SLOT_WIDTH-1:0]];
        view_b.inner_cursor = inner_cursor[sid_b[SLOT_WIDTH-1:0]];
        view_b.outer_cursor = outer_cursor[sid_b[SLOT_WIDTH-1:0]];
        view_b.addr         = cursor_addr[sid_b[SLOT_WIDTH-1:0]];
        view_b.outer_base   = cursor_base[sid_b[SLOT_WIDTH-1:0]];
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

        // Payload views come from the captured copies, which is what the walk
        // preserved; a command that needs no memory does not use them.
        fetch_cmd                   = '0;
        fetch_cmd.seq               = issue_seq;
        fetch_cmd.count             = count;
        fetch_cmd.accumulator_index = instr_acc_index(word);
        fetch_cmd.view_a            = issue_view_a;
        fetch_cmd.view_b            = issue_view_b;

        compute_cmd       = '0;
        compute_cmd.seq   = issue_seq;
        compute_cmd.count = count;

        wb_cmd            = '0;
        wb_cmd.seq        = issue_seq;
        wb_cmd.count      = count;
        wb_cmd.buffer_idx = instr_buffer_idx(word);
        wb_cmd.view_out   = issue_view_a;
        wb_cmd.view_scale = issue_view_a;

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
                wb_cmd.view_scale = issue_view_a;
                wb_cmd.view_out   = issue_view_b;
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
    // Two kinds of range, both computed without a multiplier:
    //
    //   bounded    up to MAX_STREAM_ACCESSES accesses, walked one per cycle in
    //              CP_RANGE, giving the exact row range,
    //   exhausting broadcast_mac and multi_mac consume a whole descriptor, so
    //              the range is the whole domain.
    //
    // The whole-domain approximation is safe and nearly free: reads only
    // conflict with writes, every write range is exact, and a write that
    // follows an exhausting read has to wait for Compute to drain that read's
    // packets anyway.
    logic                     res_need_a, res_need_b;
    logic                     res_a_write, res_b_write;
    logic                     res_a_owner_wb, res_b_owner_wb;
    logic                     exhausting;
    logic [3:0]               accesses_a, accesses_b;
    logic                     wide_a, wide_b;
    mem_domain_e              res_a_domain, res_b_domain;
    logic [MEM_ROW_WIDTH-1:0] res_a_low, res_a_high;
    logic [MEM_ROW_WIDTH-1:0] res_b_low, res_b_high;

    assign res_a_domain = issue_view_a.desc.domain;
    assign res_b_domain = issue_view_b.desc.domain;
    assign res_a_low    = range_low[0];
    assign res_a_high   = range_high[0];
    assign res_b_low    = range_low[1];
    assign res_b_high   = range_high[1];

    always_comb begin
        res_need_a     = 1'b0;
        res_need_b     = 1'b0;
        res_a_write    = 1'b0;
        res_b_write    = 1'b0;
        res_a_owner_wb = 1'b0;
        res_b_owner_wb = 1'b0;
        exhausting     = 1'b0;
        accesses_a     = 4'd0;
        accesses_b     = 4'd0;
        wide_a         = 1'b0;
        wide_b         = 1'b0;

        case (opcode)
            OP_LOAD_ACCUMULATORS: begin
                res_need_a = 1'b1;
                accesses_a = 4'd1;
            end
            OP_BROADCAST_MAC: begin
                res_need_a = 1'b1;
                res_need_b = 1'b1;
                exhausting = 1'b1;
            end
            OP_MULTI_MAC: begin
                res_need_a = 1'b1;
                res_need_b = 1'b1;
                exhausting = 1'b1;
                wide_a     = 1'b1;
                wide_b     = 1'b1;
            end
            OP_ELEMENTWISE_ADD, OP_ELEMENTWISE_MUL: begin
                res_need_a = 1'b1;
                res_need_b = 1'b1;
                accesses_a = out_lines;
                accesses_b = out_lines;
            end
            OP_SCALE_ACCUMULATORS: begin
                res_need_a     = 1'b1;
                res_need_b     = 1'b1;
                res_a_owner_wb = 1'b1;
                res_b_owner_wb = 1'b1;
                res_b_write    = 1'b1;
                accesses_a     = {2'b0, scale_rows};
                accesses_b     = out_lines;
                wide_a         = 1'b1;
            end
            OP_WRITE_ACCUMULATORS: begin
                res_need_a     = 1'b1;
                res_a_write    = 1'b1;
                res_a_owner_wb = 1'b1;
                accesses_a     = out_lines;
            end
            OP_WRITE_BUF: begin
                res_need_a     = 1'b1;
                res_a_write    = 1'b1;
                res_a_owner_wb = 1'b1;
                accesses_a     = 4'd1;
            end
            OP_SET_STREAM, OP_LI, OP_ADDI, OP_LOOP, OP_ENDLOOP, OP_JUMP,
            OP_BLT, OP_BGE, OP_ACC_RESET, OP_REDUCE_ACCUMULATORS,
            OP_HALT: res_need_a = 1'b0;
            default: res_need_a = 1'b0;
        endcase
    end

    // Any instruction that reserves a range goes the long way round.
    logic needs_range;
    assign needs_range = res_need_a || res_need_b;

    // The row the walker is looking at. One stream_row instance for the whole
    // Command stage.
    assign walk_row = stream_row(walk_view.desc, stream_addr(walk_view),
                                 walk_wide);

    // The stepped and exhausted views, landed in nets so there is exactly one
    // step instance and one exhaust instance each, and so no member is selected
    // straight out of a function call.
    stream_view_t walk_next;
    stream_view_t exhaust_a, exhaust_b;

    assign walk_next = stream_step(walk_view);
    assign exhaust_a = stream_exhaust(view_a);
    assign exhaust_b = stream_exhaust(view_b);

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
    // An instruction dispatches either directly from CP_RUN, when it reserves
    // nothing, or from CP_ISSUE once its range is known.
    logic can_issue;
    logic issue_phase;

    assign issue_phase = ((state == CP_RUN) && !needs_range) ||
                         (state == CP_ISSUE);
    assign all_ready   = (!need_fetch   || fetch_cmd_ready) &&
                         (!need_compute || compute_cmd_ready) &&
                         (!need_wb      || wb_cmd_ready);
    assign can_issue   = issue_phase && !decode_error && !res_conflict &&
                         res_space_ok;
    assign issue_ok    = can_issue && all_ready;

    // Atomic dispatch: a stage sees valid only when every other stage this
    // instruction needs can accept in the same cycle.
    assign fetch_cmd_valid   = need_fetch   && can_issue && all_ready;
    assign compute_cmd_valid = need_compute && can_issue && all_ready;
    assign wb_cmd_valid      = need_wb      && can_issue && all_ready;

    assign structural_stall = issue_phase && !decode_error &&
                              !res_conflict && res_space_ok && !all_ready;
    assign dependency_stall = issue_phase && !decode_error &&
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
                else if (needs_range)
                    next_state = CP_RANGE;
                else if (issue_ok) begin
                    if (opcode == OP_SET_STREAM)
                        next_state = CP_STREAM_W1;
                    else if ((opcode == OP_LOOP) && (imm_value <= 0))
                        next_state = CP_SKIP_LOOP;
                    else if (opcode == OP_HALT)
                        next_state = CP_DRAIN;
                end
            end
            CP_STREAM_W1: next_state = CP_RUN;
            // One access per cycle for the walked stream, then the other one,
            // then issue. An exhausting command needs no walk at all.
            CP_RANGE: begin
                if (exhausting)
                    next_state = CP_ISSUE;
                else if ((walk_left == WALK_WIDTH'(1'b1)) &&
                         (walk_phase_b || (accesses_b == 4'd0)))
                    next_state = CP_ISSUE;
            end
            CP_ISSUE: begin
                if (issue_ok)
                    next_state = CP_RUN;
            end
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

    assign slot_a   = sid_a[SLOT_WIDTH-1:0];
    assign slot_b   = sid_b[SLOT_WIDTH-1:0];
    assign loop_top = 2'(loop_sp - SP_WIDTH'(1'b1));

    // A set_stream field selected by reg_select carries a register index in its
    // low four bits instead of a literal. A register is 32-bit, so a resolved
    // field is truncated to the field width (section 21).
    function automatic logic [STREAM_COUNT_WIDTH-1:0] ss_count(
            logic selected, logic [STREAM_COUNT_WIDTH-1:0] field);
        logic signed [INT_WIDTH-1:0] register_value;
        register_value = int_rf[field[REG_IDX_WIDTH-1:0]];
        return selected ? register_value[STREAM_COUNT_WIDTH-1:0] : field;
    endfunction

    function automatic logic signed [STREAM_STRIDE_WIDTH-1:0] ss_stride(
            logic selected, logic signed [STREAM_STRIDE_WIDTH-1:0] field);
        logic signed [INT_WIDTH-1:0] register_value;
        register_value = int_rf[field[REG_IDX_WIDTH-1:0]];
        return selected ? $signed(register_value[STREAM_STRIDE_WIDTH-1:0])
                        : field;
    endfunction

    function automatic logic signed [STREAM_ADDR_WIDTH-1:0] ss_addr(
            logic selected, logic signed [STREAM_ADDR_WIDTH-1:0] field);
        logic signed [INT_WIDTH-1:0] register_value;
        register_value = int_rf[field[REG_IDX_WIDTH-1:0]];
        return selected ? $signed(register_value[STREAM_ADDR_WIDTH-1:0]) : field;
    endfunction

    function automatic logic ss_missing(logic selected,
                                        logic [REG_IDX_WIDTH-1:0] index);
        return selected && !rf_valid[index];
    endfunction

    // Word 0 carries the offset, word 1 the counts and strides.
    always_comb begin
        ss_field_missing = 1'b0;
        if (state == CP_RUN)
            ss_field_missing =
                ss_missing(ss_select[4],
                           ss_offset_field[REG_IDX_WIDTH-1:0]);
        else if (state == CP_STREAM_W1)
            ss_field_missing =
                ss_missing(ss_reg_select[3],
                           ss_inner_count_field[REG_IDX_WIDTH-1:0]) ||
                ss_missing(ss_reg_select[2],
                           ss_outer_count_field[REG_IDX_WIDTH-1:0]) ||
                ss_missing(ss_reg_select[1],
                           ss_inner_stride_field[REG_IDX_WIDTH-1:0]) ||
                ss_missing(ss_reg_select[0],
                           ss_outer_stride_field[REG_IDX_WIDTH-1:0]);
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
                cursor_addr[s]  <= '0;
                cursor_base[s]  <= '0;
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
                            cursor_addr[s]       <= '0;
                            cursor_base[s]       <= '0;
                        end
                    end
                end

                CP_RUN: begin
                    if (decode_error) begin
                        error_q <= 1'b1;
                    end else if (needs_range) begin
                        // Capture the views the command will carry, then walk.
                        // An exhausting command has nothing to walk and takes
                        // the whole domain as its range.
                        issue_view_a <= view_a;
                        issue_view_b <= view_b;
                        walk_phase_b <= 1'b0;
                        walk_first   <= 1'b1;
                        walk_view    <= view_a;
                        walk_left    <= accesses_a;
                        walk_wide    <= wide_a;
                    end else if (issue_ok) begin
                        pc <= sequential_pc;

                        if (need_fetch || need_compute || need_wb)
                            seq_counter <= (issue_seq == {SEQ_WIDTH{1'b1}}) ?
                                           SEQ_WIDTH'(1) : issue_seq + 1'b1;

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
                                ss_offset           <=
                                    ss_addr(ss_select[4], ss_offset_field);
                                ss_id               <= setstream_id(word);
                                ss_domain           <= setstream_domain(word);
                                ss_layout           <= setstream_layout(word);
                                ss_base_row         <= setstream_base_row(word);
                                ss_has_outer_stride <=
                                    setstream_has_outer_stride(word);
                                ss_reg_select       <= setstream_reg_select(word);
                                if ((setstream_id(word) >=
                                     STREAM_ID_WIDTH'(STREAM_SLOTS)) ||
                                    ss_field_missing)
                                    error_q <= 1'b1;
                            end
                            OP_HALT: pc <= pc;
                            // Memory instructions never reach here: they issue
                            // from CP_ISSUE, and their cursors were advanced by
                            // the walk.
                            OP_ACC_RESET, OP_REDUCE_ACCUMULATORS,
                            OP_LOAD_ACCUMULATORS, OP_BROADCAST_MAC,
                            OP_MULTI_MAC, OP_ELEMENTWISE_ADD,
                            OP_ELEMENTWISE_MUL, OP_SCALE_ACCUMULATORS,
                            OP_WRITE_ACCUMULATORS, OP_WRITE_BUF: ;
                            default: ;
                        endcase
                    end
                end

                // Word 1 completes the descriptor. `contiguous` stands in for the
                // specified inner_count * inner_stride default, so nothing here
                // multiplies (section 15).
                CP_STREAM_W1: begin
                    pc <= sequential_pc;
                    stream_desc[ss_id[SLOT_WIDTH-1:0]].valid     <= 1'b1;
                    stream_desc[ss_id[SLOT_WIDTH-1:0]].domain    <= ss_domain;
                    stream_desc[ss_id[SLOT_WIDTH-1:0]].layout    <= ss_layout;
                    stream_desc[ss_id[SLOT_WIDTH-1:0]].base_row  <= ss_base_row;
                    stream_desc[ss_id[SLOT_WIDTH-1:0]].inner_count <=
                        ss_count(ss_reg_select[3], setstream_inner_count(word));
                    stream_desc[ss_id[SLOT_WIDTH-1:0]].outer_count <=
                        ss_count(ss_reg_select[2], setstream_outer_count(word));
                    stream_desc[ss_id[SLOT_WIDTH-1:0]].inner_stride <=
                        ss_stride(ss_reg_select[1], setstream_inner_stride(word));
                    stream_desc[ss_id[SLOT_WIDTH-1:0]].outer_stride <=
                        ss_stride(ss_reg_select[0], setstream_outer_stride(word));
                    stream_desc[ss_id[SLOT_WIDTH-1:0]].contiguous <=
                        !ss_has_outer_stride;
                    inner_cursor[ss_id[SLOT_WIDTH-1:0]] <= '0;
                    outer_cursor[ss_id[SLOT_WIDTH-1:0]] <= '0;
                    cursor_addr[ss_id[SLOT_WIDTH-1:0]]  <= ss_offset;
                    cursor_base[ss_id[SLOT_WIDTH-1:0]]  <= ss_offset;
                    if (ss_field_missing ||
                        (ss_count(ss_reg_select[3],
                                  setstream_inner_count(word)) == '0) ||
                        (ss_count(ss_reg_select[2],
                                  setstream_outer_count(word)) == '0))
                        error_q <= 1'b1;
                end

                // One access per cycle: take its row into the range, step the
                // cursor, and on the last access write the cursor back and
                // either start the second stream or go to issue.
                CP_RANGE: begin
                    if (exhausting) begin
                        range_low[0]  <= '0;
                        range_high[0] <= '1;
                        range_low[1]  <= '0;
                        range_high[1] <= '1;
                    end else begin
                        walk_view  <= stream_step(walk_view);
                        walk_first <= 1'b0;
                        walk_left  <= walk_left - WALK_WIDTH'(1'b1);

                        if (walk_first) begin
                            range_low[walk_phase_b]  <= walk_row;
                            range_high[walk_phase_b] <= walk_row;
                        end else begin
                            if (walk_row < range_low[walk_phase_b])
                                range_low[walk_phase_b] <= walk_row;
                            if (walk_row > range_high[walk_phase_b])
                                range_high[walk_phase_b] <= walk_row;
                        end

                        if (walk_left == WALK_WIDTH'(1'b1)) begin
                            if (!walk_phase_b) begin
                                inner_cursor[slot_a] <=
                                    walk_next.inner_cursor;
                                outer_cursor[slot_a] <=
                                    walk_next.outer_cursor;
                                cursor_addr[slot_a] <=
                                    walk_next.addr;
                                cursor_base[slot_a] <=
                                    walk_next.outer_base;
                                if (accesses_b != 4'd0) begin
                                    walk_phase_b <= 1'b1;
                                    walk_first   <= 1'b1;
                                    walk_view    <= view_b;
                                    walk_left    <= accesses_b;
                                    walk_wide    <= wide_b;
                                end
                            end else begin
                                inner_cursor[slot_b] <=
                                    walk_next.inner_cursor;
                                outer_cursor[slot_b] <=
                                    walk_next.outer_cursor;
                                cursor_addr[slot_b] <=
                                    walk_next.addr;
                                cursor_base[slot_b] <=
                                    walk_next.outer_base;
                            end
                        end
                    end
                end

                CP_ISSUE: begin
                    if (issue_ok) begin
                        pc          <= sequential_pc;
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

                        // Only the exhausting commands still owe a cursor
                        // update; the walk committed everything else.
                        if (exhausting) begin
                            inner_cursor[slot_a] <=
                                exhaust_a.inner_cursor;
                            outer_cursor[slot_a] <=
                                exhaust_a.outer_cursor;
                            inner_cursor[slot_b] <=
                                exhaust_b.inner_cursor;
                            outer_cursor[slot_b] <=
                                exhaust_b.outer_cursor;
                        end
                    end
                end

                CP_SKIP_LOOP: begin
                    // The body of a zero-count loop is stepped over without
                    // decoding it, so its set_stream payload words are skipped
                    // as data.
                    if (opcode == OP_SET_STREAM)
                        pc <= pc + PROG_ADDR_WIDTH'(SETSTREAM_WORDS[1:0]);
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
