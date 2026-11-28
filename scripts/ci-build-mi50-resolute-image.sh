#!/usr/bin/env bash
set -Eeuo pipefail

# CI entrypoint for the persistent, self-hosted MI50 image builder.
# Usage: ci-build-mi50-resolute-image.sh rocm|image

fail() { printf '[mi50-ci] ERROR: %s\n' "$*" >&2; exit 1; }
log()  { printf '\n[mi50-ci] %s\n' "$*"; }

prefix_inputs_sha() {
  local build_script="$REPO_ROOT/scripts/build-rocm-arm64-cross.sh"
  {
    sha256sum "$build_script"
    while IFS= read -r patch; do
      [ -f "$REPO_ROOT/$patch" ] || fail "ROCm build references a missing patch: $patch"
      sha256sum "$REPO_ROOT/$patch"
    done < <(grep -oE 'patches/[[:alnum:]_.-]+\.patch' "$build_script" | LC_ALL=C sort -u)
  } | sha256sum | awk '{print $1}'
}

MODE=${1:-}
case "$MODE" in rocm|image) ;; *) fail "Usage: $0 rocm|image" ;; esac

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
BUILDER_ROOT=${MI50_BUILDER_ROOT:-/mnt/mi50-builder}
ARMBIAN_REF=${MI50_ARMBIAN_REF:-db15c9ea657a9723dfb62d0c862d17a33987d12a}
ROCM_VER=${MI50_ROCM_VER:-6.3.3}
BUILD_JOBS=${MI50_BUILD_JOBS:-4}
LLVM_JOBS=${MI50_LLVM_JOBS:-4}

case "$ARMBIAN_REF" in
  ''|-*|*[!A-Za-z0-9._/-]*) fail "Invalid MI50_ARMBIAN_REF: $ARMBIAN_REF" ;;
esac
case "$ROCM_VER" in
  ''|*[!0-9.]*) fail "Invalid MI50_ROCM_VER: $ROCM_VER" ;;
esac
for value in "$BUILD_JOBS" "$LLVM_JOBS"; do
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || fail "Build parallelism must be a positive integer: $value"
done

[ -d "$BUILDER_ROOT" ] || fail "Builder storage directory does not exist: $BUILDER_ROOT"
[ -w "$BUILDER_ROOT" ] || fail "Builder storage is not writable by the runner user: $BUILDER_ROOT"

# The cross-build and Armbian kernel/rootfs build are deliberately not routed
# to standard GitHub-hosted runners: the finished raw image alone is 15.59 GiB.
FREE_KB=$(df -Pk "$BUILDER_ROOT" | awk 'NR == 2 {print $4}')
[ -n "$FREE_KB" ] || fail "Could not determine free space for $BUILDER_ROOT"
MIN_FREE_KB=$((120 * 1024 * 1024))
if [ "$FREE_KB" -lt "$MIN_FREE_KB" ]; then
  fail "Need at least 120 GiB free on $BUILDER_ROOT; found $((FREE_KB / 1024 / 1024)) GiB"
fi

[ "$(uname -m)" = x86_64 ] || fail "The ROCm cross-build requires an x86_64 host; found $(uname -m)"
MEM_KB=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
if ! [[ "$MEM_KB" =~ ^[0-9]+$ ]] || (( MEM_KB < 24 * 1024 * 1024 )); then
  fail 'Need at least 24 GiB RAM for ROCm/LLVM and Armbian builds'
fi
for cmd in git clang clang++ ld.lld llvm-objcopy llvm-strip cmake ninja python3 pkg-config readelf findmnt tar patch qemu-aarch64-static mmdebstrap docker zstd fdisk blkid losetup mount umount mountpoint sha256sum file; do
  command -v "$cmd" >/dev/null 2>&1 || fail "Missing builder prerequisite: $cmd"
done
clang --print-targets 2>/dev/null | grep -qi amdgpu || fail 'Host clang has no AMDGPU backend'
printf '.text\n' | clang -x assembler -target amdgcn-amd-amdhsa -mcpu=gfx906 -c - -o /dev/null \
  || fail 'Host clang cannot assemble gfx906 AMDGPU input'
