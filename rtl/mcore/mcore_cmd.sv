`timescale 1ns/1ps

// Command Processor (spec sections 3, 36-41 and 48.1).
//
// Structurally beside the Fetch -> Compute -> Writeback dataflow: it owns the
// PC, the 16x32 signed integer RF, loop/branch control, issue-side stream
// state, command expansion and hazard checking. Bulk matrix data never flows
// through this block.
//
// Program memory is read combinationally: prog_data must reflect prog_addr in
// the same cycle. Instructions are 64 bits; SetStream is four words.
//
// v0.1 issue rules and documented simplifications:
//   * a stage-targeted command is issued when every stage queue it needs can
//     accept its part, so multi-stage dispatch is atomic (section 3.2),
//   * BroadcastMAC and MultiMAC consume their whole configured stream, which
//     matches the functional reference; the CP marks those streams exhausted,
//   * memory hazards are handled conservatively (CONSERVATIVE_MEM_HAZARD):
//     a Fetch-bearing command waits for Writeback to be idle and a Writeback
//     waits for Fetch to be idle. Address-range tracking replaces this later.
module mcore_cmd
    import mcore_pkg::*;
#(
    parameter bit CONSERVATIVE_MEM_HAZARD = 1
) (
    input  logic clk,
    input  logic reset,

    input  logic start,
    output logic done,
    // Sticky illegal-program indication (section 40.1). Response policy is TBD;
    // v0.1 only reports.
    output logic error,

    // Combinational program memory read port.
    output logic [PROG_ADDR_WIDTH-1:0] prog_addr,
    input  instr_t                     prog_data,

    // Stage command ports (section 50).
    output logic         fetch_cmd_valid,
    input  logic         fetch_cmd_ready,
    output fetch_cmd_t   fetch_cmd,

    output logic         compute_cmd_valid,
    input  logic         compute_cmd_ready,
    output compute_cmd_t compute_cmd,

    output logic           writeback_cmd_valid,
    input  logic           writeback_cmd_ready,
    output writeback_cmd_t writeback_cmd,

    // Drain status for the halt/done rule (section 3.9).
    input  logic fetch_idle,
    input  logic compute_idle,
    input  logic writeback_idle
);
    typedef enum logic [2:0] {
        CP_IDLE      = 3'd0,
        CP_RUN       = 3'd1,
        CP_STREAM_W1 = 3'd2,
        CP_STREAM_W2 = 3'd3,
        CP_STREAM_W3 = 3'd4,
        CP_SKIP_LOOP = 3'd5,
        CP_DRAIN     = 3'd6
    } cp_state_e;

    cp_state_e state;
    cp_state_e next_state;

    logic [PROG_ADDR_WIDTH-1:0] pc;
    logic signed [INT_WIDTH-1:0] int_rf [INT_REGISTERS];

    stream_desc_t                stream_desc  [STREAM_SLOTS];
    logic signed [INT_WIDTH-1:0] inner_cursor [STREAM_SLOTS];
    logic signed [INT_WIDTH-1:0] outer_cursor [STREAM_SLOTS];

    logic signed [INT_WIDTH-1:0] loop_remaining [LOOP_STACK_DEPTH];
    logic [PROG_ADDR_WIDTH-1:0]  loop_body_pc   [LOOP_STACK_DEPTH];
    logic [$clog2(LOOP_STACK_DEPTH+1)-1:0] loop_sp;

    // Nesting depth while skipping the body of a zero/nonpositive loop.
    logic [$clog2(LOOP_STACK_DEPTH+1)-1:0] skip_depth;

    // SetStream staging: word 0 is latched, words 1..3 supply the values.
    logic [STREAM_ID_WIDTH-1:0] ss_id;
    mem_domain_e                ss_domain;
    layout_e                    ss_layout;
    logic [MEM_ADDR_WIDTH-1:0]  ss_base_row;
    logic                       ss_has_outer_stride;
    logic [4:0]                 ss_reg_select;
    logic signed [INT_WIDTH-1:0] ss_offset;
    logic signed [INT_WIDTH-1:0] ss_inner_count;
    logic signed [INT_WIDTH-1:0] ss_outer_count;
    logic signed [INT_WIDTH-1:0] ss_inner_stride;

    logic error_q;

    assign prog_addr = pc;
    assign error     = error_q;

    // ------------------------------------------------------------------
    // Decode
    // ------------------------------------------------------------------
    opcode_e                            opcode;
    logic [3:0]                         rd;
    logic [3:0]                         rs;
    logic [STREAM_ID_WIDTH-1:0]         sid_a;
    logic [STREAM_ID_WIDTH-1:0]         sid_b;
    logic [VALID_COLUMNS_WIDTH-1:0]     valid_columns;
    logic [ACC_SELECT_WIDTH-1:0]        acc_index;
    logic signed [INT_WIDTH-1:0]        imm_value;
    logic signed [BRANCH_OFFSET_WIDTH-1:0] branch_offset;

    assign opcode        = instr_opcode(prog_data);
    assign rd            = instr_rd(prog_data);
    assign rs            = instr_rs(prog_data);
    assign sid_a         = instr_stream_a(prog_data);
    assign sid_b         = instr_stream_b(prog_data);
    assign valid_columns = instr_valid_columns(prog_data);
    assign acc_index     = instr_acc_index(prog_data);
    assign branch_offset = instr_branch_offset(prog_data);
    // Section 35: an IntValue field is a literal or a register read.
    assign imm_value     = instr_imm_is_reg(prog_data)
                               ? int_rf[instr_imm(prog_data)[3:0]]
                               : instr_imm(prog_data);

    // Issue-side stream views captured at dispatch (section 3.6).
    stream_view_t view_a;
    stream_view_t view_b;

    always_comb begin
        view_a.desc         = stream_desc[sid_a];
        view_a.inner_cursor = inner_cursor[sid_a];
        view_a.outer_cursor = outer_cursor[sid_a];
        view_b.desc         = stream_desc[sid_b];
        view_b.inner_cursor = inner_cursor[sid_b];
        view_b.outer_cursor = outer_cursor[sid_b];
    end

    // Number of 128-bit lines a writeback of valid_columns values emits.
    logic [3:0] writeback_lines;
    assign writeback_lines = 4'((valid_columns + BF16_PER_LINE - 1) / BF16_PER_LINE);

    // ------------------------------------------------------------------
    // Command expansion and issue
    // ------------------------------------------------------------------
    logic need_fetch;
    logic need_compute;
    logic need_writeback;
    logic hazard_stall;
    logic issue_ok;
    logic executing;    // this cycle retires the instruction at pc
    logic decode_error;

    always_comb begin
        need_fetch     = 1'b0;
        need_compute   = 1'b0;
        need_writeback = 1'b0;
        fetch_cmd      = '0;
        compute_cmd    = '0;
        writeback_cmd  = '0;
        decode_error   = 1'b0;

        if (state == CP_RUN) begin
            case (opcode)
                OP_RESET_ACCUMULATORS: begin
                    need_compute            = 1'b1;
                    compute_cmd.op          = COMPUTE_RESET_ACC;
                end
                OP_LOAD_ACCUMULATORS: begin
                    need_fetch                    = 1'b1;
                    need_compute                  = 1'b1;
                    fetch_cmd.op                  = FETCH_ACC_SEED;
                    fetch_cmd.stream_a            = view_a;
                    fetch_cmd.accumulator_index   = acc_index;
                    compute_cmd.op                = COMPUTE_LOAD_ACC;
                    compute_cmd.accumulator_index = acc_index;
                    decode_error                  = !stream_desc[sid_a].valid ||
                        (stream_desc[sid_a].layout != LAYOUT_ROW_MAJOR_FP32) ||
                        (stream_desc[sid_a].domain != DOMAIN_LOMEM);
                end
                OP_BROADCAST_MAC: begin
                    need_fetch                = 1'b1;
                    need_compute              = 1'b1;
                    fetch_cmd.op              = FETCH_BROADCAST;
                    fetch_cmd.stream_a        = view_a;
                    fetch_cmd.stream_b        = view_b;
                    fetch_cmd.valid_columns   = valid_columns;
                    compute_cmd.op            = COMPUTE_BROADCAST;
                    compute_cmd.valid_columns = valid_columns;
                    decode_error              = !stream_desc[sid_a].valid ||
                        !stream_desc[sid_b].valid ||
                        (valid_columns == '0) ||
                        (valid_columns > VALID_COLUMNS_WIDTH'(TOTAL_ACCUMULATORS)) ||
                        (stream_desc[sid_b].domain != DOMAIN_LOMEM) ||
                        ((stream_desc[sid_b].layout != LAYOUT_MATMUL_B) &&
                         (stream_desc[sid_b].layout != LAYOUT_MATMUL_B_INT8));
                end
                OP_MULTI_MAC: begin
                    need_fetch                = 1'b1;
                    need_compute              = 1'b1;
                    fetch_cmd.op              = FETCH_MULTI;
                    fetch_cmd.stream_a        = view_a;
                    fetch_cmd.stream_b        = view_b;
                    fetch_cmd.valid_columns   = valid_columns;
                    compute_cmd.op            = COMPUTE_MULTI;
                    compute_cmd.valid_columns = valid_columns;
                    decode_error              = !stream_desc[sid_a].valid ||
                        !stream_desc[sid_b].valid || (valid_columns == '0) ||
                        (valid_columns > VALID_COLUMNS_WIDTH'(TOTAL_MULTIPLIERS));
                end
                OP_WRITE_ACCUMULATORS: begin
                    need_compute              = 1'b1;
                    need_writeback            = 1'b1;
                    compute_cmd.op            = COMPUTE_BROADCAST;
                    compute_cmd.snapshot      = 1'b1;
                    compute_cmd.valid_columns = valid_columns;
                    writeback_cmd.stream        = view_a;
                    writeback_cmd.valid_columns = valid_columns;
                    decode_error              = !stream_desc[sid_a].valid ||
                        (valid_columns == '0) ||
                        (valid_columns > VALID_COLUMNS_WIDTH'(TOTAL_ACCUMULATORS)) ||
                        (stream_desc[sid_a].layout != LAYOUT_ROW_MAJOR);
                end
                OP_SET_STREAM: begin
                    decode_error = 1'b0;
                end
                OP_END_LOOP: begin
                    decode_error = (loop_sp == '0);
                end
                default: begin
                    decode_error = 1'b0;
                end
            endcase
        end
    end

    // Conservative memory ordering until address-range tracking exists.
    assign hazard_stall = CONSERVATIVE_MEM_HAZARD &&
                          ((need_fetch && !writeback_idle) ||
                           (need_writeback && !fetch_idle));

    assign fetch_cmd_valid     = need_fetch     && !hazard_stall;
    assign compute_cmd_valid   = need_compute   && !hazard_stall;
    assign writeback_cmd_valid = need_writeback && !hazard_stall;

    // Atomic dispatch: advance only when every required queue accepts.
    assign issue_ok = !hazard_stall &&
                      (!need_fetch     || fetch_cmd_ready) &&
                      (!need_compute   || compute_cmd_ready) &&
                      (!need_writeback || writeback_cmd_ready);

    assign executing = (state == CP_RUN) && issue_ok;

    // ------------------------------------------------------------------
    // Branch/loop resolution
    // ------------------------------------------------------------------
    logic branch_taken;
    logic [PROG_ADDR_WIDTH-1:0] sequential_pc;
    logic [PROG_ADDR_WIDTH-1:0] branch_pc;

    assign sequential_pc = pc + 1'b1;
    // Section 39: the taken target is relative to the incremented PC.
    assign branch_pc     = sequential_pc +
                           PROG_ADDR_WIDTH'(branch_offset);

    always_comb begin
        branch_taken = 1'b0;
        if (opcode == OP_BRANCH_IF_LESS) begin
            branch_taken = (int_rf[rs] < imm_value);
        end else if (opcode == OP_BRANCH_IF_GREATER_EQ) begin
            branch_taken = (int_rf[rs] >= imm_value);
        end
    end

    // ------------------------------------------------------------------
    // Halt / drain
    // ------------------------------------------------------------------
    assign done = (state == CP_DRAIN) && fetch_idle && compute_idle && writeback_idle;

    always_comb begin
        next_state = state;
        case (state)
            CP_IDLE:      if (start) next_state = CP_RUN;
            CP_RUN: begin
                if (issue_ok) begin
                    case (opcode)
                        OP_SET_STREAM: next_state = CP_STREAM_W1;
                        OP_LOOP:       if (imm_value <= 0) next_state = CP_SKIP_LOOP;
                        OP_HALT:       next_state = CP_DRAIN;
                        default:       next_state = CP_RUN;
                    endcase
                end
            end
            CP_STREAM_W1: next_state = CP_STREAM_W2;
            CP_STREAM_W2: next_state = CP_STREAM_W3;
            CP_STREAM_W3: next_state = CP_RUN;
            CP_SKIP_LOOP: begin
                if ((opcode == OP_END_LOOP) && (skip_depth == 1)) begin
                    next_state = CP_RUN;
                end
            end
            // done stays asserted until start is deasserted, so a held start
            // cannot silently restart the program.
            CP_DRAIN:     if (done && !start) next_state = CP_IDLE;
            default:      next_state = CP_IDLE;
        endcase
    end

    // ------------------------------------------------------------------
    // Sequential state
    // ------------------------------------------------------------------
    logic signed [INT_WIDTH-1:0] derived_outer_stride;
    assign derived_outer_stride = ss_inner_count * ss_inner_stride;

    always_ff @(posedge clk) begin
        if (reset) begin
            state      <= CP_IDLE;
            pc         <= '0;
            loop_sp    <= '0;
            skip_depth <= '0;
            error_q    <= 1'b0;
            for (int unsigned r = 0; r < INT_REGISTERS; r++) begin
                int_rf[r] <= '0;
            end
            for (int unsigned s = 0; s < STREAM_SLOTS; s++) begin
                stream_desc[s]  <= '0;
                inner_cursor[s] <= '0;
                outer_cursor[s] <= '0;
            end
            for (int unsigned l = 0; l < LOOP_STACK_DEPTH; l++) begin
                loop_remaining[l] <= '0;
                loop_body_pc[l]   <= '0;
            end
        end else begin
            state <= next_state;

            if (state == CP_IDLE && start) begin
                // Section 3.8 program start.
                pc      <= '0;
                loop_sp <= '0;
                error_q <= 1'b0;
                for (int unsigned s = 0; s < STREAM_SLOTS; s++) begin
                    stream_desc[s].valid <= 1'b0;
                    inner_cursor[s]      <= '0;
                    outer_cursor[s]      <= '0;
                end
            end

            if (state == CP_RUN && issue_ok) begin
                error_q <= error_q | decode_error;

                case (opcode)
                    OP_LOAD_IMM: begin
                        int_rf[rd] <= instr_imm(prog_data);
                        pc         <= sequential_pc;
                    end
                    OP_ADD_IMM: begin
                        // Section 34: signed add, wrap modulo 2^32.
                        int_rf[rd] <= int_rf[rs] + instr_imm(prog_data);
                        pc         <= sequential_pc;
                    end
                    OP_BRANCH_IF_LESS,
                    OP_BRANCH_IF_GREATER_EQ: begin
                        pc <= branch_taken ? branch_pc : sequential_pc;
                    end
                    OP_LOOP: begin
                        pc <= sequential_pc;
                        if (imm_value > 0) begin
                            if (loop_sp == $bits(loop_sp)'(LOOP_STACK_DEPTH)) begin
                                error_q <= 1'b1;
                            end else begin
                                loop_remaining[loop_sp] <= imm_value;
                                loop_body_pc[loop_sp]   <= sequential_pc;
                                loop_sp                 <= loop_sp + 1'b1;
                            end
                        end else begin
                            // Skip to the instruction after the matching EndLoop.
                            skip_depth <= 1;
                        end
                    end
                    OP_END_LOOP: begin
                        if (loop_sp == '0) begin
                            error_q <= 1'b1;
                            pc      <= sequential_pc;
                        end else if (loop_remaining[loop_sp - 1'b1] > 1) begin
                            loop_remaining[loop_sp - 1'b1] <=
                                loop_remaining[loop_sp - 1'b1] - 1'b1;
                            pc <= loop_body_pc[loop_sp - 1'b1];
                        end else begin
                            loop_sp <= loop_sp - 1'b1;
                            pc      <= sequential_pc;
                        end
                    end
                    OP_SET_STREAM: begin
                        ss_id               <= setstream_id(prog_data);
                        ss_domain           <= setstream_domain(prog_data);
                        ss_layout           <= setstream_layout(prog_data);
                        ss_base_row         <= setstream_base_row(prog_data);
                        ss_has_outer_stride <= setstream_has_outer_stride(prog_data);
                        ss_reg_select       <= setstream_reg_select(prog_data);
                        pc                  <= sequential_pc;
                    end
                    OP_LOAD_ACCUMULATORS: begin
                        // One stream access (section 29).
                        inner_cursor[sid_a] <= stream_advance(view_a, 4'd1).inner_cursor;
                        outer_cursor[sid_a] <= stream_advance(view_a, 4'd1).outer_cursor;
                        pc                  <= sequential_pc;
                    end
                    OP_BROADCAST_MAC,
                    OP_MULTI_MAC: begin
                        // These consume the whole configured stream.
                        inner_cursor[sid_a] <= stream_exhaust(view_a).inner_cursor;
                        outer_cursor[sid_a] <= stream_exhaust(view_a).outer_cursor;
                        inner_cursor[sid_b] <= stream_exhaust(view_b).inner_cursor;
                        outer_cursor[sid_b] <= stream_exhaust(view_b).outer_cursor;
                        pc                  <= sequential_pc;
                    end
                    OP_WRITE_ACCUMULATORS: begin
                        inner_cursor[sid_a] <=
                            stream_advance(view_a, writeback_lines).inner_cursor;
                        outer_cursor[sid_a] <=
                            stream_advance(view_a, writeback_lines).outer_cursor;
                        pc <= sequential_pc;
                    end
                    OP_HALT: begin
                        pc <= pc;
                    end
                    default: begin
                        pc <= sequential_pc;
                    end
                endcase
            end

            // SetStream payload words.
            if (state == CP_STREAM_W1) begin
                ss_offset <= setstream_reg_select_bit(ss_reg_select, 4)
                                 ? int_rf[instr_high_word(prog_data)[3:0]]
                                 : instr_high_word(prog_data);
                ss_inner_count <= setstream_reg_select_bit(ss_reg_select, 3)
                                 ? int_rf[instr_low_word(prog_data)[3:0]]
                                 : instr_low_word(prog_data);
                pc <= pc + 1'b1;
            end
            if (state == CP_STREAM_W2) begin
                ss_outer_count <= setstream_reg_select_bit(ss_reg_select, 2)
                                 ? int_rf[instr_high_word(prog_data)[3:0]]
                                 : instr_high_word(prog_data);
                ss_inner_stride <= setstream_reg_select_bit(ss_reg_select, 1)
                                 ? int_rf[instr_low_word(prog_data)[3:0]]
                                 : instr_low_word(prog_data);
                pc <= pc + 1'b1;
            end
            if (state == CP_STREAM_W3) begin
                stream_desc[ss_id].valid        <= 1'b1;
                stream_desc[ss_id].domain       <= ss_domain;
                stream_desc[ss_id].layout       <= ss_layout;
                stream_desc[ss_id].base_row     <= ss_base_row;
                stream_desc[ss_id].offset       <= ss_offset;
                stream_desc[ss_id].inner_count  <= ss_inner_count;
                stream_desc[ss_id].outer_count  <= ss_outer_count;
                stream_desc[ss_id].inner_stride <= ss_inner_stride;
                stream_desc[ss_id].outer_stride <= ss_has_outer_stride
                    ? (setstream_reg_select_bit(ss_reg_select, 0)
                           ? int_rf[instr_high_word(prog_data)[3:0]]
                           : instr_high_word(prog_data))
                    : derived_outer_stride;
                inner_cursor[ss_id] <= '0;
                outer_cursor[ss_id] <= '0;
                // Section 40.1: counts must be positive.
                if ((ss_inner_count <= 0) || (ss_outer_count <= 0)) begin
                    error_q <= 1'b1;
                end
                pc <= pc + 1'b1;
            end

            // Skipping a zero/nonpositive loop body: track nesting.
            if (state == CP_SKIP_LOOP) begin
                if (opcode == OP_SET_STREAM) begin
                    // Step over the three payload words so they are never
                    // decoded as instructions.
                    pc <= pc + PROG_ADDR_WIDTH'(SETSTREAM_WORDS);
                end else begin
                    pc <= pc + 1'b1;
                    if (opcode == OP_LOOP) begin
                        skip_depth <= skip_depth + 1'b1;
                    end else if (opcode == OP_END_LOOP) begin
                        skip_depth <= skip_depth - 1'b1;
                    end
                end
            end
        end
    end
endmodule
