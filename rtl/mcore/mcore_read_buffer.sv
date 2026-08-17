`timescale 1ns/1ps

// One prefetch buffer for the Fetch stage: a small reorder buffer that lets the
// address generator run ahead of the memory.
//
// An entry is allocated when the address generator produces an address, the
// request is issued when the memory port accepts it, and the response lands in
// the entry its ticket names. Because the entry index travels in the ticket,
// responses may return in any order (matrix_core.md section 13) while the head
// of the buffer is still consumed strictly in allocation order.
//
// The data field is one 512-bit LoMem row. A 128-bit CoMem response is placed in
// the low lane by the caller, which then reads it back through head_line with
// lane 0. head_line is the 128-bit view an operand line needs; head_row is the
// whole row, which multi_mac and MATMUL_B operands use.
module mcore_read_buffer
    import mcore_pkg::*;
#(
    parameter int unsigned DEPTH = 4,
    // Ticket bit TAG_WIDTH-1 identifies which buffer a response belongs to; the
    // low bits are the entry index.
    parameter logic        BUFFER_ID = 1'b0,
    parameter int unsigned INDEX_WIDTH = (DEPTH <= 1) ? 1 : $clog2(DEPTH)
) (
    input  logic                        clk,
    input  logic                        reset,
    input  logic                        flush,
    input  logic                        alloc_valid,
    output logic                        alloc_ready,
    input  mem_domain_e                 alloc_domain,
    input  logic [MEM_ROW_WIDTH-1:0]    alloc_row,
    input  logic [LANE_SELECT_WIDTH-1:0] alloc_lane,
    output logic                        req_valid,
    input  logic                        req_ready,
    output mem_domain_e                 req_domain,
    output logic [MEM_ROW_WIDTH-1:0]    req_row,
    output logic [TAG_WIDTH-1:0]        req_tag,
    input  logic                        rsp_valid,
    input  logic [TAG_WIDTH-1:0]        rsp_tag,
    input  logic [LOMEM_WIDTH-1:0]      rsp_data,
    output logic                        head_valid,
    input  logic                        head_pop,
    output logic [LOMEM_WIDTH-1:0]      head_row,
    output logic [LINE_WIDTH-1:0]       head_line,
    output logic                        empty
);
    logic [MEM_ROW_WIDTH-1:0]     entry_row    [0:DEPTH-1];
    mem_domain_e                  entry_domain [0:DEPTH-1];
    logic [LANE_SELECT_WIDTH-1:0] entry_lane   [0:DEPTH-1];
    logic [LOMEM_WIDTH-1:0]       entry_data   [0:DEPTH-1];
    logic [DEPTH-1:0]             entry_filled;

    logic [INDEX_WIDTH:0] alloc_pointer;
    logic [INDEX_WIDTH:0] issue_pointer;
    logic [INDEX_WIDTH:0] read_pointer;

    logic [INDEX_WIDTH-1:0] alloc_index;
    logic [INDEX_WIDTH-1:0] issue_index;
    logic [INDEX_WIDTH-1:0] read_index;
    logic [INDEX_WIDTH-1:0] fill_index;
    logic                   fill_select;
    logic                   full;

    assign alloc_index = alloc_pointer[INDEX_WIDTH-1:0];
    assign issue_index = issue_pointer[INDEX_WIDTH-1:0];
    assign read_index  = read_pointer[INDEX_WIDTH-1:0];

    assign full = (alloc_pointer[INDEX_WIDTH] != read_pointer[INDEX_WIDTH]) &&
                  (alloc_index == read_index);
    assign empty = (alloc_pointer == read_pointer);

    assign alloc_ready = !full;

    // An allocated entry whose request has not been accepted yet.
    assign req_valid  = (issue_pointer != alloc_pointer);
    assign req_row    = entry_row[issue_index];
    assign req_domain = entry_domain[issue_index];
    assign req_tag    = {BUFFER_ID, {(TAG_WIDTH-1-INDEX_WIDTH){1'b0}},
                         issue_index};

    assign fill_select = rsp_valid && (rsp_tag[TAG_WIDTH-1] == BUFFER_ID);
    assign fill_index  = rsp_tag[INDEX_WIDTH-1:0];

    assign head_valid = !empty && entry_filled[read_index];
    assign head_row   = entry_data[read_index];
    // Lane select is only meaningful for 128-bit line accesses; whole-row
    // consumers allocate with lane 0.
    always_comb begin
        head_line = entry_data[read_index][LINE_WIDTH-1:0];
        for (int unsigned l = 0; l < LOMEM_LANES; l++)
            if (entry_lane[read_index] == LANE_SELECT_WIDTH'(l))
                head_line = entry_data[read_index][l*LINE_WIDTH +: LINE_WIDTH];
    end

    always_ff @(posedge clk) begin
        if (reset || flush) begin
            alloc_pointer <= '0;
            issue_pointer <= '0;
            read_pointer  <= '0;
            entry_filled  <= '0;
        end else begin
            if (alloc_valid && alloc_ready) begin
                alloc_pointer            <= alloc_pointer + 1'b1;
                entry_filled[alloc_index] <= 1'b0;
            end
            if (req_valid && req_ready)
                issue_pointer <= issue_pointer + 1'b1;
            // A response for an entry that is no longer outstanding is stale,
            // which only happens after a flush; dropping it is the intent.
            if (fill_select && !entry_filled[fill_index])
                entry_filled[fill_index] <= 1'b1;
            if (head_valid && head_pop) begin
                read_pointer              <= read_pointer + 1'b1;
                entry_filled[read_index]  <= 1'b0;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (alloc_valid && alloc_ready) begin
            entry_row[alloc_index]    <= alloc_row;
            entry_domain[alloc_index] <= alloc_domain;
            entry_lane[alloc_index]   <= alloc_lane;
        end
        if (fill_select)
            entry_data[fill_index] <= rsp_data;
    end

    if (DEPTH < 2 || (DEPTH & (DEPTH - 1)) != 0)
        $error("mcore_read_buffer: DEPTH must be a power of two >= 2");
    if (INDEX_WIDTH > TAG_WIDTH - 1)
        $error("mcore_read_buffer: DEPTH does not fit in a ticket tag");
endmodule
