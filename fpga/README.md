# First FPGA tile prototype

The tile instantiates 16 PicoRV32 cores with independent registers and a shared read-only storage window. PicoRV32 is a compact RV32 core used here to bring up the tile's memory path. The project's intended RV64 application core and Linux support are separate integration work. [Pinned PicoRV32 source and license](https://github.com/YosysHQ/picorv32/tree/ef203c2b0a3fb793280f5114941416c425c5b461) · [OpenHW CVA6 application core](https://docs.openhwgroup.org/projects/cva6-user-manual/01_cva6_user/Introduction.html)

All 16 cores start at `0x10000ff8`, two words before the first page ends. Each runs the same program, reads its own core ID from `0x20000000`, adds 42, writes its result to `0x20000004`, and halts at `ebreak`. Each port has its own result register. A round-robin arbiter serves core requests through an 8 KiB block buffer shared by the tile. The reset clears page validity so the first instruction fetch must wait for the storage backend.

## Run the checks

Use Node.js and Icarus Verilog (`iverilog` and `vvp` on `PATH`). The runner downloads the pinned PicoRV32 RTL to a temporary directory and verifies its SHA-256. For offline use, set `PICORV32_RTL` to the exact file from the pinned commit.

```powershell
node fpga/verify.mjs
node fpga/verify.mjs --synth
node fpga/verify.mjs --full-scan
node fpga/verify.mjs --emit-boot-image tile-boot.bin
```

The optional synthesis check requires Yosys on `PATH` or the `YOSYS` environment variable set to its executable. It checks the tile with its AXI adapter and synthesizes the dataset scan kernel. It does not produce a bitstream or report board timing. The tests cover the 16-core boot, storage and AXI errors, the filter's output, and a complete dataset scan from a file through an AXI memory model. `--full-scan` uses the default 64 MiB benchmark dataset and may take a few minutes in Icarus Verilog. `--emit-boot-image` creates the same 8 KiB boot file for CPU tile bring-up and refuses to overwrite a file.

## Storage adapter contract

- The CPU window at `0x10000000`–`0x10001fff` selects the last two 4 KiB pages of a decimal 1 TB test image. The backend-facing page numbers are `244140623` and `244140624`. A future NVMe adapter must establish the actual namespace geometry and translate these page numbers into device LBAs.
- A request is accepted when `page_req_valid` and `page_req_ready` are both high. At most one request is outstanding. The backend returns 1,024 ordered little-endian 32-bit words, advancing only when `page_word_valid` and `page_word_ready` are high. It asserts `page_word_last` on the final word. On error it can terminate the response with `page_word_error`.
- The tile publishes a cached page only after a complete response. A signaled error, malformed final marker, or storage timeout raises a fault that stays set until reset. The timeout applies to a stalled request or to gaps between response words. `STORAGE_TIMEOUT_CYCLES` defaults to 1,000,000 cycles and must be positive. Reset must reset or drain the backend as well.

## Alveo U50 reference platform

AMD's Alveo U50 has 8 GB of HBM, and AMD publishes an XRT NVMe peer-to-peer example demonstrated on the U50. The reference setup uses a Linux server with a compatible Vitis/XRT deployment, a P2P-capable NVMe/FPGA PCIe topology, and an allocated peer-to-peer HBM buffer. The SSD and FPGA still transfer bytes over PCIe. In this first integration the host orchestrates the copy into HBM before releasing the tile to boot. The goal is to bypass host RAM for payload staging on a validated platform. [U50 features](https://docs.amd.com/r/en-US/ug1371-u50-reconfig-accel/Card-Features) · [AMD's U50 NVMe example](https://xilinx.github.io/Vitis_Accel_Examples/2025.2/html/p2p_simple_xrt.html) · [XRT P2P requirements](https://xilinx.github.io/XRT/2025.2/html/p2p.html)

`storage_tile_axi.sv` connects the tile to a 32-bit AXI4 read channel. Given a 4 KiB-aligned HBM buffer address, it maps the two logical pages to the first 8 KiB of that buffer. It issues four 256-beat bursts per page. The address range above 4 GB is exercised in simulation. The interface carries a single ordered read stream, so a platform wrapper must tie unused AXI attributes appropriately and adapt the data width to the selected HBM port. This adapter reads FPGA-attached memory. The Vitis shell and host P2P staging code are required to reach a physical SSD. [AMBA AXI4 specification](https://developer.arm.com/-/media/Arm%20Developer%20Community/PDF/IHI0022H_amba_axi_protocol_spec.pdf)

Board bring-up requires an RTL kernel wrapper that exposes the buffer address and exposes completion, fault, and result registers to XRT. Connect the master to an HBM bank and build the board-specific bitstream. Validate P2P on the installed platform with AMD's XRT tooling before staging the boot image into the mapped HBM buffer. Keep the tile in reset until the image transfer completes. The success criterion is all 16 results reading `42` through `57` on physical hardware. After an incomplete AXI transaction, reset or drain the outstanding transaction before restarting the tile. [XRT validation commands](https://xilinx.github.io/XRT/master/html/xrt-smi-alveo.html)

## Dataset-preparation baseline

```powershell
node benchmark.mjs
node benchmark.mjs --fixture records.bin --records 4194304
node benchmark.mjs --input records.bin
```

The CPU baseline filters fixed-size 16-byte records. Each record contains four little-endian `uint32` values in order: ID, token count, flags, and tag. A match has at least 128 tokens and bit 0 of flags set. Output is the match count and the sum of matching IDs modulo 2³². The 64 MiB default fixture has 4,194,304 records, 1,179,648 matches, and checksum 70,189,056. The benchmark excludes file creation and reports buffered I/O and scan time together. OS cache state is uncontrolled.

`dataset_scan.sv` reads the corpus from FPGA-attached memory and feeds `dataset_filter.sv` one 128-bit record per accepted beat. It issues bursts of up to 256 records from a 4 KiB-aligned base, shortens the last burst as needed, and drains a failed transaction through `RLAST` before accepting a retry. The integrated test compares count and checksum through the AXI-Lite registers. The [U50 benchmark build and run guide](vitis/README.md) covers packaging, P2P staging, and the physical acceptance test for this separate kernel.