docker info >/dev/null 2>&1 || fail 'Docker daemon is unavailable to the runner user'
sudo -n losetup --version >/dev/null 2>&1 || fail 'Runner needs passwordless sudo for losetup'
sudo -n mount --version >/dev/null 2>&1 || fail 'Runner needs passwordless sudo for mount'
sudo -n umount --version >/dev/null 2>&1 || fail 'Runner needs passwordless sudo for umount'

AREA="$BUILDER_ROOT/ArmbianOPi5P"
ARMBIAN_BUILD="$AREA/build"
CLEAN="$AREA/build-mi50-clean"
WORK_ROOT="$ARMBIAN_BUILD/cache/mi50-arm64-cross"
mkdir -p "$AREA"

update_armbian_checkout() {
  local path=$1
  if [ ! -e "$path" ]; then
    log "Cloning Armbian build framework into $path"
    git clone --filter=blob:none --no-checkout https://github.com/armbian/build.git "$path"
  elif [ ! -d "$path/.git" ]; then
    fail "Refusing to use non-Git Armbian path: $path"
  fi

  if ! git -C "$path" diff --quiet || ! git -C "$path" diff --cached --quiet; then
    fail "Tracked modifications exist in dedicated Armbian checkout: $path"
  fi
  git -C "$path" fetch --depth 1 origin "$ARMBIAN_REF"
  git -C "$path" checkout --detach --force FETCH_HEAD
  git -C "$path" reset --hard FETCH_HEAD
  local actual
  actual=$(git -C "$path" rev-parse HEAD)
  log "Armbian source $path pinned to $actual"
  [ -z "$(git -C "$path" status --porcelain --untracked-files=no)" ] || fail "Tracked Armbian checkout is dirty: $path"
}

update_armbian_checkout "$ARMBIAN_BUILD"
if [ "$MODE" = image ]; then
  update_armbian_checkout "$CLEAN"
fi

if [ "$MODE" = rocm ]; then
  PREFIX_INPUTS_SHA=$(prefix_inputs_sha)
  log "Building the pinned ROCm $ROCM_VER ARM64 core prefix (inputs $PREFIX_INPUTS_SHA)"
  export WORK_ROOT ROCM_VER
  export CROSS_COMPILER=clang
  export JOBS="$BUILD_JOBS"
  export LLVM_JOBS
  export LINK_JOBS=1
  export SKIP_QEMU_SMOKE=0
  bash "$REPO_ROOT/scripts/build-rocm-arm64-cross.sh"

  for rel in bin/hipcc bin/rocminfo llvm/bin/clang llvm/bin/clang++; do
    path="$WORK_ROOT/target-rocm/$rel"
    [ -x "$path" ] || fail "Cross-build did not produce executable: $path"
    readelf -h "$path" | grep -q 'Machine:.*AArch64' || fail "Cross-build output is not AArch64: $path"
  done
  printf 'ROCM_VER=%s\nPREFIX_INPUTS_SHA=%s\nMI50_REPO_SHA=%s\nARMBIAN_REF=%s\n' \
    "$ROCM_VER" "$PREFIX_INPUTS_SHA" "$(git -C "$REPO_ROOT" rev-parse HEAD)" "$ARMBIAN_REF" \
    > "$WORK_ROOT/.mi50-ci-prefix-manifest"
  log "ROCm ARM64 core prefix verified at $WORK_ROOT/target-rocm"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      printf '\n## MI50 ROCm ARM64 prefix build\n\n'
      printf '%s\n' "- ROCm source tag: \`$ROCM_VER\`"
      printf '%s\n' "- Prefix: \`$WORK_ROOT/target-rocm\`"
      printf '%s\n' "- Armbian reference: \`$ARMBIAN_REF\`"
      printf '%s\n' "- Prefix disk usage: \`$(du -sh "$WORK_ROOT/target-rocm" | awk '{print $1}')\`"
    } >> "$GITHUB_STEP_SUMMARY"
  fi
  exit 0
fi

