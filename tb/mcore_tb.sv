`timescale 1ns/1ps

// Command Processor bring-up test for the v0.1 mcore.
//
// The stage FSMs are still skeletons (they never accept a command), so this
// testbench drives the CP directly with a behavioural program memory and
// checks control-flow, register, stream and halt/drain behaviour. Datapath
// acceptance tests follow once Fetch/Compute/Writeback are implemented.
module mcore_tb;
    import mcore_pkg::*;
    import mcore_prog_pkg::*;

    logic clk = 1'b0;
    logic reset = 1'b1;
    logic start = 1'b0;
    logic done;
    logic error;

    logic [PROG_ADDR_WIDTH-1:0] prog_addr;
    instr_t                     prog_data;

    // Behavioural program memory, combinational read.
    instr_t program_memory [1 << PROG_ADDR_WIDTH];
    assign prog_data = program_memory[prog_addr];

    // The CP is exercised standalone; stages report permanently idle and never
    // accept commands, which is also the worst case for backpressure.
    logic         fetch_cmd_valid, fetch_cmd_ready;
    fetch_cmd_t   fetch_cmd;
    logic         compute_cmd_valid, compute_cmd_ready;
    compute_cmd_t compute_cmd;
    logic           writeback_cmd_valid, writeback_cmd_ready;
    writeback_cmd_t writeback_cmd;

    int unsigned errors = 0;

    always #5 clk = ~clk;

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
        .fetch_idle          (1'b1),
        .compute_idle        (1'b1),
        .writeback_idle      (1'b1)
    );

    task automatic check(input bit condition, input string message);
        if (!condition) begin
            errors++;
            $display("FAIL: %s", message);
        end
    endtask

    task automatic reset_core();
        reset = 1'b1;
        start = 1'b0;
        repeat (3) @(posedge clk);
        reset = 1'b0;
        @(posedge clk);
    endtask

    task automatic run_until_done(input int unsigned max_cycles);
        int unsigned cycles;
        cycles = 0;
        start = 1'b1;
        while (!done && (cycles < max_cycles)) begin
            @(posedge clk);
            cycles++;
        end
        check(done, $sformatf("program did not reach done in %0d cycles", max_cycles));
        start = 1'b0;
    endtask

    task automatic clear_program();
        for (int unsigned i = 0; i < (1 << PROG_ADDR_WIDTH); i++) begin
            program_memory[i] = asm_halt();
        end
    endtask

    // ------------------------------------------------------------------
    // Tests
    // ------------------------------------------------------------------
    task automatic test_reset_state();
        reset = 1'b1;
        repeat (3) @(posedge clk);
        check(prog_addr == '0, "PC must reset to 0");
        check(!done, "done must be low in reset");
        check(!error, "error must be low in reset");
        check(!fetch_cmd_valid && !compute_cmd_valid && !writeback_cmd_valid,
              "no stage command may be valid in reset");
    endtask

    // LoadImm / AddImm with int32 wrap, then Halt.
    task automatic test_int_rf();
        clear_program();
        program_memory[0] = asm_load_imm(4'd1, 32'd7);
        program_memory[1] = asm_add_imm(4'd1, 4'd1, -32'd10);
        program_memory[2] = asm_load_imm(4'd2, 32'h7fff_ffff);
        program_memory[3] = asm_add_imm(4'd2, 4'd2, 32'd1);
        program_memory[4] = asm_halt();
        reset_core();
        run_until_done(64);
        check(u_cmd.int_rf[1] == -32'sd3, "R1 must be -3");
        check(u_cmd.int_rf[2] == 32'sh8000_0000, "R2 must wrap to INT32_MIN");
        check(!error, "int RF program must not report error");
    endtask

    // Nested loops: outer 3 x inner 2 increments of R3 -> 6.
    task automatic test_nested_loops();
        clear_program();
        program_memory[0] = asm_load_imm(4'd3, 32'd0);
        program_memory[1] = asm_loop_imm(32'd3);
        program_memory[2] = asm_loop_imm(32'd2);
        program_memory[3] = asm_add_imm(4'd3, 4'd3, 32'd1);
        program_memory[4] = asm_end_loop();
        program_memory[5] = asm_end_loop();
        program_memory[6] = asm_halt();
        reset_core();
        run_until_done(256);
        check(u_cmd.int_rf[3] == 32'sd6, "nested loops must run the body 6 times");
        check(u_cmd.loop_sp == '0, "loop stack must be empty at halt");
        check(!error, "nested loop program must not report error");
    endtask

    // A zero-count loop skips its body, including a nested loop and a SetStream.
    task automatic test_zero_count_loop();
        instr_t stream_words [SETSTREAM_WORDS];
        clear_program();
        asm_set_stream(stream_words, 3'd0, DOMAIN_LOMEM, LAYOUT_ROW_MAJOR,
                       16'd0, 32'd0, 32'd1, 32'd1, 32'd1, 1'b0, 32'd0, 5'b0);
        program_memory[0] = asm_load_imm(4'd4, 32'd0);
        program_memory[1] = asm_loop_imm(32'd0);
        program_memory[2] = stream_words[0];
        program_memory[3] = stream_words[1];
        program_memory[4] = stream_words[2];
        program_memory[5] = stream_words[3];
        program_memory[6] = asm_loop_imm(32'd4);
        program_memory[7] = asm_add_imm(4'd4, 4'd4, 32'd1);
        program_memory[8] = asm_end_loop();
        program_memory[9] = asm_end_loop();
        program_memory[10] = asm_halt();
        reset_core();
        run_until_done(256);
        check(u_cmd.int_rf[4] == 32'sd0, "zero-count loop body must be skipped");
        check(!u_cmd.stream_desc[0].valid,
              "skipped SetStream must not configure a stream");
        check(!error, "zero-count loop must not report error");
    endtask

    // Register-driven loop count.
    task automatic test_register_loop();
        clear_program();
        program_memory[0] = asm_load_imm(4'd5, 32'd4);
        program_memory[1] = asm_load_imm(4'd6, 32'd0);
        program_memory[2] = asm_loop_reg(4'd5);
        program_memory[3] = asm_add_imm(4'd6, 4'd6, 32'd2);
        program_memory[4] = asm_end_loop();
        program_memory[5] = asm_halt();
        reset_core();
        run_until_done(256);
        check(u_cmd.int_rf[6] == 32'sd8, "register loop count must run 4 iterations");
    endtask

    // BLT backward branch forms a countdown; BGE fall-through is checked too.
    task automatic test_branches();
        clear_program();
        program_memory[0] = asm_load_imm(4'd7, 32'd0);
        program_memory[1] = asm_add_imm(4'd7, 4'd7, 32'd1);
        // At PC 2 the sequential PC is 3, so offset -2 targets PC 1.
        program_memory[2] = asm_branch(OP_BRANCH_IF_LESS, 4'd7, 1'b0, 32'd5, -12'sd2);
        // Not taken: R7 == 5 is not >= 6.
        program_memory[3] = asm_branch(OP_BRANCH_IF_GREATER_EQ, 4'd7, 1'b0, 32'd6, 12'sd2);
        program_memory[4] = asm_load_imm(4'd8, 32'd1);
        program_memory[5] = asm_halt();
        program_memory[6] = asm_load_imm(4'd8, 32'd99);
        reset_core();
        run_until_done(256);
        check(u_cmd.int_rf[7] == 32'sd5, "BLT loop must count to 5");
        check(u_cmd.int_rf[8] == 32'sd1, "BGE must not be taken");
    endtask

    // SetStream configures a descriptor, derives outer_stride and clears cursors.
    task automatic test_set_stream();
        instr_t stream_words [SETSTREAM_WORDS];
        clear_program();
        asm_set_stream(stream_words, 3'd2, DOMAIN_COMEM, LAYOUT_ROW_MAJOR,
                       16'd48, 32'd5, 32'd4, 32'd3, 32'd2, 1'b0, 32'd0, 5'b0);
        program_memory[0] = stream_words[0];
        program_memory[1] = stream_words[1];
        program_memory[2] = stream_words[2];
        program_memory[3] = stream_words[3];
        program_memory[4] = asm_halt();
        reset_core();
        run_until_done(64);
        check(u_cmd.stream_desc[2].valid, "stream 2 must be valid");
        check(u_cmd.stream_desc[2].domain == DOMAIN_COMEM, "domain must be CoMem");
        check(u_cmd.stream_desc[2].layout == LAYOUT_ROW_MAJOR, "layout must be ROW_MAJOR");
        check(u_cmd.stream_desc[2].base_row == 16'd48, "base_row must be 48");
        check(u_cmd.stream_desc[2].offset == 32'sd5, "offset must be 5");
        check(u_cmd.stream_desc[2].inner_count == 32'sd4, "inner_count must be 4");
        check(u_cmd.stream_desc[2].outer_count == 32'sd3, "outer_count must be 3");
        check(u_cmd.stream_desc[2].inner_stride == 32'sd2, "inner_stride must be 2");
        // Section 29 default: inner_count * inner_stride.
        check(u_cmd.stream_desc[2].outer_stride == 32'sd8,
              "derived outer_stride must be 8");
        check(u_cmd.inner_cursor[2] == '0 && u_cmd.outer_cursor[2] == '0,
              "SetStream must clear cursors");
    endtask

    // A register-sourced SetStream field reads the RF at execution time.
    task automatic test_set_stream_register_field();
        instr_t stream_words [SETSTREAM_WORDS];
        clear_program();
        // reg_select bit 3 = inner_count comes from a register.
        asm_set_stream(stream_words, 3'd1, DOMAIN_LOMEM, LAYOUT_MATMUL_B,
                       16'd0, 32'd0, 32'd9 /* register index 9 */, 32'd2, 32'd1,
                       1'b0, 32'd0, 5'b01000);
        program_memory[0] = asm_load_imm(4'd9, 32'd6);
        program_memory[1] = stream_words[0];
        program_memory[2] = stream_words[1];
        program_memory[3] = stream_words[2];
        program_memory[4] = stream_words[3];
        program_memory[5] = asm_halt();
        reset_core();
        run_until_done(64);
        check(u_cmd.stream_desc[1].inner_count == 32'sd6,
              "inner_count must come from R9");
        check(u_cmd.stream_desc[1].outer_stride == 32'sd6,
              "derived outer_stride must use the resolved inner_count");
    endtask

    // Stage backpressure: the CP must hold at a stage-targeted command while
    // the target queue refuses it, and must not advance the PC.
    task automatic test_stage_backpressure();
        clear_program();
        program_memory[0] = asm_reset_accumulators();
        program_memory[1] = asm_halt();
        reset_core();
        start = 1'b1;
        repeat (4) @(posedge clk);
        check(compute_cmd_valid, "ResetAccumulators must present a Compute command");
        check(compute_cmd.op == COMPUTE_RESET_ACC, "Compute op must be reset");
        check(prog_addr == '0, "PC must stall while the Compute queue refuses");
        check(!done, "done must not assert while a command is unissued");
        // Accept it and let the program finish.
        compute_cmd_ready = 1'b1;
        @(posedge clk);
        compute_cmd_ready = 1'b0;
        repeat (8) @(posedge clk);
        check(done, "program must complete once the command is accepted");
        start = 1'b0;
    endtask

    // WriteAccumulators must dispatch atomically to Compute and Writeback.
    task automatic test_atomic_dispatch();
        instr_t stream_words [SETSTREAM_WORDS];
        clear_program();
        asm_set_stream(stream_words, 3'd4, DOMAIN_LOMEM, LAYOUT_ROW_MAJOR,
                       16'd8, 32'd0, 32'd8, 32'd1, 32'd1, 1'b0, 32'd0, 5'b0);
        program_memory[0] = stream_words[0];
        program_memory[1] = stream_words[1];
        program_memory[2] = stream_words[2];
        program_memory[3] = stream_words[3];
        program_memory[4] = asm_write_accumulators(3'd4, 7'd64);
        program_memory[5] = asm_halt();
        reset_core();
        start = 1'b1;
        repeat (10) @(posedge clk);
        check(compute_cmd_valid && writeback_cmd_valid,
              "WriteAccumulators must present both stage commands");
        check(compute_cmd.snapshot, "Compute half must request a snapshot");
        check(writeback_cmd.valid_columns == 7'd64, "valid_columns must be 64");
        // Only one queue accepts: the CP must not advance.
        compute_cmd_ready = 1'b1;
        @(posedge clk);
        check(prog_addr == PROG_ADDR_WIDTH'(4),
              "PC must not advance on partial acceptance");
        writeback_cmd_ready = 1'b1;
        @(posedge clk);
        compute_cmd_ready   = 1'b0;
        writeback_cmd_ready = 1'b0;
        // 64 columns pack into eight 128-bit lines, so the cursor advanced by 8.
        check(u_cmd.outer_cursor[4] == 32'sd1 && u_cmd.inner_cursor[4] == '0,
              "writeback must consume eight stream accesses");
        repeat (8) @(posedge clk);
        check(done, "program must drain after Halt");
        start = 1'b0;
    endtask

    // An already-issued command keeps its stream snapshot when the descriptor
    // is later reconfigured (section 3.6).
    task automatic test_issue_time_capture();
        instr_t stream_words [SETSTREAM_WORDS];
        clear_program();
        asm_set_stream(stream_words, 3'd5, DOMAIN_LOMEM, LAYOUT_ROW_MAJOR_FP32,
                       16'd16, 32'd3, 32'd4, 32'd2, 32'd1, 1'b0, 32'd0, 5'b0);
        program_memory[0] = stream_words[0];
        program_memory[1] = stream_words[1];
        program_memory[2] = stream_words[2];
        program_memory[3] = stream_words[3];
        program_memory[4] = asm_load_accumulators(3'd5, 4'd3);
        program_memory[5] = asm_halt();
        reset_core();
        start = 1'b1;
        repeat (10) @(posedge clk);
        check(fetch_cmd_valid && compute_cmd_valid,
              "LoadAccumulators must present Fetch and Compute commands");
        check(fetch_cmd.stream_a.desc.base_row == 16'd16,
              "captured base_row must be 16");
        check(fetch_cmd.stream_a.desc.offset == 32'sd3, "captured offset must be 3");
        check(fetch_cmd.stream_a.inner_cursor == '0,
              "captured cursor must be the pre-command value");
        check(fetch_cmd.accumulator_index == 4'd3, "accumulator index must be 3");
        fetch_cmd_ready   = 1'b1;
        compute_cmd_ready = 1'b1;
        @(posedge clk);
        fetch_cmd_ready   = 1'b0;
        compute_cmd_ready = 1'b0;
        check(u_cmd.inner_cursor[5] == 32'sd1,
              "LoadAccumulators must consume one stream access");
        repeat (8) @(posedge clk);
        check(done, "program must drain after Halt");
        start = 1'b0;
    endtask

    // Illegal-program reporting: EndLoop with an empty loop stack.
    task automatic test_illegal_end_loop();
        clear_program();
        program_memory[0] = asm_end_loop();
        program_memory[1] = asm_halt();
        reset_core();
        run_until_done(64);
        check(error, "EndLoop without a loop frame must set error");
    endtask

    initial begin
        fetch_cmd_ready     = 1'b0;
        compute_cmd_ready   = 1'b0;
        writeback_cmd_ready = 1'b0;
        clear_program();

        // Structural constants frozen by the specification.
        check(TREEMACS == 4, "TreeMAC count must be 4");
        check(TREEMAC_MULTIPLIERS == 8, "8 BF16 multipliers per TreeMAC");
        check(TREEMAC_ACCUMULATORS == 16, "16 FP32 accumulators per TreeMAC");
        check(TOTAL_ACCUMULATORS == 64, "64 total accumulators");
        check(INT_REGISTERS == 16, "16 integer control registers");
        check(LOMEM_WIDTH == 512, "512-bit LoMem row");
        check(COMEM_WIDTH == 128, "128-bit CoMem row");
        check(INSTR_WIDTH == 64, "64-bit instruction word");

        test_reset_state();
        test_int_rf();
        test_nested_loops();
        test_zero_count_loop();
        test_register_loop();
        test_branches();
        test_set_stream();
        test_set_stream_register_field();
        test_stage_backpressure();
        test_atomic_dispatch();
        test_issue_time_capture();
        test_illegal_end_loop();

        if (errors == 0) begin
            $display("mcore_tb: PASS");
        end else begin
            $display("mcore_tb: FAIL (%0d errors)", errors);
        end
        $finish;
    end
endmodule
