#!/usr/bin/env bash
set -euo pipefail

export ROCM_PATH=${ROCM_PATH:-/opt/rocm}
export PATH="$ROCM_PATH/bin:$ROCM_PATH/llvm/bin:$PATH"
export LD_LIBRARY_PATH="$ROCM_PATH/lib:${LD_LIBRARY_PATH:-}"
export HIP_PLATFORM=amd
export AMDGPU_TARGETS="gfx906"
export PYTORCH_ROCM_ARCH="gfx906"
# Required on the non-coherent RK3588 PCIe host; inherited by every ROCm test/build.
export HSA_USERPTR_FOR_PAGED_MEM=0
# PyTorch 2.5.1's supported Python range does not include Python 3.13/3.14.
PYTHON_BIN=${PYTHON_BIN:-python3}
"$PYTHON_BIN" - <<'PYVER'
import sys
if not ((3, 9) <= sys.version_info[:2] < (3, 13)):
    raise SystemExit(
        f"PyTorch 2.5.1 build requires Python 3.9-3.12; got {sys.version.split()[0]}. "
        "Set PYTHON_BIN to a Python 3.11/3.12 interpreter."
    )
PYVER
# Cap parallel link jobs to reduce peak RAM use on the 16 GB RK3588 host.
export MAX_JOBS=${MAX_JOBS:-4}

WORK_DIR="${WORK_DIR:-$HOME/rocm633-src}"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

sudo apt-get update
sudo apt-get install -y \
  git cmake ninja-build build-essential gfortran pkg-config libgl-dev \
  libopenblas-dev libmsgpack-dev libboost-program-options-dev \
  libboost-filesystem-dev nlohmann-json3-dev libfmt-dev \
  libsqlite3-dev libbz2-dev libssl-dev libnuma-dev libelf-dev \
  python3-dev python3-pip python3-venv python3-yaml python3-msgpack python3-joblib

"$PYTHON_BIN" -m venv "$HOME/venv-rocm"
# shellcheck disable=SC1090,SC1091
source "$HOME/venv-rocm/bin/activate"
pip install --upgrade pip wheel setuptools packaging ninja cmake pyyaml msgpack joblib numpy

clone_rocm() {
  local repo="$1"
  if [ ! -d "$repo/.git" ]; then
    git clone --branch rocm-6.3.3 --depth 1 "https://github.com/ROCm/${repo}.git" "$repo"
  else
    local current
    current=$(git -C "$repo" describe --tags --exact-match 2>/dev/null || true)
    if [ "$current" != "rocm-6.3.3" ]; then
      echo "ERROR: $repo already exists but is not checked out at rocm-6.3.3 ($current). Remove it or pin it manually." >&2
      return 1
    fi
  fi
}

# 1. Header-only and RNG primitives.
for repo in rocPRIM hipCUB rocRAND hipRAND; do
  clone_rocm "$repo"
  cmake -S "$repo" -B "build-$repo" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_COMPILER="$ROCM_PATH/llvm/bin/clang++" \
    -DCMAKE_PREFIX_PATH="$ROCM_PATH" \
    -DCMAKE_INSTALL_PREFIX="$ROCM_PATH" \
    -DAMDGPU_TARGETS="gfx906" \
    -DBUILD_TEST=OFF -DBUILD_BENCHMARK=OFF
  cmake --build "build-$repo" -j"$MAX_JOBS"
  sudo cmake --install "build-$repo"
done

# rocThrust is a required PyTorch ROCm dependency (headers only, backed by rocPRIM).
clone_rocm rocThrust
cmake -S rocThrust -B build-rocThrust -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CXX_COMPILER="$ROCM_PATH/llvm/bin/clang++" \
  -DCMAKE_PREFIX_PATH="$ROCM_PATH" \
  -DCMAKE_INSTALL_PREFIX="$ROCM_PATH" \
  -DTHRUST_HOST_SYSTEM=CPP \
  -DBUILD_TEST=OFF -DBUILD_BENCHMARKS=OFF -DBUILD_EXAMPLES=OFF
cmake --build build-rocThrust -j"$MAX_JOBS"
sudo cmake --install build-rocThrust

