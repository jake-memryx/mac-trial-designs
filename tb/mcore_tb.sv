`timescale 1ns/1ps

// Self-checking Matrix Core testbench.
//
// The core is driven exactly as it would be in a system: a combinationally read
// program memory, two behavioral memories on the LoMem and CoMem ports, and a
// start pulse. Everything is checked from the outside - program-visible memory
// contents, `done` and `error` - rather than by peeking at internal state, so
// the tests constrain behavior and not implementation.
//
// Arithmetic expectations are computed in `real` and compared with a relative
// tolerance, because the datapath rounds to BF16 at the Compute->WB snapshot.
// Stimulus values are chosen to be exactly representable in BF16 so the only
// error is the one the architecture prescribes.
module mcore_tb
    import mcore_pkg::*;
    import mcore_prog_pkg::*;
();
    localparam int unsigned MEM_ROWS      = 1024;
    localparam int unsigned READ_LATENCY  = 3;
    localparam real         TOLERANCE     = 0.02;

    logic clk = 1'b0;
    logic reset;
    logic flush;
    logic start;
    logic done;
    logic error;
    logic structural_stall, dependency_stall;

    logic [PROG_ADDR_WIDTH-1:0] prog_addr;
    instr_t                     prog_data;
    instr_t                     program_memory [0:(1<<PROG_ADDR_WIDTH)-1];

    logic                     lomem_req_valid, lomem_req_ready, lomem_req_write;
    logic [MEM_ROW_WIDTH-1:0] lomem_req_row;
    logic [TICKET_WIDTH-1:0]  lomem_req_ticket;
    logic [LOMEM_WIDTH-1:0]   lomem_req_wdata;
    logic [LOMEM_LANES-1:0]   lomem_req_lane_en;
    logic                     lomem_rsp_valid;
    logic [TICKET_WIDTH-1:0]  lomem_rsp_ticket;
    logic [LOMEM_WIDTH-1:0]   lomem_rsp_data;

    logic                     comem_req_valid, comem_req_ready, comem_req_write;
    logic [MEM_ROW_WIDTH-1:0] comem_req_row;
    logic [TICKET_WIDTH-1:0]  comem_req_ticket;
    logic [COMEM_WIDTH-1:0]   comem_req_wdata;
    logic                     comem_rsp_valid;
    logic [TICKET_WIDTH-1:0]  comem_rsp_ticket;
    logic [COMEM_WIDTH-1:0]   comem_rsp_data;

    int unsigned errors = 0;
    int unsigned checks = 0;
    int unsigned pc_cursor;

    assign prog_data = program_memory[prog_addr];

    always #5 clk = ~clk;

    mcore dut (
        .clk               (clk),
        .reset             (reset),
        .flush             (flush),
        .start             (start),
        .done              (done),
        .error             (error),
        .prog_addr         (prog_addr),
        .prog_data         (prog_data),
        .lomem_req_valid   (lomem_req_valid),
        .lomem_req_ready   (lomem_req_ready),
        .lomem_req_write   (lomem_req_write),
        .lomem_req_row     (lomem_req_row),
        .lomem_req_ticket  (lomem_req_ticket),
        .lomem_req_wdata   (lomem_req_wdata),
        .lomem_req_lane_en (lomem_req_lane_en),
        .lomem_rsp_valid   (lomem_rsp_valid),
        .lomem_rsp_ticket  (lomem_rsp_ticket),
        .lomem_rsp_data    (lomem_rsp_data),
        .comem_req_valid   (comem_req_valid),
        .comem_req_ready   (comem_req_ready),
        .comem_req_write   (comem_req_write),
        .comem_req_row     (comem_req_row),
        .comem_req_ticket  (comem_req_ticket),
        .comem_req_wdata   (comem_req_wdata),
        .comem_rsp_valid   (comem_rsp_valid),
        .comem_rsp_ticket  (comem_rsp_ticket),
        .comem_rsp_data    (comem_rsp_data),
        .structural_stall  (structural_stall),
        .dependency_stall  (dependency_stall)
    );

    mcore_mem_model #(
        .WIDTH           (LOMEM_WIDTH),
        .ROWS            (MEM_ROWS),
        .LANES           (LOMEM_LANES),
        .TICKET_W        (TICKET_WIDTH),
        .ROW_W           (MEM_ROW_WIDTH),
        .READ_LATENCY    (READ_LATENCY),
        .MAX_OUTSTANDING (MEMORY_Q_DEPTH)
    ) lomem (
        .clk         (clk),
        .reset       (reset),
        .req_valid   (lomem_req_valid),
        .req_ready   (lomem_req_ready),
        .req_write   (lomem_req_write),
        .req_row     (lomem_req_row),
        .req_ticket  (lomem_req_ticket),
        .req_wdata   (lomem_req_wdata),
        .req_lane_en (lomem_req_lane_en),
        .rsp_valid   (lomem_rsp_valid),
        .rsp_ticket  (lomem_rsp_ticket),
        .rsp_data    (lomem_rsp_data)
    );

    mcore_mem_model #(
        .WIDTH           (COMEM_WIDTH),
        .ROWS            (MEM_ROWS),
        .LANES           (1),
        .TICKET_W        (TICKET_WIDTH),
        .ROW_W           (MEM_ROW_WIDTH),
        .READ_LATENCY    (READ_LATENCY),
        .MAX_OUTSTANDING (MEMORY_Q_DEPTH)
    ) comem (
        .clk         (clk),
        .reset       (reset),
        .req_valid   (comem_req_valid),
        .req_ready   (comem_req_ready),
        .req_write   (comem_req_write),
        .req_row     (comem_req_row),
        .req_ticket  (comem_req_ticket),
        .req_wdata   (comem_req_wdata),
        .req_lane_en (1'b1),
        .rsp_valid   (comem_rsp_valid),
        .rsp_ticket  (comem_rsp_ticket),
        .rsp_data    (comem_rsp_data)
    );

    // ------------------------------------------------------------- utilities
    task automatic check(input logic condition, input string message);
        checks++;
        if (!condition) begin
            errors++;
            $display("FAIL: %s", message);
        end
    endtask

    task automatic check_close(input real got, input real want,
                               input string message);
        real tolerance;
        checks++;
        tolerance = (want >= 0.0 ? want : -want) * TOLERANCE;
        if (tolerance < 1.0e-6)
            tolerance = 1.0e-6;
        if ((got - want > tolerance) || (want - got > tolerance)) begin
            errors++;
            $display("FAIL: %s (got %f, want %f)", message, got, want);
        end
    endtask

    task automatic clear_program();
        for (int unsigned w = 0; w < (1<<PROG_ADDR_WIDTH); w++)
            program_memory[w] = asm_halt();
        pc_cursor = 0;
    endtask

    task automatic emit(input instr_t instruction);
        program_memory[pc_cursor] = instruction;
        pc_cursor++;
    endtask

    task automatic emit_stream(input int unsigned id, input mem_domain_e domain,
                               input layout_e layout, input int unsigned base_row,
                               input int offset, input int inner_count,
                               input int outer_count, input int inner_stride);
        instr_t words [SETSTREAM_WORDS];
        asm_set_stream(words, id, domain, layout, base_row, offset, inner_count,
                       outer_count, inner_stride, 1'b0, 0, 5'b0);
        for (int unsigned w = 0; w < SETSTREAM_WORDS; w++)
            emit(words[w]);
    endtask

    // +trace prints every stage dispatch and completion, which is how a
    // sequencing or drain problem is localized.
    logic trace_enabled = 1'b0;

    always @(posedge clk) begin
        if (trace_enabled) begin
            if (dut.fetch_cmd_valid && dut.fetch_cmd_ready)
                $display("%0t  issue fetch   seq=%0d op=%0d count=%0d", $time,
                         dut.fetch_cmd.seq, int'(dut.fetch_cmd.op),
                         dut.fetch_cmd.count);
            if (dut.compute_cmd_valid && dut.compute_cmd_ready)
                $display("%0t  issue compute seq=%0d op=%0d count=%0d", $time,
                         dut.compute_cmd.seq, int'(dut.compute_cmd.op),
                         dut.compute_cmd.count);
            if (dut.wb_cmd_valid && dut.wb_cmd_ready)
                $display("%0t  issue wb      seq=%0d op=%0d count=%0d", $time,
                         dut.wb_cmd.seq, int'(dut.wb_cmd.op), dut.wb_cmd.count);
            if (dut.fetch_done_valid)
                $display("%0t  done  fetch   seq=%0d", $time, dut.fetch_done_seq);
            if (dut.wb_done_valid)
                $display("%0t  done  wb      seq=%0d", $time, dut.wb_done_seq);
        end
    end

    // Printed when a program fails to drain, which is otherwise very hard to
    // diagnose from the outside.
    task automatic dump_state(input string label);
        $display("  %s: cmd_state=%0d pc=%0d res_valid=%b fetch=%0d(idle=%0b) compute=%0d(idle=%0b) wb=%0d(idle=%0b) quiet=%0b%0b stalls=%0b%0b",
                 label, int'(dut.command_stage.state), dut.prog_addr,
                 dut.command_stage.res_valid,
                 int'(dut.fetch_stage.state), dut.fetch_idle,
                 int'(dut.compute_stage.state), dut.compute_idle,
                 int'(dut.writeback_stage.state_q), dut.wb_idle,
                 dut.lomem_quiet, dut.comem_quiet,
                 structural_stall, dependency_stall);
    endtask

    task automatic reset_core();
        reset = 1'b1;
        flush = 1'b0;
        start = 1'b0;
        repeat (4) @(posedge clk);
        reset = 1'b0;
        @(posedge clk);
    endtask

    // Runs the loaded program to completion. A program always ends in halt, so
    // done is the drain-complete indication of section 19.
    task automatic run_program(input int unsigned max_cycles = 20000);
        int unsigned cycles;
        cycles = 0;
        start  = 1'b1;
        @(posedge clk);
        start = 1'b0;
        while (!done && (cycles < max_cycles)) begin
            @(posedge clk);
            cycles++;
        end
        if (!done) begin
            errors++;
            $display("FAIL: program did not complete in %0d cycles", max_cycles);
            dump_state("stuck");
        end
        @(posedge clk);
    endtask

    // ------------------------------------------------------- data packing
    function automatic logic [LINE_WIDTH-1:0] pack_line(
            input logic [15:0] values [0:BF16_PER_LINE-1]);
        logic [LINE_WIDTH-1:0] line;
        line = '0;
        for (int unsigned e = 0; e < BF16_PER_LINE; e++)
            line[e*16 +: 16] = values[e];
        return line;
    endfunction

    function automatic logic [15:0] line_value(
            input logic [LINE_WIDTH-1:0] line, input int unsigned index);
        return line[index*16 +: 16];
    endfunction

    // The 128-bit line at logical index q of a row-major LoMem stream.
    function automatic logic [LINE_WIDTH-1:0] lomem_line(
            input int unsigned base_row, input int unsigned q);
        logic [LOMEM_WIDTH-1:0] row;
        row = lomem.read_row(int'(base_row + (q / LOMEM_LANES)));
        return row[(q % LOMEM_LANES)*LINE_WIDTH +: LINE_WIDTH];
    endfunction

    task automatic write_lomem_line(input int unsigned base_row,
                                    input int unsigned q,
                                    input logic [LINE_WIDTH-1:0] line);
        logic [LOMEM_WIDTH-1:0] row;
        row = lomem.read_row(int'(base_row + (q / LOMEM_LANES)));
        row[(q % LOMEM_LANES)*LINE_WIDTH +: LINE_WIDTH] = line;
        lomem.write_row(int'(base_row + (q / LOMEM_LANES)), row);
    endtask

    // ------------------------------------------------------- control tests
    localparam int unsigned OUT_ROW   = 100;
    localparam int unsigned PRELOAD_ROW = 200;
    localparam int unsigned A_ROW     = 300;
    localparam int unsigned B_ROW     = 310;
    localparam int unsigned SCALE_ROW = 400;
    localparam int unsigned CO_ROW    = 40;

    // Stream 0 is the standard output stream: eight row-major LoMem lines, which
    // covers a full 64-value snapshot.
    task automatic emit_out_stream();
        emit_stream(0, DOMAIN_LOMEM, LAYOUT_ROW_MAJOR, OUT_ROW, 0, 8, 1, 1);
    endtask

    task automatic clear_out_rows();
        for (int unsigned r = 0; r < 4; r++)
            lomem.write_row(int'(OUT_ROW + r), '1);
    endtask

    task automatic test_reset_state();
        reset_core();
        check(prog_addr == '0, "reset: PC is zero");
        check(!done, "reset: not done");
        check(!error, "reset: no error");
    endtask

    // li and addi are signed 32-bit with wraparound, and a loop body runs its
    // trip count exactly once per iteration.
    task automatic test_registers_and_loops();
        reset_core();
        clear_program();
        emit(asm_li(1, 32'h7fffffff));
        emit(asm_addi(1, 1, 1));
        emit(asm_li(2, 0));
        emit(asm_loop_imm(3));
        emit(asm_loop_imm(2));
        emit(asm_addi(2, 2, 1));
        emit(asm_endloop());
        emit(asm_endloop());
        emit(asm_li(3, 4));
        emit(asm_loop_reg(3));
        emit(asm_addi(2, 2, 10));
        emit(asm_endloop());
        emit(asm_halt());
        run_program();
        check(!error, "loops: no error");
        check(dut.command_stage.int_rf[1] == 32'sh80000000,
              "li/addi: int32 wraparound");
        check(dut.command_stage.int_rf[2] == 32'sd46,
              "loops: 3*2 + 4*10 iterations");
        check(dut.command_stage.loop_sp == '0, "loops: stack unwound");
    endtask

    // A zero-count loop steps over its body without decoding it, including the
    // four payload words of a set_stream.
    task automatic test_zero_count_loop();
        reset_core();
        clear_program();
        emit(asm_li(4, 0));
        emit(asm_loop_imm(0));
        emit_stream(1, DOMAIN_COMEM, LAYOUT_ROW_MAJOR, 7, 0, 1, 1, 1);
        emit(asm_addi(4, 4, 1));
        emit(asm_loop_imm(2));
        emit(asm_addi(4, 4, 1));
        emit(asm_endloop());
        emit(asm_endloop());
        emit(asm_halt());
        run_program();
        check(!error, "zero loop: no error");
        check(dut.command_stage.int_rf[4] == '0, "zero loop: body skipped");
        check(!dut.command_stage.stream_desc[1].valid,
              "zero loop: set_stream payload not decoded");
    endtask

    // Branches and jump are relative to the sequential PC.
    task automatic test_branches();
        reset_core();
        clear_program();
        emit(asm_li(5, 0));
        emit(asm_addi(5, 5, 1));
        emit(asm_blt(5, 1'b0, 5, -2));
        emit(asm_li(6, 1));
        emit(asm_bge(5, 1'b0, 99, 2));
        emit(asm_addi(6, 6, 10));
        emit(asm_jump(1));
        emit(asm_addi(6, 6, 100));
        emit(asm_halt());
        run_program();
        check(!error, "branches: no error");
        check(dut.command_stage.int_rf[5] == 32'sd5, "blt: loops to the bound");
        check(dut.command_stage.int_rf[6] == 32'sd11,
              "bge not taken, jump skips one instruction");
    endtask

    task automatic test_illegal_endloop();
        reset_core();
        clear_program();
        emit(asm_endloop());
        emit(asm_halt());
        run_program();
        check(error, "endloop with an empty stack raises error");
    endtask

    task automatic test_uninitialized_register();
        reset_core();
        clear_program();
        emit(asm_addi(1, 7, 1));
        emit(asm_halt());
        run_program();
        check(error, "reading an uninitialized register raises error");
    endtask

    // ------------------------------------------------------ datapath tests
    // acc_reset clears all 64 accumulators, and write_accumulators zero-pads
    // whole lines, so the eight output lines must read back as BF16 zero.
    task automatic test_acc_reset_write();
        reset_core();
        clear_program();
        clear_out_rows();
        emit_out_stream();
        emit(asm_acc_reset());
        emit(asm_write_accumulators(0, 64));
        emit(asm_halt());
        run_program();
        check(!error, "acc_reset: no error");
        for (int unsigned q = 0; q < 8; q++)
            check(lomem_line(OUT_ROW, q) == '0,
                  $sformatf("acc_reset: output line %0d is zero", q));
    endtask

    // load_accumulators writes one FP32 line into accumulator idx of all four
    // lanes, which lands at global indices idx*4 .. idx*4+3.
    task automatic test_load_accumulators();
        logic [LOMEM_WIDTH-1:0] row;
        logic [LINE_WIDTH-1:0]  line;
        real                    preload [0:3];
        int unsigned            idx;
        idx        = 3;
        preload[0] = 1.5;
        preload[1] = -2.0;
        preload[2] = 3.25;
        preload[3] = 4.0;

        reset_core();
        clear_program();
        clear_out_rows();
        row = '0;
        for (int unsigned e = 0; e < FP32_PER_LINE; e++)
            row[e*32 +: 32] = real_to_fp32(preload[e]);
        lomem.write_row(PRELOAD_ROW, row);

        emit_out_stream();
        emit_stream(1, DOMAIN_LOMEM, LAYOUT_ROW_MAJOR_FP32, PRELOAD_ROW,
                    0, 1, 1, 1);
        emit(asm_acc_reset());
        emit(asm_load_accumulators(1, idx));
        emit(asm_write_accumulators(0, 64));
        emit(asm_halt());
        run_program();
        check(!error, "load_accumulators: no error");

        line = lomem_line(OUT_ROW, (idx*4) / BF16_PER_LINE);
        for (int unsigned l = 0; l < TREEMACS; l++)
            check_close(bf16_to_real(line_value(line,
                            ((idx*4 + l) % BF16_PER_LINE))),
                        preload[l],
                        $sformatf("load_accumulators: lane %0d", l));
        check(lomem_line(OUT_ROW, 0) == '0,
              "load_accumulators: other accumulators untouched");
    endtask

    // GEMV through broadcast_mac: one A row of Dk BF16 against a MATMUL_B tile,
    // producing valid_columns outputs. This checks the accumulator mapping, the
    // column-group ordering and the tail lane mask.
    task automatic run_broadcast_gemv(input int unsigned columns,
                                      input mem_domain_e a_domain);
        localparam int unsigned DK = 8;
        real                    a_values [0:DK-1];
        real                    b_values [0:DK-1][0:63];
        logic [15:0]            a_line [0:BF16_PER_LINE-1];
        logic [15:0]            column_line [0:BF16_PER_LINE-1];
        logic [LOMEM_WIDTH-1:0] b_row;
        real                    expected;
        int unsigned            groups;
        int unsigned            column;
        logic [LINE_WIDTH-1:0]  line;

        groups = (columns + 3) / 4;
        reset_core();
        clear_program();
        clear_out_rows();

        for (int unsigned k = 0; k < DK; k++) begin
            a_values[k] = real'(int'(k) - 3) * 0.5;
            a_line[k]   = real_to_bf16(a_values[k]);
        end
        for (int unsigned k = 0; k < DK; k++)
            for (int unsigned n = 0; n < columns; n++)
                b_values[k][n] = real'(int'((k + 2*n) % 7) - 3) * 0.25;

        // MATMUL_B: one output column per LoMem lane, one row per group.
        for (int unsigned s = 0; s < groups; s++) begin
            b_row = '0;
            for (int unsigned l = 0; l < LOMEM_LANES; l++) begin
                column = s*4 + l;
                for (int unsigned k = 0; k < BF16_PER_LINE; k++)
                    column_line[k] = (column < columns) ?
                        real_to_bf16(b_values[k][column]) : BF16_ZERO;
                b_row[l*LINE_WIDTH +: LINE_WIDTH] = pack_line(column_line);
            end
            lomem.write_row(int'(B_ROW + s), b_row);
        end

        if (a_domain == DOMAIN_LOMEM)
            write_lomem_line(A_ROW, 0, pack_line(a_line));
        else
            comem.write_row(CO_ROW, pack_line(a_line));

        emit_out_stream();
        if (a_domain == DOMAIN_LOMEM)
            emit_stream(1, DOMAIN_LOMEM, LAYOUT_ROW_MAJOR, A_ROW, 0, 1, 1, 1);
        else
            emit_stream(1, DOMAIN_COMEM, LAYOUT_ROW_MAJOR, CO_ROW, 0, 1, 1, 1);
        emit_stream(2, DOMAIN_LOMEM, LAYOUT_MATMUL_B, B_ROW, 0, int'(groups), 1, 1);
        emit(asm_acc_reset());
        emit(asm_broadcast_mac(1, 2, columns));
        emit(asm_write_accumulators(0, columns));
        emit(asm_halt());
        run_program();
        check(!error, "broadcast_mac: no error");

        for (int unsigned n = 0; n < columns; n++) begin
            expected = 0.0;
            for (int unsigned k = 0; k < DK; k++)
                expected = expected + a_values[k] * b_values[k][n];
            line = lomem_line(OUT_ROW, n / BF16_PER_LINE);
            check_close(bf16_to_real(line_value(line, n % BF16_PER_LINE)),
                        expected,
                        $sformatf("broadcast_mac columns=%0d domain=%0d out[%0d]",
                                  columns, a_domain, n));
        end
    endtask

    // MATMUL_B_INT8 packs two column groups into one physical row: the low eight
    // bytes of lane l are group 2p, the high eight bytes group 2p+1, and the
    // bytes are converted to BF16 before the multipliers. With an odd group
    // count the high half of the last row is never fetched.
    task automatic run_broadcast_gemv_int8(input int unsigned columns);
        localparam int unsigned DK = 8;
        real                    a_values [0:DK-1];
        int                     b_values [0:DK-1][0:63];
        logic [15:0]            a_line [0:BF16_PER_LINE-1];
        logic [LOMEM_WIDTH-1:0] b_row;
        real                    expected;
        int unsigned            groups;
        int unsigned            b_rows;
        int unsigned            column;
        int unsigned            half;
        logic [LINE_WIDTH-1:0]  line;

        groups = (columns + 3) / 4;
        b_rows = (groups + 1) / 2;
        reset_core();
        clear_program();
        clear_out_rows();

        for (int unsigned k = 0; k < DK; k++) begin
            a_values[k] = real'(int'(k) - 3) * 0.5;
            a_line[k]   = real_to_bf16(a_values[k]);
        end
        for (int unsigned k = 0; k < DK; k++)
            for (int unsigned n = 0; n < columns; n++)
                b_values[k][n] = (int'((k + 3*n) % 15)) - 7;

        for (int unsigned r = 0; r < b_rows; r++)
            lomem.write_row(int'(B_ROW + r), '0);
        for (int unsigned g = 0; g < groups; g++) begin
            half  = g % 2;
            b_row = lomem.read_row(int'(B_ROW + (g / 2)));
            for (int unsigned l = 0; l < LOMEM_LANES; l++) begin
                column = g*4 + l;
                for (int unsigned k = 0; k < BF16_PER_LINE; k++)
                    b_row[l*LINE_WIDTH + half*64 + k*8 +: 8] =
                        (column < columns) ?
                            $unsigned(8'(b_values[k][column])) : 8'b0;
            end
            lomem.write_row(int'(B_ROW + (g / 2)), b_row);
        end
        write_lomem_line(A_ROW, 0, pack_line(a_line));

        emit_out_stream();
        emit_stream(1, DOMAIN_LOMEM, LAYOUT_ROW_MAJOR, A_ROW, 0, 1, 1, 1);
        emit_stream(2, DOMAIN_LOMEM, LAYOUT_MATMUL_B_INT8, B_ROW, 0,
                    int'(b_rows), 1, 1);
        emit(asm_acc_reset());
        emit(asm_broadcast_mac(1, 2, columns));
        emit(asm_write_accumulators(0, columns));
        emit(asm_halt());
        run_program();
        check(!error, "broadcast_mac int8: no error");

        for (int unsigned n = 0; n < columns; n++) begin
            expected = 0.0;
            for (int unsigned k = 0; k < DK; k++)
                expected = expected + a_values[k] * real'(b_values[k][n]);
            line = lomem_line(OUT_ROW, n / BF16_PER_LINE);
            check_close(bf16_to_real(line_value(line, n % BF16_PER_LINE)),
                        expected,
                        $sformatf("broadcast_mac int8 columns=%0d out[%0d]",
                                  columns, n));
        end
    endtask

    // multi_mac splits valid_elements across the four lanes, each producing an
    // 8-element dot product into its own accumulator 0.
    task automatic run_multi_mac(input int unsigned elements);
        real                    a_values [0:63];
        real                    b_values [0:63];
        logic [LOMEM_WIDTH-1:0] a_row, b_row;
        real                    expected;
        int unsigned            rows;
        int unsigned            index;
        logic [LINE_WIDTH-1:0]  line;

        rows = (elements + 31) / 32;
        reset_core();
        clear_program();
        clear_out_rows();

        for (int unsigned e = 0; e < 64; e++) begin
            a_values[e] = real'(int'(e % 5) - 2) * 0.5;
            b_values[e] = real'(int'(e % 3) + 1) * 0.25;
        end
        for (int unsigned r = 0; r < rows; r++) begin
            a_row = '0;
            b_row = '0;
            for (int unsigned e = 0; e < BF16_PER_ROW; e++) begin
                index = r*32 + e;
                a_row[e*16 +: 16] = real_to_bf16(a_values[index]);
                b_row[e*16 +: 16] = real_to_bf16(b_values[index]);
            end
            lomem.write_row(int'(A_ROW + r), a_row);
            lomem.write_row(int'(B_ROW + r), b_row);
        end

        emit_out_stream();
        emit_stream(1, DOMAIN_LOMEM, LAYOUT_ROW_MAJOR, A_ROW, 0, int'(rows), 1, 1);
        emit_stream(2, DOMAIN_LOMEM, LAYOUT_ROW_MAJOR, B_ROW, 0, int'(rows), 1, 1);
        emit(asm_acc_reset());
        emit(asm_multi_mac(1, 2, elements));
        emit(asm_write_accumulators(0, 4));
        emit(asm_halt());
        run_program();
        check(!error, "multi_mac: no error");

        line = lomem_line(OUT_ROW, 0);
        for (int unsigned l = 0; l < TREEMACS; l++) begin
            expected = 0.0;
            for (int unsigned r = 0; r < rows; r++)
                for (int unsigned e = 0; e < BF16_PER_LINE; e++) begin
                    index = r*32 + l*8 + e;
                    if (index < elements)
                        expected = expected + a_values[index] * b_values[index];
                end
            check_close(bf16_to_real(line_value(line, l)), expected,
                        $sformatf("multi_mac elements=%0d lane %0d",
                                  elements, l));
        end
    endtask

    // Elementwise operations reuse the multiplier array as A*1 + B*1 or A*B and
    // land value i in accumulator i/4 of lane i%4, so the snapshot is in
    // element order.
    task automatic run_elementwise(input logic add_not_mul,
                                   input int unsigned elements);
        real                   a_values [0:63];
        real                   b_values [0:63];
        logic [15:0]           values [0:BF16_PER_LINE-1];
        real                   expected;
        int unsigned           lines;
        logic [LINE_WIDTH-1:0] line;

        lines = (elements + 7) / 8;
        reset_core();
        clear_program();
        clear_out_rows();

        for (int unsigned e = 0; e < 64; e++) begin
            a_values[e] = real'(int'(e % 7) - 3) * 0.5;
            b_values[e] = real'(int'(e % 4) + 1) * 0.25;
        end
        for (int unsigned q = 0; q < lines; q++) begin
            for (int unsigned e = 0; e < BF16_PER_LINE; e++)
                values[e] = real_to_bf16(a_values[q*8 + e]);
            write_lomem_line(A_ROW, q, pack_line(values));
            for (int unsigned e = 0; e < BF16_PER_LINE; e++)
                values[e] = real_to_bf16(b_values[q*8 + e]);
            write_lomem_line(B_ROW, q, pack_line(values));
        end

        emit_out_stream();
        emit_stream(1, DOMAIN_LOMEM, LAYOUT_ROW_MAJOR, A_ROW, 0, int'(lines), 1, 1);
        emit_stream(2, DOMAIN_LOMEM, LAYOUT_ROW_MAJOR, B_ROW, 0, int'(lines), 1, 1);
        emit(asm_acc_reset());
        if (add_not_mul)
            emit(asm_elementwise_add(1, 2, elements));
        else
            emit(asm_elementwise_mul(1, 2, elements));
        emit(asm_write_accumulators(0, elements));
        emit(asm_halt());
        run_program();
        check(!error, "elementwise: no error");

        for (int unsigned e = 0; e < elements; e++) begin
            expected = add_not_mul ? (a_values[e] + b_values[e])
                                   : (a_values[e] * b_values[e]);
            line = lomem_line(OUT_ROW, e / BF16_PER_LINE);
            check_close(bf16_to_real(line_value(line, e % BF16_PER_LINE)),
                        expected,
                        $sformatf("elementwise add=%0d elements=%0d out[%0d]",
                                  add_not_mul, elements, e));
        end
    endtask

    // reduce_accumulators folds the snapshot with one sequential BF16 add per
    // cycle into an output buffer slot, and write_buf emits the whole buffer
    // with zeros for unset slots and then clears it.
    task automatic test_reduce_and_write_buf();
        localparam int unsigned ELEMENTS = 8;
        real                    a_values [0:ELEMENTS-1];
        logic [15:0]            values [0:BF16_PER_LINE-1];
        logic [15:0]            running;
        real                    expected;
        logic [LINE_WIDTH-1:0]  line;

        reset_core();
        clear_program();
        clear_out_rows();

        for (int unsigned e = 0; e < ELEMENTS; e++) begin
            a_values[e] = real'(int'(e) + 1) * 0.5;
            values[e]   = real_to_bf16(a_values[e]);
        end
        write_lomem_line(A_ROW, 0, pack_line(values));
        for (int unsigned e = 0; e < BF16_PER_LINE; e++)
            values[e] = real_to_bf16(0.0);
        write_lomem_line(B_ROW, 0, pack_line(values));

        emit_out_stream();
        emit_stream(1, DOMAIN_LOMEM, LAYOUT_ROW_MAJOR, A_ROW, 0, 1, 1, 1);
        emit_stream(2, DOMAIN_LOMEM, LAYOUT_ROW_MAJOR, B_ROW, 0, 1, 1, 1);
        emit(asm_acc_reset());
        emit(asm_elementwise_add(1, 2, ELEMENTS));
        emit(asm_reduce_accumulators(2, ELEMENTS));
        emit(asm_reduce_accumulators(5, 1));
        emit(asm_write_buf(0));
        emit(asm_halt());
        run_program();
        check(!error, "reduce: no error");

        // The reduction order is architectural: initialize from value 0, then
        // one BF16 add per remaining value.
        running = real_to_bf16(a_values[0]);
        for (int unsigned e = 1; e < ELEMENTS; e++)
            running = real_to_bf16(bf16_to_real(running) +
                                   bf16_to_real(real_to_bf16(a_values[e])));
        expected = bf16_to_real(running);

        line = lomem_line(OUT_ROW, 0);
        check_close(bf16_to_real(line_value(line, 2)), expected,
                    "reduce: slot 2 holds the full sum");
        check_close(bf16_to_real(line_value(line, 5)), a_values[0],
                    "reduce: count 1 copies the first value into slot 5");
        for (int unsigned s = 0; s < OUTPUT_BUFFER_SLOTS; s++)
            if ((s != 2) && (s != 5))
                check(line_value(line, s) == BF16_ZERO,
                      $sformatf("write_buf: unset slot %0d is zero", s));
    endtask

    // scale_accumulators multiplies the snapshot by a BF16 scale row in the WB
    // FPU and writes zero-padded 128-bit lines, here into CoMem.
    task automatic test_scale_accumulators();
        localparam int unsigned COLUMNS = 12;
        real                    a_values [0:COLUMNS-1];
        real                    scales [0:COLUMNS-1];
        logic [15:0]            values [0:BF16_PER_LINE-1];
        logic [LOMEM_WIDTH-1:0] scale_row;
        real                    expected;
        logic [LINE_WIDTH-1:0]  line;

        reset_core();
        clear_program();
        for (int unsigned r = 0; r < 2; r++)
            comem.write_row(int'(CO_ROW + r), '1);

        for (int unsigned e = 0; e < COLUMNS; e++) begin
            a_values[e] = real'(int'(e % 5) + 1) * 0.5;
            scales[e]   = real'(int'(e % 3) + 1) * 0.25;
        end
        for (int unsigned q = 0; q < 2; q++) begin
            for (int unsigned e = 0; e < BF16_PER_LINE; e++)
                values[e] = (q*8 + e < COLUMNS) ?
                    real_to_bf16(a_values[q*8 + e]) : BF16_ZERO;
            write_lomem_line(A_ROW, q, pack_line(values));
            for (int unsigned e = 0; e < BF16_PER_LINE; e++)
                values[e] = BF16_ZERO;
            write_lomem_line(B_ROW, q, pack_line(values));
        end
        scale_row = '0;
        for (int unsigned e = 0; e < BF16_PER_ROW; e++)
            scale_row[e*16 +: 16] = (e < COLUMNS) ? real_to_bf16(scales[e])
                                                  : BF16_ZERO;
        lomem.write_row(SCALE_ROW, scale_row);

        emit_stream(1, DOMAIN_LOMEM, LAYOUT_ROW_MAJOR, A_ROW, 0, 2, 1, 1);
        emit_stream(2, DOMAIN_LOMEM, LAYOUT_ROW_MAJOR, B_ROW, 0, 2, 1, 1);
        emit_stream(0, DOMAIN_LOMEM, LAYOUT_ROW_MAJOR, SCALE_ROW, 0, 1, 1, 1);
        emit_stream(3, DOMAIN_COMEM, LAYOUT_ROW_MAJOR, CO_ROW, 0, 2, 1, 1);
        emit(asm_acc_reset());
        emit(asm_elementwise_add(1, 2, COLUMNS));
        emit(asm_scale_accumulators(0, 3, COLUMNS));
        emit(asm_halt());
        run_program();
        check(!error, "scale: no error");

        for (int unsigned e = 0; e < COLUMNS; e++) begin
            expected = a_values[e] * scales[e];
            line     = comem.read_row(int'(CO_ROW + (e / BF16_PER_LINE)));
            check_close(bf16_to_real(line_value(line, e % BF16_PER_LINE)),
                        expected, $sformatf("scale: out[%0d]", e));
        end
        line = comem.read_row(CO_ROW + 1);
        for (int unsigned e = COLUMNS % BF16_PER_LINE; e < BF16_PER_LINE; e++)
            check(line_value(line, e) == BF16_ZERO,
                  $sformatf("scale: final line padding at %0d", e));
    endtask

    // A read that follows an unfinished write to the same rows must see the
    // written data, and the Command stage must report a dependency stall while
    // it waits (section 19).
    task automatic test_range_dependency();
        localparam int unsigned ELEMENTS = 8;
        logic [15:0]           values [0:BF16_PER_LINE-1];
        logic [LINE_WIDTH-1:0] line;
        logic                  saw_dependency_stall;

        reset_core();
        clear_program();
        clear_out_rows();

        // A = 1.0 in every element, B = 0, so the first elementwise_add writes
        // 1.0 into the output rows, which the second one then reads as its A.
        for (int unsigned e = 0; e < BF16_PER_LINE; e++)
            values[e] = real_to_bf16(1.0);
        write_lomem_line(A_ROW, 0, pack_line(values));
        for (int unsigned e = 0; e < BF16_PER_LINE; e++)
            values[e] = BF16_ZERO;
        write_lomem_line(B_ROW, 0, pack_line(values));

        emit_stream(0, DOMAIN_LOMEM, LAYOUT_ROW_MAJOR, OUT_ROW, 0, 1, 2, 1);
        emit_stream(1, DOMAIN_LOMEM, LAYOUT_ROW_MAJOR, A_ROW, 0, 1, 1, 1);
        emit_stream(2, DOMAIN_LOMEM, LAYOUT_ROW_MAJOR, B_ROW, 0, 1, 1, 1);
        emit_stream(3, DOMAIN_LOMEM, LAYOUT_ROW_MAJOR, OUT_ROW, 0, 1, 1, 1);
        emit(asm_acc_reset());
        emit(asm_elementwise_add(1, 2, ELEMENTS));
        emit(asm_write_accumulators(0, ELEMENTS));
        emit(asm_acc_reset());
        emit(asm_elementwise_add(3, 2, ELEMENTS));
        emit(asm_write_accumulators(0, ELEMENTS));
        emit(asm_halt());

        saw_dependency_stall = 1'b0;
        fork
            begin
                run_program();
            end
            begin
                while (!done) begin
                    @(posedge clk);
                    if (dependency_stall)
                        saw_dependency_stall = 1'b1;
                end
            end
        join
        check(!error, "range dependency: no error");
        check(!structural_stall, "range dependency: settled with no queue stall");
        check(saw_dependency_stall,
              "range dependency: issue reports a dependency stall");
        line = lomem_line(OUT_ROW, 1);
        for (int unsigned e = 0; e < ELEMENTS; e++)
            check_close(bf16_to_real(line_value(line, e)), 1.0,
                        $sformatf("range dependency: second pass out[%0d]", e));
    endtask

    // ------------------------------------------------------------------ main
    // +only=<group> runs one group of tests, which keeps debug turnarounds
    // short. Groups: ctrl, acc, bcast, multi, ew, buf, scale, dep.
    function automatic logic selected(input string group);
        string only;
        if (!$value$plusargs("only=%s", only))
            return 1'b1;
        return (only == group);
    endfunction

    initial begin
        clear_program();
        trace_enabled = $test$plusargs("trace");
        reset = 1'b1;
        flush = 1'b0;
        start = 1'b0;

        check(TREEMACS == 4, "constant: four TreeMACs");
        check(TREEMAC_MULTIPLIERS == 8, "constant: eight multipliers per lane");
        check(TREEMAC_ACCUMULATORS == 16, "constant: 16 accumulators per lane");
        check(TOTAL_ACCUMULATORS == 64, "constant: 64 accumulators");
        check(LOMEM_WIDTH == 512, "constant: 512-bit LoMem row");
        check(COMEM_WIDTH == 128, "constant: 128-bit CoMem line");

        if (selected("ctrl")) begin
            test_reset_state();
            test_registers_and_loops();
            test_zero_count_loop();
            test_branches();
            test_illegal_endloop();
            test_uninitialized_register();
        end
        if (selected("acc")) begin
            test_acc_reset_write();
            test_load_accumulators();
        end
        if (selected("bcast")) begin
            run_broadcast_gemv(4, DOMAIN_LOMEM);
            run_broadcast_gemv(5, DOMAIN_LOMEM);
            run_broadcast_gemv(64, DOMAIN_LOMEM);
            run_broadcast_gemv(1, DOMAIN_COMEM);
            run_broadcast_gemv(13, DOMAIN_COMEM);
        end
        if (selected("int8")) begin
            run_broadcast_gemv_int8(5);
            run_broadcast_gemv_int8(12);
            run_broadcast_gemv_int8(64);
        end
        if (selected("multi")) begin
            run_multi_mac(8);
            run_multi_mac(32);
            run_multi_mac(64);
            run_multi_mac(21);
        end
        if (selected("ew")) begin
            run_elementwise(1'b1, 7);
            run_elementwise(1'b0, 7);
            run_elementwise(1'b1, 64);
            run_elementwise(1'b0, 1);
        end
        if (selected("buf"))
            test_reduce_and_write_buf();
        if (selected("scale"))
            test_scale_accumulators();
        if (selected("dep"))
            test_range_dependency();

        if (errors == 0)
            $display("mcore_tb: PASS (%0d checks)", checks);
        else
            $display("mcore_tb: FAIL (%0d errors, %0d checks)", errors, checks);
        $finish;
    end
endmodule



