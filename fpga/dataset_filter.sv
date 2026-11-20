`timescale 1ns/1ps

module dataset_filter (
    input  wire         clk,
    input  wire         resetn,
    input  wire [127:0] record_data,
    input  wire         record_valid,
    output wire         record_ready,
    input  wire         record_last,
    output reg          result_valid,
    input  wire         result_ready,
    output reg  [63:0]  match_count,
    output reg  [31:0]  checksum
);
    reg [63:0] running_count;
    reg [31:0] running_checksum;
    wire [31:0] id = record_data[31:0];
    wire [31:0] tokens = record_data[63:32];
    wire selected = tokens >= 32'd128 && record_data[64];
    wire [63:0] next_count = running_count + {63'b0, selected};
    wire [31:0] next_checksum = running_checksum + (selected ? id : 32'b0);

    assign record_ready = !result_valid;

    always @(posedge clk) begin
        if (!resetn) begin
            running_count <= 0;
            running_checksum <= 0;
            result_valid <= 0;
            match_count <= 0;
            checksum <= 0;
        end else if (result_valid && result_ready) begin
            result_valid <= 0;
        end else if (record_valid && record_ready) begin
            if (record_last) begin
                match_count <= next_count;
                checksum <= next_checksum;
                result_valid <= 1;
                running_count <= 0;
                running_checksum <= 0;
            end else begin
                running_count <= next_count;
                running_checksum <= next_checksum;
            end
        end
    end
endmodule
