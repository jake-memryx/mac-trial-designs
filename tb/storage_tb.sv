`timescale 1ns/1ps

`ifndef ENTRIES
`define ENTRIES 8
`endif

// Directed checks for the register bank and the shift register.
module storage_tb;
    localparam int unsigned ENTRIES = `ENTRIES;
    localparam int unsigned WIDTH   = 128;
    localparam int unsigned ADDR_W  = (ENTRIES <= 1) ? 1 : $clog2(ENTRIES);
    localparam int unsigned DEPTH   = 8;
    localparam int unsigned TAP     = 4;

    logic                clk, reset;
    logic                write_enable;
    logic [ADDR_W-1:0]   write_address, read_address;
    logic [WIDTH-1:0]    write_data, read_data;

    logic                sr_enable;
    logic [WIDTH-1:0]    sr_in, sr_out;

    int failures = 0;

    reg_bank #(.ENTRIES(ENTRIES), .WIDTH(WIDTH)) bank (
        .clk (clk), .reset (reset),
        .write_enable (write_enable), .write_address (write_address),
        .write_data (write_data), .read_address (read_address),
        .read_data (read_data)
    );

    shift_reg #(.DEPTH(DEPTH), .WIDTH(WIDTH), .OUTPUT_TAP(TAP)) pipe (
        .clk (clk), .reset (reset), .enable (sr_enable),
        .data_in (sr_in), .data_out (sr_out)
    );

    initial clk = 1'b0;
    always #5 clk = ~clk;

    function automatic logic [WIDTH-1:0] pattern(input int seed);
        logic [WIDTH-1:0] value;
        for (int w = 0; w < WIDTH/32; w++)
            value[w*32 +: 32] = 32'h1000_0000 * (seed + 1) + w;
        return value;
    endfunction

    task automatic expect_read(input int index, input logic [WIDTH-1:0] want,
                               input string name);
        read_address = ADDR_W'(index);
        #1;
        if (read_data !== want) begin
            $error("%s: entry %0d expected %032h, got %032h",
                   name, index, want, read_data);
            failures++;
        end
    endtask

    logic [WIDTH-1:0] expected_bank [0:ENTRIES-1];

    initial begin
        reset = 1'b1; write_enable = 1'b0; sr_enable = 1'b0;
        write_address = '0; read_address = '0; write_data = '0; sr_in = '0;
        repeat (2) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        // Every entry reads back zero after reset.
        for (int i = 0; i < ENTRIES; i++)
            expect_read(i, '0, "reset");

        // Write each entry with a distinct pattern, one per cycle.
        for (int i = 0; i < ENTRIES; i++) begin
            @(negedge clk);
            write_enable  = 1'b1;
            write_address = ADDR_W'(i);
            write_data    = pattern(i);
            expected_bank[i] = pattern(i);
            @(posedge clk);
        end
        @(negedge clk);
        write_enable = 1'b0;

        for (int i = 0; i < ENTRIES; i++)
            expect_read(i, expected_bank[i], "write/readback");
        $display("PASS: bank write and readback (%0d entries)", ENTRIES);

        // A disabled write must leave the bank untouched.
        @(negedge clk);
        write_enable  = 1'b0;
        write_address = '0;
        write_data    = '1;
        @(posedge clk);
        @(negedge clk);
        expect_read(0, expected_bank[0], "write disabled");

        // Overwrite one entry only.
        @(negedge clk);
        write_enable  = 1'b1;
        write_address = ADDR_W'(ENTRIES-1);
        write_data    = pattern(99);
        expected_bank[ENTRIES-1] = pattern(99);
        @(posedge clk);
        @(negedge clk);
        write_enable = 1'b0;
        for (int i = 0; i < ENTRIES; i++)
            expect_read(i, expected_bank[i], "single overwrite");
        $display("PASS: bank isolation");

        // Shift register: a value must appear exactly TAP cycles after entry.
        @(negedge clk);
        sr_enable = 1'b1;
        for (int i = 0; i < DEPTH + TAP; i++) begin
            sr_in = pattern(i);
            @(posedge clk);
            @(negedge clk);
            if (i >= TAP - 1) begin
                if (sr_out !== pattern(i - (TAP - 1))) begin
                    $error("shift: cycle %0d expected %032h, got %032h",
                           i, pattern(i - (TAP - 1)), sr_out);
                    failures++;
                end
            end
        end
        $display("PASS: shift register latency of %0d cycles", TAP);

        // Enable low must stall the pipeline.
        begin
            logic [WIDTH-1:0] held;
            // Deassert before the next rising edge, then sample: the output
            // must not move again.
            sr_enable = 1'b0;
            sr_in     = pattern(123);
            held      = sr_out;
            repeat (3) @(posedge clk);
            @(negedge clk);
            if (sr_out !== held) begin
                $error("shift: output moved while disabled");
                failures++;
            end
        end
        $display("PASS: shift register stalls on enable low");

        if (failures == 0) begin
            $display("\nSTORAGE TEST PASSED (bank %0dx%0d, shift %0dx%0d tap %0d)",
                     ENTRIES, WIDTH, DEPTH, WIDTH, TAP);
            $finish;
        end
        $fatal(1, "STORAGE TEST FAILED with %0d failure(s)", failures);
    end

    initial begin
        #100000;
        $fatal(1, "STORAGE TEST FAILED: timeout");
    end
endmodule
