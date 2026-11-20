`timescale 1ns/1ps

module dataset_scan_tb;
    localparam [63:0] BASE = 64'h0000_0001_0000_3000;
    reg ap_clk = 0, ap_rst_n = 0;
    always #5 ap_clk = ~ap_clk;

    reg [11:0] s_axi_control_awaddr = 0, s_axi_control_araddr = 0;
    reg [31:0] s_axi_control_wdata = 0;
    reg [3:0] s_axi_control_wstrb = 0;
    reg s_axi_control_awvalid = 0, s_axi_control_wvalid = 0, s_axi_control_arvalid = 0;
    reg s_axi_control_bready = 0, s_axi_control_rready = 0;
    wire s_axi_control_awready, s_axi_control_wready, s_axi_control_bvalid;
    wire s_axi_control_arready, s_axi_control_rvalid;
    wire [1:0] s_axi_control_bresp, s_axi_control_rresp;
    wire [31:0] s_axi_control_rdata;

    wire [63:0] m_axi_gmem_araddr;
    wire [7:0] m_axi_gmem_arlen;
    wire [2:0] m_axi_gmem_arsize, m_axi_gmem_arprot;
    wire [1:0] m_axi_gmem_arburst;
    wire [3:0] m_axi_gmem_arcache;
    wire m_axi_gmem_arvalid, m_axi_gmem_rready;
    reg [127:0] m_axi_gmem_rdata;
    reg active = 0, stalled = 0;
    reg [63:0] held_address;
    reg [7:0] held_length;
    integer file, mode = 0, length, beat, requested_records;
    integer bursts = 0, bytes_read = 0, scan_start_bytes = -1;
    integer fixture_records, fixture_matches, fixture_checksum;
    wire m_axi_gmem_arready = !active && stalled;
    wire m_axi_gmem_rvalid = active;
    wire [1:0] m_axi_gmem_rresp = mode == 1 && beat == 1 ? 2'b10 : 2'b00;
    wire m_axi_gmem_rlast = beat == (mode == 2 ? length : length - 1);

    dataset_scan dut (.*);

    task load_record;
        reg [127:0] from_file;
        if ($fread(from_file, file) != 16) $fatal(1, "Truncated dataset fixture");
        m_axi_gmem_rdata <= {from_file[7:0], from_file[15:8], from_file[23:16], from_file[31:24],
                            from_file[39:32], from_file[47:40], from_file[55:48], from_file[63:56],
                            from_file[71:64], from_file[79:72], from_file[87:80], from_file[95:88],
                            from_file[103:96], from_file[111:104], from_file[119:112], from_file[127:120]};
    endtask

    always @(posedge ap_clk) begin
        if (ap_rst_n) begin
            if (stalled && (m_axi_gmem_arvalid !== 1'b1 || m_axi_gmem_araddr !== held_address ||
                            m_axi_gmem_arlen !== held_length))
                $fatal(1, "AXI burst changed under backpressure");
            stalled <= m_axi_gmem_arvalid && !m_axi_gmem_arready;
            if (m_axi_gmem_arvalid && !m_axi_gmem_arready) begin
                held_address <= m_axi_gmem_araddr;
                held_length <= m_axi_gmem_arlen;
            end
            if (m_axi_gmem_arvalid && m_axi_gmem_arready) begin
                integer offset, records_left, expected_length;
                offset = 32'(m_axi_gmem_araddr - BASE);
                records_left = requested_records - offset/16;
                expected_length = records_left > 256 ? 256 : records_left;
                if (m_axi_gmem_araddr < BASE || (m_axi_gmem_araddr - BASE) >= 64'(requested_records)*16 ||
                    m_axi_gmem_araddr[11:0] != 0 || m_axi_gmem_arburst != 1 || m_axi_gmem_arsize != 4 ||
                    int'(m_axi_gmem_arlen) + 1 != expected_length)
                    $fatal(1, "Unexpected burst at %h len=%d", m_axi_gmem_araddr, m_axi_gmem_arlen);
                if ($fseek(file, offset, 0) != 0) $fatal(1, "Cannot seek to fixture data");
                load_record();
                active <= 1;
                beat <= 0;
                length <= expected_length;
                bursts <= bursts + 1;
            end
            if (m_axi_gmem_rvalid && m_axi_gmem_rready) begin
                bytes_read <= bytes_read + 16;
                if (fixture_records > 1025 && scan_start_bytes >= 0 &&
                    ((bytes_read + 16 - scan_start_bytes) % 16777216) == 0)
                    $display("RTL scan consumed %0d MiB", (bytes_read + 16 - scan_start_bytes)/1048576);
                if (m_axi_gmem_rlast) active <= 0;
                else begin
                    load_record();
                    beat <= beat + 1;
                end
            end
        end
    end

    task write_register(input [11:0] addr, input [31:0] data, input [3:0] mask);
        // Exercise independent AXI-Lite write channels by sending data first.
        @(negedge ap_clk);
        s_axi_control_wdata = data;
        s_axi_control_wstrb = mask;
        s_axi_control_wvalid = 1;
        do @(posedge ap_clk); while (!s_axi_control_wready);
        @(negedge ap_clk);
        s_axi_control_wvalid = 0;
        s_axi_control_awaddr = addr;
        s_axi_control_awvalid = 1;
        do @(posedge ap_clk); while (!s_axi_control_awready);
        @(negedge ap_clk);
        s_axi_control_awvalid = 0;
        wait (s_axi_control_bvalid);
        repeat (2) @(negedge ap_clk);
        if (!s_axi_control_bvalid || s_axi_control_bresp != 0) $fatal(1, "AXI-Lite write failed");
        s_axi_control_bready = 1;
        @(negedge ap_clk);
        s_axi_control_bready = 0;
    endtask

    task read_register(input [11:0] addr, input [31:0] expect_data);
        @(negedge ap_clk);
        s_axi_control_araddr = addr;
        s_axi_control_arvalid = 1;
        do @(posedge ap_clk); while (!s_axi_control_arready);
        @(negedge ap_clk);
        s_axi_control_arvalid = 0;
        wait (s_axi_control_rvalid);
        repeat (2) @(negedge ap_clk);
        if (!s_axi_control_rvalid || s_axi_control_rresp != 0 || s_axi_control_rdata !== expect_data)
            $fatal(1, "Register %h returned %h instead of %h", addr, s_axi_control_rdata, expect_data);
        s_axi_control_rready = 1;
        @(negedge ap_clk);
        s_axi_control_rready = 0;
    endtask

    task launch(input [63:0] base, input integer count);
        requested_records = count;
        write_register(12'h010, base[31:0], 4'hf);
        write_register(12'h014, base[63:32], 4'hf);
        write_register(12'h018, count, 4'hf);
        write_register(12'h000, 1, 4'h1);
        wait (dut.done === 1'b1);
    endtask

    initial begin
        integer before_bursts, before_bytes;
        if (!$value$plusargs("records=%d", fixture_records) || !$value$plusargs("matches=%d", fixture_matches) ||
            !$value$plusargs("checksum=%d", fixture_checksum)) $fatal(1, "Missing fixture metadata");
        file = $fopen("records.bin", "rb");
        if (!file) $fatal(1, "Missing records.bin");
        repeat (4) @(negedge ap_clk);
        ap_rst_n = 1;

        launch(BASE + 4, 3);
        read_register(12'h000, 3);
        launch(BASE, 0);
        read_register(12'h000, 3);
        launch(64'hffff_ffff_ffff_f000, 257);
        read_register(12'h000, 3);
        if (bursts != 0) $fatal(1, "Invalid arguments caused AXI reads");

        mode = 1;
        launch(BASE, 3);
        read_register(12'h000, 3);
        if (bursts != 1 || bytes_read != 48) $fatal(1, "AXI error did not drain transaction");
        mode = 2;
        launch(BASE, 3);
        read_register(12'h000, 3);
        if (bursts != 2 || bytes_read != 112) $fatal(1, "Malformed burst did not drain transaction");

        mode = 0;
        before_bursts = bursts;
        before_bytes = bytes_read;
        scan_start_bytes = before_bytes;
        launch(BASE, fixture_records);
        read_register(12'h000, 1);
        read_register(12'h020, fixture_matches);
        read_register(12'h024, 0);
        read_register(12'h028, fixture_checksum);
        if (bursts - before_bursts != (fixture_records + 255)/256 || bytes_read - before_bytes != fixture_records*16)
            $fatal(1, "Wrong normal scan traffic");
        $display("PASS: integrated AXI scan of %0d file records, %0d matches, checksum %0d",
                 fixture_records, fixture_matches, fixture_checksum);
        $display("PASS: AXI-Lite stalls, argument validation, malformed response drain, and restart");
        $fclose(file);
        $finish;
    end

    initial begin
        #1000;
        #(fixture_records*20 + 100000);
        $fatal(1, "Dataset scan timed out (%0d bursts, %0d bytes)", bursts, bytes_read);
    end
endmodule