# half/half.hpp and hipBLAS-common are prerequisites for MIOpen/hipBLASLt.
clone_rocm half
cmake -S half -B build-half -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="$ROCM_PATH" \
  -DCMAKE_INSTALL_PREFIX="$ROCM_PATH"
cmake --build build-half -j"$MAX_JOBS"
sudo cmake --install build-half

clone_rocm hipBLAS-common
cmake -S hipBLAS-common -B build-hipBLAS-common -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CXX_COMPILER="$ROCM_PATH/llvm/bin/clang++" \
  -DCMAKE_PREFIX_PATH="$ROCM_PATH" \
  -DCMAKE_INSTALL_PREFIX="$ROCM_PATH"
cmake --build build-hipBLAS-common -j"$MAX_JOBS"
sudo cmake --install build-hipBLAS-common

# 2. rocBLAS 6.3.3 + Tensile gfx906 kernels.
clone_rocm rocBLAS
cmake -S rocBLAS -B build-rocBLAS -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CXX_COMPILER="$ROCM_PATH/llvm/bin/clang++" \
  -DCMAKE_C_COMPILER="$ROCM_PATH/llvm/bin/clang" \
  -DCMAKE_PREFIX_PATH="$ROCM_PATH" \
  -DCMAKE_INSTALL_PREFIX="$ROCM_PATH" \
  -DAMDGPU_TARGETS="gfx906" \
  -DGPU_TARGETS="gfx906" \
  -DTensile_ARCHITECTURE="gfx906" \
  -DTensile_LOGIC="asm_full" \
  -DTensile_SEPARATE_ARCHITECTURES=ON \
  -DTensile_LAZY_LIBRARY_LOADING=ON \
  -DTensile_CPU_THREADS="$MAX_JOBS" \
  -DRUN_HEADER_TESTING=OFF \
  -DBUILD_CLIENTS_SAMPLES=OFF \
  -DBUILD_CLIENTS_TESTS=OFF \
  -DBUILD_CLIENTS_BENCHMARKS=ON
cmake --build build-rocBLAS -j"$MAX_JOBS"
sudo cmake --install build-rocBLAS

# This requires an MI50 at runtime; set SKIP_ROCBLAS_GPU_SMOKE=1 for build-only hosts.
if [ "${SKIP_ROCBLAS_GPU_SMOKE:-0}" != 1 ]; then
  "$ROCM_PATH/bin/rocblas-bench" -f gemm_ex -r h -m 2048 -n 2048 -k 2048
fi

# 3. BLAS, sparse, FFT, and solver layers.
for repo in hipBLAS rocSPARSE hipSPARSE rocFFT hipFFT rocSOLVER; do
  clone_rocm "$repo"
  cmake -S "$repo" -B "build-$repo" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_COMPILER="$ROCM_PATH/llvm/bin/clang++" \
    -DCMAKE_C_COMPILER="$ROCM_PATH/llvm/bin/clang" \
    -DCMAKE_PREFIX_PATH="$ROCM_PATH" \
    -DCMAKE_INSTALL_PREFIX="$ROCM_PATH" \
    -DAMDGPU_TARGETS="gfx906" \
    -DGPU_TARGETS="gfx906" \
    -DBUILD_CLIENTS_SAMPLES=OFF \
    -DBUILD_CLIENTS_TESTS=OFF \
    -DBUILD_CLIENTS_BENCHMARKS=OFF
  cmake --build "build-$repo" -j"$MAX_JOBS"
  sudo cmake --install "build-$repo"
done

# PyTorch v2.5.1 requires hipSOLVER in addition to rocSOLVER.
clone_rocm hipSOLVER
cmake -S hipSOLVER -B build-hipSOLVER -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CXX_COMPILER="$ROCM_PATH/llvm/bin/clang++" \
  -DCMAKE_C_COMPILER="$ROCM_PATH/llvm/bin/clang" \
  -DCMAKE_PREFIX_PATH="$ROCM_PATH" \
  -DCMAKE_INSTALL_PREFIX="$ROCM_PATH" \
  -DBUILD_CLIENTS_SAMPLES=OFF \
  -DBUILD_CLIENTS_TESTS=OFF \
  -DBUILD_CLIENTS_BENCHMARKS=OFF