PREFIX="$WORK_ROOT/target-rocm"
[ -x "$PREFIX/bin/hipcc" ] || fail "Cached ROCm prefix missing: $PREFIX/bin/hipcc; run workflow with rebuild_rocm=true"
[ -x "$PREFIX/bin/rocminfo" ] || fail "Cached ROCm prefix missing: $PREFIX/bin/rocminfo; run workflow with rebuild_rocm=true"
PREFIX_MANIFEST="$WORK_ROOT/.mi50-ci-prefix-manifest"
[ -s "$PREFIX_MANIFEST" ] || fail "ROCm prefix provenance manifest missing: $PREFIX_MANIFEST; run workflow with rebuild_rocm=true"
grep -Fqx "ROCM_VER=$ROCM_VER" "$PREFIX_MANIFEST" || fail "Cached ROCm prefix version differs from requested $ROCM_VER; rebuild it first"
CURRENT_PREFIX_INPUTS_SHA=$(prefix_inputs_sha)
grep -Fqx "PREFIX_INPUTS_SHA=$CURRENT_PREFIX_INPUTS_SHA" "$PREFIX_MANIFEST" \
  || fail 'Cached ROCm prefix was built from different cross-build inputs; run workflow with rebuild_rocm=true'

log 'Preparing the isolated Armbian Resolute profile and overlay.'
MI50_VOLUME="$BUILDER_ROOT" \
MI50_AREA="$AREA" \
MI50_ARMBIAN_BUILD="$ARMBIAN_BUILD" \
MI50_CLEAN_BUILD="$CLEAN" \
MI50_ROCM_WORK_ROOT="$WORK_ROOT" \
  bash "$REPO_ROOT/scripts/prepare-mi50-resolute-image.sh"

log 'Building Orange Pi 5 Plus Resolute KDE image through Armbian.'
BUILD_STARTED=$(date +%s)
(
  cd "$CLEAN"
  PREFER_DOCKER=yes ./compile.sh mi50-resolute
)

IMAGE=$(find "$CLEAN/output/images" -maxdepth 1 -type f \
  -name 'Armbian-unofficial*Orangepi5-plus*resolute*current*6.18*kde-plasma*desktop.img' \
  -printf '%T@ %p\n' 2>/dev/null | sort -nr | sed -n '1p' | cut -d ' ' -f 2-)
if [ -z "$IMAGE" ] || [ ! -f "$IMAGE" ]; then
  fail 'Could not locate the generated Resolute Orange Pi 5 Plus image'
fi
IMAGE=$(realpath "$IMAGE")
IMAGE_MTIME=$(stat -c %Y "$IMAGE")
[ "$IMAGE_MTIME" -ge "$BUILD_STARTED" ] || fail "Newest image predates this build invocation: $IMAGE"

log 'Checking that the latest Armbian build log records the MI50 GTT patch and object compilation.'
BUILD_LOG=$(find "$CLEAN/output/logs" -maxdepth 1 -type f -name 'log-build-*.log.ans' \
  -printf '%T@ %p\n' 2>/dev/null | sort -nr | sed -n '1p' | cut -d ' ' -f 2-)
if [ -z "$BUILD_LOG" ] || [ ! -f "$BUILD_LOG" ]; then
  fail 'Armbian build log not found'
fi
grep -Fq '0001-drm-amdgpu-use-write-combined-GTT-on-non-coherent-hosts' "$BUILD_LOG" \
  || fail 'Latest Armbian build log does not show the MI50 GTT patch'
grep -Fq 'amdgpu_gtt_mgr.o' "$BUILD_LOG" \
  || fail 'Latest Armbian build log does not show amdgpu_gtt_mgr.o compilation'

log "Running read-only image audit: $IMAGE"
bash "$REPO_ROOT/scripts/verify-mi50-resolute-image.sh" "$IMAGE"

log 'Compressing verified image with Zstandard.'
COMPRESSED="$IMAGE.zst"
zstd -T0 -3 -f "$IMAGE" -o "$COMPRESSED"
zstd -t "$COMPRESSED"

IMAGE_SHA=$(sha256sum "$IMAGE" | awk '{print $1}')
COMPRESSED_SHA=$(sha256sum "$COMPRESSED" | awk '{print $1}')
PAYLOAD="$CLEAN/userpatches/overlay/mi50-rocm-arm64.tar.gz"
[ -s "$PAYLOAD" ] || fail "Prepared ROCm payload missing: $PAYLOAD"
PAYLOAD_SHA=$(sha256sum "$PAYLOAD" | awk '{print $1}')
PATCH="$CLEAN/userpatches/kernel/archive/rockchip64-6.18/0001-drm-amdgpu-use-write-combined-GTT-on-non-coherent-hosts.patch"
[ -s "$PATCH" ] || fail "Staged GTT kernel patch missing: $PATCH"
PATCH_SHA=$(sha256sum "$PATCH" | awk '{print $1}')
IMAGE_SHA_FILE="$IMAGE.sha256"
COMPRESSED_SHA_FILE="$COMPRESSED.sha256"
printf '%s  %s\n' "$IMAGE_SHA" "$(basename "$IMAGE")" > "$IMAGE_SHA_FILE"
printf '%s  %s\n' "$COMPRESSED_SHA" "$(basename "$COMPRESSED")" > "$COMPRESSED_SHA_FILE"

