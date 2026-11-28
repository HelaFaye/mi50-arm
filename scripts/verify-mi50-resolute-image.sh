#!/usr/bin/env bash
set -Eeuo pipefail

fail() { printf '[mi50-image-verify] ERROR: %s\n' "$*" >&2; exit 1; }
log()  { printf '[mi50-image-verify] %s\n' "$*"; }

IMAGE=${1:-}
[ -n "$IMAGE" ] || fail "Usage: $0 /path/to/Armbian-image.img"
[ -f "$IMAGE" ] || fail "Image does not exist: $IMAGE"
IMAGE=$(realpath "$IMAGE")

for cmd in sha256sum fdisk blkid losetup mount umount mountpoint readelf file find python3; do
  command -v "$cmd" >/dev/null 2>&1 || fail "Missing host tool: $cmd"
done
command -v sudo >/dev/null 2>&1 || fail "sudo is required for read-only loop mounting"
sudo -n losetup --version >/dev/null 2>&1 || fail "Passwordless sudo is required for losetup verification"
sudo -n mount --version >/dev/null 2>&1 || fail "Passwordless sudo is required for mount verification"
sudo -n umount --version >/dev/null 2>&1 || fail "Passwordless sudo is required for umount verification"

SHA_FILE="$IMAGE.sha"
if [ -f "$SHA_FILE" ]; then
  log "Checking Armbian checksum file: $SHA_FILE"
  (cd "$(dirname "$IMAGE")" && sha256sum --check "$(basename "$SHA_FILE")")
else
  log 'No Armbian .sha companion found; calculating image checksum.'
  sha256sum "$IMAGE"
fi

log 'Checking GPT and protective MBR.'
FDISK=$(fdisk -l "$IMAGE")
printf '%s\n' "$FDISK"
printf '%s\n' "$FDISK" | grep -Fq 'Disklabel type: gpt' || fail 'Image partition table is not GPT'

