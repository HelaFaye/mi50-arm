#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 /path/to/armbian/build <kernel-major.minor>" >&2
  exit 2
fi

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
ARMBIAN_BUILD="$(cd -- "$1" && pwd)"
KERNEL_MM="$2"
if [[ ! "$KERNEL_MM" =~ ^[0-9]+\.[0-9]+$ ]]; then
  echo "Kernel version must be MAJOR.MINOR (for example 6.18 or 7.3): $KERNEL_MM" >&2
  exit 2
fi

USERPATCHES="$ARMBIAN_BUILD/userpatches"
mkdir -p "$USERPATCHES/extensions" "$USERPATCHES/kernel/archive/rockchip64-$KERNEL_MM" "$USERPATCHES/overlay"

install -m 0644 "$REPO_ROOT/armbian/extensions/mi50-amdgpu.sh" "$USERPATCHES/extensions/mi50-amdgpu.sh"
install -m 0644 "$REPO_ROOT/patches/0001-drm-amdgpu-use-write-combined-GTT-on-non-coherent-hosts.patch" \
  "$USERPATCHES/kernel/archive/rockchip64-$KERNEL_MM/0001-drm-amdgpu-use-write-combined-GTT-on-non-coherent-hosts.patch"
cp -a "$REPO_ROOT/armbian/image/overlay/." "$USERPATCHES/overlay/"

CUSTOMIZE="$USERPATCHES/customize-image.sh"
BEGIN_MARKER="# BEGIN mi50-arm image integration"
END_MARKER="# END mi50-arm image integration"
if [ ! -e "$CUSTOMIZE" ]; then
  install -m 0755 "$REPO_ROOT/armbian/image/customize-image.sh" "$CUSTOMIZE"
elif ! grep -Fq "$BEGIN_MARKER" "$CUSTOMIZE"; then
  cat >> "$CUSTOMIZE" <<'EOF'

# BEGIN mi50-arm image integration
if [ -x /tmp/overlay/mi50-customize-image.sh ]; then
  /tmp/overlay/mi50-customize-image.sh "$@"
else
  echo "mi50-arm integration: /tmp/overlay/mi50-customize-image.sh missing" >&2
  exit 1
fi
# END mi50-arm image integration
EOF
fi

if ! grep -Fq "$BEGIN_MARKER" "$CUSTOMIZE" || ! grep -Fq "$END_MARKER" "$CUSTOMIZE"; then
  echo "Failed to install MI50 call into $CUSTOMIZE" >&2
  exit 1
fi

chmod 0755 "$CUSTOMIZE"
printf 'Installed MI50 Armbian integration into %s\n' "$ARMBIAN_BUILD"
printf 'Kernel patch directory: userpatches/kernel/archive/rockchip64-%s\n' "$KERNEL_MM"
printf 'Copy the built ARM64 payload to: %s/userpatches/overlay/mi50-arm64-payload.tar.gz\n' "$USERPATCHES"
