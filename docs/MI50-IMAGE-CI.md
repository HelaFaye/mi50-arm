# MI50 Resolute image CI

The `MI50 Resolute image rebuild` workflow is a manually triggered, two-stage
pipeline. It deliberately keeps the expensive build off standard GitHub-hosted
runners: the generated raw image is 15.59 GiB, while standard Linux hosted
runners have a 14 GB SSD.

## Runner requirements

Register one dedicated repository-level self-hosted runner with all of these
labels:

- `self-hosted`
- `linux`
- `x64`
- `mi50-image-builder`

The pipeline assumes exactly one online runner has the `mi50-image-builder`
label. The ROCm prefix is kept on persistent local storage between the
`rebuild_rocm` and `rebuild_image` jobs. Do not register multiple machines with
this label unless the workspace is moved to a shared, safely locked filesystem.

Use Ubuntu 24.04 x86-64 as the builder host. It needs at least 24 GiB RAM and
120 GiB free space on the filesystem containing the builder root. The runner
must have Docker access and non-interactive sudo permission for `losetup`,
`mount`, and `umount`, which are used only to inspect the finished image
read-only.

Install the host prerequisites once:

```bash
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  build-essential cmake ninja-build clang llvm lld \
  mmdebstrap qemu-user-static binfmt-support \
  python3 python3-venv python3-dev pkg-config \
  git curl wget rsync patch zstd xz-utils \
  libdrm-dev libelf-dev libnuma-dev libzstd-dev zlib1g-dev \
  libxml2-dev libedit-dev libncurses-dev libffi-dev libssl-dev \
  libtinfo-dev libpciaccess-dev liblzma-dev \
  fdisk e2fsprogs util-linux file jq docker.io
```

Install and enable Docker Engine, then make the runner user a member of the
`docker` group. Confirm that the host's `clang --print-targets` includes
`AMDGPU`, and that `qemu-aarch64-static`, `llvm-objcopy`, and `llvm-strip` are
available. The workflow checks these prerequisites before building.

Mount a dedicated persistent filesystem at the builder path; a directory
on the system root filesystem is not sufficient because the cross-build
requires an external writable mount. Confirm `findmnt -T` reports that
dedicated mount, then grant ownership to the runner account:

```bash
sudo mkdir -p /mnt/mi50-builder
sudo chown RUNNER_USER:RUNNER_USER /mnt/mi50-builder
```

The default path is `/mnt/mi50-builder`. To use another mount point, create the
repository Actions variable `MI50_BUILDER_ROOT` with that absolute path. Keep
this workspace dedicated to this repository and this runner; do not point it
at a directory containing unrelated Armbian work.

Because this runner can execute the repository's build scripts through Docker
and privileged loop-mount operations, keep it dedicated to trusted maintainers
and do not accept untrusted pull-request workloads on it.

## Running a rebuild

Open **Actions → MI50 Resolute image rebuild → Run workflow**.

- `rebuild_rocm = true` rebuilds the pinned ROCm 6.3.3 ARM64 core prefix, then
  builds the Armbian image.
- `rebuild_rocm = false` reuses the existing
  `$MI50_BUILDER_ROOT/ArmbianOPi5P/build/cache/mi50-arm64-cross/target-rocm`
  prefix and rebuilds only the Armbian kernel/rootfs/image.
- `armbian_ref` defaults to the Armbian framework commit used for the verified
  November 27, 2026 image. Changing it is an explicit framework update; the
  kernel patch directory and supported kernel branch must be reviewed when
  moving to a different Armbian/kernel baseline.

The build is split into separate jobs because GitHub Actions caps a job at
360 minutes. Both jobs use the one labelled self-hosted runner and its
persistent build directory.

## Outputs and verification

The full image is not uploaded to Actions artifact storage by design.
It is much larger than a suitable CI report artifact and remains on the
self-hosted builder under:

```text
$MI50_BUILDER_ROOT/ArmbianOPi5P/build-mi50-clean/output/images/
```

The workflow verifies the raw image checksum, GPT/ext4 layout, Resolute
release identity, AArch64 ROCm executables, symlink containment, MI50 systemd
and udev integration, and presence of the built `amdgpu.ko` module. It also
requires the latest Armbian build log to show both the MI50 GTT patch and
compilation of `amdgpu_gtt_mgr.o`.

For each successful build, the output directory contains:

- the raw `.img` image;
- a `.img.zst` compressed copy;
- SHA-256 sidecars for both;
- a `.manifest.json` with source revisions and payload/image digests.

A small Actions artifact retains the manifest, checksum files, and Armbian
build log for 30 days. The builder also requires a provenance marker in the
cache before a no-ROCm-rebuild run, so an untracked or mismatched prefix is not
reused silently. The raw and compressed image remain on the builder's
persistent storage so the workflow does not depend on GitHub artifact storage
quotas.

This is build-time and filesystem validation only. It does not establish that
the Orange Pi 5 Plus boots successfully or that the MI50 is detected and
executes HIP workloads. Those still require hardware tests.
