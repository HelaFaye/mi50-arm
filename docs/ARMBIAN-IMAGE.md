# Prebuilt ROCm/PyTorch Armbian image

The image build is split into two independently validated products:

1. Armbian produces the RK3588 kernel and base root filesystem with the `mi50-amdgpu` extension, firmware, and GTT coherency patch.
2. A native ARM64 builder produces `/opt/rocm` and `/opt/venv-rocm`, which are packaged into `mi50-arm64-payload.tar.gz` and unpacked by Armbian's `customize-image.sh`.

Armbian documents `userpatches/customize-image.sh` as running in the target-rootfs chroot and `userpatches/overlay/` as available at `/tmp/overlay` within that chroot. This integration uses those supported paths instead of copying from the build host's filesystem at runtime.

## 1. Build the ARM64 payload

Use Ubuntu Noble for both the ARM64 builder and target image. Noble ships Python 3.12, matching the current PyTorch 2.5.1 build guard. Debian Trixie is not enabled by this first image integration: it needs a separately packaged Python 3.12 runtime as well as headers, and that runtime must be included in the payload and validated before Trixie can be safely supported.

On the ARM64 builder, create `/opt/venv-rocm` as a writable directory for the build user. For example:

```bash
sudo install -d -o "$USER" -g "$(id -gn)" /opt/venv-rocm
```

Then run from the repository root:

```bash
VENV=/opt/venv-rocm SKIP_ROCBLAS_GPU_SMOKE=1 SKIP_PYTORCH_GPU_SMOKE=1 \
  ./scripts/build-rocm-math-and-torch.sh
VENV=/opt/venv-rocm SKIP_BNB_GPU_SMOKE=1 \
  ./scripts/build-bitsandbytes-gfx906.sh
```

`SKIP_BNB_GPU_SMOKE=1` skips `python -m bitsandbytes` and NF4 forward/backward execution, but does **not** skip PyTorch version validation, pip dependency checks, importing bitsandbytes, checking for `libbitsandbytes_rocm63.so`, or loading that shared library through `ctypes`.

Run non-GPU validations:

```bash
/opt/venv-rocm/bin/python -c 'import torch; assert torch.version.hip; print(torch.__version__, torch.version.hip)'
/opt/venv-rocm/bin/python -m pip check
```

Do not move the venv after creation. Python console scripts such as `accelerate` and `torchrun` carry absolute shebang paths. Building directly at `/opt/venv-rocm` preserves them in the image.

Create the payload archive from `/` so it contains `opt/rocm/...` and `opt/venv-rocm/...` paths:

```bash
sudo chown -R root:root /opt/rocm /opt/venv-rocm
sudo tar -C / --numeric-owner -czf "$HOME/mi50-arm64-payload.tar.gz" opt/rocm opt/venv-rocm
sha256sum "$HOME/mi50-arm64-payload.tar.gz"
```

Do not include the build source tree (`$HOME/rocm633-src`) in this archive. The target and build host should match distro release, architecture, and glibc compatibility.

## 2. Install the Armbian integration

From the `mi50-arm` checkout, install into an Armbian build tree and specify the kernel version directory corresponding to its branch:

```bash
./armbian/image/install-to-armbian-build.sh /path/to/armbian/build 6.18
```

Use the actual `MAJOR.MINOR` version selected by Armbian (for example 6.18 for a current branch or 7.3 for an edge branch). The installer installs the kernel extension and patch, stages the image overlay, and creates or extends `userpatches/customize-image.sh`. It preserves any existing customize script and adds a marked, idempotent integration call.

Copy the payload archive into the Armbian build tree:

```bash
install -m 0644 "$HOME/mi50-arm64-payload.tar.gz" \
  /path/to/armbian/build/userpatches/overlay/mi50-arm64-payload.tar.gz
```

Then build (example values only):

```bash
cd /path/to/armbian/build
./compile.sh BOARD=orangepi5plus BRANCH=current RELEASE=noble \
  ENABLE_EXTENSIONS=mi50-amdgpu FIXED_IMAGE_SIZE=16384
```

The integration deliberately fails the image build if the payload is missing, not ARM64, has unsafe archive paths, lacks `hipcc`, or lacks a Python 3.9–3.12 venv. It never compiles ROCm or PyTorch in the QEMU chroot.

The installed stack consumes several GiB. Choose `FIXED_IMAGE_SIZE` with room for the base OS, stack, package caches, and model storage. 16 GiB is a reasonable starting image size, but inspect actual image/rootfs usage before treating it as sufficient.

## 3. Installed integration

| Path | Purpose |
| --- | --- |
| `/opt/rocm`, `/opt/venv-rocm` | Prebuilt ARM64 ROCm and Python environment |
| `/etc/ld.so.conf.d/mi50-rocm.conf` | Registers `/opt/rocm/lib` with the dynamic linker |
| `/etc/mi50-rocm.env` | Literal systemd `EnvironmentFile` values |
| `/etc/profile.d/mi50-rocm.sh` | Interactive shell ROCm defaults |
| `/etc/udev/rules.d/70-mi50-rocm.rules` | `video`/`render` permissions for KFD/DRM nodes |
| `mi50-device-access.timer` | Retries normal-user group assignment after Armbian creates its first-boot account |
| `mi50-power-cap.service` | Attempts a 165 W sysfs cap for AMD PCI ID `1002:66a1` |

`/etc/mi50-rocm.env` is plain systemd environment-file syntax. Do not put `$PATH` expansion or shell expressions in it. The dynamic linker registration removes the need for a global `LD_LIBRARY_PATH`.

The device-access helper adds all local accounts with UID >= 1000 (excluding `nobody` and nologin/false shells) to `video` and `render`. The timer keeps retrying until at least one normal user exists, then records completion. Group changes require a new login session.

The power-cap helper checks the MI50 PCI ID and any supported min/max values before writing. No device, absent hwmon support, or unsupported cap is logged without failing boot. The default is 165000000 microwatts; set `MI50_POWER_CAP_UW=0` in `/etc/mi50-rocm.env` to disable it.

## 4. First boot validation

Before using the preinstalled venv:

1. Confirm PCIe enumeration, Gen3 x4 link, BAR0 assignment, and VBIOS suitability. A non-resizable 16/32 GiB BAR that cannot fit the RK3588 window remains a hard blocker.
2. Confirm the Vega20 firmware is present and `amdgpu` probes without ring/IB errors.
3. Confirm `/dev/kfd`, `/dev/dri/renderD*`, and group access.
4. Source `/etc/profile.d/mi50-rocm.sh` (or log in again), then run `rocminfo` and verify `gfx906`.
5. Run `tests/hip-smoke.hip`, ROCm GPU parity, PyTorch autograd, and the bitsandbytes NF4 forward/backward test. These require the real MI50 and are intentionally not run in the image-build chroot.

The GTT write-combined kernel patch and `HSA_USERPTR_FOR_PAGED_MEM=0` are a coupled, experimental design for the RK3588 non-coherent PCIe host. A successful image build does not validate GPU coherency or stability under load.
