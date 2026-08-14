`timescale 1ns/1ps

// Behavioral model of one Matrix Core memory domain (matrix_core.md section
// 13). Instantiate once per domain: WIDTH=512 with LANES=4 for LoMem, and
// WIDTH=128 with LANES=1 for CoMem.
//
// Requests are row-aligned. Writes are posted: they commit on acceptance and
// produce no response. Reads are answered READ_LATENCY cycles after
// acceptance with the request's ticket echoed back, and up to
// MAX_OUTSTANDING may be in flight before req_ready drops. At most one
// response leaves per cycle.
//
// Because the core is required to match responses by ticket rather than by
// arrival order, +mem_reorder returns ready responses newest-first (LIFO)
// instead of oldest-first, briefly holding a lone ready response so a later
// read can catch up and the order really inverts. Both modes are
// deterministic.
//
// A testbench preloads and inspects the array hierarchically through
// write_row, read_row and clear_all.
module mcore_mem_model #(
    parameter int unsigned WIDTH           = 512,
    parameter int unsigned ROWS            = 4096,
    parameter int unsigned LANES           = 4,
    parameter int unsigned TICKET_W        = 5,
    parameter int unsigned ROW_W           = 16,
    parameter int unsigned READ_LATENCY    = 3,
    parameter int unsigned MAX_OUTSTANDING = 12
) (
    input  logic                clk,
    input  logic                reset,
    input  logic                req_valid,
    output logic                req_ready,
    input  logic                req_write,
    input  logic [ROW_W-1:0]    req_row,
    input  logic [TICKET_W-1:0] req_ticket,
    input  logic [WIDTH-1:0]    req_wdata,
    input  logic [LANES-1:0]    req_lane_en,
    output logic                rsp_valid,
    output logic [TICKET_W-1:0] rsp_ticket,
    output logic [WIDTH-1:0]    rsp_data
);
    localparam int unsigned LANE_WIDTH = WIDTH / LANES;
    // A pending read counts down from READ_LATENCY-1, so it becomes eligible
    // on the READ_LATENCY-th edge after the one that accepted it.
    localparam int unsigned INITIAL_WAIT =
        (READ_LATENCY > 0) ? READ_LATENCY - 1 : 0;
    localparam int unsigned WAIT_W =
        unsigned'((INITIAL_WAIT > 0) ? $clog2(INITIAL_WAIT + 1) : 1);
    localparam int unsigned LEN_W = unsigned'($clog2(MAX_OUTSTANDING + 1));
    // Cycles a single ready response waits in reorder mode for a later one to
    // become ready, so the LIFO order has something to reverse. Bounded, so a
    // response is never starved.
    localparam int unsigned REORDER_HOLD = 2;
    localparam int unsigned HOLD_W = unsigned'($clog2(REORDER_HOLD + 1));

    logic [WIDTH-1:0] rows [0:ROWS-1];

    // Pending reads, oldest at index 0. The whole list shifts down when an
    // entry retires, which keeps arrival order explicit and the selection
    // rules trivial.
    logic [TICKET_W-1:0] pend_ticket [0:MAX_OUTSTANDING-1];
    logic [WIDTH-1:0]    pend_data   [0:MAX_OUTSTANDING-1];
    logic [WAIT_W-1:0]   pend_wait   [0:MAX_OUTSTANDING-1];
    logic [LEN_W-1:0]    pend_len;
    logic [HOLD_W-1:0]   hold_timer;

    logic reorder_mode;
    initial reorder_mode = ($test$plusargs("mem_reorder") != 0);

    assign req_ready = (pend_len < LEN_W'(MAX_OUTSTANDING));

    // Rows outside the modelled range fold onto row 0 rather than corrupting
    // the array; an out-of-range access is a testbench bug either way.
    function automatic int unsigned row_index(input logic [ROW_W-1:0] row);
        return (32'({1'b0, row}) < ROWS) ? 32'({1'b0, row}) : 0;
    endfunction

    task automatic write_row(input int row, input logic [WIDTH-1:0] data);
        rows[row_index(ROW_W'($unsigned(row)))] = data;
    endtask

    function automatic logic [WIDTH-1:0] read_row(input int row);
        return rows[row_index(ROW_W'($unsigned(row)))];
    endfunction

    task automatic clear_all();
        for (int unsigned r = 0; r < ROWS; r++)
            rows[r] = '0;
    endtask

    // Posted writes: commit the enabled lanes of the addressed row, lane 0 in
    // the low bits, and generate no response.
    always @(posedge clk) begin : write_commit
        if (req_valid && req_ready && req_write)
            for (int unsigned l = 0; l < LANES; l++)
                if (req_lane_en[l])
                    rows[row_index(req_row)][l*LANE_WIDTH +: LANE_WIDTH] <=
                        req_wdata[l*LANE_WIDTH +: LANE_WIDTH];
    end

    // Reads: snapshot the row when the request is accepted, then hand it back
    // once the countdown expires. A read accepted in the same cycle as a
    // write to the same row therefore sees the pre-write contents, which the
    // core never relies on because it treats a write as complete at accept.
    always_ff @(posedge clk) begin : read_pipeline
        logic [TICKET_W-1:0] next_ticket [0:MAX_OUTSTANDING-1];
        logic [WIDTH-1:0]    next_data   [0:MAX_OUTSTANDING-1];
        logic [WAIT_W-1:0]   next_wait   [0:MAX_OUTSTANDING-1];
        logic [LEN_W-1:0]    length;
        logic [LEN_W-1:0]    pick;
        logic                pick_valid;
        logic                emit_now;
        int unsigned         ready_count;
        int unsigned         live;

        if (reset) begin
            pend_len   <= '0;
            hold_timer <= HOLD_W'(REORDER_HOLD);
            rsp_valid  <= 1'b0;
            rsp_ticket <= '0;
            rsp_data   <= '0;
            for (int unsigned i = 0; i < MAX_OUTSTANDING; i++) begin
                pend_ticket[i] <= '0;
                pend_data[i]   <= '0;
                pend_wait[i]   <= '0;
            end
        end else begin
            live        = 32'({1'b0, pend_len});
            pick        = '0;
            pick_valid  = 1'b0;
            ready_count = 0;
            for (int unsigned i = 0; i < MAX_OUTSTANDING; i++)
                if ((i < live) && (pend_wait[i] == '0)) begin
                    ready_count = ready_count + 1;
                    // In order the first match wins, which is the oldest
                    // entry; reordering keeps overwriting, so the newest
                    // ready entry wins instead.
                    if (reorder_mode || !pick_valid) begin
                        pick       = LEN_W'(i);
                        pick_valid = 1'b1;
                    end
                end

            // All reads share one latency, so a lone ready response would
            // always be the oldest one and LIFO would degenerate to FIFO.
            // Holding it briefly lets the next read catch up and the order
            // genuinely invert.
            emit_now = pick_valid && (!reorder_mode || (ready_count > 1) ||
                                      (hold_timer == '0));
            if (!pick_valid || emit_now)
                hold_timer <= HOLD_W'(REORDER_HOLD);
            else
                hold_timer <= hold_timer - HOLD_W'(1'b1);

            rsp_valid  <= emit_now;
            rsp_ticket <= emit_now ? pend_ticket[pick] : '0;
            rsp_data   <= emit_now ? pend_data[pick] : '0;

            for (int unsigned i = 0; i < MAX_OUTSTANDING; i++) begin
                next_ticket[i] = '0;
                next_data[i]   = '0;
                next_wait[i]   = '0;
            end

            length = '0;
            for (int unsigned i = 0; i < MAX_OUTSTANDING; i++)
                if ((i < live) && !(emit_now && (LEN_W'(i) == pick))) begin
                    next_ticket[length] = pend_ticket[i];
                    next_data[length]   = pend_data[i];
                    next_wait[length]   = (pend_wait[i] == '0) ? '0 :
                                          pend_wait[i] - WAIT_W'(1'b1);
                    length              = length + LEN_W'(1'b1);
                end

            if (req_valid && req_ready && !req_write &&
                (length < LEN_W'(MAX_OUTSTANDING))) begin
                next_ticket[length] = req_ticket;
                next_data[length]   = rows[row_index(req_row)];
                next_wait[length]   = WAIT_W'(INITIAL_WAIT);
                length              = length + LEN_W'(1'b1);
            end

            for (int unsigned i = 0; i < MAX_OUTSTANDING; i++) begin
                pend_ticket[i] <= next_ticket[i];
                pend_data[i]   <= next_data[i];
                pend_wait[i]   <= next_wait[i];
            end
            pend_len <= length;
        end
    end
endmodule
