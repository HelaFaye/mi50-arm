# Review of the original blueprint

The blueprint this project started from ("Overall Architectural Blueprint &
Source Inventory") lays out the right layers. However, many of its concrete
steps are wrong, would not compile, or would actively stop the card from
working. The table below lists each one. Wherever a claim could be checked
against upstream source, the source is cited.

## Blockers: following these steps guarantees failure

| Blueprint step | Problem | Do this instead |
| --- | --- | --- |
| **Modules 4–5: VFIO passthrough to an ARM64 VM** | `vfio_main.c` returns `-EINVAL` for any device whose IOMMU doesn't report `IOMMU_CAP_CACHE_COHERENCY`. The arm-smmu-v3 driver reports that only when the SMMU is coherent, and RK3588's `mmu600_pcie` isn't (`rk3588-base.dtsi` has no `dma-coherent` on it). The blueprint's own premise, that RK3588 can't snoop, is the reason passthrough can't work. | Run the GPU on the host, or share `/dev/kfd` and `/dev/dri` into an LXC container ([PROXMOX.md](PROXMOX.md)). |
| **4.2/4.3: `vfio-pci.ids=1002:66a1` and `blacklist amdgpu`** | This leaves the host with no GPU driver. Since passthrough can't work, the card ends up unusable. | Let amdgpu bind on the host. |
| **The BAR problem is named but never solved** | The RK3588 `pcie3x4` 64-bit window is `0x9_0000_0000`, size `0x4000_0000` (1 GiB). An MI50 that exposes a 16 or 32 GiB BAR0 can't be assigned, and amdgpu then fails. Nothing in the blueprint addresses this. | Resize BAR0 down to 256 MiB, or use a small-BAR VBIOS ([HARDWARE.md](HARDWARE.md#bar-space)). |
| **`CONFIG_HSA_AMD` missing from the kernel config** | Without it there's no KFD and no `/dev/kfd`, so no ROCm at all. | See the config list in [KERNEL.md](KERNEL.md). |

## Steps that don't do what they claim

| Blueprint step | Reality |
| --- | --- |
| 2.3: inject `Name (_CCA, Zero)` into the DSDT | edk2-rk3588 already does this (`Silicon/Rockchip/RK3588/AcpiTables/Pcie.asl` declares `Name (_CCA, 0)`). Mainline Device Tree boot is also non-coherent by default, because the PCIe node has no `dma-coherent`. A custom firmware build isn't needed for this. |
| 2.2: embed an "Arm64Gop.efi" | GOP is a UEFI *display* driver. The MI50 has no display outputs, and Linux compute never uses GOP. It's irrelevant. |
| 3.2: `adev->dev->dma_coherent = false` in `amdgpu_device_init` | On RK3588 that's already the value, so the patch does nothing. The actual problem is that amdgpu/TTM maps system memory as *cached* regardless of that flag. [`patches/0001`](../patches) targets that problem instead. |
| 3.3: clamp the link to Gen3 in `dw_pcie_host_init` | The patch won't compile (`pp->bridge` isn't set up at that point, and `pci_find_bus_resource` doesn't exist). It's also unnecessary: the RK3588 controller is PCIe 3.0, and its DT already sets `max-link-speed = <3>`. |
| 3.4: `CONFIG_ARM64_FORCE_PCIE_MMIO_DEVICE_MAPPINGS`, `CONFIG_CHASH` | Neither option exists in current kernels. Writing a few lines to `userpatches/linux-rockchip64-edge.config` also doesn't "append" them: Armbian uses that file as the **entire** kernel config. Use a build extension instead ([KERNEL.md](KERNEL.md)). |
| Calling the MI50 "gfx906 CDNA1" | gfx906 is GCN 5 (Vega 20). CDNA1 is the MI100 (gfx908). This matters when you read compatibility tables. |
| 3.5 / 4.1: "integrate Proxmox's out-of-tree kernel patches", and `deb [arch=amd64,arm64] https://proxmox.com trixie pve-no-subscription` | Nothing in the steps actually integrates any Proxmox patches, and the repository URL is truncated. Since August 2026, Proxmox VE 9.2 has an **official arm64** build with its own 7.0 kernel, which already has amdgpu and KFD enabled. However, it lists single-board computers as unsupported and requires UEFI boot (edk2-rk3588 on this board). Either way, the coherency patch must be added to whichever kernel you run. See [PROXMOX.md](PROXMOX.md). |
| 1.3: solder a ground wire between the board and the ATX PSU | Unnecessary. The PCIe/OCuLink link already carries many ground pins, and both supplies are earthed through mains. A soldered wire to a USB-C shell adds a ground loop and puts the board at risk. Plug both PSUs into the same power strip instead. |
| 1.4: "wait until the card's internal fans settle" | The MI50 has **no fans**. It's a passively cooled server card and needs forced airflow ([HARDWARE.md](HARDWARE.md#cooling)). |
| 5.2/5.3: `-machine q35`, `x-vga=1`, `cpu_taskset:` | `q35` and `x-vga` are x86-only. ARM64 QEMU uses `-machine virt`. Proxmox's CPU pinning key is `affinity:`, not `cpu_taskset:`. These points don't matter in practice, since passthrough can't work anyway (see above). |
| 5.1: VBIOS `romfile=` "to handle early GPU init" | A ROM file exists to shadow option ROM execution inside a VM. Neither a host ARM kernel nor a guest ever executes x86 option ROM code. On the host, amdgpu reads the VBIOS tables directly. |
| 6.2: patch `getHostAlignment()` in `AMDGPUBaseInfo.cpp` | That function doesn't exist. ROCm's LLVM fork builds on aarch64 unmodified. Also, `AMDGPU` is a regular target, not an "experimental" one: use `-DLLVM_TARGETS_TO_BUILD="AArch64;AMDGPU"`. |
| 6.3: add a `dmb` in `hsa_queue.cpp`, replace the signal wait with `dc civac` | ROCR already uses C++11 atomics with release/acquire ordering, which compile to correct barriers on aarch64. Also, `dc civac` on a user-space pointer doesn't make PCIe coherent; it just costs time. KFD doesn't need PCIe atomics for gfx906: `kfd_device.c` sets `needs_pci_atomics` only for gfx10.1.1 and newer. |
| 6.4: strip AVX2 from rocBLAS `library/src/CMakeLists.txt` | That file contains no x86 flags. rocBLAS kernels are GPU code generated by Tensile; host code is portable C++. |
| 6.5: `HSA_OVERRIDE_GFX_VERSION=9.0.6` | The MI50 *is* gfx906. The override exists to make an *unsupported* GPU pose as a supported one. Leave it unset. `HSA_ENABLE_SDMA=0` is a reasonable *troubleshooting* knob, but it has nothing to do with PCIe atomics. |
| The Part 1 "tracking" script | All of its URLs are truncated (`https://github.com`, `https://kernel.org`), so it fetches nothing. |
| The Part 2 deploy script | It writes the VFIO and blacklist configuration (see Blockers), overwrites the whole `GRUB_CMDLINE_LINUX_DEFAULT`, and writes a `qm` config with invalid keys. Don't run it. |

## What the blueprint gets right

- RK3588 PCIe is not cache-coherent, and that's the core kernel-side problem.
- A short, good-quality OCuLink cable and a redriver-equipped adapter help signal integrity.
- A separate, adequately sized PSU for the GPU. Power the GPU before the host.
- ROCm 6.3.x is a sensible pin for gfx906. Newer ROCm releases are dropping it.
- Pin compute threads to the A76 cores (4–7) on RK3588.
