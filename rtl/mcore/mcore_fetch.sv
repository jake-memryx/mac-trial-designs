`timescale 1ns/1ps

// Fetch stage (spec sections 3.3 and 48.2): command FIFO, in-order FSM,
// layout-specific address generation, MATMUL_B lane routing, INT8 half-lane
// unpacking and the ordered operand channel to Compute.
//
// SKELETON: queue and handshakes are real; the FSM body is not implemented.
module mcore_fetch
    import mcore_pkg::*;
#(
    parameter int unsigned CMD_DEPTH  = 4,
    parameter int unsigned DATA_DEPTH = 4
) (
    input  logic clk,
    input  logic reset,
    input  logic flush,

    input  logic       cmd_valid,
    output logic       cmd_ready,
    input  fetch_cmd_t cmd,

    // LoMem read client (512-bit row).
    output logic                      lomem_rd_valid,
    input  logic                      lomem_rd_ready,
    output logic [MEM_ADDR_WIDTH-1:0] lomem_rd_addr,
    input  logic                      lomem_rd_data_valid,
    input  logic [LOMEM_WIDTH-1:0]    lomem_rd_data,

    // CoMem read client (128-bit line).
    output logic                      comem_rd_valid,
    input  logic                      comem_rd_ready,
    output logic [MEM_ADDR_WIDTH-1:0] comem_rd_addr,
    input  logic                      comem_rd_data_valid,
    input  logic [COMEM_WIDTH-1:0]    comem_rd_data,

    // Ordered operand channel to Compute.
    output logic         data_valid,
    input  logic         data_ready,
    output operand_pkt_t data_pkt,

    output logic idle
);
    logic       queue_out_valid;
    logic       queue_out_ready;
    fetch_cmd_t queue_cmd;
    logic       queue_empty;

    mcore_fifo #(.T(fetch_cmd_t), .DEPTH(CMD_DEPTH)) u_cmd_fifo (
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

    logic         pkt_in_valid;
    logic         pkt_in_ready;
    operand_pkt_t pkt_in;
    logic         pkt_empty;

    mcore_fifo #(.T(operand_pkt_t), .DEPTH(DATA_DEPTH)) u_data_fifo (
        .clk       (clk),
        .reset     (reset),
        .flush     (flush),
        .in_valid  (pkt_in_valid),
        .in_ready  (pkt_in_ready),
        .in_data   (pkt_in),
        .out_valid (data_valid),
        .out_ready (data_ready),
        .out_data  (data_pkt),
        .empty     (pkt_empty)
    );

    // TODO: fetch_fsm + agu + lomem/comem routers + a/b buffers + int8_to_bf16.
    assign queue_out_ready = 1'b0;
    assign pkt_in_valid    = 1'b0;
    assign pkt_in          = '0;
    assign lomem_rd_valid  = 1'b0;
    assign lomem_rd_addr   = '0;
    assign comem_rd_valid  = 1'b0;
    assign comem_rd_addr   = '0;

    assign idle = queue_empty && pkt_empty;

    // Unused until the FSM consumes memory responses.
    logic unused;
    assign unused = lomem_rd_ready | lomem_rd_data_valid | comem_rd_ready |
                    comem_rd_data_valid | (|lomem_rd_data) | (|comem_rd_data) |
                    queue_out_valid | pkt_in_ready | (|queue_cmd);
endmodule
