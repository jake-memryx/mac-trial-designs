`timescale 1ns/1ps

// Compute stage (spec sections 7-12 and 48.3): command FIFO, in-order FSM,
// ordered operand channel from Fetch, TreeMAC[4] with a 16-entry FP32
// accumulator bank each, and the ordered snapshot channel to Writeback.
//
// SKELETON: bank, queues and handshakes are real; the TreeMAC array is not
// instantiated yet. The existing bf16_multi_mac_tree is the intended lane
// implementation (MULTIPLIERS = 8, ACCUMULATORS = 16).
module mcore_compute
    import mcore_pkg::*;
#(
    parameter int unsigned CMD_DEPTH    = 4,
    parameter int unsigned RESULT_DEPTH = 2
) (
    input  logic clk,
    input  logic reset,
    input  logic flush,

    input  logic         cmd_valid,
    output logic         cmd_ready,
    input  compute_cmd_t cmd,

    input  logic         data_valid,
    output logic         data_ready,
    input  operand_pkt_t data_pkt,

    output logic        result_valid,
    input  logic        result_ready,
    output result_pkt_t result_pkt,

    output logic idle
);
    logic         queue_out_valid;
    logic         queue_out_ready;
    compute_cmd_t queue_cmd;
    logic         queue_empty;

    mcore_fifo #(.T(compute_cmd_t), .DEPTH(CMD_DEPTH)) u_cmd_fifo (
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

    logic        snapshot_valid;
    logic        snapshot_ready;
    result_pkt_t snapshot;
    logic        result_empty;

    mcore_fifo #(.T(result_pkt_t), .DEPTH(RESULT_DEPTH)) u_result_fifo (
        .clk       (clk),
        .reset     (reset),
        .flush     (flush),
        .in_valid  (snapshot_valid),
        .in_ready  (snapshot_ready),
        .in_data   (snapshot),
        .out_valid (result_valid),
        .out_ready (result_ready),
        .out_data  (result_pkt),
        .empty     (result_empty)
    );

    // Accumulator bank, accumulator-major / lane-minor global ordering
    // (section 7): accumulator[index][lane].
    logic [31:0] accumulator [TREEMAC_ACCUMULATORS][TREEMACS];

    always_ff @(posedge clk) begin
        if (reset || flush) begin
            for (int unsigned i = 0; i < TREEMAC_ACCUMULATORS; i++) begin
                for (int unsigned l = 0; l < TREEMACS; l++) begin
                    accumulator[i][l] <= '0;
                end
            end
        end
        // TODO: reset/load/mac/snapshot updates driven by the compute FSM.
    end

    // TODO: compute_fsm + treemac[4].
    assign queue_out_ready = 1'b0;
    assign data_ready      = 1'b0;
    assign snapshot_valid  = 1'b0;
    assign snapshot        = '0;

    assign idle = queue_empty && result_empty;

    logic unused;
    assign unused = queue_out_valid | snapshot_ready | data_valid |
                    (|data_pkt) | (|queue_cmd);
endmodule
