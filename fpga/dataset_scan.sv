`timescale 1ns/1ps

module dataset_scan (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 ap_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME ap_clk, ASSOCIATED_BUSIF s_axi_control:m_axi_gmem, ASSOCIATED_RESET ap_rst_n" *)
    input  wire         ap_clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 ap_rst_n RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME ap_rst_n, POLARITY ACTIVE_LOW" *)
    input  wire         ap_rst_n,
    input  wire [11:0]  s_axi_control_awaddr,
    input  wire         s_axi_control_awvalid,
    output wire         s_axi_control_awready,
    input  wire [31:0]  s_axi_control_wdata,
    input  wire [3:0]   s_axi_control_wstrb,
    input  wire         s_axi_control_wvalid,
    output wire         s_axi_control_wready,
    output reg          s_axi_control_bvalid,
    output wire [1:0]   s_axi_control_bresp,
    input  wire         s_axi_control_bready,
    input  wire [11:0]  s_axi_control_araddr,
    input  wire         s_axi_control_arvalid,
    output wire         s_axi_control_arready,
    output reg  [31:0]  s_axi_control_rdata,
    output reg          s_axi_control_rvalid,
    output wire [1:0]   s_axi_control_rresp,
    input  wire         s_axi_control_rready,
    output wire [63:0]  m_axi_gmem_araddr,
    output wire [7:0]   m_axi_gmem_arlen,
    output wire [2:0]   m_axi_gmem_arsize,
    output wire [1:0]   m_axi_gmem_arburst,
    output wire [3:0]   m_axi_gmem_arcache,
    output wire [2:0]   m_axi_gmem_arprot,
    output wire         m_axi_gmem_arvalid,
    input  wire         m_axi_gmem_arready,
    input  wire [127:0] m_axi_gmem_rdata,
    input  wire [1:0]   m_axi_gmem_rresp,
    input  wire         m_axi_gmem_rlast,
    input  wire         m_axi_gmem_rvalid,
    output wire         m_axi_gmem_rready
);
    localparam [11:0] CONTROL = 12'h000, BASE_LO = 12'h010, BASE_HI = 12'h014,
        RECORDS = 12'h018, MATCH_LO = 12'h020, MATCH_HI = 12'h024, CHECKSUM = 12'h028;
    reg address_pending, data_pending, start;
    reg [11:0] write_address;
    reg [31:0] write_data;
    reg [3:0] write_strobes;
    reg [63:0] input_base;
    reg [31:0] record_count;
    wire busy, done, fault;
    wire [63:0] match_count;
    wire [31:0] checksum;
    wire [31:0] byte_mask = {{8{write_strobes[3]}}, {8{write_strobes[2]}},
                             {8{write_strobes[1]}}, {8{write_strobes[0]}}};
    wire [31:0] masked_write = write_data & byte_mask;

    assign s_axi_control_awready = !address_pending && !s_axi_control_bvalid;
    assign s_axi_control_wready = !data_pending && !s_axi_control_bvalid;
    assign s_axi_control_arready = !s_axi_control_rvalid;
    assign s_axi_control_bresp = 2'b00;
    assign s_axi_control_rresp = 2'b00;

    always @(posedge ap_clk) begin
        if (!ap_rst_n) begin
            address_pending <= 0;
            data_pending <= 0;
            write_address <= 0;
            write_data <= 0;
            write_strobes <= 0;
            input_base <= 0;
            record_count <= 0;
            start <= 0;
            s_axi_control_bvalid <= 0;
            s_axi_control_rvalid <= 0;
            s_axi_control_rdata <= 0;
        end else begin
            start <= 0;
            if (s_axi_control_awvalid && s_axi_control_awready) begin
                write_address <= s_axi_control_awaddr;
                address_pending <= 1;
            end
            if (s_axi_control_wvalid && s_axi_control_wready) begin
                write_data <= s_axi_control_wdata;
                write_strobes <= s_axi_control_wstrb;
                data_pending <= 1;
            end
            if (s_axi_control_bvalid && s_axi_control_bready) s_axi_control_bvalid <= 0;
            if (address_pending && data_pending && !s_axi_control_bvalid) begin
                address_pending <= 0;
                data_pending <= 0;
                s_axi_control_bvalid <= 1;
                if (!busy) begin
                    case (write_address)
                        CONTROL: start <= masked_write[0];
                        BASE_LO: input_base[31:0] <= (input_base[31:0] & ~byte_mask) | masked_write;
                        BASE_HI: input_base[63:32] <= (input_base[63:32] & ~byte_mask) | masked_write;
                        RECORDS: record_count <= (record_count & ~byte_mask) | masked_write;
                        default: ;
                    endcase
                end
            end
            if (s_axi_control_rvalid && s_axi_control_rready) s_axi_control_rvalid <= 0;
            if (s_axi_control_arvalid && s_axi_control_arready) begin
                s_axi_control_rvalid <= 1;
                case (s_axi_control_araddr)
                    CONTROL: s_axi_control_rdata <= {29'b0, busy || start, fault && !start, done && !start};
                    BASE_LO: s_axi_control_rdata <= input_base[31:0];
                    BASE_HI: s_axi_control_rdata <= input_base[63:32];
                    RECORDS: s_axi_control_rdata <= record_count;
                    MATCH_LO: s_axi_control_rdata <= match_count[31:0];
                    MATCH_HI: s_axi_control_rdata <= match_count[63:32];
                    CHECKSUM: s_axi_control_rdata <= checksum;
                    default: s_axi_control_rdata <= 0;
                endcase
            end
        end
    end

    // This port issues one ordered AXI read burst at a time.
    assign m_axi_gmem_arcache = 4'b0011;
    assign m_axi_gmem_arprot = 3'b000;
    dataset_scan_reader reader (.*);
endmodule

module dataset_scan_reader (
    input  wire         ap_clk,
    input  wire         ap_rst_n,
    input  wire         start,
    input  wire [63:0]  input_base,
    input  wire [31:0]  record_count,
    output wire         busy,
    output reg          done,
    output reg          fault,
    output wire [63:0]  match_count,
    output wire [31:0]  checksum,
    output reg  [63:0]  m_axi_gmem_araddr,
    output wire [7:0]   m_axi_gmem_arlen,
    output wire [2:0]   m_axi_gmem_arsize,
    output wire [1:0]   m_axi_gmem_arburst,
    output wire         m_axi_gmem_arvalid,
    input  wire         m_axi_gmem_arready,
    input  wire [127:0] m_axi_gmem_rdata,
    input  wire [1:0]   m_axi_gmem_rresp,
    input  wire         m_axi_gmem_rlast,
    input  wire         m_axi_gmem_rvalid,
    output wire         m_axi_gmem_rready
);
    localparam [2:0] IDLE = 0, ADDRESS = 1, READ = 2, RESULT = 3, DRAIN = 4, ERROR = 5;
    reg [2:0] state;
    reg [31:0] remaining;
    reg [8:0] burst_left;
    wire [8:0] next_burst = remaining >= 256 ? 9'd256 : {1'b0, remaining[7:0]};
    wire [64:0] last_byte = {1'b0, input_base} + {29'b0, record_count, 4'b0} - 65'd1;
    wire bad_beat = m_axi_gmem_rresp != 2'b00 || m_axi_gmem_rlast != (burst_left == 1);
    wire record_ready, result_valid;

    assign busy = state != IDLE;
    assign m_axi_gmem_arlen = next_burst[7:0] - 8'd1;
    assign m_axi_gmem_arsize = 3'd4;
    assign m_axi_gmem_arburst = 2'b01;
    assign m_axi_gmem_arvalid = state == ADDRESS;
    assign m_axi_gmem_rready = state == DRAIN || (state == READ && record_ready);

    dataset_filter filter (
        .clk(ap_clk), .resetn(ap_rst_n && state != ERROR),
        .record_data(m_axi_gmem_rdata), .record_valid(state == READ && m_axi_gmem_rvalid && !bad_beat),
        .record_ready(record_ready), .record_last(remaining == 1),
        .result_valid(result_valid), .result_ready(state == RESULT),
        .match_count(match_count), .checksum(checksum)
    );

    always @(posedge ap_clk) begin
        if (!ap_rst_n) begin
            state <= IDLE;
            m_axi_gmem_araddr <= 0;
            remaining <= 0;
            burst_left <= 0;
            done <= 0;
            fault <= 0;
        end else begin
            case (state)
                IDLE: if (start) begin
                    done <= 0;
                    fault <= 0;
                    if (input_base[11:0] != 0 || record_count == 0 || last_byte[64]) begin
                        state <= ERROR;
                    end else begin
                        m_axi_gmem_araddr <= input_base;
                        remaining <= record_count;
                        state <= ADDRESS;
                    end
                end
                ADDRESS: if (m_axi_gmem_arready) begin
                    burst_left <= next_burst;
                    state <= READ;
                end
                READ: if (m_axi_gmem_rvalid && m_axi_gmem_rready) begin
                    if (bad_beat) begin
                        state <= m_axi_gmem_rlast ? ERROR : DRAIN;
                    end else begin
                        remaining <= remaining - 1'b1;
                        burst_left <= burst_left - 1'b1;
                        if (remaining == 1) begin
                            state <= RESULT;
                        end else if (burst_left == 1) begin
                            m_axi_gmem_araddr <= m_axi_gmem_araddr + 64'd4096;
                            state <= ADDRESS;
                        end
                    end
                end
                RESULT: if (result_valid) begin
                    done <= 1;
                    state <= IDLE;
                end
                DRAIN: if (m_axi_gmem_rvalid && m_axi_gmem_rlast) state <= ERROR;
                ERROR: begin
                    fault <= 1;
                    done <= 1;
                    state <= IDLE;
                end
                default: state <= ERROR;
            endcase
        end
    end
endmodule
