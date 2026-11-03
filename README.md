# MI50 on ARM64: running LLMs on an AMD Instinct MI50 32GB from an RK3588 board

This repo has notes, scripts and one experimental kernel patch for running LLM
inference (llama.cpp) on an **AMD Instinct MI50 (Vega 20, gfx906)** attached to an
**ARM64** host. The main target is an **Orange Pi 5 Plus (RK3588)** with the card
on an M.2 to OCuLink adapter. Most of it also applies to other aarch64 hosts.

> **Status: untested.** Nobody has run this end to end on real hardware yet. Each
> layer below has a check, so you can tell exactly where it breaks. Run
> `scripts/check-mi50.sh` and keep its output.

## The short version

```
 MI50 ── OCuLink ── M.2 (PCIe 3.0 x4) ── RK3588 ── Linux (mainline, DT boot)
                                                     │
                                                     ├─ amdgpu + KFD  (kernel)
                                                     │
                     ┌───────────────────────────────┴───────────────────┐
             Mesa RADV (Vulkan)                                 ROCm 6.3.3 built from source
             llama.cpp -DGGML_VULKAN=ON   ◄── start here        llama.cpp -DGGML_HIP=ON
```

1. **Run the GPU on the host or in an LXC container, not in a VM.** VFIO
   passthrough on RK3588 cannot work: the kernel refuses to hand a device to
   VFIO unless its IOMMU reports cache coherency, and RK3588's PCIe SMMU
   doesn't. Proxmox still works if you share the GPU into an LXC container
   (see [docs/PROXMOX.md](docs/PROXMOX.md)).
2. **Check the VRAM BAR before anything else.** The RK3588 PCIe 3.0 x4
   controller has only a **1 GiB** 64-bit memory window. If the MI50 asks for a
   32 GiB BAR, it won't fit, and amdgpu will never load. See
   [docs/HARDWARE.md](docs/HARDWARE.md#bar-space).
3. **The kernel driver is the real risk.** RK3588 PCIe is not cache-coherent,
   and stock amdgpu assumes it is. This is the same class of problem people hit
   with GPUs on the Raspberry Pi 5. [docs/KERNEL.md](docs/KERNEL.md) covers the
   kernel config, the firmware, and an experimental patch.
4. **Get Vulkan working first.** llama.cpp's Vulkan backend runs on Mesa RADV,
   which supports gfx906 and ships as an arm64 package. It needs no ROCm at all.
   If Vulkan works, the kernel side is healthy.
5. **Build ROCm only if you want it.** AMD ships no aarch64 ROCm packages, so
   `scripts/build-rocm-aarch64.sh` builds a minimal ROCm 6.3.3 for gfx906 from
   source: compiler, runtime, HIP, rocBLAS and hipBLAS. The sources need no
   patches for aarch64. See [docs/ROCM.md](docs/ROCM.md).

## Quick start

```bash
# 0. Hardware: external PSU on first, a blower fan on the MI50 (it is passively cooled)
# 1. Host OS: Armbian (Debian trixie / Ubuntu noble), mainline "edge" kernel >= 6.12
sudo ./scripts/check-mi50.sh            # fix the first FAIL, repeat

# 2. Vulkan path
./scripts/build-llamacpp.sh vulkan
~/llama.cpp/build-vulkan/bin/llama-bench -m model.gguf -ngl 99

# 3. ROCm path (optional; takes hours)
./scripts/build-rocm-aarch64.sh
. ./scripts/rocm-env.sh && rocminfo | grep gfx906
./scripts/build-llamacpp.sh hip
```

## What to expect

- **Link:** PCIe 3.0 x4 (about 3.9 GB/s). That's RK3588's limit. It makes
  model loading slow but barely affects token generation once the weights are
  in VRAM.
- **Memory:** with 32 GB of HBM2 you can fully offload models up to about 30B
  parameters at Q4/Q5, or 70B at roughly Q3 with a small context.
- **Host CPU:** the A76 cores matter during prompt processing and sampling.
  Pin llama.cpp to them (`taskset -c 4-7` on RK3588).

## Repo layout

| Path | What it is |
| --- | --- |
| `scripts/check-mi50.sh` | Read-only diagnostic for each layer (PCIe, BAR, driver, KFD, Vulkan, ROCm) |
| `scripts/build-llamacpp.sh` | Builds llama.cpp with the `vulkan` or `hip` backend |
| `scripts/build-rocm-aarch64.sh` | Builds a minimal ROCm 6.3.3 for gfx906 from source; can resume from any stage |
| `scripts/rocm-env.sh` | Environment for the self-built ROCm |
| `patches/0001-…` | Experimental amdgpu patch: write-combined GTT on non-coherent hosts |
| `docs/BLUEPRINT-REVIEW.md` | What in the original blueprint is wrong, and why |
| `docs/HARDWARE.md` | Adapter, power, cooling, BAR space |
| `docs/KERNEL.md` | Kernel config, firmware, boot parameters, coherency |
| `docs/ROCM.md` | Building ROCm on aarch64 and troubleshooting it |
| `docs/PROXMOX.md` | Keeping Proxmox: an LXC container instead of VFIO |
