#!/usr/bin/env bash
# check-mi50.sh - diagnose an AMD Instinct MI50 (Vega 20 / gfx906) on an ARM64 host.
# Read-only: it changes nothing. Run as root for full output.
#
#   sudo ./scripts/check-mi50.sh
#
# Each check prints PASS / WARN / FAIL with a reason. Work through the first
# FAIL before anything else: later layers depend on earlier ones.

set -u

pass() { printf '  [PASS] %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; }
hdr()  { printf '\n== %s ==\n' "$*"; }

[ "$(id -u)" -eq 0 ] || echo "Note: not root; some checks (lspci -vv capabilities, dmesg) may be incomplete."

hdr "Host"
echo "  arch:   $(uname -m)"
echo "  kernel: $(uname -r)"
[ -r /proc/device-tree/model ] && echo "  board:  $(tr -d '\0' </proc/device-tree/model)"
if [ -d /sys/firmware/acpi/tables ] && [ -e /sys/firmware/acpi/tables/DSDT ]; then
  echo "  boot:   ACPI"
else
  echo "  boot:   Device Tree"
fi
[ "$(uname -m)" = "aarch64" ] || warn "not an aarch64 host; this script targets ARM64"

hdr "PCIe device"
command -v lspci >/dev/null || { fail "lspci missing: apt install pciutils"; exit 1; }
# 1002:66a0/66a1/66a7 = Vega 20 (MI50/MI60/Radeon VII/Pro VII variants)
GPU=$(lspci -D -d 1002: -nn | grep -iE '\[1002:66a[0-9a-f]\]' | head -n1 | cut -d' ' -f1)
if [ -z "$GPU" ]; then
  fail "no Vega 20 device on the bus. Check the adapter, cable, external PSU (power the GPU first) and 'dmesg | grep -i pcie'."
  lspci -nn
  exit 1
fi
pass "found $(lspci -s "$GPU" -nn | cut -d' ' -f2-)"

LNK=$(lspci -s "$GPU" -vv 2>/dev/null | grep -E 'LnkSta:' | head -n1 | sed 's/^\s*//')
echo "  $LNK"
case "$LNK" in
  *"8GT/s"*) pass "link is Gen3 (RK3588 maximum)";;
  *"2.5GT/s"*|*"5GT/s"*) warn "link trained below Gen3; check cable length/quality or use a redriver adapter";;
esac

hdr "BAR assignment (most common blocker on RK3588)"
BAD=0
i=0
while read -r start end flags; do
  if [ $((flags)) -ne 0 ]; then
    size=$(( end - start + 1 ))
    if [ "$start" = "0x0000000000000000" ]; then
      fail "BAR$i (size $((size/1024/1024)) MiB) is NOT assigned"
      BAD=1
    else
      printf '  BAR%d: %s  size %d MiB\n' "$i" "$start" $((size/1024/1024))
    fi
  fi
  i=$((i+1))
  [ $i -ge 6 ] && break
done < "/sys/bus/pci/devices/$GPU/resource"
lspci -s "$GPU" -vv 2>/dev/null | grep -iE 'Region [0-9]|unassigned|Resizable BAR|BAR [0-9]: current|supported:' | sed 's/^/  /'
if [ "$BAD" -eq 1 ]; then
  echo
  echo "  The RK3588 PCIe 3.0 x4 controller has a 1 GiB 64-bit window. A 32 GiB (or 16 GiB)"
  echo "  VRAM BAR cannot fit. Fixes, in order of preference:"
  echo "   1. If the card shows a 'Physical Resizable BAR' capability, shrink BAR0 to 256 MiB:"
  echo "        cat /sys/bus/pci/devices/$GPU/resource0_resize      # bitmask, bit N = 2^N MiB"
  echo "        echo $GPU > /sys/bus/pci/drivers/amdgpu/unbind   # if bound"
  echo "        echo 8 > /sys/bus/pci/devices/$GPU/resource0_resize # 2^8 MiB = 256 MiB"
  echo "      (needs kernel >= 6.1 and no driver bound; see docs/KERNEL.md)"
  echo "   2. Use a VBIOS variant that exposes a small BAR (see docs/HARDWARE.md)."
