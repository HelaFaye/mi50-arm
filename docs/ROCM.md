# ROCm on aarch64 for gfx906

AMD publishes no aarch64 ROCm packages, so you have to build it.
`scripts/build-rocm-aarch64.sh` builds the minimum llama.cpp needs, at tag
`rocm-6.3.3`, for gfx906 only, into `/opt/rocm`:

| Stage | Source | Provides |
| --- | --- | --- |
| `rocm_cmake` | ROCm/rocm-cmake | CMake helpers |
| `llvm` | ROCm/llvm-project | clang, lld, compiler-rt builtins, the AMDGPU backend (`/opt/rocm/llvm`, also linked as `/opt/rocm/lib/llvm`) |
| `device_libs`, `comgr`, `hipcc` | ROCm/llvm-project `amd/*` | device bitcode libraries, code-object manager, hipcc |
| `rocr` | ROCm/ROCR-Runtime | `libhsa-runtime64`, `libhsakmt` (ROCT was merged into ROCR in 6.3) |
| `rocminfo` | ROCm/rocminfo | `rocminfo`, `rocm_agent_enumerator` |
| `hip` | ROCm/clr + ROCm/HIP | `libamdhip64`, HIP headers |
| `hipblas_common`, `rocblas`, `hipblas` | ROCm/* | BLAS for llama.cpp |

No source patches are needed. Every one of these projects is portable C++, and
the GPU code comes from LLVM's AMDGPU backend whatever the host architecture.
The script does fix up three things a plain source build lacks compared to
AMD's packages (each one was found by running the build):

- compiler-rt builtins, which `hip::host` links;
- the `lib/llvm` path, where hipcc looks for clang;
- the `amdclang`/`amdclang++` names, which Tensile looks for.

## Why 6.3.3

gfx906 entered maintenance in ROCm 6.x, and newer releases trim its rocBLAS
kernels and test coverage. 6.3.3 is the last release where gfx906 is fully
present in every component. Current llama.cpp needs ROCm 6.1 or newer. If you
want to try newer releases, set `ROCM_VER=6.4.x`; it will probably still build
for gfx906.

## Resources

Measured on a 4-core x86 build machine (see "What has been tested" below):

- **Disk:** about 11 GB for sources, build trees and the install before
  rocBLAS. With rocBLAS, see the measured total in the test log below. Put
  `SRC` on NVMe or USB SSD storage, not the SD card.
- **RAM:** LLVM linking is the peak. On a 16 GB board use `JOBS=6 LINK_JOBS=1`
  and add 8 GB of swap. On 8 GB, use `JOBS=3` plus swap.
- **Time:** LLVM took about 1.5 h on 4 x86 cores. Expect 2–4 h on RK3588's 4+4
  cores, plus rocBLAS/Tensile.

You can also build on any bigger aarch64 machine (a cloud Graviton or Ampere
instance works) and copy `/opt/rocm` over as a tarball. The build is
self-contained in `ROCM_PATH`.

To resume after a failure, fix the problem and rerun from the failed stage:
`./scripts/build-rocm-aarch64.sh rocblas`. Rerunning from an earlier stage is
cheap, because everything after it rebuilds incrementally.

## Verify

```bash
. scripts/rocm-env.sh
rocminfo | grep -E 'Name:.*gfx906|Marketing'
hipcc --offload-arch=gfx906 tests/hip-smoke.hip -o /tmp/hip-smoke && /tmp/hip-smoke
# expected on a working MI50 (exact name/size vary):
# device 0: AMD Instinct MI50 ... (gfx906:...), ~32 GiB
# PASS: 1048576 values round-tripped through the GPU
```

`hip-smoke` checks every HIP call and verifies 1 Mi values, so a coherency
problem shows up as a `FAIL: h[...]` mismatch rather than as silent garbage.

## Coherency settings (RK3588 and other non-coherent hosts)

`scripts/rocm-env.sh` sets `HSA_USERPTR_FOR_PAGED_MEM=0`. Without it,
libhsakmt puts ROCm's queues, signals and host allocations in cached user
pages the GPU can't see coherently. The kernel patch alone can't fix that.
Details are in [KERNEL.md](KERNEL.md#rocm-needs-one-more-setting).

## Troubleshooting

| Symptom | Try |
| --- | --- |
| `ROCk module is NOT loaded, possibly no GPU devices` (rocminfo) or `no ROCm-capable device is detected` (HIP) | `/dev/kfd` is missing (`CONFIG_HSA_AMD`), or your user isn't in the `render` and `video` groups |
| `hipcc`: `/opt/rocm/lib/llvm/bin/clang++: not found` | Rerun the `llvm` stage, which creates the `lib/llvm` link |
| `hip-smoke` prints `FAIL: h[...]` or hangs | Check that `HSA_USERPTR_FOR_PAGED_MEM=0` is set and that the kernel patch is applied, then try `HSA_DISABLE_CACHE=1` and `HSA_ENABLE_SDMA=0` |
| rocBLAS: `Cannot read TensileLibrary.dat ... for GPU arch : gfx906` | rocBLAS was built without gfx906. Rerun the `rocblas` stage |
| Tensile: `No assembler available` | Rerun the `llvm` stage, which creates the `amdclang++` link |
| Tensile stage runs out of memory | Lower `JOBS` (it's passed as `Tensile_CPU_THREADS`) |
| `Memory access fault by GPU` | Run with `AMD_LOG_LEVEL=3` and capture `dmesg`. This is usually coherency or the BAR, not ROCm |

## llama.cpp tips for the MI50

- Fully offload with `-ngl 99`. Partial offload over Gen3 x4 is slow.
- `-fa on` (flash attention) works on gfx906 with both backends and saves VRAM
  at long context lengths.
- For one-shot prompts, use `llama-completion`; `llama-cli` is now
  conversation-first. `llama-server` provides an OpenAI-compatible API.
- Compare the backends with `llama-bench`. On gfx906, Vulkan often matches
  HIP for token generation, while HIP is usually faster at prompt processing.
- To check a backend without the MI50 (CI, or a machine with no GPU):
  `GGML_VK_VISIBLE_DEVICES=0` lets llama.cpp use Mesa's software Vulkan
  device (lavapipe), which it otherwise hides.
