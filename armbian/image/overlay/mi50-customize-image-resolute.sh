#!/usr/bin/env bash
set -euo pipefail

RELEASE=${1:-unknown}
LINUXFAMILY=${2:-unknown}
BOARD=${3:-unknown}
BUILD_DESKTOP=${4:-no}
OVERLAY=/tmp/overlay
PAYLOAD="$OVERLAY/mi50-rocm-arm64.tar.gz"
ROCM=/opt/rocm

fail() { echo "mi50-arm image customization: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "must run as root inside the Armbian target-rootfs chroot"
[ "$(dpkg --print-architecture)" = arm64 ] || fail "target rootfs is not arm64"
[ "$RELEASE" = resolute ] || fail "this integration targets Ubuntu Resolute only (got: $RELEASE)"
[ "$BOARD" = orangepi5-plus ] || fail "unexpected board argument: $BOARD"
[ -r "$PAYLOAD" ] || fail "missing $PAYLOAD"

LIST=$(mktemp)
trap 'rm -f "$LIST"' EXIT
tar -tzf "$PAYLOAD" > "$LIST" || fail "payload is not a readable gzip tar archive"
awk '
  /^\// || /(^|\/)\.\.($|\/)/ { bad=1 }
  !/^opt\/rocm\/?$/ && !/^opt\/rocm\// { bad=1 }
  END { exit bad }
' "$LIST" || fail "payload contains unsafe paths or files outside opt/rocm"
for entry in \
  opt/rocm/bin/hipcc \
  opt/rocm/bin/rocminfo \
  opt/rocm/bin/amdclang \
  opt/rocm/bin/amdclang++ \
  opt/rocm/llvm/bin/clang \
  opt/rocm/llvm/bin/clang++ \
  opt/rocm/lib/libamdhip64.so \
  opt/rocm/lib/libhsa-runtime64.so; do
  grep -Fqx "$entry" "$LIST" || fail "payload is missing $entry"
done

log() { echo "[mi50-arm] $*"; }
log "Installing Resolute ARM64 runtime dependencies."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  libdrm2 libdrm-amdgpu1 libelf1t64 libnuma1 libzstd1 zlib1g

log "Extracting the prebuilt ROCm/HIP prefix into /opt/rocm."
tar --no-same-owner -xzf "$PAYLOAD" -C /
[ -x "$ROCM/bin/hipcc" ] || fail "hipcc was not installed"
[ -x "$ROCM/bin/rocminfo" ] || fail "rocminfo was not installed"
[ -x "$ROCM/llvm/bin/clang" ] || fail "LLVM clang was not installed"
[ "$(readlink "$ROCM/bin/amdclang")" = ../llvm/bin/clang ] || fail "amdclang has an unexpected symlink target"
[ "$(readlink "$ROCM/bin/amdclang++")" = ../llvm/bin/clang++ ] || fail "amdclang++ has an unexpected symlink target"
if find "$ROCM" -type l -lname '/*' -print -quit | grep -q .; then
  fail "absolute symlinks remain under /opt/rocm"
fi

for path in \
  etc/mi50-rocm.env \
  etc/profile.d/mi50-rocm.sh \
  etc/ld.so.conf.d/mi50-rocm.conf \
  etc/udev/rules.d/70-mi50-rocm.rules \
  etc/systemd/system/mi50-power-cap.service \
  etc/systemd/system/mi50-device-access.service \
  etc/systemd/system/mi50-device-access.timer \
  usr/local/sbin/mi50-set-power-cap \
  usr/local/sbin/mi50-add-users-to-gpu-groups; do
  [ -f "$OVERLAY/$path" ] || fail "missing MI50 support file /tmp/overlay/$path"
done

install -D -m 0644 "$OVERLAY/etc/mi50-rocm.env" /etc/mi50-rocm.env
install -D -m 0644 "$OVERLAY/etc/profile.d/mi50-rocm.sh" /etc/profile.d/mi50-rocm.sh
install -D -m 0644 "$OVERLAY/etc/ld.so.conf.d/mi50-rocm.conf" /etc/ld.so.conf.d/mi50-rocm.conf
install -D -m 0644 "$OVERLAY/etc/udev/rules.d/70-mi50-rocm.rules" /etc/udev/rules.d/70-mi50-rocm.rules
install -D -m 0644 "$OVERLAY/etc/systemd/system/mi50-power-cap.service" /etc/systemd/system/mi50-power-cap.service
install -D -m 0644 "$OVERLAY/etc/systemd/system/mi50-device-access.service" /etc/systemd/system/mi50-device-access.service
install -D -m 0644 "$OVERLAY/etc/systemd/system/mi50-device-access.timer" /etc/systemd/system/mi50-device-access.timer
install -D -m 0755 "$OVERLAY/usr/local/sbin/mi50-set-power-cap" /usr/local/sbin/mi50-set-power-cap
install -D -m 0755 "$OVERLAY/usr/local/sbin/mi50-add-users-to-gpu-groups" /usr/local/sbin/mi50-add-users-to-gpu-groups

mkdir -p /var/lib/mi50-rocm
ldconfig
systemctl --root=/ enable mi50-power-cap.service mi50-device-access.timer
apt-get clean

log "Installed core ROCm/HIP runtime: release=$RELEASE family=$LINUXFAMILY board=$BOARD desktop=$BUILD_DESKTOP"
log "Python/PyTorch/rocBLAS/hipBLAS are not part of this core-only payload."
