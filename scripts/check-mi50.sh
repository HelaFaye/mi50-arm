#!/usr/bin/env bash
# check-mi50.sh - diagnose an AMD Instinct MI50 (Vega 20 / gfx906) on an ARM64 host.
# Read-only: it changes nothing. Run as root for full output.
#
#   sudo ./scripts/check-mi50.sh
#
# Each check prints PASS / WARN / FAIL with a reason. Work through the first
# FAIL before anything else: later layers depend on earlier ones.
#
# Testing: CHECK_ROOT=/some/fake/root makes every /sys, /proc, /dev, /boot and
# /lib/firmware path relative to that directory (see tests/). lspci, dmesg,
# vulkaninfo and rocminfo are looked up on PATH, so they can be mocked too.
# Exit status: 0 = no FAIL, 1 = at least one FAIL, 2 = no GPU found.

set -u

R=${CHECK_ROOT:-}
FAILS=0
pass() { printf '  [PASS] %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; FAILS=$((FAILS+1)); }
hdr()  { printf '\n== %s ==\n' "$*"; }
human() { # bytes -> "N GiB/MiB/KiB"
  local b=$1
  if   [ "$b" -ge $((1<<30)) ]; then echo "$((b>>30)) GiB"
  elif [ "$b" -ge $((1<<20)) ]; then echo "$((b>>20)) MiB"
  else echo "$((b>>10)) KiB"; fi
}

[ -n "$R" ] || [ "$(id -u)" -eq 0 ] || echo "Note: not root; lspci capabilities and dmesg may be incomplete."

hdr "Host"
ARCH=${CHECK_ARCH:-$(uname -m)}
echo "  arch:   $ARCH"
echo "  kernel: ${CHECK_KREL:-$(uname -r)}"
KREL=${CHECK_KREL:-$(uname -r)}
MODEL=""
[ -r "$R/proc/device-tree/model" ] && MODEL=$(tr -d '\0' <"$R/proc/device-tree/model")
[ -n "$MODEL" ] && echo "  board:  $MODEL"
if [ -e "$R/sys/firmware/acpi/tables/DSDT" ]; then BOOT=ACPI; else BOOT=DT; fi
echo "  boot:   $BOOT"
[ "$ARCH" = aarch64 ] || warn "not an aarch64 host; this script targets ARM64"

hdr "PCIe device"
if ! command -v lspci >/dev/null; then fail "lspci missing: apt install pciutils"; exit 1; fi
# Vega 20: 66a0/66a1 (MI50/MI60/Pro VII), 66a2, 66a3, 66a7, 66af (Radeon VII)
GPU=$(lspci -D -nn -d 1002: | grep -iE '\[1002:66a[0-9a-f]\]' | head -n1 | cut -d' ' -f1)
if [ -z "$GPU" ]; then
  fail "no Vega 20 device on the bus. Check adapter, cable, and that the GPU PSU was on BEFORE the board booted."
  echo "  dmesg hints:"; dmesg 2>/dev/null | grep -iE 'pcie|link' | tail -n 10 | sed 's/^/    /'
  exit 2
fi
DEV=$R/sys/bus/pci/devices/$GPU
pass "found $(lspci -s "$GPU" -nn | cut -d' ' -f2-)"

LNK=$(lspci -s "$GPU" -vv 2>/dev/null | grep -E 'LnkSta:' | head -n1 | sed 's/^[[:space:]]*//')
[ -n "$LNK" ] && echo "  $LNK"
case "$LNK" in
  *"8GT/s"*) pass "link is Gen3 (RK3588 maximum)";;
  *"16GT/s"*) pass "link is Gen4";;
  *"2.5GT/s"*|*"5GT/s"*) warn "link trained below Gen3; check cable length/quality, reseat, or try a redriver adapter";;
  "") warn "could not read link status (run as root)";;
esac

hdr "BAR assignment (most common blocker on RK3588)"
BAD=0; i=0
while read -r start end flags && [ $i -lt 6 ]; do
  if [ $((flags)) -ne 0 ]; then
    size=$(( end - start + 1 ))
    if [ $((start)) -eq 0 ]; then
      fail "BAR$i ($(human $size)) is NOT assigned"
      BAD=1
    else
      echo "  BAR$i: $start  $(human $size)"
    fi
  fi
  i=$((i+1))
