#!/usr/bin/env bash
set -euo pipefail

RELEASE=${1:-unknown}
LINUXFAMILY=${2:-unknown}
BOARD=${3:-unknown}
BUILD_DESKTOP=${4:-no}
PAYLOAD=/tmp/overlay/mi50-arm64-payload.tar.gz
ROCM=/opt/rocm
VENV=/opt/venv-rocm

fail() { echo "mi50-arm image customization: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "must run as root inside the Armbian target-rootfs chroot"
[ "$(dpkg --print-architecture)" = arm64 ] || fail "target rootfs is not arm64"
case "$RELEASE" in
  noble) ;;
  *) fail "this image integration currently supports Ubuntu noble only (got: $RELEASE)" ;;
esac
[ -r "$PAYLOAD" ] || fail "missing $PAYLOAD; stage the ARM64 payload in userpatches/overlay"
command -v tar >/dev/null 2>&1 || fail "tar is missing in target rootfs"

# Validate the archive's path set before extraction. Only /opt/rocm and
# /opt/venv-rocm are permitted; absolute paths and traversal are rejected.
LIST=$(mktemp)
trap 'rm -f "$LIST"' EXIT
tar -tzf "$PAYLOAD" > "$LIST" || fail "payload archive is not a readable gzip tar"
awk '
  /^\// || /(^|\/)\.\.($|\/)/ { bad=1 }
  !/^opt\/rocm\/?$/ && !/^opt\/rocm\// && !/^opt\/venv-rocm\/?$/ && !/^opt\/venv-rocm\// { bad=1 }
  END { exit bad }
' "$LIST" || fail "payload contains paths outside opt/rocm and opt/venv-rocm"
grep -Eq '^opt/rocm/bin/hipcc$' "$LIST" || fail "payload lacks opt/rocm/bin/hipcc"
grep -Eq '^opt/venv-rocm/pyvenv\.cfg$' "$LIST" || fail "payload lacks opt/venv-rocm/pyvenv.cfg"
grep -Eq '^opt/venv-rocm/bin/python(3(\.[0-9]+)?)?$' "$LIST" || fail "payload lacks the venv Python interpreter"

# The payload was built on ARM64 and created at these exact paths. Do not move
# the venv: console-script shebangs contain /opt/venv-rocm/bin/python.
tar --no-same-owner -xzf "$PAYLOAD" -C /
[ -x "$ROCM/bin/hipcc" ] || fail "ROCm compiler not installed at $ROCM/bin/hipcc"
[ -x "$VENV/bin/python" ] || fail "venv interpreter not installed at $VENV/bin/python"
"$VENV/bin/python" -S -c 'import sys; assert (3, 9) <= sys.version_info[:2] < (3, 13), sys.version; print("MI50 venv Python:", sys.version.split()[0])' \
  || fail "venv Python must be 3.9 through 3.12"

install -D -m 0644 /tmp/overlay/etc/mi50-rocm.env /etc/mi50-rocm.env
install -D -m 0644 /tmp/overlay/etc/profile.d/mi50-rocm.sh /etc/profile.d/mi50-rocm.sh
install -D -m 0644 /tmp/overlay/etc/ld.so.conf.d/mi50-rocm.conf /etc/ld.so.conf.d/mi50-rocm.conf
install -D -m 0644 /tmp/overlay/etc/udev/rules.d/70-mi50-rocm.rules /etc/udev/rules.d/70-mi50-rocm.rules
install -D -m 0644 /tmp/overlay/etc/systemd/system/mi50-power-cap.service /etc/systemd/system/mi50-power-cap.service
install -D -m 0644 /tmp/overlay/etc/systemd/system/mi50-device-access.service /etc/systemd/system/mi50-device-access.service
install -D -m 0644 /tmp/overlay/etc/systemd/system/mi50-device-access.timer /etc/systemd/system/mi50-device-access.timer
install -D -m 0755 /tmp/overlay/usr/local/sbin/mi50-set-power-cap /usr/local/sbin/mi50-set-power-cap
install -D -m 0755 /tmp/overlay/usr/local/sbin/mi50-add-users-to-gpu-groups /usr/local/sbin/mi50-add-users-to-gpu-groups

mkdir -p /var/lib/mi50-rocm
ldconfig
systemctl --root=/ enable mi50-power-cap.service mi50-device-access.timer

printf 'MI50 image integration installed: release=%s family=%s board=%s desktop=%s\n' \
  "$RELEASE" "$LINUXFAMILY" "$BOARD" "$BUILD_DESKTOP"
