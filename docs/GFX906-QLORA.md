# gfx906 direct dispatch and QLoRA experiments

This overlay adds two experimental workstreams to `mi50-arm`:

1. Direct SDMA/PM4 submission and a partial HSA-compatible shim for gfx906.
2. A source-build path for ROCm math libraries, PyTorch 2.5.1, bitsandbytes,
   and a Qwen2.5-14B QLoRA example.

Neither workstream changes the recommended baseline: bring up amdgpu/KFD,
validate Vulkan, and validate the repository's existing HIP smoke test first.
The direct-dispatch and training code must be treated as experimental until
run on the actual MI50/RK3588 system.

## CI boundaries

`.github/workflows/gfx906-compile.yml` adds two jobs:

- `host-cpp` installs libdrm headers and compiles the shim and dispatcher on
  both x86_64 and native aarch64 Ubuntu runners. The aarch64 leg checks the
  `dsb sy` path used for ARM write-combined buffers. It also runs Bash syntax
  checks and Python bytecode compilation.
- `rocm-gfx906` uses AMD's ROCm 6.3.3 development image to generate a gfx906
  HSACO and compile the upstream bitsandbytes HIP backend with the explicit
  `BNB_ROCM_ARCH=gfx906` CMake override.

These are compile/code-generation checks only. CI has no MI50 device and does
not submit PM4 or SDMA, load the shim into ROCr, validate memory coherency, train
a model, or test 14B model fit/performance. An opt-in `workflow_dispatch`
job named `full-arm64-mi50-stack` runs the complete ROCm/PyTorch/bitsandbytes
build and NF4 smoke test on a self-hosted runner labelled
`self-hosted`, `linux`, `ARM64`, `mi50-arm64`; it is disabled by default and
requires an actual MI50 system with a supported Python interpreter and sudo.

## Direct-dispatch sources

Build on the ARM64 host (or x86 host for compile-only validation):

```bash
sudo apt-get install build-essential cmake ninja-build pkg-config libdrm-dev libdrm-amdgpu1
cmake -S experiments/gfx906 -B build/gfx906 -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build/gfx906 --parallel 2
```

Generate the test HSACO with ROCm 6.3.3:

```bash
hipcc --offload-arch=gfx906 --genco tests/vec_add.hip -o vec_add.hsaco
```

`dispatch_gfx906` expects `vec_add.hsaco` in its current working directory
and must only be executed on the target machine with a correctly powered and
cooled MI50. The PM4 packet length fields and HSA enum mappings were corrected
in the overlay after a static review. The encoder's second argument is
payload DWORD count: `DISPATCH_DIRECT` uses 4 payload DWORDs (encoded count 3)
and `ACQUIRE_MEM` uses 6 (encoded count 5). The cache-control mask includes
`TC_WB_ACTION_ENA` at bit 18 plus L1/L2 invalidation at bits 22/23, matching
Linux v6.12's GFX9 register definitions.

The shim waits for its per-queue compute IB fence before reusing that IB and
protects host-side signal fence state, but it is still not a production HSA
runtime. Queue teardown with concurrent host callers, outstanding allocations,
AQL scope semantics, full ELF relocation support, hidden kernel arguments, and
unimplemented HSA loader/memory/signal APIs remain blockers. The pool flags are
HSA's `KERNARG_INIT | FINE_GRAINED` (1 | 2) for GTT and `COARSE_GRAINED` (4)
for VRAM; those flags do not make non-coherent host memory coherent.

**Important RK3588 coherency requirement:** Linux ARM64 reports
`drm_arch_can_wc_memory() == false`, so upstream amdgpu can strip
`AMDGPU_GEM_CREATE_CPU_GTT_USWC`. `dsb sy` orders CPU stores but does not make
non-coherent PCIe mappings coherent. The direct-dispatch path's CPU-mapped GTT
rings, staging buffers and kernargs therefore depend on the repository's
experimental `patches/0001-drm-amdgpu-use-write-combined-GTT-on-non-coherent-hosts.patch`
(or an independently validated equivalent). Keep `HSA_USERPTR_FOR_PAGED_MEM=0`
for the normal ROCm/ROCR path on the RK3588 as documented in `scripts/rocm-env.sh`.

