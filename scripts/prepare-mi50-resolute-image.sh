#!/usr/bin/env bash
set -Eeuo pipefail

# Prepare a separate, core-only MI50 ROCm overlay for a clean Armbian Resolute
# Orange Pi 5 Plus image. Run from the mi50-arm repository root:
#   bash /path/to/prepare-mi50-resolute-image.sh

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log()  { printf '\n[mi50-image] %s\n' "$*"; }

MI50_REPO="${MI50_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
[ -n "$MI50_REPO" ] && [ -d "$MI50_REPO/.git" ] || fail 'Run from inside the mi50-arm Git checkout, or set MI50_REPO.'
MI50_REPO="$(cd "$MI50_REPO" && pwd -P)"

VOLUME="${MI50_VOLUME:-/run/media/hela/19c7eeb5-52f1-4c37-8483-e37745655fc7}"
AREA="${MI50_AREA:-$VOLUME/ArmbianOPi5P}"
ARMBIAN_BUILD="${MI50_ARMBIAN_BUILD:-$AREA/build}"
CLEAN="${MI50_CLEAN_BUILD:-$AREA/build-mi50-clean}"
ROOT="${MI50_ROCM_WORK_ROOT:-$ARMBIAN_BUILD/cache/mi50-arm64-cross}"
PREFIX="$ROOT/target-rocm"
STAGE="${MI50_IMAGE_STAGE:-$AREA/mi50-resolute-stage}"
STAGED_ROCM="$STAGE/opt/rocm"
USERPATCHES="$CLEAN/userpatches"
OVERLAY="$USERPATCHES/overlay"
PAYLOAD="$OVERLAY/mi50-rocm-arm64.tar.gz"

[ -d "$VOLUME" ] || fail "External volume is not mounted: $VOLUME"
[ -d "$ARMBIAN_BUILD/.git" ] || fail "Original Armbian checkout missing: $ARMBIAN_BUILD"
[ -d "$CLEAN/.git" ] || fail "Isolated Armbian checkout missing: $CLEAN"
[ -x "$PREFIX/bin/hipcc" ] || fail "Missing cross-built hipcc: $PREFIX/bin/hipcc"
[ -x "$PREFIX/bin/rocminfo" ] || fail "Missing cross-built rocminfo: $PREFIX/bin/rocminfo"
[ -x "$PREFIX/llvm/bin/clang" ] || fail "Missing target LLVM clang: $PREFIX/llvm/bin/clang"
[ -x "$PREFIX/llvm/bin/clang++" ] || fail "Missing target LLVM clang++: $PREFIX/llvm/bin/clang++"
[ -f "$MI50_REPO/armbian/extensions/mi50-amdgpu.sh" ] || fail 'MI50 Armbian extension missing from repo.'
[ -f "$MI50_REPO/patches/0001-drm-amdgpu-use-write-combined-GTT-on-non-coherent-hosts.patch" ] || fail 'GTT coherency patch missing from repo.'
[ -f "$MI50_REPO/armbian/image/overlay/mi50-customize-image-resolute.sh" ] || fail 'Resolute core-only image customizer missing from repo.'

log 'Checking that the original Armbian checkout remains untouched by this setup.'
git -C "$ARMBIAN_BUILD" status --short --branch

log 'Preparing an isolated /opt/rocm staging prefix.'
if [ -e "$STAGE" ]; then
    [ -d "$STAGED_ROCM" ] || fail "Staging path exists without opt/rocm: $STAGE; inspect it manually."
    log "Reusing existing staging prefix: $STAGED_ROCM"
else
    mkdir -p "$STAGE/opt"
    cp -a "$PREFIX" "$STAGED_ROCM"
fi

# These two symlinks were created by the cross-build with absolute host paths.
# Rewrite them only in the staging copy, never in target-rocm itself.
ln -sfn ../llvm/bin/clang "$STAGED_ROCM/bin/amdclang"
ln -sfn ../llvm/bin/clang++ "$STAGED_ROCM/bin/amdclang++"

python3 - "$STAGED_ROCM" <<'PY'
from pathlib import Path
import os
import subprocess
import sys

root = Path(sys.argv[1]).resolve()
# HIP ships a pair of Windows .bat forwarding aliases in the cross-built
# prefix. On Linux the targets do not exist (the corresponding entry points
# are the ELF hipcc/hipconfig scripts in /opt/rocm/bin). Remove only these two
# known, dangling Windows-only aliases from the staging copy.
windows_aliases = {
    "hip/bin/hipcc.bat": "../../bin/hipcc.bat",
    "hip/bin/hipconfig.bat": "../../bin/hipconfig.bat",
}
for rel, expected_target in windows_aliases.items():
    path = root / rel
    if path.is_symlink():
        target = os.readlink(path)
        resolved = (path.parent / target).resolve(strict=False)
        if target == expected_target and resolved == root / "bin" / Path(rel).name and not resolved.exists():
            path.unlink()
            print(f"Removed dangling Windows-only alias: {rel} -> {target}")