fi

hdr "Coherency / IOMMU"
if [ -L "/sys/bus/pci/devices/$GPU/iommu_group" ]; then
  echo "  IOMMU group: $(basename "$(readlink "/sys/bus/pci/devices/$GPU/iommu_group")")"
else
  echo "  no IOMMU group (SMMU disabled or not described)"
fi
echo "  RK3588's PCIe is not DMA-coherent and its SMMU does not report coherency, so"
echo "  VFIO passthrough to a VM is rejected by the kernel. Run the GPU on the host or in an LXC."

hdr "Kernel driver"
DRV=$(basename "$(readlink "/sys/bus/pci/devices/$GPU/driver" 2>/dev/null)" 2>/dev/null)
case "$DRV" in
  amdgpu) pass "amdgpu is bound";;
  vfio-pci) fail "vfio-pci is bound. Remove vfio-pci.ids/blacklist amdgpu (see docs/BLUEPRINT-REVIEW.md)";;
  "") fail "no driver bound";;
  *) warn "bound to $DRV";;
esac
if [ -r /boot/config-"$(uname -r)" ]; then
  for opt in CONFIG_DRM_AMDGPU CONFIG_HSA_AMD CONFIG_DRM_AMDGPU_USERPTR CONFIG_HMM_MIRROR; do
    v=$(grep -E "^$opt=" /boot/config-"$(uname -r)" | cut -d= -f2)
    case "$v" in y|m) pass "$opt=$v";; *) fail "$opt not set (needed for ROCm/KFD)";; esac
  done
else
  warn "/boot/config-$(uname -r) not found; can't check CONFIG_HSA_AMD (KFD), which ROCm needs"
fi
ls /lib/firmware/amdgpu/vega20_* >/dev/null 2>&1 && pass "vega20 firmware present" || fail "vega20 firmware missing: install linux-firmware (amdgpu/vega20_*.bin)"

hdr "dmesg (amdgpu / kfd / pcie errors)"
if dmesg >/dev/null 2>&1; then
  dmesg | grep -iE 'amdgpu|kfd|AER|BAR [0-9]|no space for|failed to assign|SError|Unhandled fault|alignment' | tail -n 40 | sed 's/^/  /'
else
  warn "cannot read dmesg (run as root)"
fi

hdr "User-space nodes"
[ -e /dev/kfd ] && pass "/dev/kfd exists (ROCm can talk to KFD)" || fail "/dev/kfd missing (KFD not loaded; ROCm will not work, Vulkan may)"
ls /dev/dri/renderD* >/dev/null 2>&1 && pass "render node(s): $(ls /dev/dri/renderD* | tr '\n' ' ')" || fail "no /dev/dri/renderD*"
if [ -r /sys/class/kfd/kfd/topology/nodes ]; then
  for n in /sys/class/kfd/kfd/topology/nodes/*; do
    v=$(awk '/gfx_target_version/{print $2}' "$n/properties" 2>/dev/null)
    [ -n "$v" ] && [ "$v" != 0 ] && echo "  KFD node $(basename "$n"): gfx_target_version=$v (90006 = gfx906)"
  done
fi

hdr "User-space tools (optional)"
command -v vulkaninfo >/dev/null && { vulkaninfo --summary 2>/dev/null | grep -E 'deviceName|driverName' | sed 's/^/  /'; } || echo "  vulkaninfo not installed (apt install vulkan-tools mesa-vulkan-drivers)"
for t in /opt/rocm/bin/rocminfo rocminfo; do
  if command -v "$t" >/dev/null; then "$t" 2>&1 | grep -E 'Name:.*gfx|Marketing' | head -n 4 | sed 's/^/  /'; break; fi
done

echo
echo "Done. Paste this output when asking for help."