The shim does not implement the AMD loader extension table, `hsa_amd_memory_lock/unlock`,
`hsa_amd_pointer_info`, async signal handlers, or file-based code-object readers;
it rejects GOT relocations and kernels requiring unsupported hidden dispatch
SGPRs. It cannot currently run CLR/HIP, rocBLAS or PyTorch. On the recommended
mi50-arm kernel (`CONFIG_HSA_AMD=y`), use the real `/dev/kfd` and upstream ROCR;
keep this KFD-free shim only for isolated DRM/PM4 experiments or KFD-less
kernel diagnostics.

## PyTorch/ROCm source build

`scripts/build-rocm-math-and-torch.sh` builds the extended math stack and
PyTorch 2.5.1 for gfx906 under `/opt/rocm`. It is pinned to ROCm 6.3.3 to match
`mi50-arm`'s minimal ROCm build and exports `HSA_USERPTR_FOR_PAGED_MEM=0`
before any ROCm smoke test. It is intentionally excluded from
CI: it is a long, memory-intensive source build and the rocBLAS smoke test
requires a real GPU. The PyTorch 2.5.1 + ROCm 6.3.3 combination is a custom
source-build target, not an AMD-validated binary pairing: AMD's ROCm 6.3.x
compatibility tables list PyTorch 2.4.0 in their validated container matrix.
Treat the PyTorch build and its downstream bitsandbytes/QLoRA path as a
bring-up experiment until the MI50 smoke tests pass. Use `SKIP_ROCBLAS_GPU_SMOKE=1` only to skip that runtime
check on a build-only machine; skipping it does not establish rocBLAS works.

## bitsandbytes and QLoRA

`scripts/build-bitsandbytes-gfx906.sh` builds the HIP backend with
`BNB_ROCM_ARCH=gfx906`, applies a single CMake patch to make the hipBLASLt
link optional, and installs it without resolving dependencies. The patch is
pinned to bitsandbytes commit `f81c74f4496f16fe98a8939ceb50accd77c16e1c`;
it does not perform heuristic BF16 line wrapping or modify the Python loader.
The pinned Hugging Face requirements resolve the non-Torch transitive
dependencies while preserving the custom ROCm PyTorch wheel. The QLoRA path
uses FP16 compute and disables BF16/flash/memory-efficient SDPA in the
training configuration.

Set `MODEL_ID`, `DATASET_PATH`, and optionally `OUTPUT_DIR`, then run:

```bash
MODEL_ID=/path/to/Qwen2.5-0.5B DATASET_PATH=/path/to/smoke-dataset \
  MAX_STEPS=20 scripts/train-qwen14b-qlora.sh
```

Use the small checkpoint and a short run first; remove `MAX_STEPS=20` when
moving to the full training schedule. The training script disables KV caching
while gradient checkpointing is active.

The paths must point to local model and `datasets.load_from_disk` directories.
The wrapper attempts to set a 165 W power cap where the relevant sysfs file is
writable (or passwordless sudo is available). Verify the card's supported cap
and cooling before using a sustained training load. Start with a small model
and a short smoke run before attempting Qwen2.5-14B. The trainer counts
non-masked labels after the causal one-token shift across the complete gradient
accumulation window. Each micro-batch contributes its summed token loss divided
by that shared count, so accumulated gradients equal the window-wide token mean.
With the pinned Transformers 4.46.3 / Accelerate 1.1.1 stack, Trainer owns the
accumulation loop and constructs Accelerator without forwarding the training
argument's accumulation count. The script pins
`ACCELERATE_GRADIENT_ACCUMULATION_STEPS=1` to prevent a shell-level environment
override from applying a second loss division.

The `requirements-qlora.txt` file pins the Hugging Face package set and the
runtime dependencies needed when installing with `--no-deps`. Install the
custom ROCm PyTorch wheel first; do not let pip resolve or replace it with a
CPU/CUDA wheel. Review these dependency pins together if you change the
Transformers/TRL versions.
