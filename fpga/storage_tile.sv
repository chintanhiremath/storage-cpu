`timescale 1ns/1ps

module storage_tile #(
    parameter integer STORAGE_TIMEOUT_CYCLES = 1_000_000,
    parameter [27:0] FIRST_LBA = 28'd244140623
) (
    input  wire         clk,
    input  wire         resetn,
    output wire         page_req_valid,
    input  wire         page_req_ready,
    output wire [27:0]  page_req_lba,
    input  wire         page_word_valid,
    output wire         page_word_ready,
    input  wire [31:0]  page_word_data,
    input  wire         page_word_last,
    input  wire         page_word_error,
    output wire [15:0]  result_valid,
    output wire [511:0] results,
    output wire [15:0]  core_trap,
    output wire         fault
);
    wire [15:0] read_valid, read_ready, bad_access;
    wire [511:0] read_addr;
    wire [31:0] read_data;
    wire bridge_fault;
    assign fault = bridge_fault | (|bad_access);

    for (genvar id = 0; id < 16; id = id + 1) begin : cores
        localparam [31:0] CORE_ID = id;
        wire valid, instr, ready;
        wire [31:0] addr, wdata, rdata;
        wire [3:0] wstrb;
        reg done, illegal;
        reg [31:0] result;

        wire storage_read = (addr & 32'hffff_e000) == 32'h1000_0000 && wstrb == 0;
        wire id_read = addr == 32'h2000_0000 && !instr && wstrb == 0;
        wire result_write = addr == 32'h2000_0004 && !instr && wstrb == 4'hf;
        assign read_valid[id] = valid && storage_read && !fault;
        assign read_addr[id*32 +: 32] = addr;
        assign ready = !fault && (read_ready[id] || id_read || result_write);
        assign rdata = id_read ? CORE_ID : read_data;
        assign bad_access[id] = illegal;
        assign result_valid[id] = done;
        assign results[id*32 +: 32] = result;

        always @(posedge clk) begin
            if (!resetn) begin
                done <= 0;
                illegal <= 0;
                result <= 0;
            end else if (valid && !fault) begin
                if (ready && result_write) begin
                    done <= 1;
                    result <= wdata;
                end
                if (!storage_read && !id_read && !result_write)
                    illegal <= 1;
            end
        end

        picorv32 #(.PROGADDR_RESET(32'h1000_0ff8), .ENABLE_COUNTERS(0)) cpu (
            .clk(clk), .resetn(resetn), .trap(core_trap[id]),
            .mem_valid(valid), .mem_instr(instr), .mem_ready(ready),
            .mem_addr(addr), .mem_rdata(rdata), .mem_wdata(wdata), .mem_wstrb(wstrb),
            .irq(32'b0), .pcpi_wr(1'b0), .pcpi_rd(32'b0),
            .pcpi_wait(1'b0), .pcpi_ready(1'b0)
        );
    end

    storage_read_bridge #(.TIMEOUT_CYCLES(STORAGE_TIMEOUT_CYCLES), .FIRST_LBA(FIRST_LBA)) bridge (
        .clk(clk), .resetn(resetn), .read_valid(read_valid), .read_addr(read_addr),
        .read_ready(read_ready), .read_data(read_data), .fault(bridge_fault),
        .page_req_valid(page_req_valid), .page_req_ready(page_req_ready),
        .page_req_lba(page_req_lba), .page_word_valid(page_word_valid),
        .page_word_ready(page_word_ready), .page_word_data(page_word_data),
        .page_word_last(page_word_last), .page_word_error(page_word_error)
    );
endmodule

module storage_read_bridge #(
    parameter integer TIMEOUT_CYCLES = 1_000_000,
    parameter [27:0] FIRST_LBA = 28'd244140623
) (
    input  wire         clk,
    input  wire         resetn,
    input  wire [15:0]  read_valid,
    input  wire [511:0] read_addr,
    output reg  [15:0]  read_ready,
    output reg  [31:0]  read_data,
    output wire         page_req_valid,
    input  wire         page_req_ready,
    output wire [27:0]  page_req_lba,
    input  wire         page_word_valid,
    output wire         page_word_ready,
    input  wire [31:0]  page_word_data,
    input  wire         page_word_last,
    input  wire         page_word_error,
    output wire         fault
);
    localparam [2:0] IDLE = 0, REQUEST = 1, FILL = 2, READ_WORD = 3, RESPOND = 4, FAILED = 5;
    localparam integer WAIT_WIDTH = $clog2(TIMEOUT_CYCLES + 1);
    localparam [WAIT_WIDTH-1:0] LAST_WAIT = WAIT_WIDTH'(TIMEOUT_CYCLES - 1);
    reg [2:0] state;
    reg [31:0] cache [0:2047];
    reg [1:0] cached;
    reg [3:0] next_core, owner, grant;
    reg grant_valid;
    reg [10:0] word_index;
    reg [9:0] fill_index;
    reg [WAIT_WIDTH-1:0] wait_cycles;

    wire [31:0] grant_addr = read_addr[grant*32 +: 32];
    wire selected_page = word_index[10];
    wire final_word = fill_index == 10'd1023;
    wire waiting = (state == REQUEST && !page_req_ready) || (state == FILL && !page_word_valid);
    wire timed_out = waiting && wait_cycles == LAST_WAIT;
    assign fault = state == FAILED;
    assign page_req_valid = state == REQUEST;
    assign page_req_lba = FIRST_LBA + {27'b0, selected_page};
    assign page_word_ready = state == FILL;

    always @* begin
        grant = next_core;
        grant_valid = 0;
        for (integer offset = 0; offset < 16; offset = offset + 1) begin
            if (!grant_valid && read_valid[$unsigned(4'(int'(next_core) + offset))]) begin
                grant = 4'(int'(next_core) + offset);
                grant_valid = 1;
            end
        end
        read_ready = 0;
        if (state == RESPOND) read_ready[owner] = 1;
    end

    always @(posedge clk) begin
        if (!resetn) begin
            state <= IDLE;
            cached <= 0;
            next_core <= 0;
            owner <= 0;
            word_index <= 0;
            fill_index <= 0;
            read_data <= 0;
            wait_cycles <= 0;
        end else if (timed_out) begin
            state <= FAILED;
        end else begin
            wait_cycles <= waiting ? wait_cycles + 1'b1 : 0;
            case (state)
                IDLE: if (grant_valid) begin
                    owner <= grant;
                    word_index <= grant_addr[12:2];
                    state <= cached[grant_addr[12]] ? READ_WORD : REQUEST;
                end
                REQUEST: if (page_req_ready) begin
                    fill_index <= 0;
                    state <= FILL;
                end
                FILL: if (page_word_valid) begin
                    if (page_word_error || page_word_last != final_word) begin
                        state <= FAILED;
                    end else begin
                        cache[{selected_page, fill_index}] <= page_word_data;
                        if (final_word) begin
                            cached[selected_page] <= 1;
                            state <= READ_WORD;
                        end else begin
                            fill_index <= fill_index + 1'b1;
                        end
                    end
                end
                READ_WORD: begin
                    read_data <= cache[word_index];
                    state <= RESPOND;
                end
                RESPOND: if (read_valid[owner]) begin
                    next_core <= owner + 1'b1;
                    state <= IDLE;
                end
                FAILED: state <= FAILED;
                default: state <= FAILED;
            endcase
        end
    end
endmodule