LOOP=''
MNT=''
# shellcheck disable=SC2317,SC2329 # Invoked indirectly by the EXIT trap below.
cleanup() {
  local rc=$?
  trap - EXIT
  if [ -n "$MNT" ] && mountpoint -q "$MNT"; then
    sudo -n umount "$MNT" || rc=1
  fi
  if [ -n "$LOOP" ]; then
    sudo -n losetup -d "$LOOP" || rc=1
  fi
  if [ -n "$MNT" ] && [ -d "$MNT" ]; then
    rmdir "$MNT" || rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT

log 'Attaching image read-only.'
LOOP=$(sudo -n losetup --find --show --read-only --partscan "$IMAGE")
PART="${LOOP}p1"
[ -b "$PART" ] || fail "Expected root partition device missing: $PART"
BLKID=$(sudo -n blkid "$PART")
printf '%s\n' "$BLKID"
printf '%s\n' "$BLKID" | grep -q 'TYPE="ext4"' || fail 'Root partition is not ext4'

MNT=$(mktemp -d /tmp/mi50-image-verify.XXXXXX)
sudo -n mount -o ro,noload "$PART" "$MNT"

log 'Checking distribution identity.'
[ -r "$MNT/etc/os-release" ] || fail 'Missing /etc/os-release'
grep -Fqx 'VERSION_CODENAME=resolute' "$MNT/etc/os-release" || fail 'Image is not Ubuntu Resolute'
grep -Fqx 'VERSION_ID="26.04"' "$MNT/etc/os-release" || fail 'Unexpected Ubuntu version'

ROCM="$MNT/opt/rocm"
for rel in \
  bin/hipcc \
  bin/rocminfo \
  bin/amdclang \
  bin/amdclang++ \
  llvm/bin/clang \
  llvm/bin/clang++ \
  lib/libamdhip64.so \
  lib/libhsa-runtime64.so; do
  [ -e "$ROCM/$rel" ] || fail "Missing ROCm payload entry: /opt/rocm/$rel"
done
[ -x "$ROCM/bin/hipcc" ] || fail 'hipcc is not executable'
[ -x "$ROCM/bin/rocminfo" ] || fail 'rocminfo is not executable'
[ "$(readlink "$ROCM/bin/amdclang")" = '../llvm/bin/clang' ] || fail 'amdclang alias is not the expected relative link'
[ "$(readlink "$ROCM/bin/amdclang++")" = '../llvm/bin/clang++' ] || fail 'amdclang++ alias is not the expected relative link'
[ "$(readlink "$ROCM/lib/llvm")" = '../llvm' ] || fail 'lib/llvm alias is not the expected relative link'

for rel in bin/hipcc bin/rocminfo llvm/bin/clang llvm/bin/clang++; do
  header=$(readelf -h "$ROCM/$rel") || fail "Cannot read ELF header: $rel"
  printf '%s\n' "$header" | grep -q 'Class:.*ELF64' || fail "$rel is not ELF64"
  printf '%s\n' "$header" | grep -q 'Machine:.*AArch64' || fail "$rel is not AArch64"
done

log 'Checking /opt/rocm symlink containment and resolution.'
python3 - "$ROCM" <<'PY'
from pathlib import Path
import os
import sys

root = Path(sys.argv[1]).resolve(strict=True)
problems = []
for base, dirs, files in os.walk(root, followlinks=False):
    for name in dirs + files:
        path = Path(base) / name
        if not path.is_symlink():
            continue
        raw = os.readlink(path)
        if os.path.isabs(raw):
            problems.append(f"absolute symlink: {path.relative_to(root)} -> {raw}")
            continue
        try:
            resolved = path.resolve(strict=True)
        except (OSError, RuntimeError) as exc:
            problems.append(f"unresolved symlink: {path.relative_to(root)} -> {raw}: {exc}")
            continue
        if not resolved.is_relative_to(root):
            problems.append(f"escaping symlink: {path.relative_to(root)} -> {raw}")
if problems:
    raise SystemExit("\n".join(problems[:100]))
print("PASS: all /opt/rocm symlinks are relative, contained, and resolve")
PY

log 'Checking MI50 host integration.'
for rel in \
  etc/mi50-rocm.env \
  etc/profile.d/mi50-rocm.sh \
  etc/ld.so.conf.d/mi50-rocm.conf \
  etc/udev/rules.d/70-mi50-rocm.rules \
  etc/systemd/system/mi50-power-cap.service \
  etc/systemd/system/mi50-device-access.service \
  etc/systemd/system/mi50-device-access.timer \
  usr/local/sbin/mi50-set-power-cap \
  usr/local/sbin/mi50-add-users-to-gpu-groups; do
  [ -f "$MNT/$rel" ] || fail "Missing MI50 integration file: /$rel"
done
[ -x "$MNT/usr/local/sbin/mi50-set-power-cap" ] || fail 'Power-cap helper is not executable'
[ -x "$MNT/usr/local/sbin/mi50-add-users-to-gpu-groups" ] || fail 'GPU group helper is not executable'
[ -L "$MNT/etc/systemd/system/multi-user.target.wants/mi50-power-cap.service" ] || fail 'Power-cap service is not enabled'
[ -L "$MNT/etc/systemd/system/timers.target.wants/mi50-device-access.timer" ] || fail 'Device-access timer is not enabled'
[ -s "$MNT/etc/udev/rules.d/70-mi50-rocm.rules" ] || fail 'MI50 udev rules are empty'

log 'Checking the installed AMDGPU kernel module.'
AMDGPU_MODULE=$(find "$MNT/lib/modules" -type f \
  \( -name amdgpu.ko -o -name amdgpu.ko.xz -o -name amdgpu.ko.zst -o -name amdgpu.ko.gz \) \
  -print -quit)
[ -n "$AMDGPU_MODULE" ] || fail 'No amdgpu kernel module found in /lib/modules'
printf 'AMDGPU module: %s\n' "${AMDGPU_MODULE#"$MNT"}"

log 'Image audit passed.'