done < "$DEV/resource"
lspci -s "$GPU" -vv 2>/dev/null | grep -iE 'Region [0-9]|Resizable BAR|BAR [0-9]: current|supported:' | sed 's/^/  /'
if [ "$BAD" -eq 1 ]; then
  cat <<MSG

  The RK3588 PCIe 3.0 x4 controller has a 1 GiB 64-bit window; a 16/32 GiB VRAM
  BAR cannot fit. amdgpu does not shrink a BAR the VBIOS made large. Fixes:
   1. Resizable BAR (needs kernel >= 6.1, no driver bound):
        cat $DEV/resource0_resize           # bitmask; bit N = 2^N MiB supported
        echo $GPU > /sys/bus/pci/drivers/amdgpu/unbind   # only if bound
        echo 8 > $DEV/resource0_resize      # 256 MiB
        echo $GPU > /sys/bus/pci/drivers/amdgpu/bind
   2. A VBIOS that exposes a small BAR (docs/HARDWARE.md).
MSG
  if [ -e "$DEV/resource0_resize" ]; then
    pass "resource0_resize exists: supported-size bitmask $(cat "$DEV/resource0_resize")"
  else
    warn "no resource0_resize: card shows no Resizable BAR capability, or kernel < 6.1"
  fi
fi

hdr "VBIOS"
# Known MI50 32 GB VBIOSes (community VBIOS comparison, see docs/HARDWARE.md#vbios).
# vbios_version only exists once amdgpu has bound to the card.
VB=""
[ -r "$DEV/vbios_version" ] && VB=$(cat "$DEV/vbios_version")
REBAR=$(lspci -s "$GPU" -vv 2>/dev/null | grep -c 'Resizable BAR')
case "$VB" in
  113-D1631711-100)
    if [ "$BAD" -eq 1 ]; then
      fail "VBIOS $VB has no Resizable BAR and a 16 GiB BAR0: it can't fit this window. A VBIOS with Resizable BAR is needed (113-D1631700-111 or 113-D1640200-043; docs/HARDWARE.md#vbios)"
    else
      warn "VBIOS $VB: no Resizable BAR, and Vulkan sees only 16 GiB of VRAM with it (HIP sees all 32)"
    fi;;
  113-D1631700-111|113-D1640200-043|113-D163A1XT-045)
    pass "VBIOS $VB supports Resizable BAR: BAR0 can be shrunk to 256 MiB";;
  "")
    if [ "$REBAR" -gt 0 ]; then
      echo "  VBIOS version unreadable (amdgpu not bound), but the card has a Resizable BAR capability"
    else
      echo "  VBIOS version unreadable (amdgpu not bound). Without Resizable BAR the BAR can't be shrunk; check the VBIOS with amdvbflash -i on an x86 machine"
    fi;;
  *)
    echo "  VBIOS $VB: not in the table in docs/HARDWARE.md#vbios";;
esac

hdr "Coherency / IOMMU"
if [ -L "$DEV/iommu_group" ]; then
  echo "  IOMMU group: $(basename "$(readlink "$DEV/iommu_group")")"
else
  echo "  no IOMMU group (SMMU disabled, not described, or iommu.passthrough)"
fi
COH=unknown
if [ "$BOOT" = DT ]; then
  # Like the kernel's of_dma_is_coherent(): find the nearest sysfs ancestor with a
  # DT node, then look for "dma-coherent" on that node or any DT parent.
  p=$(readlink -f "$DEV" 2>/dev/null)
  while [ -n "$p" ] && [ "$p" != / ] && [ "$p" != "$R" ] && [ ! -e "$p/of_node" ]; do
    p=$(dirname "$p")
  done
  if [ -e "$p/of_node" ]; then
    COH=no
    n=$(readlink -f "$p/of_node")
    while [ -n "$n" ] && [ "$n" != / ]; do
      [ -e "$n/dma-coherent" ] && { COH=yes; break; }
      case "$n" in */devicetree/base) break;; esac
      n=$(dirname "$n")
    done
  fi
fi
case "$COH" in
  no)  warn "PCIe host bridge is NOT DMA-coherent: needs patches/0001 (docs/KERNEL.md); VFIO passthrough impossible";;
  yes) pass "PCIe host bridge is DMA-coherent";;
  *)   echo "  coherency: could not determine (ACPI boot or no DT node). RK3588 is non-coherent.";;
esac

