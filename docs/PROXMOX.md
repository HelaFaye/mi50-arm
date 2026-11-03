# Proxmox on RK3588 without VFIO

VFIO passthrough of the MI50 to a VM **can't work** on RK3588 (see
[BLUEPRINT-REVIEW.md](BLUEPRINT-REVIEW.md)). There's another way to keep
Proxmox: drive the GPU with amdgpu on the **host**, and give an **LXC
container** access to its device nodes. Containers share the host kernel, so
no IOMMU coherency is needed and there's no virtualization overhead.

Proxmox doesn't publish arm64 builds. Use a community port; PXVirt, formerly
"Proxmox-Port", is the most widely used. Install it on Armbian trixie following
that project's instructions, and keep the kernel that has amdgpu
([KERNEL.md](KERNEL.md)). **Don't** install `vfio-pci.ids=` or blacklist
amdgpu.

## Container config

Create an arm64 Debian or Ubuntu container (for example, ID 101), then add
these lines to `/etc/pve/lxc/101.conf`:

```
# /dev/kfd and /dev/dri/* (DRM major 226; get kfd's major from `ls -l /dev/kfd`)
lxc.cgroup2.devices.allow: c 226:* rwm
lxc.cgroup2.devices.allow: c 235:* rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
lxc.mount.entry: /dev/kfd dev/kfd none bind,optional,create=file
# pin to the A76 cores
lxc.cgroup2.cpuset.cpus: 4-7
```

Replace `235` with the major number from `ls -l /dev/kfd` on your host. The
number is assigned dynamically.

For an **unprivileged** container, also map the host `render` and `video` groups
into the container, or make the nodes world-accessible with a host udev rule:

```
# /etc/udev/rules.d/70-mi50-lxc.rules  (host)
KERNEL=="kfd", MODE="0666"
SUBSYSTEM=="drm", KERNEL=="renderD*", MODE="0666"
```

Inside the container, use either the Vulkan path (`apt install mesa-vulkan-drivers`)
or bind-mount a host-built `/opt/rocm` read-only:

```
lxc.mount.entry: /opt/rocm opt/rocm none bind,ro,create=dir
```

Then run `scripts/build-llamacpp.sh` inside the container as usual.
