#!/usr/bin/env python3
"""End-to-end fixture test for the isolated Resolute image preparation script."""
from __future__ import annotations

import hashlib
import os
from pathlib import Path, PurePosixPath
import shutil
import struct
import subprocess
import tarfile
import tempfile

REPO = Path(__file__).resolve().parents[1]
PREPARE = REPO / "scripts/prepare-mi50-resolute-image.sh"
CUSTOMIZER_SOURCE = REPO / "armbian/image/overlay/mi50-customize-image-resolute.sh"
EXTENSION = REPO / "armbian/extensions/mi50-amdgpu.sh"
KERNEL_PATCH = REPO / "patches/0001-drm-amdgpu-use-write-combined-GTT-on-non-coherent-hosts.patch"


def run(args, *, env=None, cwd=None):
    result = subprocess.run(
        args, cwd=cwd, env=env, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    if result.returncode:
        raise RuntimeError(f"command failed ({result.returncode}): {args}\n{result.stdout}")
    return result.stdout


def init_git(path: Path, *, dirty: bool = False):
    path.mkdir(parents=True)
    run(["git", "init", "-q", str(path)])
    run(["git", "-C", str(path), "config", "user.name", "CI test"])
    run(["git", "-C", str(path), "config", "user.email", "ci@example.invalid"])
    (path / "tracked.txt").write_text("committed baseline\n")
    run(["git", "-C", str(path), "add", "tracked.txt"])
    run(["git", "-C", str(path), "commit", "-qm", "fixture baseline"])
    if dirty:
        (path / "tracked.txt").write_text("pre-existing local modification\n")
        (path / "curl_response").write_text("pre-existing untracked data\n")


def write_aarch64_elf(path: Path, *, executable=False):
    """Write a valid minimal ELF64 little-endian AArch64 header for readelf."""
    ident = b"\x7fELF" + bytes([2, 1, 1, 0, 0]) + bytes(7)
    header = struct.pack(
        "<HHIQQQIHHHHHH",
        1,       # ET_REL
        183,     # EM_AARCH64
        1,
        0, 0, 0,
        0,
        64,
        56,
        0,
        64,
        0,
        0,
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(ident + header)
    path.chmod(0o755 if executable else 0o644)


def make_target_prefix(prefix: Path):
    for rel in ("bin/hipcc", "bin/rocminfo", "llvm/bin/clang", "llvm/bin/clang++"):
        write_aarch64_elf(prefix / rel, executable=True)

    # These two build-host-absolute aliases must be rewritten in the image copy.
    (prefix / "bin/amdclang").symlink_to("/host/build/prefix/llvm/bin/clang")
    (prefix / "bin/amdclang++").symlink_to("/host/build/prefix/llvm/bin/clang++")

    lib = prefix / "lib"
    lib.mkdir(parents=True, exist_ok=True)
    for soname in (
        "libamdhip64.so.6.3.42134-a9a80e7",
        "libhsa-runtime64.so.1.14.0",
    ):
        (lib / soname).write_bytes(b"synthetic shared library placeholder\n")
    (lib / "libamdhip64.so").symlink_to("libamdhip64.so.6.3.42134-a9a80e7")
    (lib / "libhsa-runtime64.so").symlink_to("libhsa-runtime64.so.1.14.0")

    # Confirm the two known Windows-only dangling aliases are pruned, not used
    # as justification for ignoring arbitrary dangling runtime symlinks.
    (prefix / "hip/bin").mkdir(parents=True, exist_ok=True)
    (prefix / "hip/bin/hipcc.bat").symlink_to("../../bin/hipcc.bat")
    (prefix / "hip/bin/hipconfig.bat").symlink_to("../../bin/hipconfig.bat")


def main():
    for required in (PREPARE, CUSTOMIZER_SOURCE, EXTENSION, KERNEL_PATCH):
        if not required.is_file():
            raise SystemExit(f"Required fixture source missing: {required}")

    with tempfile.TemporaryDirectory(prefix="mi50-resolute-prep-ci-") as tmp:
        tmp = Path(tmp)
        volume = tmp / "external-volume"
        area = volume / "ArmbianOPi5P"
        original = area / "build"
        clean = area / "build-mi50-clean"
        root = original / "cache/mi50-arm64-cross"
        prefix = root / "target-rocm"
        stage = area / "mi50-resolute-stage"

        volume.mkdir(parents=True)
        init_git(original, dirty=True)
        init_git(clean)
        make_target_prefix(prefix)

        original_status_before = run(["git", "-C", str(original), "status", "--porcelain"])
        original_tracked_before = (original / "tracked.txt").read_bytes()
        original_untracked_before = (original / "curl_response").read_bytes()

        env = os.environ.copy()
        env.update({
            "MI50_REPO": str(REPO),
            "MI50_VOLUME": str(volume),
            "MI50_AREA": str(area),
            "MI50_ROCM_WORK_ROOT": str(root),
        })

        # Run twice: the first pass prepares the files, the second checks that
        # an existing staging tree and marked hook are handled idempotently.
        first = run(["bash", str(PREPARE)], env=env, cwd=REPO)
        second = run(["bash", str(PREPARE)], env=env, cwd=REPO)
        output = first + "\n" + second

        payload = clean / "userpatches/overlay/mi50-rocm-arm64.tar.gz"
        config = clean / "userpatches/config-mi50-resolute.conf"
        hook = clean / "userpatches/customize-image.sh"
        customizer = clean / "userpatches/overlay/mi50-customize-image.sh"
        extension = clean / "userpatches/extensions/mi50-amdgpu.sh"
        patch = clean / "userpatches/kernel/archive/rockchip64-6.18/0001-drm-amdgpu-use-write-combined-GTT-on-non-coherent-hosts.patch"

        for path in (payload, config, hook, customizer, extension, patch):
            if not path.is_file():
                raise AssertionError(f"expected generated file missing: {path}")
        if not os.access(customizer, os.X_OK):
            raise AssertionError("generated target-rootfs customizer is not executable")
        if customizer.read_bytes() != CUSTOMIZER_SOURCE.read_bytes():
            raise AssertionError("generated customizer differs from its tracked source")
        if extension.read_bytes() != EXTENSION.read_bytes():
            raise AssertionError("MI50 kernel extension changed while staging")
        if patch.read_bytes() != KERNEL_PATCH.read_bytes():
            raise AssertionError("GTT coherency patch changed while staging")

        conf = config.read_text()
        for required in (
            'BOARD="orangepi5-plus"',
            'BRANCH="current"',
            'RELEASE="resolute"',
            'DESKTOP_ENVIRONMENT="kde-plasma"',
            'DESKTOP_TIER="mid"',
            'ENABLE_EXTENSIONS="mi50-amdgpu"',
            'EXTRA_ROOTFS_MIB_SIZE="2048"',
        ):
            if required not in conf:
                raise AssertionError(f"missing image profile setting: {required}")

        hook_text = hook.read_text()
        if hook_text.count("BEGIN mi50-arm Resolute core image integration") != 1:
            raise AssertionError("customize-image hook marker is missing or duplicated")
        if hook_text.count("END mi50-arm Resolute core image integration") != 1:
            raise AssertionError("customize-image end marker is missing or duplicated")

        # Validate archive path safety and symlink containment.
        with tarfile.open(payload, "r:gz") as archive:
            members = archive.getmembers()
            names = {m.name for m in members}
            if not names or any(
                name.startswith("/") or ".." in PurePosixPath(name).parts
                or not (name == "opt/rocm" or name.startswith("opt/rocm/"))
                for name in names
            ):
                raise AssertionError("payload contains unsafe or out-of-prefix archive paths")
            for member in members:
                if member.issym() or member.islnk():
                    target = PurePosixPath(member.name).parent.joinpath(member.linkname)
                    normalized = []
                    for part in target.parts:
                        if part in ("", "."):
                            continue
                        if part == "..":
                            if not normalized:
                                raise AssertionError(f"symlink escapes payload: {member.name} -> {member.linkname}")
                            normalized.pop()
                        else:
                            normalized.append(part)
                    if not normalized or normalized[0] != "opt":
                        raise AssertionError(f"symlink escapes /opt: {member.name} -> {member.linkname}")
            required = {
                "opt/rocm/bin/hipcc", "opt/rocm/bin/rocminfo",
                "opt/rocm/bin/amdclang", "opt/rocm/bin/amdclang++",
                "opt/rocm/llvm/bin/clang", "opt/rocm/llvm/bin/clang++",
                "opt/rocm/lib/libamdhip64.so", "opt/rocm/lib/libhsa-runtime64.so",
            }
            if required - names:
                raise AssertionError(f"payload missing entries: {sorted(required - names)}")
            if "opt/rocm/hip/bin/hipcc.bat" in names or "opt/rocm/hip/bin/hipconfig.bat" in names:
                raise AssertionError("dangling Windows-only .bat aliases were packaged")
            links = {m.name: m.linkname for m in members if m.issym()}
            if links.get("opt/rocm/bin/amdclang") != "../llvm/bin/clang":
                raise AssertionError("amdclang image alias is not relative")
            if links.get("opt/rocm/bin/amdclang++") != "../llvm/bin/clang++":
                raise AssertionError("amdclang++ image alias is not relative")

        if (stage / "opt/rocm/hip/bin/hipcc.bat").exists() or (stage / "opt/rocm/hip/bin/hipcc.bat").is_symlink():
            raise AssertionError("Windows-only alias remains in staged image tree")

        status_after = run(["git", "-C", str(original), "status", "--porcelain"])
        if status_after != original_status_before:
            raise AssertionError("original Armbian checkout Git status changed")
        if (original / "tracked.txt").read_bytes() != original_tracked_before:
            raise AssertionError("original Armbian tracked file was modified")
        if (original / "curl_response").read_bytes() != original_untracked_before:
            raise AssertionError("original Armbian untracked file was modified")

        print("PASS: Resolute preparation fixture and repeat-run idempotency")
        print("PASS: only known dangling Windows .bat aliases pruned")
        print("PASS: archive paths and symlinks contained under /opt/rocm")
        print("PASS: profile, extension, kernel patch, and customizer staged")
        print("PASS: original Armbian checkout preserved")
        print(f"Payload fixture size: {payload.stat().st_size} bytes")
        print("Preparation output tail:")
        print("\n".join(output.strip().splitlines()[-12:]))


if __name__ == "__main__":
    main()
