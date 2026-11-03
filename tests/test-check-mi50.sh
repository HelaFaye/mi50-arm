#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2129,SC2001
# Exercises scripts/check-mi50.sh against fake sysfs/devicetree trees and mock
# lspci/dmesg, covering the main failure modes. No hardware needed.
#   ./tests/test-check-mi50.sh
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
CHECK=$HERE/../scripts/check-mi50.sh
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
GPU=0004:41:00.0
T_PASS=0; T_FAIL=0

# --- mocks -------------------------------------------------------------------
mkdir -p "$WORK/bin"
cat > "$WORK/bin/lspci" <<'M'
#!/usr/bin/env bash
[ -f "$MOCK/nogpu" ] && { [[ " $* " == *" -D "* ]] && echo "0000:00:00.0 PCI bridge [0604]: Rockchip RK3588 [1d87:3588]"; exit 0; }
case " $* " in
  *" -vv "*) cat "$MOCK/lspci-vv";;
  *" -D "*)  echo "$GPU Display controller [0380]: Advanced Micro Devices, Inc. [AMD/ATI] Vega 20 [Radeon Pro VII/Radeon Instinct MI50] [1002:66a1] (rev 01)";;
  *" -s "*)  echo "$GPU Display controller [0380]: Advanced Micro Devices, Inc. [AMD/ATI] Vega 20 [Radeon Pro VII/Radeon Instinct MI50] [1002:66a1] (rev 01)";;
esac
M
printf '#!/bin/sh\ncat "$MOCK/dmesg"\n' > "$WORK/bin/dmesg"
chmod +x "$WORK/bin/"*

# --- fake root builder -------------------------------------------------------
# mkroot <dir> [bigbar] [vfio] [coherent] [ringfail]
mkroot() {
  local r=$1; shift; local opts=" $* "
  local dt=$r/sys/firmware/devicetree/base
  local plat=$r/sys/devices/platform/a40000000.pcie
  local dev=$plat/pci0004:40/0004:40:00.0/$GPU
  mkdir -p "$dt/pcie@fe150000" "$dev" "$r/sys/bus/pci/devices" "$r/proc/device-tree" \
           "$r/boot" "$r/lib/firmware/amdgpu" "$r/dev/dri" "$r/sys/class/kfd/kfd/topology/nodes/1" \
           "$r/sys/bus/pci/drivers/amdgpu" "$r/sys/bus/pci/drivers/vfio-pci" "$r/mock"
  printf 'Xunlong Orange Pi 5 Plus\0' > "$r/proc/device-tree/model"
  echo rockchip,rk3588-pcie > "$dt/pcie@fe150000/compatible"
  [[ $opts == *" coherent "* ]] && : > "$dt/pcie@fe150000/dma-coherent"
  ln -s "$dt/pcie@fe150000" "$plat/of_node"
  ln -s "$dev" "$r/sys/bus/pci/devices/$GPU"
  if [[ $opts == *" bigbar "* ]]; then
    printf '0x0000000000000000 0x00000007ffffffff 0x000000000014220c\n' > "$dev/resource"
    echo 0000000000003f00 > "$dev/resource0_resize"
  else
    printf '0x0000000900000000 0x000000090fffffff 0x000000000014220c\n' > "$dev/resource"
  fi
  printf '0x0000000000000000 0x0000000000000000 0x0000000000000000\n' >> "$dev/resource"
  printf '0x0000000910000000 0x00000009101fffff 0x000000000014220c\n' >> "$dev/resource"
  printf '0x0000000000000000 0x0000000000000000 0x0000000000000000\n' >> "$dev/resource"
  printf '0x0000000000000000 0x0000000000000000 0x0000000000000000\n' >> "$dev/resource"
  printf '0x00000000f0200000 0x00000000f027ffff 0x0000000000040200\n' >> "$dev/resource"
  for _ in 1 2 3 4 5 6 7; do printf '0x0000000000000000 0x0000000000000000 0x0000000000000000\n' >> "$dev/resource"; done
  if [[ $opts == *" vfio "* ]]; then ln -s "$r/sys/bus/pci/drivers/vfio-pci" "$dev/driver"
  else
    ln -s "$r/sys/bus/pci/drivers/amdgpu" "$dev/driver"
    : > "$r/dev/kfd"; : > "$r/dev/dri/renderD128"
    printf 'cpu_cores_count 0\ngfx_target_version 90006\n' > "$r/sys/class/kfd/kfd/topology/nodes/1/properties"
  fi
  printf 'CONFIG_DRM_AMDGPU=m\nCONFIG_HSA_AMD=y\nCONFIG_DRM_AMDGPU_USERPTR=y\n' > "$r/boot/config-6.12.0-test"
  : > "$r/lib/firmware/amdgpu/vega20_gpu_info.bin"
  echo "		LnkSta:	Speed 8GT/s, Width x4 (downgraded)" > "$r/mock/lspci-vv"
  if [[ $opts == *" ringfail "* ]]; then
    echo "[    5.1] amdgpu 0004:41:00.0: [drm:amdgpu_ring_test_helper [amdgpu]] *ERROR* ring gfx test failed (-110)" > "$r/mock/dmesg"
  else
    echo "[    5.1] [drm] Initialized amdgpu 3.59.0 for 0004:41:00.0" > "$r/mock/dmesg"
  fi
}

