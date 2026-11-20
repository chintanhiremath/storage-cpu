`timescale 1ns/1ps

module storage_tile_axi_tb;
    localparam [63:0] BASE = 64'h0000_0001_0000_3000;
    reg clk = 0, resetn = 0;
    always #5 clk = ~clk;

    integer mode = 0;
    wire [63:0] buffer_base = mode == 4 ? BASE + 4 : BASE;
    wire [63:0] m_axi_araddr;
    wire [7:0] m_axi_arlen;
    wire [2:0] m_axi_arsize;
    wire [1:0] m_axi_arburst;
    wire m_axi_arvalid, m_axi_rready, fault;
    wire [15:0] result_valid, core_trap;
    wire [511:0] results;

    reg [7:0] image [0:8191];
    integer cycle, bursts, beats, beat, burst_offset, address_stalls;
    reg active, ar_stalled, r_stalled;
    reg [63:0] held_address;
    wire m_axi_arready = !active && ar_stalled && cycle % 4 == 1;
    wire m_axi_rvalid = active && (r_stalled || cycle % 5 != 0);
    wire [1:0] m_axi_rresp = mode == 2 && beat == 0 ? 2'b10 : 2'b00;
    wire m_axi_rlast = beat == (mode == 1 ? 3 : mode == 3 ? 256 : 255);
    wire [31:0] m_axi_rdata = {image[burst_offset + beat*4 + 3], image[burst_offset + beat*4 + 2],
                              image[burst_offset + beat*4 + 1], image[burst_offset + beat*4]};

    storage_tile_axi #(.STORAGE_TIMEOUT_CYCLES(64)) dut (.*);

    always @(posedge clk) begin
        if (!resetn) begin
            cycle <= 0;
            bursts <= 0;
            beats <= 0;
            beat <= 0;
            burst_offset <= 0;
            address_stalls <= 0;
            active <= 0;
            ar_stalled <= 0;
            r_stalled <= 0;
            held_address <= 0;
        end else begin
            cycle <= cycle + 1;
            ar_stalled <= m_axi_arvalid && !m_axi_arready;
            r_stalled <= m_axi_rvalid && !m_axi_rready;
            if (ar_stalled && (!m_axi_arvalid || m_axi_araddr !== held_address))
                $fatal(1, "AXI address changed while stalled");
            if (m_axi_arvalid && !m_axi_arready) begin
                held_address <= m_axi_araddr;
                address_stalls <= address_stalls + 1;
            end
            if (m_axi_arvalid && m_axi_arready) begin
                if (bursts >= 8 || m_axi_araddr !== BASE + 64'(bursts * 1024) ||
                    m_axi_arlen !== 8'd255 || m_axi_arsize !== 3'd2 || m_axi_arburst !== 2'b01)
                    $fatal(1, "Unexpected AXI burst %0d at %h", bursts, m_axi_araddr);
                burst_offset <= bursts * 1024;
                bursts <= bursts + 1;
                beat <= 0;
                active <= 1;
            end
            if (m_axi_rvalid && m_axi_rready) begin
                beats <= beats + 1;
                if (m_axi_rlast) active <= 0;
                else beat <= beat + 1;
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
        integer file, size;
        file = $fopen("boot-pages.bin", "rb");
        if (!file) $fatal(1, "Missing boot-pages.bin");
        size = $fread(image, file);
        $fclose(file);
        if (size != 8192) $fatal(1, "Invalid boot image length %0d", size);

        for (integer failure = 1; failure <= 4; failure = failure + 1) begin
            start(failure);
            wait (fault === 1'b1);
            wait (!active);
            repeat (3) @(negedge clk);
            if (result_valid !== 16'b0 || core_trap !== 16'b0 || m_axi_arvalid || m_axi_rready ||
                bursts != (failure == 4 ? 0 : 1) ||
                beats != (failure == 1 ? 4 : failure == 2 ? 256 : failure == 3 ? 257 : 0))
                $fatal(1, "AXI fault case %0d: bursts=%0d beats=%0d results=%h", failure, bursts, beats, result_valid);
        end

        start(0);
        wait (core_trap === 16'hffff || fault === 1'b1);
        @(negedge clk);
        if (fault || result_valid !== 16'hffff || bursts != 8 || beats != 2048 || address_stalls < 8)
            $fatal(1, "AXI boot: fault=%b results=%h bursts=%0d beats=%0d stalls=%0d",
                   fault, result_valid, bursts, beats, address_stalls);
        for (integer id = 0; id < 16; id = id + 1)
            if (results[id*32 +: 32] !== 42 + id)
                $fatal(1, "AXI boot: core %0d returned %0d", id, results[id*32 +: 32]);

        $display("PASS: 16-core AXI boot, 8 bursts, 8192 bytes from file-backed simulated HBM");
        $display("PASS: AXI address stalls, response errors, burst length errors, and alignment checks");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "AXI test timed out: mode=%0d fault=%b results=%h bursts=%0d beats=%0d",
               mode, fault, result_valid, bursts, beats);
    end
endmodule
