#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1090,SC1091
source "${VENV:-$HOME/venv-rocm}/bin/activate"
export ROCM_PATH=${ROCM_PATH:-/opt/rocm}
export LD_LIBRARY_PATH="$ROCM_PATH/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export HIP_PLATFORM=amd
export HSA_USERPTR_FOR_PAGED_MEM=0
export PYTORCH_ROCM_ARCH=gfx906

# Optional 165 W cap. Root or passwordless sudo is required to change sysfs.
POWER_CAP_UW=${POWER_CAP_UW:-165000000}
for cap in /sys/class/drm/card*/device/hwmon/hwmon*/power1_cap; do
  [ -e "$cap" ] || continue
  if [ -w "$cap" ]; then
    printf '%s\n' "$POWER_CAP_UW" > "$cap"
  elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    printf '%s\n' "$POWER_CAP_UW" | sudo tee "$cap" >/dev/null
  else
    echo "WARN: cannot write $cap; leaving the power limit unchanged" >&2
  fi
done

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
python3 "$SCRIPT_DIR/../examples/train_qwen14b_qlora.py"
