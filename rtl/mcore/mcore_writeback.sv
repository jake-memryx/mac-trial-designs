`timescale 1ns/1ps

// Writeback stage (spec sections 42 and 48.4): command FIFO, in-order FSM,
// result packet buffering from Compute, FP32 -> BF16 conversion, 128-bit line
// packing with tail zeroing, and LoMem/CoMem write generation.
//
// SKELETON: queues and handshakes are real; the FSM body is not implemented.
module mcore_writeback
    import mcore_pkg::*;
#(
    parameter int unsigned CMD_DEPTH    = 4,
    parameter int unsigned RESULT_DEPTH = 2
) (
    input  logic clk,
    input  logic reset,
    input  logic flush,

    input  logic           cmd_valid,
    output logic           cmd_ready,
    input  writeback_cmd_t cmd,

    input  logic        result_valid,
    output logic        result_ready,
    input  result_pkt_t result_pkt,

    // LoMem write client: 512-bit row with a 4-bit lane mask (section 15).
    output logic                      lomem_wr_valid,
    input  logic                      lomem_wr_ready,
    output logic [MEM_ADDR_WIDTH-1:0] lomem_wr_addr,
    output logic [LOMEM_WIDTH-1:0]    lomem_wr_data,
    output logic [LOMEM_LANES-1:0]    lomem_wr_lane_en,

    // CoMem write client: one 128-bit line (section 16).
    output logic                      comem_wr_valid,
    input  logic                      comem_wr_ready,
    output logic [MEM_ADDR_WIDTH-1:0] comem_wr_addr,
    output logic [COMEM_WIDTH-1:0]    comem_wr_data,

    output logic idle
);
    logic           queue_out_valid;
    logic           queue_out_ready;
    writeback_cmd_t queue_cmd;
    logic           queue_empty;

    mcore_fifo #(.T(writeback_cmd_t), .DEPTH(CMD_DEPTH)) u_cmd_fifo (
        .clk       (clk),
        .reset     (reset),
        .flush     (flush),
        .in_valid  (cmd_valid),
        .in_ready  (cmd_ready),
        .in_data   (cmd),
        .out_valid (queue_out_valid),
        .out_ready (queue_out_ready),
        .out_data  (queue_cmd),
        .empty     (queue_empty)
    );

    logic        held_valid;
    logic        held_ready;
    result_pkt_t held_pkt;
    logic        held_empty;

    mcore_fifo #(.T(result_pkt_t), .DEPTH(RESULT_DEPTH)) u_result_fifo (
        .clk       (clk),
        .reset     (reset),
        .flush     (flush),
        .in_valid  (result_valid),
        .in_ready  (result_ready),
        .in_data   (result_pkt),
        .out_valid (held_valid),
        .out_ready (held_ready),
        .out_data  (held_pkt),
        .empty     (held_empty)
    );

    // TODO: writeback_fsm + result mux + fp32_to_bf16 + line packer + router.
    assign queue_out_ready   = 1'b0;
    assign held_ready        = 1'b0;
    assign lomem_wr_valid    = 1'b0;
    assign lomem_wr_addr     = '0;
    assign lomem_wr_data     = '0;
    assign lomem_wr_lane_en  = '0;
    assign comem_wr_valid    = 1'b0;
    assign comem_wr_addr     = '0;
    assign comem_wr_data     = '0;

    assign idle = queue_empty && held_empty;

    logic unused;
    assign unused = queue_out_valid | held_valid | lomem_wr_ready |
                    comem_wr_ready | (|held_pkt) | (|queue_cmd);
endmodule
