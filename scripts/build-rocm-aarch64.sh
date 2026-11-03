#!/usr/bin/env bash
# build-rocm-aarch64.sh - build a minimal ROCm 6.3.3 stack from source on ARM64,
# targeting only gfx906 (MI50). Enough for llama.cpp's HIP backend.
#
# Components, in build order:
#   rocm-cmake -> llvm/clang/lld (ROCm fork) -> device-libs -> comgr -> hipcc
#   -> ROCR-Runtime (includes libhsakmt) -> rocminfo -> HIP (clr + HIP headers)
#   -> hipBLAS-common -> rocBLAS (+Tensile) -> hipBLAS
#
# Usage:
#   ./scripts/build-rocm-aarch64.sh            # all stages
#   ./scripts/build-rocm-aarch64.sh rocblas    # resume from a stage
#   ./scripts/build-rocm-aarch64.sh --list
#
# Env:
#   ROCM_VER   (default 6.3.3)       git tag rocm-$ROCM_VER in every repo
#   ROCM_PATH  (default /opt/rocm)   install prefix (must be writable, or use sudo)
#   SRC        (default ~/rocm-src)  source/build tree
#   JOBS       (default nproc)       LLVM needs ~2 GB RAM per job; lower this on 8 GB boards
#   LINK_JOBS  (default 2)           parallel LLVM links (~4+ GB RAM each)
#
# Expect hours on an RK3588 (LLVM and rocBLAS/Tensile dominate). Building on an
# 16+ GB board with swap, or natively on any bigger aarch64 machine, is fine:
# everything installs into ROCM_PATH and can be copied over as a tarball.
#
# No source patches are applied: these projects already build on aarch64. If a
# stage fails, fix that stage and rerun the script from it.
set -euo pipefail

ROCM_VER=${ROCM_VER:-6.3.3}
TAG=rocm-$ROCM_VER
ROCM_PATH=${ROCM_PATH:-/opt/rocm}
SRC=${SRC:-$HOME/rocm-src}
JOBS=${JOBS:-$(nproc)}
GFX=gfx906
LLVM=$ROCM_PATH/llvm

STAGES=(deps rocm_cmake llvm device_libs comgr hipcc rocr rocminfo hip hipblas_common rocblas hipblas)

log() { printf '\n\033[1m>>> %s\033[0m\n' "$*"; }

fetch() { # fetch <repo> [dir]
  local repo=$1 dir=${2:-$1}
  if [ ! -d "$SRC/$dir/.git" ]; then
    git clone --depth 1 --branch "$TAG" "https://github.com/ROCm/$repo" "$SRC/$dir"
  fi
}

cm() { # cm <srcdir> <builddir> [cmake args...]
  local s=$1 b=$2; shift 2
  cmake -S "$s" -B "$b" -G Ninja -DCMAKE_BUILD_TYPE=Release "$@"
  cmake --build "$b" -j "$JOBS"
  cmake --install "$b"
}

stage_deps() {
  log "system packages"
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends \
    git cmake ninja-build build-essential lld pkg-config python3 python3-pip python3-venv python3-dev \
    libelf-dev libnuma-dev libdrm-dev libdrm-amdgpu1 libzstd-dev zlib1g-dev libncurses-dev \
    xxd file gfortran libmsgpack-dev libfmt-dev libsqlite3-dev
  mkdir -p "$SRC"
  if [ ! -w "$(dirname "$ROCM_PATH")" ] && [ ! -w "$ROCM_PATH" ]; then
    sudo mkdir -p "$ROCM_PATH" && sudo chown "$(id -u):$(id -g)" "$ROCM_PATH"
  fi
  mkdir -p "$ROCM_PATH"
  # Python venv for build-time helpers (clr needs CppHeaderParser; Tensile installs itself).
  python3 -m venv "$SRC/venv"
  "$SRC/venv/bin/pip" install -q --upgrade pip CppHeaderParser pyyaml joblib msgpack
}

stage_rocm_cmake() {
  log "rocm-cmake"
  fetch rocm-cmake
  cm "$SRC/rocm-cmake" "$SRC/build/rocm-cmake" -DCMAKE_INSTALL_PREFIX="$ROCM_PATH"
}

stage_llvm() {
  log "LLVM/Clang/LLD (ROCm fork) - the long one"
  fetch llvm-project
  # AMDGPU is a normal (non-experimental) LLVM target; "host" = AArch64 on ARM64.
  cm "$SRC/llvm-project/llvm" "$SRC/build/llvm" \
    -DCMAKE_INSTALL_PREFIX="$LLVM" \
    -DLLVM_TARGETS_TO_BUILD="host;AMDGPU" \
    -DLLVM_ENABLE_PROJECTS="clang;lld"  \
    -DLLVM_ENABLE_ASSERTIONS=OFF -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_ENABLE_ZSTD=ON -DLLVM_USE_LINKER=lld \
    -DLLVM_PARALLEL_LINK_JOBS="${LINK_JOBS:-2}"
}

