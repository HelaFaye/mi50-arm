# Hardware

## Link

- On the Orange Pi 5 Plus, the M.2 M-key slot is the RK3588 **PCIe 3.0 x4**
  controller (`pcie3x4`, `fe150000`). The link tops out at Gen3 x4, so the
  MI50 trains down to that.
- Use an M.2 to OCuLink (SFF-8611/8612) adapter and a short cable, 50 cm or
  less. A redriver on the adapter helps, but isn't magic. If
  `scripts/check-mi50.sh` shows the link below 8 GT/s, or `dmesg` shows AER
  errors, try a shorter or better cable first.
- Any OCuLink eGPU dock with an x16 slot and an ATX PSU input works.

## Power

- The MI50 is rated at 300 W through two 8-pin PCIe connectors. Use a quality
  ATX PSU of 550 W or more, and cables that aren't daisy-chained.
- **Order:** turn on the GPU's PSU first, then the board. The card must
  be up when the kernel probes the PCIe bus. If it isn't, do a power cycle; a
  bus rescan often won't recover it.
- Plug both supplies into the same power strip. **Don't** solder extra ground
  wires. The PCIe link already shares ground across many pins.
- To cut heat and power draw with only a small loss of inference speed, cap
  the board power once the stack works:
  `rocm-smi --setpoweroverdrive 150`, or write to
  `/sys/class/drm/card*/device/hwmon/hwmon*/power1_cap`.

## Cooling

The MI50 is a **passively cooled** server card with no fan. Outside a server
chassis, it overheats and throttles or shuts down within a minute of load.
Mount a blower (a 3D-printed shroud with a 40 mm or 97 mm blower is common)
or a high-static-pressure fan ducted through the heatsink. Watch the
temperature:
`cat /sys/class/drm/card*/device/hwmon/hwmon*/temp*_input` (values are in millidegrees C).

## BAR space

**This is the most likely hard blocker.**

The `pcie3x4` controller's 64-bit prefetchable window is **1 GiB**
(`0x9_0000_0000`–`0x9_3fff_ffff` in `rk3588-extra.dtsi`), with about 14 MiB of
32-bit space. The MI50 needs:

| BAR | Purpose | Size |
| --- | --- | --- |
| BAR0 | VRAM aperture | 256 MiB, or the full VRAM (16 or 32 GiB) on large-BAR VBIOSes |
| BAR2 | Doorbells | 2 MiB |
| BAR5 | MMIO registers | 512 KiB |

If `check-mi50.sh` reports BAR0 as unassigned, or `dmesg` shows
`BAR 0: no space for [mem size 0x800000000 64bit pref]`, there are two
options, in this order:

1. **Resizable BAR.** If `lspci -vv` shows a `Physical Resizable BAR`
   capability, shrink BAR0 to 256 MiB before amdgpu binds:
   ```bash
   GPU=0000:01:00.0                                   # adjust to your bus ID
   cat /sys/bus/pci/devices/$GPU/resource0_resize     # bitmask; bit N = 2^N MiB supported
   echo $GPU | sudo tee /sys/bus/pci/drivers/amdgpu/unbind 2>/dev/null
   echo 8 | sudo tee /sys/bus/pci/devices/$GPU/resource0_resize   # 256 MiB
   echo $GPU | sudo tee /sys/bus/pci/drivers/amdgpu/bind
   ```
   To do this automatically at boot, put `amdgpu` on the module blacklist and
   run the commands above from a systemd unit, followed by `modprobe amdgpu`.
   amdgpu works fine with a small BAR: it uses a 256 MiB window for CPU access
   and the GPU still sees all 32 GB.
2. **A VBIOS with a small BAR.** Some MI50 VBIOS variants (as found in the
   community VBIOS collections) expose 256 MiB instead of the full VRAM.
   Reflashing is risky. Use `amdvbflash` on an x86 machine, keep a backup of
   the original image, and match the memory size (16 GB vs 32 GB) exactly.

The 1 GiB window is a hardware limit. A device tree change can't make it
bigger.

## Other aarch64 hosts

Hosts with coherent PCIe and large windows, such as Ampere Altra/AmpereOne and
NVIDIA Grace, avoid both the
coherency problem and the BAR problem. There, amdgpu works unmodified and
everything in this repo from Vulkan onward applies directly.
