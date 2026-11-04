#!/usr/bin/env bash
# build-llamacpp.sh - build llama.cpp on ARM64 for an MI50 (gfx906).
#
#   ./scripts/build-llamacpp.sh vulkan    # needs only the kernel driver + Mesa RADV (start here)
#   ./scripts/build-llamacpp.sh hip       # needs ROCm built by build-rocm-aarch64.sh
#
# Env: LLAMA_DIR (default ~/llama.cpp), LLAMA_REF (default master), JOBS.
set -euo pipefail

BACKEND=${1:-vulkan}
LLAMA_DIR=${LLAMA_DIR:-$HOME/llama.cpp}
LLAMA_REF=${LLAMA_REF:-master}
JOBS=${JOBS:-$(nproc)}

need_apt() {
  if command -v apt-get >/dev/null; then
    sudo apt-get install -y --no-install-recommends "$@"
  else
    echo "No apt-get: install the equivalents of these yourself: $*"
  fi
}

need_apt git cmake ninja-build build-essential pkg-config libcurl4-openssl-dev

if [ ! -d "$LLAMA_DIR/.git" ]; then
  git clone --depth 1 https://github.com/ggml-org/llama.cpp "$LLAMA_DIR"
fi
git -C "$LLAMA_DIR" fetch --depth 1 origin "$LLAMA_REF"   # branch, tag or commit
git -C "$LLAMA_DIR" checkout -q FETCH_HEAD

case "$BACKEND" in
  vulkan)
    need_apt libvulkan-dev glslc mesa-vulkan-drivers vulkan-tools spirv-headers || \
      echo "If glslc is missing on your distro, install the 'shaderc' package instead."
    vulkaninfo --summary 2>/dev/null | grep -qi 'RADV' || \
      echo "WARNING: vulkaninfo does not show a RADV device. Fix the kernel driver first (scripts/check-mi50.sh)."
    cmake -S "$LLAMA_DIR" -B "$LLAMA_DIR/build-vulkan" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release -DGGML_VULKAN=ON -DGGML_NATIVE=ON
    cmake --build "$LLAMA_DIR/build-vulkan" -j "$JOBS"
    OUT=$LLAMA_DIR/build-vulkan/bin
    ;;
  hip)
    : "${ROCM_PATH:=/opt/rocm}"
    [ -x "$ROCM_PATH/llvm/bin/clang" ] || { echo "No ROCm at $ROCM_PATH. Run scripts/build-rocm-aarch64.sh first."; exit 1; }
    export PATH=$ROCM_PATH/bin:$ROCM_PATH/llvm/bin:$PATH
    export LD_LIBRARY_PATH=$ROCM_PATH/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
    HIPCXX="$ROCM_PATH/llvm/bin/clang" HIP_PATH="$ROCM_PATH" \
    cmake -S "$LLAMA_DIR" -B "$LLAMA_DIR/build-hip" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release -DGGML_HIP=ON -DGPU_TARGETS=gfx906 -DAMDGPU_TARGETS=gfx906 \
      -DCMAKE_PREFIX_PATH="$ROCM_PATH" -DGGML_NATIVE=ON
    cmake --build "$LLAMA_DIR/build-hip" -j "$JOBS"
    OUT=$LLAMA_DIR/build-hip/bin
    ;;
  *) echo "usage: $0 vulkan|hip"; exit 2;;
esac

cat <<MSG

Built: $OUT
Smoke test (lists the GPU and runs a tiny benchmark once you have a GGUF):
  $OUT/llama-cli --list-devices
  $OUT/llama-bench -m /path/to/model.gguf -ngl 99
Serve an OpenAI-compatible API:
  $OUT/llama-server -m /path/to/model.gguf -ngl 99 -c 8192 --host 0.0.0.0 --port 8080
MSG
