`timescale 1ns/1ps

// Matrix Core Writeback stage: the BF16 FPU, the output buffer, the line packer
// and every store the core issues (matrix_core.md sections 14, 18).
//
// The stage runs one command at a time. The top level puts an mcore_fifo in
// front of it, so there is no internal command queue: a command is accepted
// only while the stage is idle, and it is held until its last store has been
// accepted by the memory port. Three of the four commands also consume exactly
// one result packet, the 64 BF16 accumulator values Compute snapshotted in
// global order (section 17). The packet is registered on acceptance so the
// result FIFO is released immediately and Compute can run ahead.
//
// Commands and their cost in cycles, counted from the cycle the command is
// accepted up to and including the done pulse, with a memory port that is
// always ready and a result packet already waiting:
//
//   WB_WRITE_ACC  3 + ceil(count/8)     one store per packed line
//   WB_REDUCE     4 + (count-1)         one bf16_add per remaining value
//   WB_SCALE      3 + count +
//                 ceil(count/8) +
//                 2*ceil(count/32)      one scale row read per 32 values,
//                                       plus its read latency
//   WB_WRITE_BUF  3                     no result packet, one store
//
// The done pulse is generated from a terminal WB_DONE state, so it lands the
// cycle after the last store was accepted, or after the reduction result was
// written to its output buffer slot. The command is still held during WB_DONE,
// so idle and cmd_ready rise one cycle later than the pulse.
//
// Both arithmetic operators are single instances shared over the sequence:
// WB_REDUCE walks the values through one bf16_add in the exact order section
// 7.9 specifies, and WB_SCALE walks them through one bf16_mul. Neither is
// pipelined, so one value retires per cycle.
//
// Stores are posted: a store is complete when req_valid && req_ready. A CoMem
// target takes the 128-bit line directly; a LoMem target places the line in the
// addressed lane of the 512-bit row and enables only that lane, because a
// row-major LoMem line access selects one of four lanes (section 15).
//
// A result packet whose sequence does not match the current command is a design
// error (section 19). It is not consumed and seq_error latches, so the
// misordering is visible on the interface and the stage stalls instead of
// writing a wrong result. seq_error is sticky until reset, matching the core's
// sticky error reporting; flush does not clear it.
//
// flush clears the FSM, the in-flight command and any pending store, but
// deliberately leaves the eight output buffer values and valid bits alone: they
// are architectural state that only write_buf and reset clear, and dropping
// them would silently change the result of a write_buf that survives the abort.
module mcore_writeback
    import mcore_pkg::*;
(
    input  logic                        clk,
    input  logic                        reset,
    input  logic                        flush,
    input  logic                        cmd_valid,
    output logic                        cmd_ready,
    input  writeback_cmd_t              cmd,
    input  logic                        res_valid,
    output logic                        res_ready,
    input  result_pkt_t                 res,
    output logic                        lomem_req_valid,
    input  logic                        lomem_req_ready,
    output logic                        lomem_req_write,
    output logic [MEM_ROW_WIDTH-1:0]    lomem_req_row,
    output logic [TAG_WIDTH-1:0]        lomem_req_tag,
    output logic [LOMEM_WIDTH-1:0]      lomem_req_wdata,
    output logic [LOMEM_LANES-1:0]      lomem_req_lane_en,
    input  logic                        lomem_rsp_valid,
    input  logic [TAG_WIDTH-1:0]        lomem_rsp_tag,
    input  logic [LOMEM_WIDTH-1:0]      lomem_rsp_data,
    output logic                        comem_req_valid,
    input  logic                        comem_req_ready,
    output logic                        comem_req_write,
    output logic [MEM_ROW_WIDTH-1:0]    comem_req_row,
    output logic [TAG_WIDTH-1:0]        comem_req_tag,
    output logic [COMEM_WIDTH-1:0]      comem_req_wdata,
    output logic                        idle,
    output logic                        done_valid,
    output logic [SEQ_WIDTH-1:0]        done_seq,
    output logic                        seq_error
);
    // Tags on WB traffic. Writes get no response, so their tag only has to be
    // distinct from the scale read the stage is waiting for.
    localparam logic [TAG_WIDTH-1:0] SCALE_READ_TAG = '0;
    localparam logic [TAG_WIDTH-1:0] STORE_TAG      = TAG_WIDTH'(1'b1);

    // Index widths: 0..64 values, 0..8 output lines, 8 slots per line.
    localparam int unsigned VALUE_IDX_WIDTH = COUNT_WIDTH;
    localparam int unsigned LINE_IDX_WIDTH  = $clog2(MAX_STREAM_ACCESSES) + 1;
    localparam int unsigned PACK_IDX_WIDTH  = $clog2(BF16_PER_LINE);
    localparam int unsigned VALUE_SEL_WIDTH = $clog2(TOTAL_ACCUMULATORS);

    typedef enum logic [2:0] {
        WB_IDLE        = 3'd0,
        WB_WAIT_RESULT = 3'd1,
        WB_REDUCE_RUN  = 3'd2,
        WB_SCALE_FETCH = 3'd3,
        WB_SCALE_WAIT  = 3'd4,
        WB_SCALE_RUN   = 3'd5,
        WB_STORE       = 3'd6,
        WB_DONE        = 3'd7
    } wb_state_e;

    wb_state_e                             state_q;
    writeback_cmd_t                        cmd_q;
    logic [TOTAL_ACCUMULATORS-1:0][15:0]   values_q;
    logic [SCALE_BUFFER_ENTRIES-1:0][15:0] scale_q;
    logic [BF16_PER_LINE-1:0][15:0]        line_q;
    logic [OUTPUT_BUFFER_SLOTS-1:0][15:0]  buffer_value_q;
    logic [OUTPUT_BUFFER_SLOTS-1:0]        buffer_valid_q;
    logic [15:0]                           sum_q;
    logic [VALUE_IDX_WIDTH-1:0]            value_index_q;
    logic [LINE_IDX_WIDTH-1:0]             line_index_q;
    logic [PACK_IDX_WIDTH-1:0]             pack_index_q;
    logic                                  seq_error_q;

    logic [VALUE_SEL_WIDTH-1:0]            value_select;
    logic [SCALE_IDX_WIDTH-1:0]            scale_select;
    logic [15:0]                           sum_next;
    logic [15:0]                           scaled_value;
    logic [BF16_PER_LINE-1:0][15:0]        acc_line;
    logic [BF16_PER_LINE-1:0][15:0]        buffer_line;
    logic [BF16_PER_LINE-1:0][15:0]        store_line;
    logic [LINE_IDX_WIDTH-1:0]             acc_lines;
    logic                                  value_last;
    logic                                  line_full;
    logic                                  block_start;
    logic                                  seq_match;
    logic                                  scale_response;
    logic                                  store_to_comem;
    logic                                  store_accepted;

    logic [31:0]                           line_index_wide;
    logic [31:0]                           scale_block_wide;
    logic signed [INT_WIDTH-1:0]           store_index;
    logic signed [INT_WIDTH-1:0]           scale_index;
    logic [MEM_ROW_WIDTH-1:0]              store_row;
    logic [MEM_ROW_WIDTH-1:0]              scale_row;
    logic [LANE_SELECT_WIDTH-1:0]          store_lane;
    logic [LOMEM_LANES-1:0][LINE_WIDTH-1:0] store_lanes;

    assign value_select = value_index_q[VALUE_SEL_WIDTH-1:0];
    assign scale_select = value_index_q[SCALE_IDX_WIDTH-1:0];

    bf16_add reduce_adder (
        .a      (sum_q),
        .b      (values_q[value_select]),
        .result (sum_next)
    );

    bf16_mul scale_multiplier (
        .a      (values_q[value_select]),
        .b      (scale_q[scale_select]),
        .result (scaled_value)
    );

    // ------------------------------------------------------------ line packing
    // write_accumulators needs no packing register: line n is the window
    // values[8n .. 8n+7] of the registered packet, with positions at or beyond
    // count emitting BF16 +0 so the final line is zero-padded.
    always_comb begin
        logic [VALUE_IDX_WIDTH-1:0] source_index;
        for (int unsigned s = 0; s < BF16_PER_LINE; s++) begin
            source_index = {line_index_q[VALUE_IDX_WIDTH-1-PACK_IDX_WIDTH:0],
                            s[PACK_IDX_WIDTH-1:0]};
            acc_line[s] = (source_index < cmd_q.count) ?
                          values_q[source_index[VALUE_SEL_WIDTH-1:0]] :
                          BF16_ZERO;
        end
    end

    // The output buffer holds exactly one line's worth of slots, so write_buf
    // is a single pack with BF16 +0 for the slots no reduction has written.
    always_comb begin
        for (int unsigned s = 0; s < OUTPUT_BUFFER_SLOTS; s++)
            buffer_line[s] = buffer_valid_q[s] ? buffer_value_q[s] : BF16_ZERO;
    end

    assign store_line = (cmd_q.op == WB_WRITE_ACC) ? acc_line : line_q;

    // -------------------------------------------------------- sequence control
    assign acc_lines   = cmd_q.count[COUNT_WIDTH-1:PACK_IDX_WIDTH] +
                         {{LINE_IDX_WIDTH-1{1'b0}},
                          (cmd_q.count[PACK_IDX_WIDTH-1:0] != '0)};
    assign value_last  = (value_index_q == (cmd_q.count - COUNT_WIDTH'(1'b1)));
    assign line_full   = (pack_index_q == PACK_IDX_WIDTH'(BF16_PER_LINE - 1));
    assign block_start = (value_index_q[SCALE_IDX_WIDTH-1:0] == '0);
    assign seq_match   = (res.seq == cmd_q.seq);
    assign scale_response = lomem_rsp_valid &&
                            (lomem_rsp_tag == SCALE_READ_TAG);

    // ------------------------------------------------------------- addressing
    // Output lines are consecutive accesses of view_out. Scale rows are whole
    // 512-bit LoMem rows, so their address is generated with wide_row set
    // (section 15); output lines are 128-bit accesses, so wide_row is clear.
    assign line_index_wide  = {{32-LINE_IDX_WIDTH{1'b0}}, line_index_q};
    assign scale_block_wide =
        {{32-VALUE_IDX_WIDTH+SCALE_IDX_WIDTH{1'b0}},
         value_index_q[VALUE_IDX_WIDTH-1:SCALE_IDX_WIDTH]};

    assign store_index = stream_index_ahead(cmd_q.view_out, line_index_wide);
    assign scale_index = stream_index_ahead(cmd_q.view_scale, scale_block_wide);
    assign store_row   = stream_row(cmd_q.view_out.desc, store_index, 1'b0);
    assign store_lane  = stream_lane(cmd_q.view_out.desc, store_index, 1'b0);
    assign scale_row   = stream_row(cmd_q.view_scale.desc, scale_index, 1'b1);

    assign store_to_comem = (cmd_q.view_out.desc.domain == DOMAIN_COMEM);
    assign store_accepted = (state_q == WB_STORE) &&
                            (store_to_comem ? comem_req_ready
                                            : lomem_req_ready);

    // ------------------------------------------------------------ memory ports
    // A LoMem store writes one lane of the row, so the line is replicated into
    // the addressed lane and only that lane is enabled.
    always_comb begin
        for (int unsigned l = 0; l < LOMEM_LANES; l++) begin
            store_lanes[l] = (l[LANE_SELECT_WIDTH-1:0] == store_lane) ?
                             store_line : {LINE_WIDTH{1'b0}};
            lomem_req_lane_en[l] = (state_q == WB_STORE) &&
                                   (l[LANE_SELECT_WIDTH-1:0] == store_lane);
        end
    end

    assign lomem_req_valid = (state_q == WB_SCALE_FETCH) ||
                             ((state_q == WB_STORE) && !store_to_comem);
    assign lomem_req_write = (state_q == WB_STORE);
    assign lomem_req_row   = (state_q == WB_SCALE_FETCH) ? scale_row
                                                         : store_row;
    assign lomem_req_tag   = (state_q == WB_SCALE_FETCH) ? SCALE_READ_TAG
                                                         : STORE_TAG;
    assign lomem_req_wdata = store_lanes;

    assign comem_req_valid = (state_q == WB_STORE) && store_to_comem;
    assign comem_req_write = (state_q == WB_STORE);
    assign comem_req_row   = store_row;
    assign comem_req_tag   = STORE_TAG;
    assign comem_req_wdata = store_line;

    // ----------------------------------------------------------- handshakes
    assign cmd_ready  = (state_q == WB_IDLE);
    assign res_ready  = (state_q == WB_WAIT_RESULT) && seq_match;
    assign idle       = (state_q == WB_IDLE);
    assign done_valid = (state_q == WB_DONE);
    assign done_seq   = cmd_q.seq;
    assign seq_error  = seq_error_q;

    // ----------------------------------------------------------------- control
    always_ff @(posedge clk) begin
        if (reset) begin
            state_q        <= WB_IDLE;
            cmd_q          <= '0;
            values_q       <= '0;
            scale_q        <= '0;
            line_q         <= '0;
            buffer_value_q <= '0;
            buffer_valid_q <= '0;
            sum_q          <= BF16_ZERO;
            value_index_q  <= '0;
            line_index_q   <= '0;
            pack_index_q   <= '0;
            seq_error_q    <= 1'b0;
        end else if (flush) begin
            state_q       <= WB_IDLE;
            line_q        <= '0;
            value_index_q <= '0;
            line_index_q  <= '0;
            pack_index_q  <= '0;
        end else begin
            unique case (state_q)
                WB_IDLE: begin
                    if (cmd_valid) begin
                        cmd_q         <= cmd;
                        value_index_q <= '0;
                        line_index_q  <= '0;
                        pack_index_q  <= '0;
                        if (cmd.op == WB_WRITE_BUF) begin
                            // A command is only accepted while the stage is
                            // idle, so an earlier reduction has already written
                            // its slot and no extra interlock is needed.
                            line_q  <= buffer_line;
                            state_q <= WB_STORE;
                        end else begin
                            line_q  <= '0;
                            state_q <= WB_WAIT_RESULT;
                        end
                    end
                end
                WB_WAIT_RESULT: begin
                    if (res_valid && seq_match) begin
                        values_q <= res.values;
                        sum_q    <= res.values[0];
                        unique case (cmd_q.op)
                            WB_REDUCE: begin
                                value_index_q <= VALUE_IDX_WIDTH'(1'b1);
                                state_q       <= WB_REDUCE_RUN;
                            end
                            WB_SCALE:    state_q <= WB_SCALE_FETCH;
                            WB_WRITE_ACC,
                            WB_WRITE_BUF: state_q <= WB_STORE;
                        endcase
                    end else if (res_valid) begin
                        seq_error_q <= 1'b1;
                    end
                end
                WB_REDUCE_RUN: begin
                    if (value_index_q >= cmd_q.count) begin
                        buffer_value_q[cmd_q.buffer_idx] <= sum_q;
                        buffer_valid_q[cmd_q.buffer_idx] <= 1'b1;
                        state_q                          <= WB_DONE;
                    end else begin
                        sum_q         <= sum_next;
                        value_index_q <= value_index_q + VALUE_IDX_WIDTH'(1'b1);
                    end
                end
                WB_SCALE_FETCH: begin
                    if (lomem_req_ready) begin
                        // A zero-latency memory model can return the row in the
                        // cycle the read is accepted.
                        if (scale_response) begin
                            scale_q <= lomem_rsp_data;
                            state_q <= WB_SCALE_RUN;
                        end else begin
                            state_q <= WB_SCALE_WAIT;
                        end
                    end
                end
                WB_SCALE_WAIT: begin
                    if (scale_response) begin
                        scale_q <= lomem_rsp_data;
                        state_q <= WB_SCALE_RUN;
                    end
                end
                WB_SCALE_RUN: begin
                    line_q[pack_index_q] <= scaled_value;
                    value_index_q        <= value_index_q +
                                            VALUE_IDX_WIDTH'(1'b1);
                    if (line_full || value_last)
                        state_q <= WB_STORE;
                    else
                        pack_index_q <= pack_index_q + PACK_IDX_WIDTH'(1'b1);
                end
                WB_STORE: begin
                    if (store_accepted) begin
                        line_index_q <= line_index_q + LINE_IDX_WIDTH'(1'b1);
                        pack_index_q <= '0;
                        line_q       <= '0;
                        unique case (cmd_q.op)
                            WB_WRITE_ACC:
                                state_q <=
                                    ((line_index_q + LINE_IDX_WIDTH'(1'b1)) >=
                                     acc_lines) ? WB_DONE : WB_STORE;
                            WB_SCALE:
                                if (value_index_q >= cmd_q.count)
                                    state_q <= WB_DONE;
                                else if (block_start)
                                    state_q <= WB_SCALE_FETCH;
                                else
                                    state_q <= WB_SCALE_RUN;
                            WB_WRITE_BUF: begin
                                buffer_value_q <= '0;
                                buffer_valid_q <= '0;
                                state_q        <= WB_DONE;
                            end
                            // WB_REDUCE never stores; the arm only keeps the
                            // case exhaustive.
                            WB_REDUCE: state_q <= WB_DONE;
                        endcase
                    end
                end
                WB_DONE: begin
                    state_q <= WB_IDLE;
                end
            endcase
        end
    end
endmodule
