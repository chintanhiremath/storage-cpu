# Storage CPU

An experimental RISC-V computational storage project with a 256-core functional simulator, a 16-core PicoRV32 RTL tile, and an FPGA dataset scan kernel. The Alveo U50 build targets the scan kernel. Board timing and the physical NVMe peer-to-peer path still need hardware validation.

## Run the simulator

This simulator runs an RV64 program on a drive-side processor with a simulated 1 TB SSD. The multicore design has 16 tiles of 16 cores, with one execution context per core. Each tile shares about 4 GB of DRAM page cache. The 64 GB total is divided as evenly as whole 4 KiB pages allow. The program and input are already stored on the drive. The CPU reads them through a read-only address window starting at `0x1_0000_0000`. The simulator allocates cache memory only for pages it touches.

```powershell
node demo.mjs
node demo.mjs --read-result
```

The single-core demo starts near the end of the SSD, loads its input from flash, loops across two 4 KiB blocks, and writes `42` to local working RAM. The multicore demo interleaves one instruction at a time across 256 independent contexts. Each core seeds its calculation with its core ID and writes its own result to private working RAM. The simulator verifies every result and runs both cold and warm cache cases. The `--read-result` option transfers the single-core 8-byte result across the modeled host link after that run.

| Execution | Cache | Flash block reads | Flash bytes read | Host payload bytes during execution |
| --- | ---: | ---: | ---: | ---: |
| Host CPU | 8 KiB | 2 | 8,192 | 8,192 |
| Host CPU | 4 KiB | 6 | 24,576 | 24,576 |
| One drive-side core, cold | 64 GB | 2 | 8,192 | 0 |
| One drive-side core, warm | 64 GB | 0 | 0 | 0 |
| 256 drive-side cores, cold | 16 × 4 GB | 32 | 131,072 | 0 |
| 256 drive-side cores, warm | 16 × 4 GB | 0 | 0 | 0 |

There is no preload into working RAM. On a cold start, each tile reads the same two blocks once for its 16 cores. A cache hit still delivers instruction or data bytes to a core locally. These counters cover payload bytes. They exclude boot firmware, installing the program and input before the run, and any command or completion traffic from a host-controlled implementation.

## Hardware design

```text
Drive side
  1 TB NAND flash --> flash controller --> on-chip interconnect
                                                   |
                                  16 tiles, each with 16 RISC-V cores
                                  and a 4 GB local DRAM page-cache slice

Host link carries control commands and optional results.
```

The physical design would use small SRAM caches per core and place storage tasks near their tile's DRAM. The interconnect must handle traffic from all tiles, and the flash controller can limit cold-read throughput even with many idle cores. Shared writable memory would require a coherence and synchronization design. The current model uses read-only shared pages and private working RAM for each core. [Linux NUMA documentation](https://docs.kernel.org/mm/numa.html) · [RISC-V memory model](https://docs.riscv.org/reference/isa/unpriv/rvwmo.html)

An autonomous device could start from local firmware and keep the result on-device to avoid both a host launch command and a result transfer. NAND still has to be read on a cold cache miss, and the core still has to fetch instructions even when the cache is warm.

The simulator implements `ADDI`, `AUIPC`, `BNE`, `LD`, `SD`, and a debug stop using `EBREAK`. It checks functional behavior and payload transfers. It does not model parallel hardware timing, cache coherence, interconnect contention, or SSD timing.

The [first FPGA tile prototype](fpga/README.md) uses 16 PicoRV32 cores and a shared hardware storage-read bridge. It includes an RTL simulation and an optional generic synthesis check.

The [GPU training design](gpu-training.md) extends this architecture with a separate accelerator, GPU memory, and a sizing tool for full LLM training.

[RISC-V unprivileged specification](https://docs.riscv.org/reference/isa/unpriv/rv-32-64g.html) · [SNIA computational storage architecture](https://www.snia.org/educational-library/computational-storage-architecture-and-programming-model-v11-2025) · [NVMe Computational Programs command set](https://nvmexpress.org/specification/computational-programs-command-set/)

## License

Project sources and documentation are licensed under the [Apache License 2.0](LICENSE). The RTL verification runner downloads a pinned copy of [PicoRV32](https://github.com/YosysHQ/picorv32/tree/ef203c2b0a3fb793280f5114941416c425c5b461), which is distributed separately under its upstream license.
