`timescale 1ns/1ps

module dataset_filter_tb;
    reg clk = 0, resetn = 0;
    always #5 clk = ~clk;
    reg [127:0] record_data = 0;
    reg record_valid = 0, record_last = 0, result_ready = 0;
    wire record_ready, result_valid;
    wire [63:0] match_count;
    wire [31:0] checksum;

    dataset_filter dut (.*);

    task send_record(input [31:0] id, tokens, flags, input bit last);
        @(negedge clk);
        if (!record_ready) $fatal(1, "Input stalled before end of job");
        record_data = {id ^ 32'h9e37_79b9, flags, tokens, id};
        record_valid = 1;
        record_last = last;
    endtask

    task check_result(input [63:0] expected_count, input [31:0] expected_checksum);
        @(negedge clk);
        record_valid = 0;
        repeat (3) begin
            if (result_valid !== 1'b1 || record_ready !== 1'b0 ||
                match_count !== expected_count || checksum !== expected_checksum)
                $fatal(1, "Expected count=%0d checksum=%0d, got %0d %0d",
                       expected_count, expected_checksum, match_count, checksum);
            @(negedge clk);
        end
        result_ready = 1;
        @(negedge clk);
        result_ready = 0;
        if (result_valid || !record_ready) $fatal(1, "Result handshake failed");
    endtask

    initial begin
        repeat (3) @(negedge clk);
        resetn = 1;
        for (integer id = 0; id < 1025; id = id + 1)
            send_record(id, 8 + id % 256, (id >> 3) & 1, id == 1024);
        check_result(288, 164592);

        send_record(9, 127, 1, 0);
        send_record(18, 128, 2, 0);
        send_record(32'hffff_ffff, 128, 3, 0);
        send_record(55, 128, 1, 1);
        check_result(2, 54);

        send_record(1, 0, 0, 1);
        check_result(0, 0);
        $display("PASS: dataset filter matches CPU fixture, includes the final record, and handles checksum wrap and backpressure");
        $finish;
    end

    initial begin
        #20000;
        $fatal(1, "Dataset filter timed out");
    end
endmodule