expected = {
    "bin/amdclang": "../llvm/bin/clang",
    "bin/amdclang++": "../llvm/bin/clang++",
}
for rel, target in expected.items():
    path = root / rel
    if not path.is_symlink() or os.readlink(path) != target:
        raise SystemExit(f"Bad staged symlink: {rel} -> {os.readlink(path) if path.is_symlink() else '(not a symlink)'}")

bad = []
broken = []
for directory, dirs, files in os.walk(root, followlinks=False):
    for name in dirs + files:
        path = Path(directory) / name
        if not path.is_symlink():
            continue
        target = os.readlink(path)
        if os.path.isabs(target):
            bad.append(f"{path.relative_to(root)} -> {target}")
            continue
        resolved = (path.parent / target).resolve(strict=False)
        if not resolved.is_relative_to(root):
            bad.append(f"{path.relative_to(root)} -> {target} (escapes prefix)")
        elif not resolved.exists():
            broken.append(f"{path.relative_to(root)} -> {target}")
if bad:
    raise SystemExit("Absolute or escaping symlinks remain:\n  " + "\n  ".join(bad))
if broken:
    raise SystemExit("Dangling relative symlinks found; inspect before packaging:\n  " + "\n  ".join(broken[:50]))

for rel in ("bin/hipcc", "bin/rocminfo", "llvm/bin/clang", "llvm/bin/clang++"):
    path = root / rel
    if not path.is_file():
        raise SystemExit(f"Missing staged payload file: {rel}")
    header = subprocess.check_output(["readelf", "-h", str(path)], text=True)
    if "ELF64" not in header or "AArch64" not in header:
        raise SystemExit(f"Not an AArch64 ELF executable: {rel}")
print("Staged ROCm prefix: relative symlinks contained; key binaries are ELF64 AArch64")
PY

log 'Creating compressed core-only ROCm payload.'
mkdir -p "$OVERLAY"
TMP_PAYLOAD="$PAYLOAD.tmp.$$"
trap 'rm -f "$TMP_PAYLOAD"' EXIT
tar -C "$STAGE" --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner -cf - opt/rocm | gzip -n > "$TMP_PAYLOAD"
python3 - "$TMP_PAYLOAD" <<'PY'
import sys, tarfile
path = sys.argv[1]
required = {
    "opt/rocm/bin/hipcc",
    "opt/rocm/bin/rocminfo",
    "opt/rocm/bin/amdclang",
    "opt/rocm/bin/amdclang++",
    "opt/rocm/llvm/bin/clang",
    "opt/rocm/llvm/bin/clang++",
    "opt/rocm/lib/libamdhip64.so",
    "opt/rocm/lib/libhsa-runtime64.so",
}
with tarfile.open(path, "r:gz") as archive:
    names = set(archive.getnames())
    bad = []
    for name in names:
        parts = name.split("/")
        if name.startswith("/") or ".." in parts or not (name == "opt/rocm" or name.startswith("opt/rocm/")):
            bad.append(name)
    missing = sorted(required - names)
    if bad:
        raise SystemExit("Unsafe/unexpected archive paths: " + repr(sorted(bad)[:20]))
    if missing:
        raise SystemExit("Payload missing required entries: " + repr(missing))
print(f"Payload archive validated: {len(names)} entries")
PY
mv -f "$TMP_PAYLOAD" "$PAYLOAD"
trap - EXIT

log 'Installing the MI50 kernel extension, 6.18 patch, and runtime support files.'
mkdir -p \
    "$USERPATCHES/extensions" \
    "$USERPATCHES/kernel/archive/rockchip64-6.18" \
    "$OVERLAY"
install -m 0644 "$MI50_REPO/armbian/extensions/mi50-amdgpu.sh" \
    "$USERPATCHES/extensions/mi50-amdgpu.sh"
install -m 0644 \
    "$MI50_REPO/patches/0001-drm-amdgpu-use-write-combined-GTT-on-non-coherent-hosts.patch" \
    "$USERPATCHES/kernel/archive/rockchip64-6.18/0001-drm-amdgpu-use-write-combined-GTT-on-non-coherent-hosts.patch"
cp -a "$MI50_REPO/armbian/image/overlay/etc" "$OVERLAY/"
cp -a "$MI50_REPO/armbian/image/overlay/usr" "$OVERLAY/"

log 'Writing the Resolute core-only image customizer.'
install -m 0755 "$MI50_REPO/armbian/image/overlay/mi50-customize-image-resolute.sh" \
    "$OVERLAY/mi50-customize-image.sh"

chmod 0755 "$OVERLAY/mi50-customize-image.sh"

