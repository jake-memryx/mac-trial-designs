`timescale 1ns/1ps

// Matrix Core top level.
//
// Four stages connected by bounded FIFOs (matrix_core.md sections 3 and 10):
//
//   Command --cmd--> Fetch --operands--> Compute --results--> Writeback
//      |               |                                          |
//      +--cmd----------+------------------------------------------+
//
// The Command stage drives all three stage command channels, so an instruction
// that needs two stages enqueues into both atomically. Data flows only forward.
// Each memory domain is a single port shared by Fetch and Writeback through
// mcore_memport, which tickets requests so responses can return out of order.
//
// A stage is idle for the drain rule only when its command queue is empty as
// well, and the whole core is drained when both ports report no outstanding
// read and the Command stage holds no range reservation.
module mcore
    import mcore_pkg::*;
#(
    parameter int unsigned CMD_Q_DEPTH  = COMMAND_Q_DEPTH,
    parameter int unsigned DATA_Q       = DATA_Q_DEPTH,
    parameter int unsigned BUFFER_DEPTH = FETCH_BUFFER_DEPTH
) (
    input  logic                       clk,
    input  logic                       reset,
    // Abort: empties the queues and stage state, keeps the accumulators, the
    // integer registers and the output buffer.
    input  logic                       flush,
    input  logic                       start,
    output logic                       done,
    output logic                       error,
    output logic [PROG_ADDR_WIDTH-1:0] prog_addr,
    input  instr_t                     prog_data,
    output logic                       lomem_req_valid,
    input  logic                       lomem_req_ready,
    output logic                       lomem_req_write,
    output logic [MEM_ROW_WIDTH-1:0]   lomem_req_row,
    output logic [TICKET_WIDTH-1:0]    lomem_req_ticket,
    output logic [LOMEM_WIDTH-1:0]     lomem_req_wdata,
    output logic [LOMEM_LANES-1:0]     lomem_req_lane_en,
    input  logic                       lomem_rsp_valid,
    input  logic [TICKET_WIDTH-1:0]    lomem_rsp_ticket,
    input  logic [LOMEM_WIDTH-1:0]     lomem_rsp_data,
    output logic                       comem_req_valid,
    input  logic                       comem_req_ready,
    output logic                       comem_req_write,
    output logic [MEM_ROW_WIDTH-1:0]   comem_req_row,
    output logic [TICKET_WIDTH-1:0]    comem_req_ticket,
    output logic [COMEM_WIDTH-1:0]     comem_req_wdata,
    input  logic                       comem_rsp_valid,
    input  logic [TICKET_WIDTH-1:0]    comem_rsp_ticket,
    input  logic [COMEM_WIDTH-1:0]     comem_rsp_data,
    // Why the Command stage is not issuing, for observability.
    output logic                       structural_stall,
    output logic                       dependency_stall
);
    // Command channels: Command stage side and stage side of each FIFO.
    logic           fetch_cmd_valid, fetch_cmd_ready;
    fetch_cmd_t     fetch_cmd;
    logic           compute_cmd_valid, compute_cmd_ready;
    compute_cmd_t   compute_cmd;
    logic           wb_cmd_valid, wb_cmd_ready;
    writeback_cmd_t wb_cmd;

    logic           fetch_q_valid, fetch_q_ready, fetch_q_empty;
    fetch_cmd_t     fetch_q_cmd;
    logic           compute_q_valid, compute_q_ready, compute_q_empty;
    compute_cmd_t   compute_q_cmd;
    logic           wb_q_valid, wb_q_ready, wb_q_empty;
    writeback_cmd_t wb_q_cmd;

    // Data channels.
    logic         operand_valid, operand_ready, operand_empty;
    operand_pkt_t operand_pkt;
    logic         operand_q_valid, operand_q_ready;
    operand_pkt_t operand_q_pkt;
    logic         result_valid, result_ready, result_empty;
    result_pkt_t  result_pkt;
    logic         result_q_valid, result_q_ready;
    result_pkt_t  result_q_pkt;

    // Stage status.
    logic                 fetch_idle, compute_idle, wb_idle;
    logic                 fetch_done_valid, wb_done_valid;
    logic [SEQ_WIDTH-1:0] fetch_done_seq, wb_done_seq;
    logic                 compute_seq_error, wb_seq_error;
    logic                 cmd_error;
    logic                 lomem_quiet, comem_quiet;

    // Fetch and Writeback requester sides of each port.
    logic                     f_lomem_req_valid, f_lomem_req_ready;
    logic [MEM_ROW_WIDTH-1:0] f_lomem_req_row;
    logic [TAG_WIDTH-1:0]     f_lomem_req_tag;
    logic                     f_lomem_rsp_valid;
    logic [TAG_WIDTH-1:0]     f_lomem_rsp_tag;
    logic [LOMEM_WIDTH-1:0]   f_lomem_rsp_data;
    logic                     f_comem_req_valid, f_comem_req_ready;
    logic [MEM_ROW_WIDTH-1:0] f_comem_req_row;
    logic [TAG_WIDTH-1:0]     f_comem_req_tag;
    logic                     f_comem_rsp_valid;
    logic [TAG_WIDTH-1:0]     f_comem_rsp_tag;
    logic [COMEM_WIDTH-1:0]   f_comem_rsp_data;

    logic                     w_lomem_req_valid, w_lomem_req_ready;
    logic                     w_lomem_req_write;
    logic [MEM_ROW_WIDTH-1:0] w_lomem_req_row;
    logic [TAG_WIDTH-1:0]     w_lomem_req_tag;
    logic [LOMEM_WIDTH-1:0]   w_lomem_req_wdata;
    logic [LOMEM_LANES-1:0]   w_lomem_req_lane_en;
    logic                     w_lomem_rsp_valid;
    logic [TAG_WIDTH-1:0]     w_lomem_rsp_tag;
    logic [LOMEM_WIDTH-1:0]   w_lomem_rsp_data;
    logic                     w_comem_req_valid, w_comem_req_ready;
    logic                     w_comem_req_write;
    logic [MEM_ROW_WIDTH-1:0] w_comem_req_row;
    logic [TAG_WIDTH-1:0]     w_comem_req_tag;
    logic [COMEM_WIDTH-1:0]   w_comem_req_wdata;

    // A stage counts as idle for the drain rule only when nothing is queued for
    // it either.
    logic fetch_stage_idle, compute_stage_idle, wb_stage_idle;
    assign fetch_stage_idle   = fetch_idle && fetch_q_empty && operand_empty;
    assign compute_stage_idle = compute_idle && compute_q_empty && result_empty;
    assign wb_stage_idle      = wb_idle && wb_q_empty;

    assign error = cmd_error || compute_seq_error || wb_seq_error;

    mcore_cmd command_stage (
        .clk               (clk),
        .reset             (reset),
        .start             (start),
        .done              (done),
        .error             (cmd_error),
        .prog_addr         (prog_addr),
        .prog_data         (prog_data),
        .fetch_cmd_valid   (fetch_cmd_valid),
        .fetch_cmd_ready   (fetch_cmd_ready),
        .fetch_cmd         (fetch_cmd),
        .compute_cmd_valid (compute_cmd_valid),
        .compute_cmd_ready (compute_cmd_ready),
        .compute_cmd       (compute_cmd),
        .wb_cmd_valid      (wb_cmd_valid),
        .wb_cmd_ready      (wb_cmd_ready),
        .wb_cmd            (wb_cmd),
        .fetch_idle        (fetch_stage_idle),
        .compute_idle      (compute_stage_idle),
        .writeback_idle    (wb_stage_idle),
        .fetch_done_valid  (fetch_done_valid),
        .fetch_done_seq    (fetch_done_seq),
        .wb_done_valid     (wb_done_valid),
        .wb_done_seq       (wb_done_seq),
        .mem_quiet         (lomem_quiet && comem_quiet),
        .structural_stall  (structural_stall),
        .dependency_stall  (dependency_stall)
    );

    mcore_fifo #(
        .T     (fetch_cmd_t),
        .DEPTH (CMD_Q_DEPTH)
    ) fetch_cmd_queue (
        .clk       (clk),
        .reset     (reset),
        .flush     (flush),
        .in_valid  (fetch_cmd_valid),
        .in_ready  (fetch_cmd_ready),
        .in_data   (fetch_cmd),
        .out_valid (fetch_q_valid),
        .out_ready (fetch_q_ready),
        .out_data  (fetch_q_cmd),
        .empty     (fetch_q_empty),
        .full      ()
    );

    mcore_fifo #(
        .T     (compute_cmd_t),
        .DEPTH (CMD_Q_DEPTH)
    ) compute_cmd_queue (
        .clk       (clk),
        .reset     (reset),
        .flush     (flush),
        .in_valid  (compute_cmd_valid),
        .in_ready  (compute_cmd_ready),
        .in_data   (compute_cmd),
        .out_valid (compute_q_valid),
        .out_ready (compute_q_ready),
        .out_data  (compute_q_cmd),
        .empty     (compute_q_empty),
        .full      ()
    );

    mcore_fifo #(
        .T     (writeback_cmd_t),
        .DEPTH (CMD_Q_DEPTH)
    ) wb_cmd_queue (
        .clk       (clk),
        .reset     (reset),
        .flush     (flush),
        .in_valid  (wb_cmd_valid),
        .in_ready  (wb_cmd_ready),
        .in_data   (wb_cmd),
        .out_valid (wb_q_valid),
        .out_ready (wb_q_ready),
        .out_data  (wb_q_cmd),
        .empty     (wb_q_empty),
        .full      ()
    );

    mcore_fetch #(
        .BUFFER_DEPTH (BUFFER_DEPTH)
    ) fetch_stage (
        .clk             (clk),
        .reset           (reset),
        .flush           (flush),
        .cmd_valid       (fetch_q_valid),
        .cmd_ready       (fetch_q_ready),
        .cmd             (fetch_q_cmd),
        .lomem_req_valid (f_lomem_req_valid),
        .lomem_req_ready (f_lomem_req_ready),
        .lomem_req_row   (f_lomem_req_row),
        .lomem_req_tag   (f_lomem_req_tag),
        .lomem_rsp_valid (f_lomem_rsp_valid),
        .lomem_rsp_tag   (f_lomem_rsp_tag),
        .lomem_rsp_data  (f_lomem_rsp_data),
        .comem_req_valid (f_comem_req_valid),
        .comem_req_ready (f_comem_req_ready),
        .comem_req_row   (f_comem_req_row),
        .comem_req_tag   (f_comem_req_tag),
        .comem_rsp_valid (f_comem_rsp_valid),
        .comem_rsp_tag   (f_comem_rsp_tag),
        .comem_rsp_data  (f_comem_rsp_data),
        .pkt_valid       (operand_valid),
        .pkt_ready       (operand_ready),
        .pkt             (operand_pkt),
        .idle            (fetch_idle),
        .done_valid      (fetch_done_valid),
        .done_seq        (fetch_done_seq)
    );

    mcore_fifo #(
        .T     (operand_pkt_t),
        .DEPTH (DATA_Q)
    ) operand_queue (
        .clk       (clk),
        .reset     (reset),
        .flush     (flush),
        .in_valid  (operand_valid),
        .in_ready  (operand_ready),
        .in_data   (operand_pkt),
        .out_valid (operand_q_valid),
        .out_ready (operand_q_ready),
        .out_data  (operand_q_pkt),
        .empty     (operand_empty),
        .full      ()
    );

    mcore_compute compute_stage (
        .clk       (clk),
        .reset     (reset),
        .flush     (flush),
        .cmd_valid (compute_q_valid),
        .cmd_ready (compute_q_ready),
        .cmd       (compute_q_cmd),
        .pkt_valid (operand_q_valid),
        .pkt_ready (operand_q_ready),
        .pkt       (operand_q_pkt),
        .res_valid (result_valid),
        .res_ready (result_ready),
        .res       (result_pkt),
        .idle      (compute_idle),
        .seq_error (compute_seq_error)
    );

    mcore_fifo #(
        .T     (result_pkt_t),
        .DEPTH (DATA_Q)
    ) result_queue (
        .clk       (clk),
        .reset     (reset),
        .flush     (flush),
        .in_valid  (result_valid),
        .in_ready  (result_ready),
        .in_data   (result_pkt),
        .out_valid (result_q_valid),
        .out_ready (result_q_ready),
        .out_data  (result_q_pkt),
        .empty     (result_empty),
        .full      ()
    );

    mcore_writeback writeback_stage (
        .clk               (clk),
        .reset             (reset),
        .flush             (flush),
        .cmd_valid         (wb_q_valid),
        .cmd_ready         (wb_q_ready),
        .cmd               (wb_q_cmd),
        .res_valid         (result_q_valid),
        .res_ready         (result_q_ready),
        .res               (result_q_pkt),
        .lomem_req_valid   (w_lomem_req_valid),
        .lomem_req_ready   (w_lomem_req_ready),
        .lomem_req_write   (w_lomem_req_write),
        .lomem_req_row     (w_lomem_req_row),
        .lomem_req_tag     (w_lomem_req_tag),
        .lomem_req_wdata   (w_lomem_req_wdata),
        .lomem_req_lane_en (w_lomem_req_lane_en),
        .lomem_rsp_valid   (w_lomem_rsp_valid),
        .lomem_rsp_tag     (w_lomem_rsp_tag),
        .lomem_rsp_data    (w_lomem_rsp_data),
        .comem_req_valid   (w_comem_req_valid),
        .comem_req_ready   (w_comem_req_ready),
        .comem_req_write   (w_comem_req_write),
        .comem_req_row     (w_comem_req_row),
        .comem_req_tag     (w_comem_req_tag),
        .comem_req_wdata   (w_comem_req_wdata),
        .idle              (wb_idle),
        .done_valid        (wb_done_valid),
        .done_seq          (wb_done_seq),
        .seq_error         (wb_seq_error)
    );

    mcore_memport #(
        .WIDTH (LOMEM_WIDTH),
        .LANES (LOMEM_LANES)
    ) lomem_port (
        .clk             (clk),
        .reset           (reset),
        .fetch_req_valid (f_lomem_req_valid),
        .fetch_req_ready (f_lomem_req_ready),
        .fetch_req_row   (f_lomem_req_row),
        .fetch_req_tag   (f_lomem_req_tag),
        .fetch_rsp_valid (f_lomem_rsp_valid),
        .fetch_rsp_tag   (f_lomem_rsp_tag),
        .fetch_rsp_data  (f_lomem_rsp_data),
        .wb_req_valid    (w_lomem_req_valid),
        .wb_req_ready    (w_lomem_req_ready),
        .wb_req_write    (w_lomem_req_write),
        .wb_req_row      (w_lomem_req_row),
        .wb_req_tag      (w_lomem_req_tag),
        .wb_req_wdata    (w_lomem_req_wdata),
        .wb_req_lane_en  (w_lomem_req_lane_en),
        .wb_rsp_valid    (w_lomem_rsp_valid),
        .wb_rsp_tag      (w_lomem_rsp_tag),
        .wb_rsp_data     (w_lomem_rsp_data),
        .req_valid       (lomem_req_valid),
        .req_ready       (lomem_req_ready),
        .req_write       (lomem_req_write),
        .req_row         (lomem_req_row),
        .req_ticket      (lomem_req_ticket),
        .req_wdata       (lomem_req_wdata),
        .req_lane_en     (lomem_req_lane_en),
        .rsp_valid       (lomem_rsp_valid),
        .rsp_ticket      (lomem_rsp_ticket),
        .rsp_data        (lomem_rsp_data),
        .quiet           (lomem_quiet)
    );

    // Writeback never reads CoMem, so its response side is unused here.
    mcore_memport #(
        .WIDTH (COMEM_WIDTH),
        .LANES (1)
    ) comem_port (
        .clk             (clk),
        .reset           (reset),
        .fetch_req_valid (f_comem_req_valid),
        .fetch_req_ready (f_comem_req_ready),
        .fetch_req_row   (f_comem_req_row),
        .fetch_req_tag   (f_comem_req_tag),
        .fetch_rsp_valid (f_comem_rsp_valid),
        .fetch_rsp_tag   (f_comem_rsp_tag),
        .fetch_rsp_data  (f_comem_rsp_data),
        .wb_req_valid    (w_comem_req_valid),
        .wb_req_ready    (w_comem_req_ready),
        .wb_req_write    (w_comem_req_write),
        .wb_req_row      (w_comem_req_row),
        .wb_req_tag      (w_comem_req_tag),
        .wb_req_wdata    (w_comem_req_wdata),
        .wb_req_lane_en  (1'b1),
        .wb_rsp_valid    (),
        .wb_rsp_tag      (),
        .wb_rsp_data     (),
        .req_valid       (comem_req_valid),
        .req_ready       (comem_req_ready),
        .req_write       (comem_req_write),
        .req_row         (comem_req_row),
        .req_ticket      (comem_req_ticket),
        .req_wdata       (comem_req_wdata),
        .req_lane_en     (),
        .rsp_valid       (comem_rsp_valid),
        .rsp_ticket      (comem_rsp_ticket),
        .rsp_data        (comem_rsp_data),
        .quiet           (comem_quiet)
    );
endmodule