MANIFEST="$IMAGE.manifest.json"
export IMAGE COMPRESSED IMAGE_SHA COMPRESSED_SHA PAYLOAD_SHA PATCH_SHA BUILD_LOG ARMBIAN_REF ROCM_VER REPO_ROOT CLEAN
python3 - "$MANIFEST" <<'PY'
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import subprocess
import sys

manifest_path = Path(sys.argv[1])
def git_value(path: str, *args: str) -> str:
    return subprocess.check_output(["git", "-C", path, *args], text=True).strip()

image = Path(os.environ["IMAGE"])
compressed = Path(os.environ["COMPRESSED"])
manifest = {
    "schema": 1,
    "created_utc": datetime.now(timezone.utc).isoformat(),
    "mi50_arm_commit": git_value(os.environ["REPO_ROOT"], "rev-parse", "HEAD"),
    "armbian_build_ref_requested": os.environ["ARMBIAN_REF"],
    "armbian_build_commit": git_value(os.environ["CLEAN"], "rev-parse", "HEAD"),
    "board": "orangepi5-plus",
    "distribution": "Ubuntu 26.04 Resolute",
    "desktop": "KDE Plasma mid",
    "kernel": image.name.split("_current_", 1)[1].split("_kde-plasma", 1)[0],
    "rocm_source_tag": os.environ["ROCM_VER"],
    "image_file": image.name,
    "image_bytes": image.stat().st_size,
    "image_sha256": os.environ["IMAGE_SHA"],
    "compressed_image_file": compressed.name,
    "compressed_image_bytes": compressed.stat().st_size,
    "compressed_image_sha256": os.environ["COMPRESSED_SHA"],
    "rocm_payload_sha256": os.environ["PAYLOAD_SHA"],
    "gtt_kernel_patch_sha256": os.environ["PATCH_SHA"],
    "armbian_build_log": Path(os.environ["BUILD_LOG"]).name,
}
manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
print(f"Wrote build manifest: {manifest_path}")
PY

REPORT_DIR="${RUNNER_TEMP:-$BUILDER_ROOT}/mi50-image-report"
mkdir -p "$REPORT_DIR"
cp -f "$MANIFEST" "$IMAGE_SHA_FILE" "$COMPRESSED_SHA_FILE" "$REPORT_DIR/"
cp -f "$BUILD_LOG" "$REPORT_DIR/armbian-build.log.ans"

log 'Build and audit complete.'
printf 'Raw image:        %s\n' "$IMAGE"
printf 'Raw image SHA256: %s\n' "$IMAGE_SHA"
printf 'Zstandard image:  %s\n' "$COMPRESSED"
printf 'Zstandard SHA256: %s\n' "$COMPRESSED_SHA"
printf 'Manifest:         %s\n' "$MANIFEST"
printf 'Armbian log:      %s\n' "$BUILD_LOG"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    printf '\n## MI50 Resolute image rebuild\n\n'
    printf '| Item | Result |\n|---|---|\n'
    printf '%s\n' "| Raw image | \`$IMAGE\` |"
    printf '%s\n' "| Raw SHA-256 | \`$IMAGE_SHA\` |"
    printf '%s\n' "| Zstandard image | \`$COMPRESSED\` |"
    printf '%s\n' "| Zstandard SHA-256 | \`$COMPRESSED_SHA\` |"
    printf '%s\n' "| Manifest | \`$MANIFEST\` |"
    printf '%s\n' "| Armbian commit | \`$(git -C "$CLEAN" rev-parse HEAD)\` |"
    printf '| MI50 GTT patch | applied and compiled |\n'
    printf '| Rootfs / ROCm audit | passed |\n'
    printf '\nImages remain on the self-hosted builder at the paths above; the 16 GiB disk image is not uploaded to Actions artifact storage.\n'
  } >> "$GITHUB_STEP_SUMMARY"
fi
