#!/usr/bin/env python3
"""Static regression checks for the prebuilt MI50 Armbian image integration."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
IMAGE = ROOT / "armbian/image"
CUSTOMIZER = (IMAGE / "overlay/mi50-customize-image.sh").read_text()
INSTALLER = (IMAGE / "install-to-armbian-build.sh").read_text()
PROFILE = (IMAGE / "overlay/etc/profile.d/mi50-rocm.sh").read_text()
ENV = (IMAGE / "overlay/etc/mi50-rocm.env").read_text()
POWER = (IMAGE / "overlay/usr/local/sbin/mi50-set-power-cap").read_text()
GROUPS = (IMAGE / "overlay/usr/local/sbin/mi50-add-users-to-gpu-groups").read_text()
POWER_UNIT = (IMAGE / "overlay/etc/systemd/system/mi50-power-cap.service").read_text()
GROUP_TIMER = (IMAGE / "overlay/etc/systemd/system/mi50-device-access.timer").read_text()
UDEV = (IMAGE / "overlay/etc/udev/rules.d/70-mi50-rocm.rules").read_text()

checks = {
    "image customizer requires ARM64 target": 'dpkg --print-architecture' in CUSTOMIZER and '= arm64' in CUSTOMIZER,
    "image customizer currently targets Ubuntu noble": 'noble)' in CUSTOMIZER and 'noble|trixie' not in CUSTOMIZER,
    "image customizer validates payload archive before extraction": (
        'tar -tzf "$PAYLOAD"' in CUSTOMIZER and 'contains paths outside opt/rocm and opt/venv-rocm' in CUSTOMIZER
    ),
    "payload extracts to the fixed absolute prefix": 'tar --no-same-owner -xzf "$PAYLOAD" -C /' in CUSTOMIZER,
    "payload requires an ARM64-compatible Python 3.9-3.12 venv": 'sys.version_info[:2] < (3, 13)' in CUSTOMIZER,
    "image customization does not compile ROCm or PyTorch": 'cmake --build' not in CUSTOMIZER and 'setup.py' not in CUSTOMIZER,
    "dynamic linker config registers ROCm lib": 'mi50-rocm.conf' in CUSTOMIZER and '/opt/rocm/lib' in (IMAGE / 'overlay/etc/ld.so.conf.d/mi50-rocm.conf').read_text(),
    "interactive shell defaults set non-coherent host mode": 'HSA_USERPTR_FOR_PAGED_MEM=0' in PROFILE,
    "systemd environment is literal and contains required runtime flags": (
        'HSA_USERPTR_FOR_PAGED_MEM=0' in ENV and 'TORCH_BLAS_PREFER_HIPBLASLT=0' in ENV and '$PATH' not in ENV
    ),
    "power cap is limited to the MI50 PCI ID": '0x1002' in POWER and '0x66a1' in POWER,
    "power cap validates sysfs supported range": 'power1_cap_min' in POWER and 'power1_cap_max' in POWER,
    "power service uses systemd EnvironmentFile": 'EnvironmentFile=-/etc/mi50-rocm.env' in POWER_UNIT,
    "GPU user groups are assigned after first-boot accounts exist": 'OnUnitActiveSec=60s' in GROUP_TIMER and '[ "$uid" -ge 1000 ]' in GROUPS,
    "udev grants KFD and render node group access": 'KERNEL=="kfd"' in UDEV and 'KERNEL=="renderD[0-9]*"' in UDEV,
    "Armbian installer copies the expected kernel version patch": 'archive/rockchip64-$KERNEL_MM' in INSTALLER,
    "Armbian installer does not overwrite an existing customizer": 'BEGIN mi50-arm image integration' in INSTALLER and 'cat >> "$CUSTOMIZE"' in INSTALLER,
}

failed = []
for label, ok in checks.items():
    print(("PASS" if ok else "FAIL") + ": " + label)
    if not ok:
        failed.append(label)
if failed:
    raise SystemExit("MI50 Armbian image checks failed: " + "; ".join(failed))
