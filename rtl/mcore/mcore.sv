`timescale 1ns/1ps

// Matrix Core top level (spec section 49).
//
// The Command Processor sits beside the Fetch -> Compute -> Writeback dataflow:
// it drives the three stage command queues and consumes stage idle status for
// the halt-drain `done` rule. Matrix data never passes through the CP.
//
// SKELETON: hierarchy, interfaces and channel wiring are in place; stage FSM
// bodies are still to be implemented.
module mcore
    import mcore_pkg::*;
#(
    parameter int unsigned FETCH_CMD_DEPTH     = 4,
    parameter int unsigned COMPUTE_CMD_DEPTH   = 4,
    parameter int unsigned WRITEBACK_CMD_DEPTH = 4,
    parameter int unsigned OPERAND_DEPTH       = 4,
    parameter int unsigned RESULT_DEPTH        = 2
) (
    input  logic clk,
    input  logic reset,
    // Abort/flush: clears stage command queues and inter-stage data.
    input  logic flush,

    input  logic start,
    output logic done,
    output logic error,

    // Combinational 64-bit program memory read port.
    output logic [PROG_ADDR_WIDTH-1:0] prog_addr,
    input  instr_t                     prog_data,

    // LoMem: 512-bit row read and masked row write.
    output logic                      lomem_rd_valid,
    input  logic                      lomem_rd_ready,
    output logic [MEM_ADDR_WIDTH-1:0] lomem_rd_addr,
    input  logic                      lomem_rd_data_valid,
    input  logic [LOMEM_WIDTH-1:0]    lomem_rd_data,
    output logic                      lomem_wr_valid,
    input  logic                      lomem_wr_ready,
    output logic [MEM_ADDR_WIDTH-1:0] lomem_wr_addr,
    output logic [LOMEM_WIDTH-1:0]    lomem_wr_data,
    output logic [LOMEM_LANES-1:0]    lomem_wr_lane_en,

    // CoMem: 128-bit line read and write.
    output logic                      comem_rd_valid,
    input  logic                      comem_rd_ready,
    output logic [MEM_ADDR_WIDTH-1:0] comem_rd_addr,
    input  logic                      comem_rd_data_valid,
    input  logic [COMEM_WIDTH-1:0]    comem_rd_data,
    output logic                      comem_wr_valid,
    input  logic                      comem_wr_ready,
    output logic [MEM_ADDR_WIDTH-1:0] comem_wr_addr,
    output logic [COMEM_WIDTH-1:0]    comem_wr_data
);
    logic           fetch_cmd_valid, fetch_cmd_ready;
    fetch_cmd_t     fetch_cmd;
    logic           compute_cmd_valid, compute_cmd_ready;
    compute_cmd_t   compute_cmd;
    logic           writeback_cmd_valid, writeback_cmd_ready;
    writeback_cmd_t writeback_cmd;

    logic         operand_valid, operand_ready;
    operand_pkt_t operand_pkt;
    logic         result_valid, result_ready;
    result_pkt_t  result_pkt;

    logic fetch_idle, compute_idle, writeback_idle;

    mcore_cmd u_cmd (
        .clk                 (clk),
        .reset               (reset),
        .start               (start),
        .done                (done),
        .error               (error),
        .prog_addr           (prog_addr),
        .prog_data           (prog_data),
        .fetch_cmd_valid     (fetch_cmd_valid),
        .fetch_cmd_ready     (fetch_cmd_ready),
        .fetch_cmd           (fetch_cmd),
        .compute_cmd_valid   (compute_cmd_valid),
        .compute_cmd_ready   (compute_cmd_ready),
        .compute_cmd         (compute_cmd),
        .writeback_cmd_valid (writeback_cmd_valid),
        .writeback_cmd_ready (writeback_cmd_ready),
        .writeback_cmd       (writeback_cmd),
        .fetch_idle          (fetch_idle),
        .compute_idle        (compute_idle),
        .writeback_idle      (writeback_idle)
    );

    mcore_fetch #(
        .CMD_DEPTH  (FETCH_CMD_DEPTH),
        .DATA_DEPTH (OPERAND_DEPTH)
    ) u_fetch (
        .clk                 (clk),
        .reset               (reset),
        .flush               (flush),
        .cmd_valid           (fetch_cmd_valid),
        .cmd_ready           (fetch_cmd_ready),
        .cmd                 (fetch_cmd),
        .lomem_rd_valid      (lomem_rd_valid),
        .lomem_rd_ready      (lomem_rd_ready),
        .lomem_rd_addr       (lomem_rd_addr),
        .lomem_rd_data_valid (lomem_rd_data_valid),
        .lomem_rd_data       (lomem_rd_data),
        .comem_rd_valid      (comem_rd_valid),
        .comem_rd_ready      (comem_rd_ready),
        .comem_rd_addr       (comem_rd_addr),
        .comem_rd_data_valid (comem_rd_data_valid),
        .comem_rd_data       (comem_rd_data),
        .data_valid          (operand_valid),
        .data_ready          (operand_ready),
        .data_pkt            (operand_pkt),
        .idle                (fetch_idle)
    );

    mcore_compute #(
        .CMD_DEPTH    (COMPUTE_CMD_DEPTH),
        .RESULT_DEPTH (RESULT_DEPTH)
    ) u_compute (
        .clk          (clk),
        .reset        (reset),
        .flush        (flush),
        .cmd_valid    (compute_cmd_valid),
        .cmd_ready    (compute_cmd_ready),
        .cmd          (compute_cmd),
        .data_valid   (operand_valid),
        .data_ready   (operand_ready),
        .data_pkt     (operand_pkt),
        .result_valid (result_valid),
        .result_ready (result_ready),
        .result_pkt   (result_pkt),
        .idle         (compute_idle)
    );

    mcore_writeback #(
        .CMD_DEPTH    (WRITEBACK_CMD_DEPTH),
        .RESULT_DEPTH (RESULT_DEPTH)
    ) u_writeback (
        .clk              (clk),
        .reset            (reset),
        .flush            (flush),
        .cmd_valid        (writeback_cmd_valid),
        .cmd_ready        (writeback_cmd_ready),
        .cmd              (writeback_cmd),
        .result_valid     (result_valid),
        .result_ready     (result_ready),
        .result_pkt       (result_pkt),
        .lomem_wr_valid   (lomem_wr_valid),
        .lomem_wr_ready   (lomem_wr_ready),
        .lomem_wr_addr    (lomem_wr_addr),
        .lomem_wr_data    (lomem_wr_data),
        .lomem_wr_lane_en (lomem_wr_lane_en),
        .comem_wr_valid   (comem_wr_valid),
        .comem_wr_ready   (comem_wr_ready),
        .comem_wr_addr    (comem_wr_addr),
        .comem_wr_data    (comem_wr_data),
        .idle             (writeback_idle)
    );
endmodule
