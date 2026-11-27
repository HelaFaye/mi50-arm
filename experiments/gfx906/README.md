# Experimental gfx906 direct-dispatch path

This is an experimental, low-level MI50 (gfx906) branch of work. It bypasses
ROCr's normal dispatch path and talks to the kernel's `amdgpu` DRM interface
using SDMA and PM4. It is deliberately isolated from the supported
`build-rocm-aarch64.sh` / llama.cpp path.

## Contents

- `dispatch_gfx906.cpp` is a standalone vector-add proof-of-concept. It loads a
  prebuilt `vec_add.hsaco`, stages data in GTT, uses SDMA to copy it to/from
  VRAM, and submits a compute IB through libdrm.
- `hsa_drm_shim.cpp` is a partial HSA/ROCR API experiment. It implements a
  narrow subset of agent, pool, signal, AQL queue, code-object, and executable
  calls. It is **not** a complete or drop-in HSA runtime.
- `CMakeLists.txt` builds the host-side sources against libdrm. It does not
  require an installed MI50.

## Build and validation

On Ubuntu/Debian:

```bash
sudo apt-get install build-essential cmake ninja-build pkg-config libdrm-dev libdrm-amdgpu1
cmake -S experiments/gfx906 -B build/gfx906 -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build/gfx906 --parallel 2
```

With ROCm 6.3.3 installed, build a matching code object:

```bash
hipcc --offload-arch=gfx906 --genco --no-gpu-bundle-output tests/vec_add.hip -o vec_add.hsaco
```

The standalone dispatcher expects `vec_add.hsaco` in its current working
directory. Do not run it unless a gfx906 card is present, the kernel driver is
loaded, and the card has suitable power and cooling.

The ROCm 6.3.3 `hipcc --genco` output used here is AMDGPU Code Object V5. The
three explicit `vec_add` pointer arguments occupy bytes 0..23 of the kernarg.
The dispatcher must then populate the V5 implicit arguments: three `uint32_t`
work-group counts `{N / 64, 1, 1}` at bytes 24..35, followed by three
`uint16_t` work-group sizes `{64, 1, 1}` at bytes 36..41. In particular,
`blockDim.x` reads `hidden_group_size_x`; leaving the implicit area zero makes
it evaluate to zero and causes every work-group to write the first output
range. The dispatcher now checks that `kd->kernarg_size` covers all 42 bytes
and does not exceed its 256-byte kernarg capacity before writing the fields.
The host-side `gfx906_code_object_v5_implicit_args` CTest verifies the exact
values, offsets, preserved surrounding bytes, and rejected size boundaries.

## Important limitations

CI compiles the host code and emits a gfx906 code object. It does not submit
PM4, execute SDMA, run the HSA shim against ROCr, or prove the ABI against a
real application. In particular, the shim still requires a systematic ABI
conformance pass (including signal ordering/lifetime, AQL packet fence scopes,
queue destruction with in-flight work, ELF validation/relocation coverage,
full allocation/address semantics, and API coverage) before it can be used as
`libhsa-runtime64.so`.

The PM4 helper accepts payload DWORD count, then encodes count-minus-one:
`DISPATCH_DIRECT` has 4 payload DWORDs / encoded count 3, and `ACQUIRE_MEM` has
6 payload DWORDs / encoded count 5. The GFX9 cache mask uses
`TC_WB_ACTION_ENA` bit 18, `TCL1_ACTION_ENA` bit 22 and `TC_ACTION_ENA` bit 23.

The fixed packet lengths and HSA enum mappings address concrete encoding and
ABI mistakes found during initial review, but do not make this runtime
hardware-validated. The current shim also does not implement the loader
extension table, `hsa_amd_memory_lock/unlock`, `hsa_amd_pointer_info`, AMD
asynchronous signal handlers, file-based code-object readers, or all CLR
hidden-argument conventions. It rejects code objects that require unsupported
dispatch/queue SGPRs or GOT relocations. Therefore `libamdhip64`, rocBLAS and
PyTorch are not supported by this shim. On the recommended mi50-arm kernel
(`CONFIG_HSA_AMD=y`), use the real `/dev/kfd` and upstream ROCR runtime. Keep
this shim only for isolated DRM/PM4 experiments or a KFD-less diagnostic kernel.

On ARM64, upstream `drm_arch_can_wc_memory()` can cause amdgpu to strip
`AMDGPU_GEM_CREATE_CPU_GTT_USWC`. The `dsb sy` barrier is only an ordering
barrier, not a PCIe coherency mechanism. CPU-mapped GTT rings, kernargs and
staging buffers rely on this repository's experimental non-coherent TTM patch;
without a validated equivalent, don't run the dispatch path on RK3588.
