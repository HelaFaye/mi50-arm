#!/usr/bin/env bash
# build-llamacpp.sh - build llama.cpp on ARM64 for an MI50 (gfx906).
#
#   ./scripts/build-llamacpp.sh vulkan    # needs only the kernel driver + Mesa RADV (start here)
#   ./scripts/build-llamacpp.sh hip       # needs ROCm built by build-rocm-aarch64.sh
#   LLAMA_FORK=mx ./scripts/build-llamacpp.sh hip
#                                         # mx-llama.cpp: gfx906 kernels, weight repack, multi-GPU -tps
#
# Env:
#   LLAMA_DIR       checkout (default ~/llama.cpp, or ~/mx-llama.cpp for LLAMA_FORK=mx)
#   LLAMA_REF       branch, tag or commit (default master)
#   LLAMA_REPO      repository URL (default upstream ggml-org/llama.cpp)
#   LLAMA_FORK=mx   https://github.com/mxxm-t/mx-llama.cpp, with its recommended HIP flags
#   LLAMA_ARM_ARCH  build for a CPU other than this one, e.g. armv8.2-a+dotprod+fp16 for RK3588
#                   (scripts/arm-cpu.sh prints the right value); default: this machine's own CPU
#   JOBS            parallel compile jobs
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
BACKEND=${1:-vulkan}
LLAMA_FORK=${LLAMA_FORK:-}
case "$LLAMA_FORK" in
  "")  LLAMA_REPO=${LLAMA_REPO:-https://github.com/ggml-org/llama.cpp}; LLAMA_DIR=${LLAMA_DIR:-$HOME/llama.cpp};;
  mx)  LLAMA_REPO=${LLAMA_REPO:-https://github.com/mxxm-t/mx-llama.cpp}; LLAMA_DIR=${LLAMA_DIR:-$HOME/mx-llama.cpp};;
  *)   echo "LLAMA_FORK: empty (upstream) or mx"; exit 2;;
esac
LLAMA_REF=${LLAMA_REF:-master}
JOBS=${JOBS:-$(nproc)}

# CPU code generation: this machine's CPU, or a named portable architecture (Llaminar-style: the build must not
# use instructions the CPU that runs it lacks; scripts/arm-cpu.sh --check-build verifies that afterwards).
if [ -n "${LLAMA_ARM_ARCH:-}" ]; then
  CPU_FLAGS=(-DGGML_NATIVE=OFF "-DGGML_CPU_ARM_ARCH=$LLAMA_ARM_ARCH")
else
  CPU_FLAGS=(-DGGML_NATIVE=ON)
fi

need_apt() {
  if command -v apt-get >/dev/null; then
    sudo apt-get install -y --no-install-recommends "$@"
  else
    echo "No apt-get: install the equivalents of these yourself: $*"
  fi
}

need_apt git cmake ninja-build build-essential pkg-config libcurl4-openssl-dev

if [ ! -d "$LLAMA_DIR/.git" ]; then
  git clone --depth 1 "$LLAMA_REPO" "$LLAMA_DIR"
fi
git -C "$LLAMA_DIR" fetch --depth 1 "$LLAMA_REPO" "$LLAMA_REF"   # branch, tag or commit, from LLAMA_REPO
git -C "$LLAMA_DIR" checkout -q FETCH_HEAD

case "$BACKEND" in
  vulkan)
    need_apt libvulkan-dev glslc mesa-vulkan-drivers vulkan-tools spirv-headers || \
      echo "If glslc is missing on your distro, install the 'shaderc' package instead."
    vulkaninfo --summary 2>/dev/null | grep -qi 'RADV' || \
      echo "WARNING: vulkaninfo does not show a RADV device. Fix the kernel driver first (scripts/check-mi50.sh)."
    cmake -S "$LLAMA_DIR" -B "$LLAMA_DIR/build-vulkan" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release -DGGML_VULKAN=ON "${CPU_FLAGS[@]}"
    cmake --build "$LLAMA_DIR/build-vulkan" -j "$JOBS"
    OUT=$LLAMA_DIR/build-vulkan/bin
    ;;
  hip)
    : "${ROCM_PATH:=/opt/rocm}"
    [ -x "$ROCM_PATH/llvm/bin/clang" ] || { echo "No ROCm at $ROCM_PATH. Run scripts/build-rocm-aarch64.sh first."; exit 1; }
    export PATH=$ROCM_PATH/bin:$ROCM_PATH/llvm/bin:$PATH
    export LD_LIBRARY_PATH=$ROCM_PATH/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
    FORK_FLAGS=()
    # mx-llama.cpp's recommended HIP graphs. Its RCCL path is for several GPUs and needs RCCL, which
    # build-rocm-aarch64.sh does not build: off here.
    [ "$LLAMA_FORK" = mx ] && FORK_FLAGS=(-DGGML_HIP_GRAPHS=ON -DGGML_HIP_RCCL=OFF)
    HIPCXX="$ROCM_PATH/llvm/bin/clang" HIP_PATH="$ROCM_PATH" \
    cmake -S "$LLAMA_DIR" -B "$LLAMA_DIR/build-hip" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release -DGGML_HIP=ON -DGPU_TARGETS=gfx906 -DAMDGPU_TARGETS=gfx906 \
      -DCMAKE_PREFIX_PATH="$ROCM_PATH" "${CPU_FLAGS[@]}" "${FORK_FLAGS[@]}"
    cmake --build "$LLAMA_DIR/build-hip" -j "$JOBS"
    OUT=$LLAMA_DIR/build-hip/bin
    ;;
  *) echo "usage: $0 vulkan|hip"; exit 2;;
esac

# Does the build use CPU instructions this machine lacks? (only meaningful on the machine that will run it)
if [ "$(uname -m)" = aarch64 ]; then
  "$HERE/arm-cpu.sh" --check-build "$(dirname "$OUT")" | sed -n '/== Build check/,$p' || \
    echo "WARNING: this build uses CPU instructions this machine lacks (see above)."
fi

MX_NOTE=""
[ "$LLAMA_FORK" = mx ] && MX_NOTE="
mx-llama.cpp: always add -lm dio (mmap hangs on that stack). Do NOT set HSA_FORCE_FINE_GRAIN_PCIE=1 on
RK3588: it needs fine-grained PCIe coherence, which this board's PCIe lacks; it only speeds up the
multi-GPU AllReduce anyway. Several GPUs: -sm tensor -tps N (FEATURES.md in the checkout)."

cat <<MSG

Built: $OUT
Check that the GPU computes what the CPU does, before trusting a model on it:
  LLAMA_BIN=$OUT $HERE/gpu-parity.sh
Smoke test (lists the GPU and runs a tiny benchmark once you have a GGUF):
  $OUT/llama-cli --list-devices
  $OUT/llama-bench -m /path/to/model.gguf -ngl 99
Serve an OpenAI-compatible API:
  $OUT/llama-server -m /path/to/model.gguf -ngl 99 -c 8192 --host 0.0.0.0 --port 8080
Thread flags for this CPU (big.LITTLE pinning): $HERE/arm-cpu.sh$MX_NOTE
MSG
