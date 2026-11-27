#!/usr/bin/env bash
# Build bitsandbytes' HIP backend for gfx906 without replacing the custom ROCm PyTorch.
set -euo pipefail

ROCM_PATH=${ROCM_PATH:-/opt/rocm}
VENV=${VENV:-$HOME/venv-rocm}
WORK_DIR=${WORK_DIR:-$HOME/rocm633-src}
BNB_REF=${BNB_REF:-f81c74f4496f16fe98a8939ceb50accd77c16e1c}
BNB_DIR=${BNB_DIR:-$WORK_DIR/bitsandbytes}
JOBS=${JOBS:-2}
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

if [ ! -f "$VENV/bin/activate" ]; then
  echo "Missing Python environment: $VENV" >&2
  exit 1
fi
# shellcheck disable=SC1090,SC1091
source "$VENV/bin/activate"
export ROCM_PATH
export HIP_PLATFORM=amd
export PYTORCH_ROCM_ARCH=gfx906
export HSA_USERPTR_FOR_PAGED_MEM=0
export TORCH_BLAS_PREFER_HIPBLASLT=0
export PATH="$ROCM_PATH/bin:$ROCM_PATH/llvm/bin:$PATH"
export LD_LIBRARY_PATH="$ROCM_PATH/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

TORCH_VERSION_BEFORE=$(python3 -c 'import torch; print(torch.__version__)')
python3 - <<'PY'
import torch
if not torch.version.hip:
    raise SystemExit("Expected the custom ROCm-enabled PyTorch wheel in this venv")
if torch.version.hip.split(".")[:2] != ["6", "3"]:
    raise SystemExit(f"Expected ROCm 6.3.x, got HIP runtime {torch.version.hip}")
print(f"PyTorch {torch.__version__}; HIP runtime {torch.version.hip}")
PY

mkdir -p "$WORK_DIR"
if [ ! -d "$BNB_DIR/.git" ]; then
  git clone --filter=blob:none https://github.com/bitsandbytes-foundation/bitsandbytes.git "$BNB_DIR"
  git -C "$BNB_DIR" fetch --depth 1 origin "$BNB_REF"
  git -C "$BNB_DIR" checkout --detach "$BNB_REF"
else
  current=$(git -C "$BNB_DIR" rev-parse HEAD)
  if [ "$current" != "$BNB_REF" ]; then
    echo "ERROR: $BNB_DIR is at $current, expected pinned bitsandbytes commit $BNB_REF." >&2
    echo "Remove the checkout or set BNB_REF to the intended commit." >&2
    exit 1
  fi
fi
printf 'bitsandbytes source: %s\n' "$(git -C "$BNB_DIR" rev-parse HEAD)"

# Current bitsandbytes CMake supports BNB_ROCM_ARCH natively. Its HIP >=6.1
# branch nevertheless links hipBLASLt unconditionally; apply a one-line patch
# to make that optional on gfx906, where this stack intentionally omits it.
# This pinned upstream revision is checked before the patch is applied.
PATCH_FILE="$SCRIPT_DIR/../patches/0001-bitsandbytes-disable-hipblaslt-gfx906.patch"
if ! grep -q 'HIP_VERSION VERSION_LESS "6.1" OR BNB_DISABLE_HIPBLASLT' "$BNB_DIR/CMakeLists.txt"; then
  git -C "$BNB_DIR" apply --check "$PATCH_FILE"
  git -C "$BNB_DIR" apply "$PATCH_FILE"
fi
if ! grep -q 'HIP_VERSION VERSION_LESS "6.1" OR BNB_DISABLE_HIPBLASLT' "$BNB_DIR/CMakeLists.txt"; then
  echo "ERROR: bitsandbytes hipBLASLt-disable patch did not apply" >&2
  exit 1
fi

cmake -S "$BNB_DIR" -B "$BNB_DIR/build-gfx906" -G Ninja \
  -DCOMPUTE_BACKEND=hip \
  -DBNB_ROCM_ARCH=gfx906 \
  -DBNB_DISABLE_HIPBLASLT=ON \
  -DCMAKE_HIP_ARCHITECTURES=gfx906 \
  -DCMAKE_HIP_COMPILER="$ROCM_PATH/llvm/bin/clang++" \
  -DCMAKE_CXX_COMPILER="$ROCM_PATH/llvm/bin/clang++" \
  -DCMAKE_PREFIX_PATH="$ROCM_PATH" \
  -DCMAKE_BUILD_TYPE=Release
cmake --build "$BNB_DIR/build-gfx906" --parallel "$JOBS"

# Install bitsandbytes itself without dependency resolution. For the pinned HF
# stack, allow pip to resolve every non-Torch transitive dependency; the already
# installed custom torch wheel satisfies the declared torch>= constraints.
cd "$BNB_DIR"
pip install --no-build-isolation --no-deps .
pip install --upgrade-strategy only-if-needed -r "$SCRIPT_DIR/../requirements-qlora.txt"
TORCH_VERSION_AFTER=$(python3 -c 'import torch; print(torch.__version__)')
if [ "$TORCH_VERSION_AFTER" != "$TORCH_VERSION_BEFORE" ]; then
  echo "ERROR: Python dependency installation changed torch from $TORCH_VERSION_BEFORE to $TORCH_VERSION_AFTER" >&2
  exit 1
fi
pip check

# This import/shared-library check works without a visible MI50. It confirms
# that the HIP build artifact is present and its dynamic dependencies resolve.
python3 - <<'PY'
import ctypes
import torch
import bitsandbytes as bnb
from bitsandbytes.consts import DYNAMIC_LIBRARY_SUFFIX, PACKAGE_DIR

if not torch.version.hip or torch.version.hip.split(".")[:2] != ["6", "3"]:
    raise SystemExit(f"Expected a ROCm 6.3 PyTorch build, got {torch.version.hip!r}")
native_library = PACKAGE_DIR / f"libbitsandbytes_rocm63{DYNAMIC_LIBRARY_SUFFIX}"
if not native_library.is_file():
    raise SystemExit(f"Missing gfx906 bitsandbytes ROCm library: {native_library}")
ctypes.CDLL(str(native_library))
print(f"bitsandbytes import and shared-library load PASSED: {native_library}")
PY

if [ "${SKIP_BNB_GPU_SMOKE:-0}" != 1 ]; then
  python3 -m bitsandbytes
  python3 - <<'PY'
import torch
import bitsandbytes as bnb
assert torch.cuda.is_available(), "HIP device not detected by PyTorch"
print("Device:", torch.cuda.get_device_name(0))
layer = bnb.nn.Linear4bit(
    1024, 1024, bias=False, compute_dtype=torch.float16, quant_type="nf4"
).cuda()
x = torch.randn(2, 16, 1024, device="cuda", dtype=torch.float16, requires_grad=True)
loss = layer(x).sum()
loss.backward()
assert x.grad is not None and not torch.isnan(x.grad).any(), "NF4 gradient check failed"
print("bitsandbytes 4-bit NF4 forward/backward PASSED on gfx906")
PY
else
  echo "SKIP_BNB_GPU_SMOKE=1: skipped GPU-dependent bitsandbytes diagnostics and NF4 test"
fi
