# Kernel

## Base

- Use **Armbian with a mainline kernel**. As of November 2026, rockchip64
  `current` is 6.18 and `edge` is 7.3. The patch below applies to 6.12,
  6.18, 7.3 and 7.4-rc mainline.
- **Boot with Device Tree**, which is the Armbian default. ACPI through
  edk2-rk3588 also works, and its PCIe tables already declare `_CCA = 0`, but
  you don't need custom UEFI firmware for any of this.
- **Stock Armbian rockchip64 kernels don't build amdgpu at all.** Neither
  `linux-rockchip64-current.config` nor `-edge.config` mentions it, so you
  must build your own kernel.

## Building the kernel with Armbian

This repo ships an Armbian build extension, [`armbian/extensions/mi50-amdgpu.sh`](../armbian/extensions/mi50-amdgpu.sh).
It enables the options below through Armbian's `custom_kernel_config` hook,
and it selects the full firmware package:

```bash
git clone --depth 1 https://github.com/armbian/build && cd build
mkdir -p userpatches/extensions userpatches/kernel/archive/rockchip64-7.3   # 7.3 = edge; 6.18 = current
cp ../mi50-arm/armbian/extensions/mi50-amdgpu.sh userpatches/extensions/
cp ../mi50-arm/patches/0001-*.patch userpatches/kernel/archive/rockchip64-7.3/
./compile.sh kernel BOARD=orangepi5plus BRANCH=edge ENABLE_EXTENSIONS=mi50-amdgpu
```

The patch directory is `archive/<family>-<KERNEL_MAJOR_MINOR>`. Check the
version for your branch in `config/sources/families/include/rockchip64_common.inc`.

> Don't put a partial `userpatches/linux-rockchip64-edge.config` in place. That
> file **replaces** the whole kernel config, not just the lines in it.

Options the extension sets (it was tested by applying them to Armbian's
rockchip64 config and running `olddefconfig`):

| Option | Why |
| --- | --- |
| `DRM_AMDGPU=m` | the driver |
| `HSA_AMD=y` | KFD, which provides `/dev/kfd`. **ROCm can't work without it** |
| `DRM_AMDGPU_USERPTR=y` | ROCm `hipHostRegister` and similar |
| `MEMORY_HOTPLUG`, `MEMORY_HOTREMOVE`, `ZONE_DEVICE`, `DEVICE_PRIVATE`, `HSA_AMD_SVM` | optional HMM-based SVM (HIP managed memory). Armbian leaves memory hotplug off, so the dependencies must be enabled explicitly |
| `DRM_AMDGPU_SI=n`, `DRM_AMDGPU_CIK=n` | not needed |

`HMM_MIRROR`, `MMU_NOTIFIER` and `DRM_TTM` are selected automatically.

## Firmware

amdgpu needs the `amdgpu/vega20_*.bin` blobs at probe time. On Armbian, use
`armbian-firmware-full` (the extension selects it for images). On plain
Debian, install `firmware-amd-graphics` from the `non-free-firmware`
component; on Ubuntu, `linux-firmware`. If amdgpu ends up in the initramfs,
run `update-initramfs -u` afterwards.

## Boot parameters (eGPU stability)

Add these to `extraargs=` in `/boot/armbianEnv.txt`, or to GRUB's cmdline if you
boot through UEFI:

```
pcie_aspm=off amdgpu.runpm=0 amdgpu.aspm=0
```

If `dmesg` shows `arm-smmu-v3 ... event 0x10` (translation faults) for the GPU,
also try `iommu.passthrough=1`.

## BAR handling

amdgpu tries on its own to *grow* BAR0 to the full VRAM size
(`amdgpu_device_resize_fb_bar`). When the window is too small, it logs
`Not enough PCI address space for a large BAR.` and keeps the old size, so a
card that boots with a 256 MiB BAR just works. However, amdgpu **skips** that
logic when the VBIOS already advertises a BAR as large as VRAM. On RK3588 such
a BAR is left unassigned, so you have to shrink it yourself first
([HARDWARE.md](HARDWARE.md#bar-space)).

## The coherency problem

RK3588's PCIe doesn't snoop CPU caches. The DMA API handles that for drivers
that use it properly (`dma_map_*` does cache maintenance). amdgpu, however,
maps the system memory it shares with the GPU (GTT) as **cached** CPU memory
and relies on the PCIe link being coherent. The DRM core deliberately disables
the write-combined option on arm64 (`drm_arch_can_wc_memory()` returns
`false`). On a non-coherent host, the CPU and GPU then see different data.
Typical symptoms:

- `amdgpu: ring gfx/comp/sdma test failed` or IB test timeouts during probe
  (`check-mi50.sh` flags these)
- fence timeouts or GPU hangs under load
- garbage output or NaNs from llama.cpp on otherwise healthy kernels

### The patch

[`patches/0001-drm-amdgpu-use-write-combined-GTT-on-non-coherent-hosts.patch`](../patches)
maps GTT buffer objects write-combined (Normal-NC on arm64) instead of cached
whenever `dev_is_dma_coherent()` is false.

- **Tested:** applies to v6.12, v6.18, v7.3 and mainline, and compiles for
  arm64 against v6.12. **Not yet tested:** running on hardware.
- **Why it should be sufficient for GTT:** it follows the same model as
  arm64's own `dma_alloc_coherent` on non-coherent devices. The kernel's
  cacheable linear-map alias stays, but TTM DMA-maps each page with
  `dma_map_page()` whenever a buffer is populated, which cleans dirty lines
  (including the zeroing TTM does). After that, every CPU access goes through
  the non-cacheable alias.
- **What it doesn't cover:** *userptr* memory, meaning ordinary user pages
  registered with the GPU. These stay CPU-cached. This matters for ROCm
  (next section) and for Vulkan's `VK_EXT_external_memory_host`.

### ROCm needs one more setting

By default, libhsakmt (ROCm's thunk library) allocates **all pageable host
memory** as userptr. That includes AQL queues, signals, kernel arguments and
`hipHostMalloc` (see `fmm_allocate_host_gpu` in ROCR-Runtime
`libhsakmt/src/fmm.c`). So with only the kernel patch, ROCm would still
break. Set

```bash
export HSA_USERPTR_FOR_PAGED_MEM=0
```

This makes libhsakmt allocate those buffers as kernel GTT BOs, which the patch
maps write-combined. `scripts/rocm-env.sh` sets it. `HSA_DISABLE_CACHE=1`
additionally marks host memory as uncached on the GPU side; try it if results
are still wrong.

### Alignment faults

If you see `Unhandled fault: alignment fault`, or SIGBUS in Mesa or ROCm, when
the CPU writes to VRAM through BAR0, user space is making unaligned accesses
to device memory. That was the other big issue on the Raspberry Pi 5. Report
the exact backtrace; the fix depends on where it happens.

## Checks

```bash
sudo ./scripts/check-mi50.sh
sudo dmesg | grep -iE 'amdgpu|kfd' | head -50
```

A healthy probe ends with `[drm] Initialized amdgpu ...` and
`kfd kfd: amdgpu: added device 1002:66a1`.
