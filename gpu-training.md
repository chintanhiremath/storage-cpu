# GPU extension for LLM training

Use NVIDIA B300 as the reference accelerator, with 288 GB of HBM3e per GPU in NVIDIA's HGX specifications. The 256-core RISC-V subsystem handles drive-side tasks and shares the existing 1 TB SSD and 64 GB page cache across its 16 tiles. Add a GPU subsystem with its own HBM and a supported Linux controller to run the GPU drivers and training software. An eight-GPU HGX configuration uses NVLink for GPU-to-GPU traffic. Larger builds need a network fabric between nodes. [NVIDIA HGX B300 reference architecture](https://docs.nvidia.com/enterprise-reference-architectures/hgx-ai-factory/latest/components.html)

```text
256 RISC-V cores <--> 64 GB page cache <--> 1 TB SSD
                                           |
                               local PCIe / GPUDirect Storage
                                           |
                               GPU HBM <--> GPU compute
                                           |
                               NVLink and inter-node fabric
```

With a verified GPUDirect Storage route, storage DMA can stream tokenized batches into GPU memory without staging them in CPU RAM. The RISC-V core's 64 GB cache is outside this direct data path. Training weights, gradients, optimizer state, and active tensors live in GPU memory in this design. Initial model state and batches still move into HBM, GPU peers exchange tensors when training is distributed, and checkpoints move back to storage. A remote workstation can submit jobs without carrying the dataset if the data and training storage are already local to the training system. [GPUDirect Storage requirements](https://docs.nvidia.com/gpudirect-storage/o-direct-guide/gpudirect-storage-requirements.html) · [Megatron Core parallelism guide](https://docs.nvidia.com/megatron-core/developer-guide/latest/user-guide/parallelism-guide.html)

## Capacity estimates

The planner assumes a dense model with BF16 weights and gradients plus FP32 master weights and two FP32 AdamW moment arrays. That is 16 bytes per parameter for training state. One checkpoint contains the weights, master weights, and optimizer moments at 14 bytes per parameter. It excludes gradients, file overhead, and small resume metadata such as training step and random-number-generator state. Actual frameworks may store different tensor formats.

| Parameters | Training state | Minimum B300 GPUs with 20% HBM reserved | One checkpoint |
| --- | ---: | ---: | ---: |
| 7B | 112 GB | 1 | 98 GB |
| 70B | 1,120 GB | 5 | 980 GB |
| 405B | 6,480 GB | 29 | 5,670 GB |

These are capacity floors assuming even sharding. The 20% reserve is a sizing assumption for activations, temporary tensors, and communications. Batch size, sequence length, activation checkpointing, framework behavior, and sharding efficiency determine actual peaks. A 70B design can start with an eight-GPU node as the reference configuration. A 405B design needs multiple nodes and storage beyond the original SSD. More GPUs may be required to reach a practical training time. [PyTorch fully sharded data parallelism](https://docs.pytorch.org/docs/stable/fsdp.html)

```powershell
node training-plan.mjs
node training-plan.mjs --model-b 70 --gpus 8 --storage-tb 4 --dataset-gb 500 --checkpoint-copies 2
```

The example budgets 2,460 GB for a 500 GB dataset and two modeled 70B checkpoints. The default excludes the dataset because its size is unspecified. The existing 1 TB SSD can serve as a local input cache while a larger local NVMe tier or storage system holds datasets and checkpoints. The tool checks capacity only. It does not estimate training time, execute GPU kernels, or validate a physical direct-storage route.
