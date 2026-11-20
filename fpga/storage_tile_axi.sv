`timescale 1ns/1ps

module storage_tile_axi #(
    parameter integer STORAGE_TIMEOUT_CYCLES = 1_000_000
) (
    input  wire         clk,
    input  wire         resetn,
    input  wire [63:0]  buffer_base,
    output wire [63:0]  m_axi_araddr,
    output wire [7:0]   m_axi_arlen,
    output wire [2:0]   m_axi_arsize,
    output wire [1:0]   m_axi_arburst,
    output wire         m_axi_arvalid,
    input  wire         m_axi_arready,
    input  wire [31:0]  m_axi_rdata,
    input  wire [1:0]   m_axi_rresp,
    input  wire         m_axi_rlast,
    input  wire         m_axi_rvalid,
    output wire         m_axi_rready,
    output wire [15:0]  result_valid,
    output wire [511:0] results,
    output wire [15:0]  core_trap,
    output wire         fault
);
    localparam [27:0] FIRST_LBA = 28'd244140623;
    wire page_req_valid, page_req_ready, page_word_valid, page_word_ready;
    wire page_word_last, page_word_error;
    wire [27:0] page_req_lba;
    wire [31:0] page_word_data;

    storage_tile #(.STORAGE_TIMEOUT_CYCLES(STORAGE_TIMEOUT_CYCLES), .FIRST_LBA(FIRST_LBA)) tile (.*);
    axi_page_reader #(.FIRST_LBA(FIRST_LBA)) reader (.*);
endmodule

module axi_page_reader #(
    parameter [27:0] FIRST_LBA = 28'd244140623
) (
    input  wire         clk,
    input  wire         resetn,
    input  wire [63:0]  buffer_base,
    input  wire         page_req_valid,
    output wire         page_req_ready,
    input  wire [27:0]  page_req_lba,
    output wire         page_word_valid,
    input  wire         page_word_ready,
    output wire [31:0]  page_word_data,
    output wire         page_word_last,
    output wire         page_word_error,
    output wire [63:0]  m_axi_araddr,
    output wire [7:0]   m_axi_arlen,
    output wire [2:0]   m_axi_arsize,
    output wire [1:0]   m_axi_arburst,
    output wire         m_axi_arvalid,
    input  wire         m_axi_arready,
    input  wire [31:0]  m_axi_rdata,
    input  wire [1:0]   m_axi_rresp,
    input  wire         m_axi_rlast,
    input  wire         m_axi_rvalid,
    output wire         m_axi_rready
);
    localparam [2:0] IDLE = 0, ADDRESS = 1, DATA = 2, REJECT = 3, DRAIN = 4, FAILED = 5;
    reg [2:0] state;
    reg [63:0] address;
    reg [1:0] burst_index;
    reg [7:0] beat_index;
    wire final_beat = beat_index == 8'd255;
    wire invalid_beat = m_axi_rresp != 2'b00 || m_axi_rlast != final_beat;

    assign page_req_ready = state == IDLE;
    assign page_word_valid = (state == DATA && m_axi_rvalid) || state == REJECT;
    assign page_word_data = state == REJECT ? 32'b0 : m_axi_rdata;
    assign page_word_error = state == REJECT || (state == DATA && invalid_beat);
    assign page_word_last = page_word_error || (state == DATA && burst_index == 3 && final_beat);

    assign m_axi_araddr = address;
    assign m_axi_arlen = 8'd255;
    assign m_axi_arsize = 3'd2;
    assign m_axi_arburst = 2'b01;
    assign m_axi_arvalid = state == ADDRESS;
    assign m_axi_rready = state == DRAIN || (state == DATA && page_word_ready);

    always @(posedge clk) begin
        if (!resetn) begin
            state <= IDLE;
            address <= 0;
            burst_index <= 0;
            beat_index <= 0;
        end else begin
            case (state)
                IDLE: if (page_req_valid) begin
                    if ((page_req_lba != FIRST_LBA && page_req_lba != FIRST_LBA + 1'b1) ||
                        buffer_base[11:0] != 0 || buffer_base > 64'hffff_ffff_ffff_e000) begin
                        state <= REJECT;
                    end else begin
                        address <= buffer_base + (page_req_lba == FIRST_LBA ? 64'd0 : 64'd4096);
                        burst_index <= 0;
                        state <= ADDRESS;
                    end
                end
                ADDRESS: if (m_axi_arready) begin
                    beat_index <= 0;
                    state <= DATA;
                end
                DATA: if (m_axi_rvalid && m_axi_rready) begin
                    if (invalid_beat) begin
                        state <= m_axi_rlast ? FAILED : DRAIN;
                    end else if (!final_beat) begin
                        beat_index <= beat_index + 1'b1;
                    end else if (burst_index == 3) begin
                        state <= IDLE;
                    end else begin
                        burst_index <= burst_index + 1'b1;
                        address <= address + 64'd1024;
                        state <= ADDRESS;
                    end
                end
                REJECT: if (page_word_ready) state <= FAILED;
                DRAIN: if (m_axi_rvalid && m_axi_rlast) state <= FAILED;
                default: state <= FAILED;
            endcase
        end
    end
endmodule