cmake --build build-hipSOLVER -j"$MAX_JOBS"
sudo cmake --install build-hipSOLVER

# PyTorch 2.5.1's LoadHIP.cmake requires the hipBLASLt CMake target even on
# gfx906. Build the host library and headers only: no Tensile/device kernels.
clone_rocm hipBLASLt
cmake -S hipBLASLt -B build-hipBLASLt -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CXX_COMPILER="$ROCM_PATH/llvm/bin/clang++" \
  -DCMAKE_PREFIX_PATH="$ROCM_PATH" \
  -DCMAKE_INSTALL_PREFIX="$ROCM_PATH" \
  -DAMDGPU_TARGETS="gfx906" \
  -DBUILD_WITH_TENSILE=OFF \
  -DBUILD_CLIENTS_SAMPLES=OFF \
  -DBUILD_CLIENTS_TESTS=OFF \
  -DBUILD_CLIENTS_BENCHMARKS=OFF
cmake --build build-hipBLASLt -j"$MAX_JOBS"
sudo cmake --install build-hipBLASLt

# 4. MIOpen. Composable Kernel / MLIR, hipBLASLt and AI tuning paths are
# disabled for gfx906; the latter avoids optional frugally-deep/Eigen deps.
clone_rocm MIOpen
cmake -S MIOpen -B build-MIOpen -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CXX_COMPILER="$ROCM_PATH/llvm/bin/clang++" \
  -DCMAKE_C_COMPILER="$ROCM_PATH/llvm/bin/clang" \
  -DCMAKE_PREFIX_PATH="$ROCM_PATH" \
  -DCMAKE_INSTALL_PREFIX="$ROCM_PATH" \
  -DBoost_USE_STATIC_LIBS=OFF \
  -DAMDGPU_TARGETS="gfx906" \
  -DMIOPEN_BACKEND=HIP \
  -DMIOPEN_USE_COMPOSABLEKERNEL=OFF \
  -DMIOPEN_USE_MLIR=OFF \
  -DMIOPEN_USE_HIPBLASLT=OFF \
  -DMIOPEN_ENABLE_AI_IMMED_MODE_FALLBACK=OFF \
  -DMIOPEN_ENABLE_AI_KERNEL_TUNING=OFF \
  -DMIOPEN_USE_ROCTRACER=OFF \
  -DBUILD_TESTING=OFF
cmake --build build-MIOpen -j"$MAX_JOBS"
sudo cmake --install build-MIOpen

sudo ldconfig

# 5. PyTorch 2.5.1. This full source build is intentionally not part of CI.
if [ ! -d pytorch/.git ]; then
  git clone --branch v2.5.1 --recursive https://github.com/pytorch/pytorch.git pytorch
fi
cd pytorch
git submodule sync
git submodule update --init --recursive
pip install -r requirements.txt
python3 tools/amd_build/build_amd.py

export USE_ROCM=1
export USE_CUDA=0
export USE_NCCL=0
export USE_RCCL=0
export USE_MAGMA=0
export USE_FLASH_ATTENTION=0
export USE_MEM_EFF_ATTENTION=0
export USE_KINETO=0
export BUILD_TEST=0

python3 setup.py bdist_wheel
pip install dist/torch-2.5.1*.whl

# GPU smoke test: prefer rocBLAS because hipBLASLt above was installed host-only.
export TORCH_BLAS_PREFER_HIPBLASLT=0
if [ "${SKIP_PYTORCH_GPU_SMOKE:-0}" != 1 ]; then
python3 -c '
import torch
assert torch.cuda.is_available(), "HIP device not detected"
print("Device:", torch.cuda.get_device_name(0))
a = torch.randn(1024, 1024, device="cuda", dtype=torch.float16, requires_grad=True)
loss = (a @ a.T).sum()
loss.backward()
assert not torch.isnan(a.grad).any(), "NaN in gradient"
print("PyTorch 2.5.1 ROCm gfx906 autograd check PASSED")
'
else
  echo "SKIP_PYTORCH_GPU_SMOKE=1: skipped GPU-dependent PyTorch smoke test"
fi
