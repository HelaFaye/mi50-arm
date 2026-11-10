# Testing

This records what has been tested, how, and what still needs the real
hardware (Orange Pi 5 Plus plus an MI50). The audit ran on 2026-11-03/04 in a
4-core x86_64 Ubuntu 24.04 container with no GPU, plus Ubuntu 24.04 and
Debian trixie **arm64** chroots under qemu-user.

## Results

| Area | What was done | Result |
| --- | --- | --- |
| Shell scripts | `shellcheck` on every script, the tests and the Armbian extension | clean |
| `check-mi50.sh` | `tests/test-check-mi50.sh`: 9 simulated systems (healthy non-coherent RK3588, unassigned 32 GiB BAR, the fixed-BAR VBIOS 113-D1631711-100, a Resizable BAR VBIOS, an unknown VBIOS, vfio-pci bound, coherent host, ring-test failure, no GPU), with fake sysfs/devicetree trees and mock `lspci`/`dmesg` | the first 6: 6/6 on x86, Ubuntu arm64 and Debian trixie arm64 (mawk). All 9: 9/9 on x86 |
| Test suite sensitivity | Mutation test: broke BAR detection on purpose | suite caught it (5/6) |
| Kernel patch | `patch --dry-run` against `amdgpu_ttm.c` from v6.12, v6.18, v7.3, master (7.4-rc1) | applies to all 4 |
| Kernel patch | Cross-compiled `amdgpu_ttm.o` for arm64 against v6.12 with `DRM_AMDGPU=m` and `HSA_AMD=y` | compiles |
| Armbian extension | Applied its options to Armbian's real `linux-rockchip64-current.config`, then ran `olddefconfig` | all options resolve (after adding the memory-hotplug dependencies the first run showed were missing) |
| Package names | Every apt package the scripts install, checked with `apt-cache policy` on arm64 | all exist on Ubuntu 24.04 and Debian trixie (the firmware package differs per distro, as documented) |
| Firmware | Downloaded Debian trixie's `firmware-amd-graphics` (arm64) | contains 14 `amdgpu/vega20_*` blobs |
| `build-llamacpp.sh vulkan` | Full build, then inference on Mesa's software Vulkan device (`GGML_VK_VISIBLE_DEVICES=0`, `-ngl 99`, stories15M Q4_0) | builds, and generates coherent text |
| `build-rocm-aarch64.sh` | **Full build of all 12 stages** (LLVM, device-libs, comgr, hipcc, ROCR, rocminfo, HIP, hipBLAS-common, rocBLAS with gfx906 Tensile kernels, hipBLAS), including resuming from a stage | builds after fixing 4 bugs (below); about 12 GB of disk, with LLVM taking about 1.5 h on 4 cores |
| hipcc | Compiled `tests/hip-smoke.hip` for gfx906 and unbundled the code object | contains `amdgcn-amd-amdhsa--gfx906` |
| rocBLAS | Inspected the installed Tensile library | 156 gfx906 kernel/library files |
| `build-llamacpp.sh hip` | Full build against the self-built ROCm | builds; `libggml-hip.so` carries 44 MB of gfx906 device code; runs and reports "no ROCm-capable device" without a GPU |
| Proxmox | Checked Proxmox's own sources: `pve-kernel` (arm64 is a supported arch; config = Ubuntu arm64 annotations + overrides that don't touch amdgpu; patches are applied with `patch --batch -p1`), `pve-container` (`devN` syntax, gid mapping, generated cgroup rules), Ubuntu's arm64 `7.0.0-42-generic` kernel config (`DRM_AMDGPU=m`, `HSA_AMD=y`, `HSA_AMD_SVM=y`, `PCIE_ROCKCHIP_DW_HOST=y`), edk2-rk3588's PCIe ACPI tables (`_CCA 0`, no `_DSM`, 768 MiB MEM64), and the patch applies to v7.0 | consistent with docs/PROXMOX.md; a Proxmox install on the board is **not** tested |
| Source claims | Checked against upstream source: VFIO's coherency requirement, the RK3588 DT PCIe windows and SMMU, edk2-rk3588 `_CCA`, KFD's PCIe-atomics rules, amdgpu BAR resizing, sysfs `resourceN_resize`, `drm_arch_can_wc_memory`, TTM page handling, libhsakmt userptr allocation, Armbian config/patch/extension mechanics, llama.cpp flags | see [docs/BLUEPRINT-REVIEW.md](docs/BLUEPRINT-REVIEW.md) and [docs/KERNEL.md](docs/KERNEL.md) |

The ROCm build ran natively on x86_64. LLVM's target list is `host;AMDGPU`, so
on the board the same script builds for AArch64. The code paths that depend
on the host architecture are ordinary portable C++. Building on real arm64
hardware is still worth doing once; see below.

## Bugs found by this testing (all fixed)

1. **ROCm needs `HSA_USERPTR_FOR_PAGED_MEM=0` on non-coherent hosts.**
   libhsakmt allocates queues, signals and host memory as cached userptr pages,
   which the kernel patch can't cover. The earlier docs said ROCm didn't use
   that path, which was wrong. `rocm-env.sh` now sets the variable.
2. **Armbian:** stock rockchip64 kernels don't build amdgpu. The earlier advice
   to "append" to `userpatches/linux-rockchip64-edge.config` would have replaced
   the whole kernel config. This is now an extension, and it also enables the
   memory-hotplug options that SVM depends on.
3. **ROCm build:** clr needs `libgl-dev`.
4. **ROCm build:** `hip::host` links compiler-rt builtins, so LLVM now builds them.
5. **ROCm build:** hipcc looks for clang in `$ROCM_PATH/lib/llvm`, so the script now creates that link.
6. **ROCm build:** Tensile looks for `amdclang++`, so the script now creates the symlinks, and the rocBLAS stage has hipcc on its PATH.
7. `rocm-env.sh`: added `HIP_PLATFORM=amd`, fixed quoting, and dropped the unneeded `llvm/lib` from `LD_LIBRARY_PATH`.
8. `check-mi50.sh`: small BARs were reported as "0 MiB"; it now reads coherency from the DT, falls back to `/proc/config.gz`, reports an exit status, and can be tested.
9. `build-llamacpp.sh`: no longer aborts on distros without apt, and clones shallow.
10. Docs: `rocm-smi` isn't built, so power capping now uses sysfs; ACPI `preserve_config` blocks BAR resizing; amdgpu's own BAR-resize behaviour is described; the ROCm verify example now checks for errors (`tests/hip-smoke.hip`).

## Still needs the real hardware

In order:

1. Does the MI50 enumerate over the OCuLink link, at Gen3 x4?
2. Does BAR0 fit in RK3588's window, or does the resize step in `docs/HARDWARE.md` work?
3. Does amdgpu probe and pass its ring/IB tests **with** `patches/0001`? (Comparing with and without it is the key experiment.)
4. Vulkan: `llama-bench` on a real model.
5. ROCm: `tests/hip-smoke.hip`, then `llama-bench` with the HIP build.
6. The Proxmox LXC sharing in `docs/PROXMOX.md`.
7. A native build of the ROCm script on the board (time and RAM).

CI (`.github/workflows/ci.yml`) reruns shellcheck, the fake-sysfs tests and
the patch-applies check on every push.
