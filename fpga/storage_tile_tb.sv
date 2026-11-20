`timescale 1ns/1ps

module storage_tile_tb;
    localparam [27:0] FIRST_LBA = 28'd244140623;
    reg clk = 0;
    reg resetn = 0;
    always #5 clk = ~clk;

    wire page_req_valid, page_word_ready, fault;
    wire [27:0] page_req_lba;
    wire [15:0] result_valid, core_trap;
    wire [511:0] results;
    integer cycle, reads, words, stalled_cycles, mode;
    reg active;
    reg [27:0] lba;
    reg [9:0] word_index;
    reg request_stalled;
    reg [27:0] stalled_lba;
    wire page_req_ready = !active && mode != 4 && request_stalled && cycle % 4 == 3;
    wire page_word_valid = active && mode != 5 && cycle % 7 != 0;
    wire page_word_error = mode == 1;
    wire page_word_last = mode == 1 || mode == 2 || (mode == 0 && word_index == 1023);
    reg [31:0] page_word_data;

    storage_tile #(.STORAGE_TIMEOUT_CYCLES(32)) dut (.*);

    always @* begin
        page_word_data = 32'h0000_0013; // nop
        if (lba == FIRST_LBA) begin
            case (word_index)
                1022: page_word_data = 32'h2000_02b7; // lui x5, 0x20000
                1023: page_word_data = 32'h0002_a303; // lw x6, 0(x5)
                default: ;
            endcase
        end else begin
            case (word_index)
                0: page_word_data = 32'h02a3_0313; // addi x6, x6, 42
                1: page_word_data = 32'h0062_a223; // sw x6, 4(x5)
                2: page_word_data = 32'h0010_0073; // ebreak
                default: ;
            endcase
        end
    end

    always @(posedge clk) begin
        if (!resetn) begin
            cycle <= 0;
            reads <= 0;
            words <= 0;
            stalled_cycles <= 0;
            active <= 0;
            lba <= 0;
            word_index <= 0;
            request_stalled <= 0;
            stalled_lba <= 0;
        end else begin
            cycle <= cycle + 1;
            if (!fault && request_stalled && (!page_req_valid || stalled_lba != page_req_lba))
                $fatal(1, "Page request changed under backpressure");
            request_stalled <= page_req_valid && !page_req_ready;
            if (page_req_valid && !page_req_ready) begin
                stalled_lba <= page_req_lba;
                stalled_cycles <= stalled_cycles + 1;
            end
            if (page_req_valid && page_req_ready) begin
                if (reads >= 2 || page_req_lba != FIRST_LBA + reads)
                    $fatal(1, "Unexpected page request %0d at read %0d", page_req_lba, reads);
                active <= 1;
                lba <= page_req_lba;
                word_index <= 0;
                reads <= reads + 1;
            end
            if (page_word_valid && page_word_ready) begin
                words <= words + 1;
                if (page_word_last || word_index == 1023) active <= 0;
                else word_index <= word_index + 1'b1;
            end
        end
    end

    task start(input integer next_mode);
        @(negedge clk);
        resetn = 0;
        mode = next_mode;
        repeat (4) @(negedge clk);
        resetn = 1;
    endtask

    initial begin
        for (integer failure = 1; failure <= 5; failure = failure + 1) begin
            start(failure);
            wait (fault === 1'b1);
            repeat (4) @(negedge clk);
            if (fault !== 1'b1 || result_valid !== 16'b0 || core_trap !== 16'b0 ||
                reads != (failure == 4 ? 0 : 1) || page_req_valid || page_word_ready)
                $fatal(1, "Fault case %0d executed code or did not halt the bridge", failure);
        end

        start(0);
        wait (core_trap === 16'hffff || fault === 1'b1);
        @(negedge clk);
        if (fault || result_valid !== 16'hffff || reads != 2 || words != 2048 || stalled_cycles == 0)
            $fatal(1, "Unexpected tile completion: fault=%b results=%h reads=%0d words=%0d stalls=%0d",
                   fault, result_valid, reads, words, stalled_cycles);
        for (integer id = 0; id < 16; id = id + 1)
            if (results[id*32 +: 32] !== 42 + id)
                $fatal(1, "Core %0d returned %0d", id, results[id*32 +: 32]);

        $display("PASS: 16 PicoRV32 cores completed, 2 page reads, 8192 storage bytes");
        $display("PASS: backpressure, storage error, malformed lengths, timeouts, and reset recovery");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "Tile timed out: mode=%0d fault=%b results=%h traps=%h reads=%0d words=%0d",
               mode, fault, result_valid, core_trap, reads, words);
    end
endmodule
