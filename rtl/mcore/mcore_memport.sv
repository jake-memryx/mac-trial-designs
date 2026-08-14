`timescale 1ns/1ps

// One memory domain port shared by two requesters.
//
// Fetch reads operands; Writeback stores results and reads scale rows. Both are
// tagged, and this module turns a requester tag into the ticket the memory
// echoes back (matrix_core.md section 13):
//
//   ticket = {source, tag}      source 0 = Fetch, 1 = Writeback
//
// Responses are routed by the source bit, so reads may complete out of order
// without either requester having to track arrival order. Fetch wins the
// request arbitration; it cannot starve Writeback because Fetch requests are
// bounded by its prefetch buffer credits.
//
// `quiet` reports that no read is outstanding, which the drain rule needs.
// Writes are posted, so they are accounted complete when accepted.
module mcore_memport
    import mcore_pkg::*;
#(
    parameter int unsigned WIDTH = LOMEM_WIDTH,
    parameter int unsigned LANES = LOMEM_LANES
) (
    input  logic                     clk,
    input  logic                     reset,
    input  logic                     fetch_req_valid,
    output logic                     fetch_req_ready,
    input  logic [MEM_ROW_WIDTH-1:0] fetch_req_row,
    input  logic [TAG_WIDTH-1:0]     fetch_req_tag,
    output logic                     fetch_rsp_valid,
    output logic [TAG_WIDTH-1:0]     fetch_rsp_tag,
    output logic [WIDTH-1:0]         fetch_rsp_data,
    input  logic                     wb_req_valid,
    output logic                     wb_req_ready,
    input  logic                     wb_req_write,
    input  logic [MEM_ROW_WIDTH-1:0] wb_req_row,
    input  logic [TAG_WIDTH-1:0]     wb_req_tag,
    input  logic [WIDTH-1:0]         wb_req_wdata,
    input  logic [LANES-1:0]         wb_req_lane_en,
    output logic                     wb_rsp_valid,
    output logic [TAG_WIDTH-1:0]     wb_rsp_tag,
    output logic [WIDTH-1:0]         wb_rsp_data,
    output logic                     req_valid,
    input  logic                     req_ready,
    output logic                     req_write,
    output logic [MEM_ROW_WIDTH-1:0] req_row,
    output logic [TICKET_WIDTH-1:0]  req_ticket,
    output logic [WIDTH-1:0]         req_wdata,
    output logic [LANES-1:0]         req_lane_en,
    input  logic                     rsp_valid,
    input  logic [TICKET_WIDTH-1:0]  rsp_ticket,
    input  logic [WIDTH-1:0]         rsp_data,
    output logic                     quiet
);
    localparam int unsigned COUNT_BITS = $clog2(MEMORY_Q_DEPTH + 1);

    logic                  fetch_grant;
    logic [COUNT_BITS-1:0] outstanding;
    logic                  read_accepted;
    logic                  capacity_left;

    assign capacity_left = (outstanding < COUNT_BITS'(MEMORY_Q_DEPTH));

    // Fetch only ever reads, so it is gated by the outstanding-read capacity;
    // a Writeback store never is.
    assign fetch_grant = fetch_req_valid && capacity_left;

    assign req_valid   = fetch_grant || wb_req_valid;
    assign req_write   = !fetch_grant && wb_req_write;
    assign req_row     = fetch_grant ? fetch_req_row : wb_req_row;
    assign req_ticket  = fetch_grant ? {1'b0, fetch_req_tag}
                                     : {1'b1, wb_req_tag};
    assign req_wdata   = fetch_grant ? '0 : wb_req_wdata;
    assign req_lane_en = fetch_grant ? '0 : wb_req_lane_en;

    assign fetch_req_ready = fetch_grant && req_ready;
    assign wb_req_ready    = !fetch_grant && wb_req_valid && req_ready &&
                             (wb_req_write || capacity_left);

    assign fetch_rsp_valid = rsp_valid && (rsp_ticket[TICKET_WIDTH-1] == 1'b0);
    assign fetch_rsp_tag   = rsp_ticket[TAG_WIDTH-1:0];
    assign fetch_rsp_data  = rsp_data;
    assign wb_rsp_valid    = rsp_valid && (rsp_ticket[TICKET_WIDTH-1] == 1'b1);
    assign wb_rsp_tag      = rsp_ticket[TAG_WIDTH-1:0];
    assign wb_rsp_data     = rsp_data;

    assign read_accepted = req_valid && req_ready && !req_write;
    assign quiet         = (outstanding == '0);

    always_ff @(posedge clk) begin
        if (reset)
            outstanding <= '0;
        else if (read_accepted && !rsp_valid)
            outstanding <= outstanding + 1'b1;
        else if (!read_accepted && rsp_valid)
            outstanding <= outstanding - 1'b1;
    end
endmodule