hdr "Kernel driver"
DRV=""
[ -L "$DEV/driver" ] && DRV=$(basename "$(readlink "$DEV/driver")")
case "$DRV" in
  amdgpu)   pass "amdgpu is bound";;
  vfio-pci) fail "vfio-pci is bound. Remove vfio-pci.ids= and 'blacklist amdgpu' (docs/BLUEPRINT-REVIEW.md)";;
  "")       fail "no driver bound (see dmesg section below)";;
  *)        warn "bound to $DRV";;
esac
CFG=""
if [ -r "$R/boot/config-$KREL" ]; then CFG=$(cat "$R/boot/config-$KREL")
elif [ -r "$R/proc/config.gz" ]; then CFG=$(zcat "$R/proc/config.gz")
fi
if [ -n "$CFG" ]; then
  for opt in CONFIG_DRM_AMDGPU CONFIG_HSA_AMD CONFIG_DRM_AMDGPU_USERPTR; do
    v=$(printf '%s\n' "$CFG" | grep -E "^$opt=" | cut -d= -f2)
    case "$v" in y|m) pass "$opt=$v";; *) fail "$opt not set (required; docs/KERNEL.md)";; esac
  done
  v=$(printf '%s\n' "$CFG" | grep -E "^CONFIG_HSA_AMD_SVM=" | cut -d= -f2)
  if [ "$v" = y ]; then pass "CONFIG_HSA_AMD_SVM=y"; else warn "CONFIG_HSA_AMD_SVM not set (optional; needs CONFIG_DEVICE_PRIVATE)"; fi
else
  warn "no /boot/config-$KREL or /proc/config.gz; can't check CONFIG_HSA_AMD (KFD), which ROCm needs"
fi
if compgen -G "$R/lib/firmware/amdgpu/vega20_*" >/dev/null; then
  pass "vega20 firmware present"
else
  fail "vega20 firmware missing: install firmware-amd-graphics (Debian) / linux-firmware (Ubuntu)"
fi

hdr "dmesg (amdgpu / kfd / pcie errors)"
if dmesg >/dev/null 2>&1; then
  dmesg | grep -iE 'amdgpu|kfd|AER|BAR [0-9]|no space for|failed to assign|SError|Unhandled fault|alignment|arm-smmu' \
    | tail -n 40 | sed 's/^/  /'
  if dmesg | grep -qiE 'ring .* test failed|IB test failed|ring .* timeout'; then
    fail "ring/IB test failures: classic non-coherency symptom (docs/KERNEL.md)"
  fi
else
  warn "cannot read dmesg (run as root)"
fi

hdr "User-space nodes"
if [ -e "$R/dev/kfd" ]; then pass "/dev/kfd exists"; else fail "/dev/kfd missing (KFD not loaded: ROCm won't work; Vulkan may)"; fi
if compgen -G "$R/dev/dri/renderD*" >/dev/null; then
  pass "render node(s): $(cd "$R/dev/dri" && echo renderD*)"
else
  fail "no /dev/dri/renderD*"
fi
for n in "$R"/sys/class/kfd/kfd/topology/nodes/*; do
  [ -r "$n/properties" ] || continue
  v=$(awk '/^gfx_target_version/{print $2}' "$n/properties")
  [ -n "$v" ] && [ "$v" != 0 ] && echo "  KFD node $(basename "$n"): gfx_target_version=$v (90006 = gfx906)"
done

hdr "User-space tools (optional)"
if command -v vulkaninfo >/dev/null; then
  vulkaninfo --summary 2>/dev/null | grep -E 'deviceName|driverName' | sed 's/^/  /'
else
  echo "  vulkaninfo not installed (apt install vulkan-tools mesa-vulkan-drivers)"
fi
for t in "$R/opt/rocm/bin/rocminfo" rocminfo; do
  if command -v "$t" >/dev/null; then "$t" 2>&1 | grep -E 'Name:.*gfx|Marketing' | head -n 4 | sed 's/^/  /'; break; fi
done
if [ "$COH" = no ] && [ "${HSA_USERPTR_FOR_PAGED_MEM:-1}" != 0 ]; then
  warn "non-coherent host: export HSA_USERPTR_FOR_PAGED_MEM=0 before running ROCm (scripts/rocm-env.sh)"
fi

echo
echo "Done: $FAILS failure(s). Paste this output when asking for help."
[ "$FAILS" -eq 0 ]
