# Kernel

## Base

- **Armbian with the mainline `edge` kernel (6.12 or newer)** on the Orange
  Pi 5 Plus. The vendor 6.1 BSP kernel also has amdgpu, but it's older and
  less tested with PCIe GPUs.
- **Boot with Device Tree**, which is the Armbian default. ACPI through
  edk2-rk3588 also works, and its PCIe tables already declare `_CCA = 0`, but
  you don't need custom UEFI firmware for any of this.

## Kernel config

Build with Armbian's `./compile.sh kernel BOARD=orangepi5plus BRANCH=edge KERNEL_CONFIGURE=yes`,
or append to `userpatches/linux-rockchip64-edge.config`:

```
CONFIG_DRM_AMDGPU=m
CONFIG_DRM_AMDGPU_USERPTR=y
CONFIG_HSA_AMD=y            # KFD: provides /dev/kfd. Required for ROCm.
CONFIG_HSA_AMD_SVM=y        # optional (HMM-based shared virtual memory)
CONFIG_HMM_MIRROR=y
CONFIG_MMU_NOTIFIER=y
CONFIG_DRM_TTM=m
```

`check-mi50.sh` checks these against `/boot/config-$(uname -r)`.

## Firmware

amdgpu needs the `amdgpu/vega20_*.bin` blobs at probe time. Install them with
`apt install firmware-amd-graphics` on Debian, or `linux-firmware` on Ubuntu.
On Armbian, use `armbian-firmware-full`. If amdgpu is built into the
initramfs, run `update-initramfs -u` afterwards.

## Boot parameters (eGPU stability)

Add these to `extraargs=` in `/boot/armbianEnv.txt`, or to GRUB's cmdline if you
boot through UEFI:

```
pcie_aspm=off amdgpu.runpm=0 amdgpu.aspm=0
```

If `dmesg` shows `arm-smmu-v3 ... event 0x10` (translation faults) for the GPU,
also try `iommu.passthrough=1`.

## The coherency problem

RK3588's PCIe doesn't snoop CPU caches. The DMA API handles that for drivers
that use it properly (`dma_map_*` does cache maintenance). However, amdgpu maps
most system memory it shares with the GPU (GTT) as **cached** CPU memory and
expects the PCIe link to keep it coherent. On a non-coherent host, the CPU and
GPU then see different data. Typical symptoms:

- `amdgpu: ring gfx/comp/sdma test failed` or IB test timeouts during probe
- fence timeouts or GPU hangs under load, and a random `-ETIME` from KFD
- garbage output from llama.cpp, or NaNs, on otherwise healthy kernels

[`patches/0001-drm-amdgpu-use-write-combined-GTT-on-non-coherent-hosts.patch`](../patches)
is a small, **experimental** patch. When `dev_is_dma_coherent()` is false, it
maps GTT buffers write-combined instead of cached, so the CPU never caches
memory the GPU also reads. It's untested. The idea is the same one other
non-coherent ARM GPU efforts use, such as the AMD-on-Raspberry-Pi-5 kernel
branches, which are the best existing reference if you need to go further.
It doesn't cover `hipHostRegister`/userptr memory, which the GPU can still
see as stale. llama.cpp doesn't use that path.

Apply it with Armbian:

```bash
mkdir -p userpatches/kernel/archive/rockchip64-6.12   # match your kernel version dir
cp patches/0001-*.patch userpatches/kernel/archive/rockchip64-6.12/
./compile.sh kernel BOARD=orangepi5plus BRANCH=edge
```

If you see **alignment faults** (`Unhandled fault: alignment fault`, or SIGBUS
in Mesa or ROCm) when the CPU writes to VRAM through BAR0, user space is doing
unaligned accesses to device memory. That was the other big issue on the
Pi 5. Report the exact backtrace; the fix depends on where it happens.

## Checks

```bash
sudo dmesg | grep -iE 'amdgpu|kfd' | head -50
ls -l /dev/kfd /dev/dri/renderD*
cat /sys/class/kfd/kfd/topology/nodes/*/properties | grep gfx_target_version  # 90006
```

A healthy probe ends with `amdgpu: ... Initialized amdgpu` and
`kfd kfd: amdgpu: added device 1002:66a1`.