bash -n "$OVERLAY/mi50-customize-image.sh"
bash -n "$OVERLAY/usr/local/sbin/mi50-set-power-cap"
bash -n "$OVERLAY/usr/local/sbin/mi50-add-users-to-gpu-groups"

log 'Installing a reproducible Armbian image profile.'
CONFIG="$USERPATCHES/config-mi50-resolute.conf"
TMP_CONFIG="$CONFIG.tmp.$$"
cat > "$TMP_CONFIG" <<'CONFIG'
# Clean Orange Pi 5 Plus + KDE Plasma + preinstalled MI50 ROCm/HIP core.
BOARD="orangepi5-plus"
BRANCH="current"
RELEASE="resolute"

BUILD_MINIMAL="no"
BUILD_DESKTOP="yes"
DESKTOP_ENVIRONMENT="kde-plasma"
DESKTOP_TIER="mid"
DESKTOP_ENVIRONMENT_CONFIG_NAME="config_base"
DESKTOP_APPGROUPS_SELECTED="desktop_tools internet multimedia"

KERNEL_CONFIGURE="no"
KERNEL_GIT="shallow"
ENABLE_EXTENSIONS="mi50-amdgpu"

# Keep Armbian's dynamic image sizing and leave an additional 2 GiB headroom.
EXTRA_ROOTFS_MIB_SIZE="2048"
CONFIG
if [ -e "$CONFIG" ]; then
    if ! cmp -s "$TMP_CONFIG" "$CONFIG"; then
        rm -f "$TMP_CONFIG"
        fail "Existing $CONFIG differs from the intended profile; inspect it before replacing."
    fi
    rm -f "$TMP_CONFIG"
else
    mv "$TMP_CONFIG" "$CONFIG"
fi

CUSTOMIZE="$USERPATCHES/customize-image.sh"
BEGIN_MARKER='# BEGIN mi50-arm Resolute core image integration'
END_MARKER='# END mi50-arm Resolute core image integration'
if [ ! -e "$CUSTOMIZE" ]; then
    cat > "$CUSTOMIZE" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail

# Armbian arguments: RELEASE LINUXFAMILY BOARD BUILD_DESKTOP
# BEGIN mi50-arm Resolute core image integration
if [ ! -x /tmp/overlay/mi50-customize-image.sh ]; then
  echo "mi50-arm: /tmp/overlay/mi50-customize-image.sh missing" >&2
  exit 1
fi
/tmp/overlay/mi50-customize-image.sh "$@"
# END mi50-arm Resolute core image integration
HOOK
elif ! grep -Fq "$BEGIN_MARKER" "$CUSTOMIZE"; then
    cat >> "$CUSTOMIZE" <<'HOOK'

# BEGIN mi50-arm Resolute core image integration
if [ ! -x /tmp/overlay/mi50-customize-image.sh ]; then
  echo "mi50-arm: /tmp/overlay/mi50-customize-image.sh missing" >&2
  exit 1
fi
/tmp/overlay/mi50-customize-image.sh "$@"
# END mi50-arm Resolute core image integration
HOOK
fi
chmod 0755 "$CUSTOMIZE"

log 'Validating installed profile, hooks, extension, patch, and payload.'
grep -Fqx 'RELEASE="resolute"' "$CONFIG"
grep -Fqx 'ENABLE_EXTENSIONS="mi50-amdgpu"' "$CONFIG"
grep -Fq "$BEGIN_MARKER" "$CUSTOMIZE"
grep -Fq "$END_MARKER" "$CUSTOMIZE"
test -x "$OVERLAY/mi50-customize-image.sh"
test -s "$PAYLOAD"
test -s "$USERPATCHES/extensions/mi50-amdgpu.sh"
test -s "$USERPATCHES/kernel/archive/rockchip64-6.18/0001-drm-amdgpu-use-write-combined-GTT-on-non-coherent-hosts.patch"

printf '\n=== READY: ISOLATED ARMBIAN MI50 IMAGE PROFILE ===\n'
printf 'Armbian checkout: %s\n' "$CLEAN"
printf 'Armbian revision:  %s\n' "$(git -C "$CLEAN" rev-parse --short HEAD)"
printf 'MI50 source:       %s\n' "$MI50_REPO"
printf 'ROCm source prefix:%s\n' "$PREFIX"
printf 'Payload archive:   %s\n' "$PAYLOAD"
printf 'Payload SHA256:    %s\n' "$(sha256sum "$PAYLOAD" | awk '{print $1}')"
printf 'Image hook:        %s\n' "$OVERLAY/mi50-customize-image.sh"
printf 'Image profile:     %s\n' "$CONFIG"
printf 'Config profile:    %s\n' "$CONFIG"
printf 'Kernel patch dir:  %s\n' "$USERPATCHES/kernel/archive/rockchip64-6.18"
printf '\nNext build command (run manually after reviewing the profile):\n'
printf '  cd %q && ./compile.sh mi50-resolute\n' "$CLEAN"
