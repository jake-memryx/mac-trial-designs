`timescale 1ns/1ps

// Matrix Core Fetch stage: address generation, prefetch, and operand assembly.
//
// The stage is split into an allocation side and a consumption side that share
// nothing but the two prefetch buffers (matrix_core.md section 16):
//
//   allocation   walks the A and B stream cursors and allocates a read per
//                access, as far ahead as the buffers allow,
//   consumption  pairs the heads of the two buffers, routes them into an
//                operand packet, and pops each buffer on its own schedule.
//
// The two sides are independent because a broadcast_mac A line is reused across
// every column group of its row: A is popped once per outer iteration while B is
// popped once per group. Splitting them also makes the memory latency invisible
// as long as FETCH_BUFFER_DEPTH covers it.
//
// Formats handled here rather than in Compute: INT8 B halves are converted to
// BF16, elementwise operands are routed onto the multiplier array as A*1 + B*1
// or A*B, and multi_mac tail elements are replaced with BF16 zero so their
// products are exactly zero.
module mcore_fetch
    import mcore_pkg::*;
#(
    parameter int unsigned BUFFER_DEPTH = FETCH_BUFFER_DEPTH
) (
    input  logic                     clk,
    input  logic                     reset,
    input  logic                     flush,
    input  logic                     cmd_valid,
    output logic                     cmd_ready,
    input  fetch_cmd_t               cmd,
    output logic                     lomem_req_valid,
    input  logic                     lomem_req_ready,
    output logic [MEM_ROW_WIDTH-1:0] lomem_req_row,
    output logic [TAG_WIDTH-1:0]     lomem_req_tag,
    input  logic                     lomem_rsp_valid,
    input  logic [TAG_WIDTH-1:0]     lomem_rsp_tag,
    input  logic [LOMEM_WIDTH-1:0]   lomem_rsp_data,
    output logic                     comem_req_valid,
    input  logic                     comem_req_ready,
    output logic [MEM_ROW_WIDTH-1:0] comem_req_row,
    output logic [TAG_WIDTH-1:0]     comem_req_tag,
    input  logic                     comem_rsp_valid,
    input  logic [TAG_WIDTH-1:0]     comem_rsp_tag,
    input  logic [COMEM_WIDTH-1:0]   comem_rsp_data,
    output logic                     pkt_valid,
    input  logic                     pkt_ready,
    output operand_pkt_t             pkt,
    output logic                     idle,
    // Single-cycle pulse when the command's last packet has been accepted, which
    // releases its range reservation in the Command stage (section 19).
    output logic                     done_valid,
    output logic [SEQ_WIDTH-1:0]     done_seq
);
    localparam int unsigned COUNTER_WIDTH = 6;

    typedef enum logic [1:0] {
        F_IDLE = 2'd0,
        F_RUN  = 2'd1,
        F_DONE = 2'd2
    } fetch_state_e;

    fetch_state_e state;
    fetch_cmd_t   command;

    // Derived iteration counts, latched with the command.
    logic [COUNTER_WIDTH-1:0]    groups;
    logic [COUNTER_WIDTH-1:0]    rows;
    logic [COUNTER_WIDTH-1:0]    lines;
    logic [COUNTER_WIDTH-1:0]    b_rows;
    logic [COUNTER_WIDTH-1:0]    inner_total;
    logic [COUNTER_WIDTH-1:0]    b_inner_total;
    // Outer iteration counts follow the descriptor width, not the integer
    // register width.
    logic [STREAM_COUNT_WIDTH-1:0] outer_total;
    logic [STREAM_COUNT_WIDTH-1:0] a_total;
    logic                        wide_rows;
    logic                        int8_b;
    logic                        uses_b;

    // Allocation side.
    stream_view_t                a_view, b_view;
    logic [STREAM_COUNT_WIDTH-1:0] a_count;
    logic [COUNTER_WIDTH-1:0]    b_inner;
    logic [STREAM_COUNT_WIDTH-1:0] b_outer;
    logic                        a_alloc_more, b_alloc_more;
    logic                        a_alloc_valid, a_alloc_ready;
    logic                        b_alloc_valid, b_alloc_ready;

    // Consumption side.
    logic [COUNTER_WIDTH-1:0]    cons_inner;
    logic [STREAM_COUNT_WIDTH-1:0] cons_outer;
    logic                        last_packet;
    logic                        a_pop, b_pop;
    logic                        a_head_valid, b_head_valid;
    logic [LOMEM_WIDTH-1:0]      a_head_row, b_head_row;
    logic [LINE_WIDTH-1:0]       a_head_line, b_head_line;
    logic                        packet_taken;
    logic                        heads_ready;

    // Buffer request and response plumbing.
    mem_domain_e                 a_req_domain, b_req_domain;
    logic                        a_req_valid, a_req_ready;
    logic                        b_req_valid, b_req_ready;
    logic [MEM_ROW_WIDTH-1:0]    a_req_row, b_req_row;
    logic [TAG_WIDTH-1:0]        a_req_tag, b_req_tag;
    logic                        a_grant_lomem, a_grant_comem;
    logic                        b_grant_lomem, b_grant_comem;
    logic                        a_rsp_valid, b_rsp_valid;
    logic [TAG_WIDTH-1:0]        a_rsp_tag, b_rsp_tag;
    logic [LOMEM_WIDTH-1:0]      a_rsp_data, b_rsp_data;

    // ------------------------------------------------------- derived iteration
    // groups: 4 output columns or 4 elementwise values per packet.
    // rows:   32 BF16 elements per multi_mac row pair.
    // lines:  8 BF16 values per elementwise operand line.
    localparam int unsigned WIDE_COUNT = COUNT_WIDTH + 1;

    function automatic logic [COUNTER_WIDTH-1:0] ceil_div(
            logic [COUNT_WIDTH-1:0] value, int unsigned shift);
        logic [WIDE_COUNT-1:0] rounded;
        logic [WIDE_COUNT-1:0] one;
        one     = WIDE_COUNT'(1'b1);
        rounded = {1'b0, value} + ((one << shift) - one);
        return COUNTER_WIDTH'(rounded >> shift);
    endfunction

    // Derived from the latched command, never from the command channel: the
    // channel only presents a command until it is accepted.
    always_comb begin
        groups = ceil_div(command.count, 2);
        rows   = ceil_div(command.count, 5);
        lines  = ceil_div(command.count, 3);
        int8_b = (command.view_b.desc.layout == LAYOUT_MATMUL_B_INT8);
        b_rows = int8_b ? ((groups + 1'b1) >> 1) : groups;
    end

    always_comb begin
        // Elementwise is the default shape: one packet per group of four
        // values, one operand line per two groups.
        inner_total   = groups;
        b_inner_total = lines;
        outer_total   = STREAM_COUNT_WIDTH'(1'b1);
        a_total       = {{(STREAM_COUNT_WIDTH-COUNTER_WIDTH){1'b0}}, lines};
        uses_b        = 1'b1;
        wide_rows     = 1'b0;
        case (command.op)
            FETCH_ACC_LOAD: begin
                inner_total   = 6'd1;
                b_inner_total = 6'd0;
                outer_total   = STREAM_COUNT_WIDTH'(1'b1);
                a_total       = STREAM_COUNT_WIDTH'(1'b1);
                uses_b        = 1'b0;
                wide_rows     = 1'b0;
            end
            FETCH_BROADCAST: begin
                inner_total   = groups;
                b_inner_total = b_rows;
                outer_total   = command.view_a.desc.outer_count;
                a_total       = command.view_a.desc.outer_count;
                uses_b        = 1'b1;
                wide_rows     = 1'b0;
            end
            FETCH_MULTI: begin
                inner_total   = rows;
                b_inner_total = rows;
                outer_total   = STREAM_COUNT_WIDTH'(1'b1);
                a_total       = {{(STREAM_COUNT_WIDTH-COUNTER_WIDTH){1'b0}}, rows};
                uses_b        = 1'b1;
                wide_rows     = 1'b1;
            end
            FETCH_ELEMENTWISE: ;
            default: ;
        endcase
    end

    // ------------------------------------------------------- allocation side
    assign a_alloc_more = (a_count < a_total);
    assign b_alloc_more = uses_b && (b_outer < outer_total);

    assign a_alloc_valid = (state == F_RUN) && a_alloc_more;
    assign b_alloc_valid = (state == F_RUN) && b_alloc_more;

    mcore_read_buffer #(
        .DEPTH     (BUFFER_DEPTH),
        .BUFFER_ID (1'b0)
    ) buffer_a (
        .clk          (clk),
        .reset        (reset),
        .flush        (flush),
        .alloc_valid  (a_alloc_valid),
        .alloc_ready  (a_alloc_ready),
        .alloc_domain (a_view.desc.domain),
        .alloc_row    (stream_row(a_view.desc, stream_addr(a_view), wide_rows)),
        .alloc_lane   (stream_lane(a_view.desc, stream_addr(a_view), wide_rows)),
        .req_valid    (a_req_valid),
        .req_ready    (a_req_ready),
        .req_domain   (a_req_domain),
        .req_row      (a_req_row),
        .req_tag      (a_req_tag),
        .rsp_valid    (a_rsp_valid),
        .rsp_tag      (a_rsp_tag),
        .rsp_data     (a_rsp_data),
        .head_valid   (a_head_valid),
        .head_pop     (a_pop),
        .head_row     (a_head_row),
        .head_line    (a_head_line),
        // The stage only leaves F_RUN after its last packet is accepted, and a
        // packet is only built from filled entries, so the buffers are
        // necessarily empty by then; the drain rule needs no extra check.
        .empty        ()
    );

    mcore_read_buffer #(
        .DEPTH     (BUFFER_DEPTH),
        .BUFFER_ID (1'b1)
    ) buffer_b (
        .clk          (clk),
        .reset        (reset),
        .flush        (flush),
        .alloc_valid  (b_alloc_valid),
        .alloc_ready  (b_alloc_ready),
        .alloc_domain (b_view.desc.domain),
        .alloc_row    (stream_row(b_view.desc, stream_addr(b_view), wide_rows)),
        .alloc_lane   (stream_lane(b_view.desc, stream_addr(b_view), wide_rows)),
        .req_valid    (b_req_valid),
        .req_ready    (b_req_ready),
        .req_domain   (b_req_domain),
        .req_row      (b_req_row),
        .req_tag      (b_req_tag),
        .rsp_valid    (b_rsp_valid),
        .rsp_tag      (b_rsp_tag),
        .rsp_data     (b_rsp_data),
        .head_valid   (b_head_valid),
        .head_pop     (b_pop),
        .head_row     (b_head_row),
        .head_line    (b_head_line),
        .empty        ()
    );

    // Port arbitration: A wins, which cannot starve B because A is bounded by
    // one allocation per outer iteration.
    assign a_grant_lomem = a_req_valid && (a_req_domain == DOMAIN_LOMEM);
    assign a_grant_comem = a_req_valid && (a_req_domain == DOMAIN_COMEM);
    assign b_grant_lomem = b_req_valid && (b_req_domain == DOMAIN_LOMEM) &&
                           !a_grant_lomem;
    assign b_grant_comem = b_req_valid && (b_req_domain == DOMAIN_COMEM) &&
                           !a_grant_comem;

    assign lomem_req_valid = a_grant_lomem || b_grant_lomem;
    assign lomem_req_row   = a_grant_lomem ? a_req_row : b_req_row;
    assign lomem_req_tag   = a_grant_lomem ? a_req_tag : b_req_tag;
    assign comem_req_valid = a_grant_comem || b_grant_comem;
    assign comem_req_row   = a_grant_comem ? a_req_row : b_req_row;
    assign comem_req_tag   = a_grant_comem ? a_req_tag : b_req_tag;

    assign a_req_ready = (a_grant_lomem && lomem_req_ready) ||
                         (a_grant_comem && comem_req_ready);
    assign b_req_ready = (b_grant_lomem && lomem_req_ready) ||
                         (b_grant_comem && comem_req_ready);

    // Responses are steered by the buffer bit of the ticket. A given buffer only
    // has requests outstanding in one domain at a time, because a command's
    // stream has one domain and the stage drains between commands.
    always_comb begin
        a_rsp_valid = 1'b0;
        a_rsp_tag   = '0;
        a_rsp_data  = '0;
        if (lomem_rsp_valid && (lomem_rsp_tag[TAG_WIDTH-1] == 1'b0)) begin
            a_rsp_valid = 1'b1;
            a_rsp_tag   = lomem_rsp_tag;
            a_rsp_data  = lomem_rsp_data;
        end else if (comem_rsp_valid && (comem_rsp_tag[TAG_WIDTH-1] == 1'b0)) begin
            a_rsp_valid = 1'b1;
            a_rsp_tag   = comem_rsp_tag;
            a_rsp_data  = {{(LOMEM_WIDTH-COMEM_WIDTH){1'b0}}, comem_rsp_data};
        end
    end

    always_comb begin
        b_rsp_valid = 1'b0;
        b_rsp_tag   = '0;
        b_rsp_data  = '0;
        if (lomem_rsp_valid && (lomem_rsp_tag[TAG_WIDTH-1] == 1'b1)) begin
            b_rsp_valid = 1'b1;
            b_rsp_tag   = lomem_rsp_tag;
            b_rsp_data  = lomem_rsp_data;
        end else if (comem_rsp_valid && (comem_rsp_tag[TAG_WIDTH-1] == 1'b1)) begin
            b_rsp_valid = 1'b1;
            b_rsp_tag   = comem_rsp_tag;
            b_rsp_data  = {{(LOMEM_WIDTH-COMEM_WIDTH){1'b0}}, comem_rsp_data};
        end
    end

    // ------------------------------------------------------- consumption side
    assign heads_ready  = a_head_valid && (!uses_b || b_head_valid);
    assign pkt_valid    = (state == F_RUN) && heads_ready;
    assign packet_taken = pkt_valid && pkt_ready;

    assign last_packet = (cons_inner == inner_total - 1'b1) &&
                         (cons_outer == outer_total - STREAM_COUNT_WIDTH'(1'b1));

    // A is held for every group of its row; B is held for both INT8 halves.
    always_comb begin
        a_pop = 1'b0;
        b_pop = 1'b0;
        if (packet_taken) begin
            case (command.op)
                FETCH_ACC_LOAD: a_pop = 1'b1;
                FETCH_BROADCAST: begin
                    a_pop = (cons_inner == inner_total - 1'b1);
                    b_pop = !int8_b || cons_inner[0] ||
                            (cons_inner == inner_total - 1'b1);
                end
                FETCH_MULTI: begin
                    a_pop = 1'b1;
                    b_pop = 1'b1;
                end
                FETCH_ELEMENTWISE: begin
                    a_pop = cons_inner[0] || (cons_inner == inner_total - 1'b1);
                    b_pop = a_pop;
                end
                default: ;
            endcase
        end
    end

    // ------------------------------------------------------- packet assembly
    logic [LANE_SELECT_WIDTH-1:0] lane_index;
    logic [2:0]                   line_element;
    logic [15:0]                  ew_a_value, ew_b_value;
    logic [11:0]                  element_base;
    logic [11:0]                  element_offset;

    always_comb begin
        pkt = '0;
        pkt.seq  = command.seq;
        pkt.last = last_packet;
        pkt.active_lanes = '0;
        pkt.preload_valid = (command.op == FETCH_ACC_LOAD);
        pkt.accumulator_index = (command.op == FETCH_ACC_LOAD) ?
                                command.accumulator_index :
                                (command.op == FETCH_MULTI) ?
                                '0 : cons_inner[ACC_SELECT_WIDTH-1:0];

        for (int unsigned l = 0; l < TREEMACS; l++) begin
            lane_index     = LANE_SELECT_WIDTH'(l);
            line_element   = 3'(cons_inner[0] ? (4 + l) : l);
            ew_a_value     = a_head_line[{line_element, 4'b0} +: 16];
            ew_b_value     = b_head_line[{line_element, 4'b0} +: 16];
            element_base   = {1'b0, cons_inner, 5'b0} + {7'b0, lane_index, 3'b0};
            element_offset = '0;

            case (command.op)
                FETCH_ACC_LOAD: begin
                    pkt.preload[l] = a_head_line[l*32 +: 32];
                    pkt.active_lanes[l] = 1'b1;
                end
                FETCH_BROADCAST: begin
                    for (int unsigned m = 0; m < TREEMAC_MULTIPLIERS; m++) begin
                        pkt.lhs[l][m] = a_head_line[m*16 +: 16];
                        if (int8_b)
                            pkt.rhs[l][m] = int8_to_bf16(
                                $signed(b_head_row[l*LINE_WIDTH +
                                                   (cons_inner[0] ? 64 : 0) +
                                                   m*8 +: 8]));
                        else
                            pkt.rhs[l][m] =
                                b_head_row[l*LINE_WIDTH + m*16 +: 16];
                    end
                    pkt.active_lanes[l] =
                        ({cons_inner, 2'b0} + {6'b0, lane_index}) <
                        {1'b0, command.count};
                end
                FETCH_MULTI: begin
                    for (int unsigned m = 0; m < TREEMAC_MULTIPLIERS; m++) begin
                        element_offset = 12'(m);
                        if ((element_base + element_offset) <
                            {5'b0, command.count}) begin
                            pkt.lhs[l][m] = a_head_row[l*LINE_WIDTH + m*16 +: 16];
                            pkt.rhs[l][m] = b_head_row[l*LINE_WIDTH + m*16 +: 16];
                        end else begin
                            pkt.lhs[l][m] = BF16_ZERO;
                            pkt.rhs[l][m] = BF16_ZERO;
                        end
                    end
                    pkt.active_lanes[l] = element_base < {5'b0, command.count};
                end
                FETCH_ELEMENTWISE: begin
                    // One value per lane, routed as A*1 + B*1 or A*B onto the
                    // multiplier array (section 16).
                    if (command.add_not_mul) begin
                        pkt.lhs[l][0] = ew_a_value;
                        pkt.rhs[l][0] = BF16_ONE;
                        pkt.lhs[l][1] = ew_b_value;
                        pkt.rhs[l][1] = BF16_ONE;
                    end else begin
                        pkt.lhs[l][0] = ew_a_value;
                        pkt.rhs[l][0] = ew_b_value;
                    end
                    pkt.active_lanes[l] =
                        ({cons_inner, 2'b0} + {6'b0, lane_index}) <
                        {1'b0, command.count};
                end
                default: ;
            endcase
        end
    end

    // ------------------------------------------------------- sequencing
    assign cmd_ready  = (state == F_IDLE);
    assign idle       = (state == F_IDLE);
    assign done_valid = (state == F_DONE);
    assign done_seq   = command.seq;

    always_ff @(posedge clk) begin
        if (reset || flush) begin
            state      <= F_IDLE;
            command    <= '0;
            a_view     <= '0;
            b_view     <= '0;
            a_count    <= '0;
            b_inner    <= '0;
            b_outer    <= '0;
            cons_inner <= '0;
            cons_outer <= '0;
        end else begin
            case (state)
                F_IDLE: begin
                    if (cmd_valid) begin
                        state      <= F_RUN;
                        command    <= cmd;
                        a_view     <= cmd.view_a;
                        b_view     <= cmd.view_b;
                        a_count    <= '0;
                        b_inner    <= '0;
                        b_outer    <= '0;
                        cons_inner <= '0;
                        cons_outer <= '0;
                    end
                end
                F_RUN: begin
                    if (a_alloc_valid && a_alloc_ready) begin
                        a_view  <= stream_step(a_view);
                        a_count <= a_count + STREAM_COUNT_WIDTH'(1'b1);
                    end
                    if (b_alloc_valid && b_alloc_ready) begin
                        b_view <= stream_step(b_view);
                        if (b_inner == b_inner_total - 1'b1) begin
                            b_inner <= '0;
                            b_outer <= b_outer + STREAM_COUNT_WIDTH'(1'b1);
                        end else begin
                            b_inner <= b_inner + 1'b1;
                        end
                    end
                    if (packet_taken) begin
                        if (last_packet) begin
                            state <= F_DONE;
                        end else if (cons_inner == inner_total - 1'b1) begin
                            cons_inner <= '0;
                            cons_outer <= cons_outer + STREAM_COUNT_WIDTH'(1'b1);
                        end else begin
                            cons_inner <= cons_inner + 1'b1;
                        end
                    end
                end
                F_DONE:  state <= F_IDLE;
                default: state <= F_IDLE;
            endcase
        end
    end

endmodule