stage_device_libs() {
  log "ROCm-Device-Libs (amd/device-libs)"
  cm "$SRC/llvm-project/amd/device-libs" "$SRC/build/device-libs" \
    -DCMAKE_INSTALL_PREFIX="$ROCM_PATH" -DCMAKE_PREFIX_PATH="$LLVM"
}

stage_comgr() {
  log "comgr (amd/comgr)"
  cm "$SRC/llvm-project/amd/comgr" "$SRC/build/comgr" \
    -DCMAKE_INSTALL_PREFIX="$ROCM_PATH" -DCMAKE_PREFIX_PATH="$LLVM;$ROCM_PATH" \
    -DBUILD_TESTING=OFF
}

stage_hipcc() {
  log "hipcc (amd/hipcc)"
  cm "$SRC/llvm-project/amd/hipcc" "$SRC/build/hipcc" -DCMAKE_INSTALL_PREFIX="$ROCM_PATH"
}

stage_rocr() {
  log "ROCR-Runtime (libhsa-runtime64 + libhsakmt)"
  fetch ROCR-Runtime
  cm "$SRC/ROCR-Runtime" "$SRC/build/rocr" \
    -DCMAKE_INSTALL_PREFIX="$ROCM_PATH" -DCMAKE_PREFIX_PATH="$LLVM;$ROCM_PATH" \
    -DBUILD_SHARED_LIBS=ON
}

stage_rocminfo() {
  log "rocminfo"
  fetch rocminfo
  cm "$SRC/rocminfo" "$SRC/build/rocminfo" \
    -DCMAKE_INSTALL_PREFIX="$ROCM_PATH" -DCMAKE_PREFIX_PATH="$ROCM_PATH"
}

stage_hip() {
  log "HIP runtime (clr + HIP)"
  fetch HIP
  fetch clr
  PATH="$SRC/venv/bin:$PATH" cm "$SRC/clr" "$SRC/build/clr" \
    -DCMAKE_INSTALL_PREFIX="$ROCM_PATH" -DCMAKE_PREFIX_PATH="$LLVM;$ROCM_PATH" \
    -DCLR_BUILD_HIP=ON -DCLR_BUILD_OCL=OFF -DHIP_PLATFORM=amd \
    -DHIP_COMMON_DIR="$SRC/HIP" -DHIPCC_BIN_DIR="$ROCM_PATH/bin" \
    -DHIP_ENABLE_ROCPROFILER_REGISTER=OFF -D__HIP_ENABLE_PCH=OFF \
    -DROCM_PATH="$ROCM_PATH"
}

hip_cmake_args=(
  -DCMAKE_INSTALL_PREFIX="$ROCM_PATH"
  -DCMAKE_PREFIX_PATH="$ROCM_PATH;$LLVM"
  -DCMAKE_C_COMPILER="$LLVM/bin/clang"
  -DCMAKE_CXX_COMPILER="$LLVM/bin/clang++"
  -DROCM_PATH="$ROCM_PATH"
  -DAMDGPU_TARGETS="$GFX" -DGPU_TARGETS="$GFX"
)

stage_hipblas_common() {
  log "hipBLAS-common"
  fetch hipBLAS-common
  cm "$SRC/hipBLAS-common" "$SRC/build/hipblas-common" "${hip_cmake_args[@]}"
}

stage_rocblas() {
  log "rocBLAS + Tensile kernels for $GFX (long)"
  fetch rocBLAS
  PATH="$SRC/venv/bin:$PATH" cm "$SRC/rocBLAS" "$SRC/build/rocblas" "${hip_cmake_args[@]}" \
    -DBUILD_WITH_TENSILE=ON -DBUILD_WITH_HIPBLASLT=OFF \
    -DBUILD_CLIENTS_TESTS=OFF -DBUILD_CLIENTS_BENCHMARKS=OFF -DBUILD_CLIENTS_SAMPLES=OFF \
    -DBUILD_TESTING=OFF -DTensile_LIBRARY_FORMAT=msgpack -DTensile_CPU_THREADS="$JOBS"
}

stage_hipblas() {
  log "hipBLAS"
  fetch hipBLAS
  cm "$SRC/hipBLAS" "$SRC/build/hipblas" "${hip_cmake_args[@]}" \
    -DBUILD_CLIENTS_TESTS=OFF -DBUILD_CLIENTS_BENCHMARKS=OFF -DBUILD_CLIENTS_SAMPLES=OFF \
    -DBUILD_WITH_SOLVER=OFF
}

if [ "${1:-}" = "--list" ]; then printf '%s\n' "${STAGES[@]}"; exit 0; fi
[ "$(uname -m)" = aarch64 ] || echo "WARNING: host is $(uname -m), not aarch64. This script builds native host tools."

START=${1:-deps}
run=0
for s in "${STAGES[@]}"; do
  [ "$s" = "$START" ] && run=1
  [ $run -eq 1 ] && "stage_$s"
done
[ $run -eq 1 ] || { echo "unknown stage '$START'; use --list"; exit 2; }

log "done. Next:"
cat <<MSG
  . $(dirname "$0")/rocm-env.sh
  rocminfo | grep -E 'gfx|Marketing'      # should list gfx906
  $(dirname "$0")/build-llamacpp.sh hip
MSG
