# Alveo U50 dataset benchmark

The `dataset_scan` user-managed RTL kernel reads records from HBM and exposes count and checksum through AXI-Lite. This Vitis build targets the scan kernel. The 16-core boot tile is verified separately in RTL simulation.

## Build on Linux

Use a compatible Vivado, Vitis, and XRT installation with the U50 XDMA platform. Source the vendor environment before running `make`. The default platform is `xilinx_u50_gen3x16_xdma_5_202210_1`. `PLATFORM` can override it when using a compatible platform installed on the server. `make` invokes `package_xo`, links the hardware `.xclbin`, and builds the XRT host executable. [U50 XDMA platform](https://docs.amd.com/r/en-US/ug1120-alveo-platforms/U50-Gen3x16-XDMA-base_5-Platform) · [Vivado RTL kernel packaging](https://docs.amd.com/r/en-US/ug1700-vitis-accelerated-data-center/Packaging-the-RTL-Code-as-a-Vitis-XO)

```bash
make -C fpga/vitis
```

## Run the comparison

Confirm P2P is enabled on the installed U50 and validate the card and the path to the NVMe SSD using the XRT and AMD NVMe P2P validation tools. Use a regular file on that SSD. The host opens the file read-only with `O_DIRECT` and stages it into an XRT P2P HBM buffer. The file length must be a multiple of 4096 bytes and fit the connected HBM bank. The host has no buffered fallback. [XRT peer-to-peer requirements](https://xilinx.github.io/XRT/2025.2/html/p2p.html) · [AMD NVMe P2P validation](https://xilinx.github.io/xbtest/doc/main/user-guide/build/html/docs/test-cases/p2p-nvme-test-case-description.html)

```bash
node benchmark.mjs --fixture /mnt/nvme/records.bin --runs 3
fpga/vitis/build/dataset_scan_host \
  fpga/vitis/build/dataset_scan.xclbin \
  /mnt/nvme/records.bin 1179648 70189056
```

The default 64 MiB dataset has 4,194,304 records. Both paths must report 1,179,648 matches and checksum 70,189,056. The host executable reports staging time, scan plus result-read time, and total throughput. These timings exclude bitstream loading. The device returns a 12-byte result plus register control traffic. The 64 MiB input still crosses the PCIe peer link. Validate the physical route before reporting avoided host-RAM traffic. For a fair comparison, record filesystem and cache conditions for both runs. The CPU baseline uses buffered I/O.

## Control registers

| Offset | Register |
| --- | --- |
| `0x00` | Write bit 0 to start. Read bits 0, 1, and 2 for done, fault, and busy. Completion stays latched until the next launch. |
| `0x10`, `0x14` | Low and high words of the 4 KiB-aligned HBM address. |
| `0x18` | Number of 16-byte records. |
| `0x20`, `0x24` | Low and high words of the 64-bit match count. |
| `0x28` | Sum of matching IDs modulo 2³². |

The kernel reports invalid arguments and AXI response errors through the fault bit. If the host times out because a transaction never finishes, reset the compute unit before reusing it. Device bitstream linking, board timing, and the physical P2P benchmark require the vendor toolchain and a compatible U50 server.
