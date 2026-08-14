`timescale 1ns/1ps

// Matrix Core Compute stage: four TreeMAC lanes, their 64 FP32 accumulators, and
// the Compute->WB snapshot.
//
// One command is active at a time (matrix_core.md section 3). The stage never
// needs to know how many operand packets a command produces: Fetch marks the
// final packet with `last`, so a MAC of one row and a MAC of a hundred rows are
// the same control problem.
//
// Commands (section 17):
//   COMPUTE_RESET     one cycle, clear all 64 accumulators
//   COMPUTE_LOAD_ACC  one packet, lane l writes preload[l] into acc[index]
//   COMPUTE_MAC       one accumulate cycle per packet, until `last`
//   COMPUTE_SNAPSHOT  ceil(count/4) cycles, reading four lanes per cycle and
//                     rounding each FP32 to BF16
//
// The snapshot reads the bank through a dedicated combinational port, so it
// never contends with accumulation, and the live bank is free to move on as soon
// as the result packet is accepted.
module mcore_compute
    import mcore_pkg::*;
(
    input  logic                 clk,
    input  logic                 reset,
    input  logic                 flush,
    input  logic                 cmd_valid,
    output logic                 cmd_ready,
    input  compute_cmd_t         cmd,
    input  logic                 pkt_valid,
    output logic                 pkt_ready,
    input  operand_pkt_t         pkt,
    output logic                 res_valid,
    input  logic                 res_ready,
    output result_pkt_t          res,
    output logic                 idle,
    // A packet whose sequence does not match the active command is refused
    // rather than consumed, so a sequencing bug stalls visibly instead of
    // corrupting an accumulator (section 19).
    output logic                 seq_error
);
    typedef enum logic [2:0] {
        C_IDLE     = 3'd0,
        C_RESET    = 3'd1,
        C_LOAD_ACC = 3'd2,
        C_MAC      = 3'd3,
        C_SNAPSHOT = 3'd4,
        C_RESULT   = 3'd5
    } compute_state_e;

    compute_state_e state, next_state;
    compute_cmd_t   command;
    logic           command_valid;

    logic [ACC_SELECT_WIDTH-1:0] group;
    logic [ACC_SELECT_WIDTH-1:0] last_group;
    logic [TOTAL_ACCUMULATORS-1:0][15:0] snapshot_values;
    logic [TOTAL_ACCUMULATORS-1:0][15:0] snapshot_next;

    logic lane_clear;
    logic lane_enable;
    logic lane_write;
    logic packet_taken;
    logic seq_match;
    logic seq_error_q;

    // Unpacked per-lane operand views for the TreeMAC ports.
    logic [15:0] lane_a [0:TREEMACS-1][0:TREEMAC_MULTIPLIERS-1];
    logic [15:0] lane_b [0:TREEMACS-1][0:TREEMAC_MULTIPLIERS-1];
    logic [31:0] lane_read [0:TREEMACS-1];

    assign seq_match    = (pkt.seq == command.seq);
    assign packet_taken = pkt_valid && pkt_ready;
    assign last_group   = ACC_SELECT_WIDTH'((command.count - 1'b1) >> 2);

    always_comb begin
        for (int unsigned l = 0; l < TREEMACS; l++) begin
            for (int unsigned m = 0; m < TREEMAC_MULTIPLIERS; m++) begin
                lane_a[l][m] = pkt.lhs[l][m];
                lane_b[l][m] = pkt.rhs[l][m];
            end
        end
    end

    // Accumulation and preload are both driven straight from the packet at the
    // head of the operand queue, so a packet costs exactly one cycle.
    assign lane_clear  = (state == C_RESET);
    assign lane_enable = (state == C_MAC) && packet_taken;
    assign lane_write  = (state == C_LOAD_ACC) && packet_taken;

    genvar lane;
    generate
        for (lane = 0; lane < TREEMACS; lane = lane + 1) begin : g_lane
            mcore_treemac #(
                .MULTIPLIERS          (TREEMAC_MULTIPLIERS),
                .ACCUMULATORS         (TREEMAC_ACCUMULATORS),
                .REDUCTION_GUARD_BITS (REDUCTION_GUARD_BITS)
            ) treemac (
                .clk                (clk),
                .reset              (reset),
                .clear              (lane_clear),
                .enable             (lane_enable && pkt.active_lanes[lane]),
                .accumulator_select (pkt.accumulator_index),
                .a                  (lane_a[lane]),
                .b                  (lane_b[lane]),
                .write_enable       (lane_write),
                .write_index        (pkt.accumulator_index),
                .write_data         (pkt.preload[lane]),
                .read_index         (group),
                .read_data          (lane_read[lane])
            );
        end
    endgenerate

    // Global order is accumulator-major, lane-minor, so one snapshot cycle
    // fills four consecutive result values (section 17).
    always_comb begin
        snapshot_next = snapshot_values;
        for (int unsigned l = 0; l < TREEMACS; l++)
            snapshot_next[{group, LANE_SELECT_WIDTH'(l)}] =
                fp32_to_bf16(lane_read[l]);
    end

    always_comb begin
        next_state = state;
        case (state)
            C_IDLE: begin
                if (cmd_valid) begin
                    case (cmd.op)
                        COMPUTE_RESET:    next_state = C_RESET;
                        COMPUTE_LOAD_ACC: next_state = C_LOAD_ACC;
                        COMPUTE_MAC:      next_state = C_MAC;
                        COMPUTE_SNAPSHOT: next_state = C_SNAPSHOT;
                        default:          next_state = C_SNAPSHOT;
                    endcase
                end
            end
            C_RESET: next_state = C_IDLE;
            C_LOAD_ACC: begin
                if (packet_taken)
                    next_state = C_IDLE;
            end
            C_MAC: begin
                if (packet_taken && pkt.last)
                    next_state = C_IDLE;
            end
            C_SNAPSHOT: begin
                if (group == last_group)
                    next_state = C_RESULT;
            end
            C_RESULT: begin
                if (res_ready)
                    next_state = C_IDLE;
            end
            default: next_state = C_IDLE;
        endcase
    end

    assign cmd_ready = (state == C_IDLE);
    // Packets are consumed only while a command that expects them is active and
    // only when their sequence matches.
    assign pkt_ready = ((state == C_LOAD_ACC) || (state == C_MAC)) && seq_match;

    assign res_valid = (state == C_RESULT);
    assign res.seq   = command.seq;
    assign res.count = command.count;
    assign res.values = snapshot_values;

    assign idle      = (state == C_IDLE) && !command_valid;
    assign seq_error = seq_error_q;

    always_ff @(posedge clk) begin
        if (reset || flush) begin
            state         <= C_IDLE;
            command       <= '0;
            command_valid <= 1'b0;
            group         <= '0;
            snapshot_values <= '0;
        end else begin
            state <= next_state;
            if (state == C_IDLE && cmd_valid) begin
                command       <= cmd;
                command_valid <= 1'b1;
                group         <= '0;
                if (cmd.op == COMPUTE_SNAPSHOT)
                    snapshot_values <= '0;
            end
            if (state == C_SNAPSHOT) begin
                snapshot_values <= snapshot_next;
                group <= group + 1'b1;
            end
            if (next_state == C_IDLE && state != C_IDLE)
                command_valid <= 1'b0;
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            seq_error_q <= 1'b0;
        end else if (pkt_valid && !seq_match &&
                     ((state == C_LOAD_ACC) || (state == C_MAC))) begin
            seq_error_q <= 1'b1;
        end
    end
endmodule
