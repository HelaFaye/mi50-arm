# Proxmox on RK3588 with an MI50

**Short version:** run Proxmox on the board, drive the MI50 with amdgpu **on
the host**, and give it to an **LXC container** with Proxmox's `devN:` option.
A VM with the GPU passed through (VFIO) can't work on RK3588, whichever
Proxmox build you use.

## Why not a VM

When a device is handed to VFIO, the kernel requires its IOMMU to report
`IOMMU_CAP_CACHE_COHERENCY` (`drivers/vfio/vfio_main.c`), and otherwise
refuses with `-EINVAL`. RK3588's PCIe SMMU (`mmu600_pcie`) isn't coherent, so
the check always fails. This is a kernel rule, not a Proxmox setting, so no
Proxmox version or VM option gets around it. Containers share the host
kernel, so they don't need VFIO at all, and they also run without
virtualization overhead.

## Which Proxmox

| | Official Proxmox VE 9.2 arm64 | Community port (PXVirt, formerly Proxmox-Port) |
| --- | --- | --- |
| Status on RK3588 | Single-board computers are **not supported**; other ARMv8 hardware is "best effort". Forum reports for the Orange Pi 5 Plus describe installer failures | used on RK3588 by the community, on top of Armbian |
| Firmware/boot | UEFI is required. Proxmox's roadmap says ACPI as well, so on RK3588 that means **edk2-rk3588** | normal Armbian boot (U-Boot + Device Tree) |
| Kernel | `proxmox-kernel` 7.0, built from Ubuntu's arm64 config. That config has `DRM_AMDGPU=m`, `HSA_AMD=y`, `HSA_AMD_SVM=y` and the RK3588 PCIe driver (checked on Ubuntu's `7.0.0-42-generic` arm64 build) | your Armbian kernel built with [`armbian/extensions/mi50-amdgpu.sh`](../armbian/extensions/mi50-amdgpu.sh) |
| Coherency patch | Not included. You have to rebuild `proxmox-kernel` (below) | included in your Armbian build |

Both routes need the same kernel patch and the same container setup. The
official build comes with Proxmox's support lifecycle and the amdgpu/KFD
config already in place. The community route has the better RK3588 hardware
support today. On real hardware, nothing here has been tested yet.

### Official route: notes

- **Flash edk2-rk3588** and choose the firmware mode under
  `Device Manager → Rockchip Platform Configuration → ACPI / Device Tree`:
  - **ACPI** is what Proxmox lists as required. In ACPI mode, edk2-rk3588
    supports PCIe (including NVMe and the Realtek NICs), USB, SATA and the UART
    under Linux, which is enough for a Proxmox host. Its PCIe tables already
    set `_CCA = 0` and have no `_DSM`, so BAR resizing isn't blocked. The 64-bit
    window is **768 MiB**, and a single BAR can be at most 512 MiB, so the MI50's
    BAR0 must be 256 MiB ([HARDWARE.md](HARDWARE.md#bar-space)). The firmware's
    own notes say its ACPI support is developed against Windows only.
  - **Device Tree (Mainline)** gives Linux full RK3588 support and still
    boots through UEFI. Proxmox doesn't list it, but its arm64 kernel has the
    Rockchip drivers built in. Try this if ACPI mode misbehaves.
- If the ISO installer fails on the board, which matches the forum reports,
  install Debian 13 arm64 first and add Proxmox on top, following Proxmox's
  "Install Proxmox VE on Debian" guide.
- **Rebuild the Proxmox kernel with the coherency patch.** The patch applies
  to Linux v7.0. The packaging is the `pve-kernel` repo, which supports
  `amd64` and `arm64`:
  ```bash
  git clone https://git.proxmox.com/git/pve-kernel.git && cd pve-kernel
  make submodule                       # fetches the Ubuntu kernel + ZFS sources
  # patches/kernel/*.patch are applied in order with `patch --batch -p1`
  cp /path/to/mi50-arm/patches/0001-*.patch patches/kernel/0900-mi50-noncoherent-gtt.patch
  make build-dir-fresh && mk-build-deps -ir proxmox-kernel-*/debian/control
  make deb          # on an arm64 machine; installs as proxmox-kernel-<ver>-pve
  ```
  Then install the resulting `proxmox-kernel-*.deb`, and pin it
  (`proxmox-boot-tool kernel pin <version>`) so updates don't silently replace
  it with the unpatched kernel.

### Community route: notes

Install Armbian trixie, build and install the kernel from
[KERNEL.md](KERNEL.md), and then install PXVirt following that project's
instructions. Keep your kernel: don't let the port replace it.

## Container setup (both routes)

**Don't** configure `vfio-pci.ids=`, and don't put amdgpu on the module
blacklist. amdgpu must bind on the host. Check with `scripts/check-mi50.sh`
first.

Create an arm64 Debian or Ubuntu container (for example, ID 101). Find the IDs
of the `render` and `video` groups *inside the container*
(`getent group render video`), then pass the devices through. This is the
syntax from pve-container's `devN` option:

```bash
pct set 101 -dev0 /dev/kfd,gid=<render-gid-in-ct>
pct set 101 -dev1 /dev/dri/renderD128,gid=<render-gid-in-ct>
pct set 101 -dev2 /dev/dri/card0,gid=<video-gid-in-ct>      # usually card1 if the board's own GPU is card0
```

Proxmox maps the container-side gid to the host for unprivileged containers
and generates the cgroup device rules itself. You don't need to know
`/dev/kfd`'s major number, which is assigned dynamically
(`register_chrdev(0, "kfd", ...)`). Only `root@pam` may add device
passthrough. If a process in the container still can't open `/dev/kfd`, a
problem forum users have reported, add `mode=0666` to the `dev0` entry as a
blunt workaround.

To keep compute on the A76 cores, add a raw cpuset line to
`/etc/pve/lxc/101.conf` (raw `lxc.cgroup2.*` keys are allowed there):

```
lxc.cgroup2.cpuset.cpus: 4-7
```

Inside the container:

- **Vulkan:** `apt install mesa-vulkan-drivers vulkan-tools`, then
  `scripts/build-llamacpp.sh vulkan`.
- **ROCm:** bind-mount the ROCm you built on the host read-only, and use
  `scripts/rocm-env.sh`, which includes `HSA_USERPTR_FOR_PAGED_MEM=0`:
  ```bash
  pct set 101 -mp0 /opt/rocm,mp=/opt/rocm,ro=1
  ```
  Then `scripts/build-llamacpp.sh hip` inside the container. The container's
  ROCm user space runs against the host's patched kernel driver, so nothing
  kernel-related is needed in the container.

Verify in the container with `ls -l /dev/kfd /dev/dri`, then run
`tests/hip-smoke.hip` ([ROCM.md](ROCM.md#verify)).