# expect <name> <expected-exit> <grep-pattern...>  (reads $OUT, $RC)
run() {
  local name=$1 want=$2; shift 2
  local ok=1
  [ "$RC" -eq "$want" ] || { echo "    exit $RC, wanted $want"; ok=0; }
  for pat in "$@"; do
    grep -qE -- "$pat" <<<"$OUT" || { echo "    missing: $pat"; ok=0; }
  done
  if [ $ok -eq 1 ]; then echo "ok   - $name"; T_PASS=$((T_PASS+1))
  else echo "FAIL - $name"; echo "$OUT" | sed 's/^/      | /'; T_FAIL=$((T_FAIL+1)); fi
}
check() { # check <root> -> sets OUT, RC
  OUT=$(env -u HSA_USERPTR_FOR_PAGED_MEM PATH="$WORK/bin:/usr/bin:/bin" MOCK="$1/mock" GPU=$GPU \
        CHECK_ROOT="$1" CHECK_ARCH=aarch64 CHECK_KREL=6.12.0-test bash "$CHECK" 2>&1); RC=$?
}

mkroot "$WORK/healthy"; check "$WORK/healthy"
run "healthy non-coherent RK3588" 0 '\[PASS\] found .*1002:66a1' 'PASS\] link is Gen3' \
    'BAR0: 0x0000000900000000  256 MiB' 'BAR5: .*512 KiB' 'NOT DMA-coherent' 'PASS\] amdgpu is bound' \
    'CONFIG_HSA_AMD=y' 'gfx_target_version=90006' 'HSA_USERPTR_FOR_PAGED_MEM=0' 'Done: 0 failure'

mkroot "$WORK/bigbar" bigbar; check "$WORK/bigbar"
run "32 GiB BAR0 unassigned" 1 'FAIL\] BAR0 \(32 GiB\) is NOT assigned' 'resource0_resize exists' 'echo 8 >'

mkroot "$WORK/vfio" vfio; check "$WORK/vfio"
run "vfio-pci bound (blueprint config)" 1 'FAIL\] vfio-pci is bound' 'FAIL\] /dev/kfd missing'

mkroot "$WORK/coh" coherent; check "$WORK/coh"
run "coherent host bridge" 0 'PASS\] PCIe host bridge is DMA-coherent'

mkroot "$WORK/ring" ringfail; check "$WORK/ring"
run "ring test failure in dmesg" 1 'FAIL\] ring/IB test failures'

mkroot "$WORK/nogpu"; : > "$WORK/nogpu/mock/nogpu"; check "$WORK/nogpu"
run "no GPU on bus" 2 'FAIL\] no Vega 20 device'

echo; echo "$T_PASS passed, $T_FAIL failed"
[ "$T_FAIL" -eq 0 ]
