#!/usr/bin/env python3
"""Static regression checks for the Noble ARM64 ROCm cross-build bootstrap."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = (ROOT / "scripts/build-rocm-arm64-cross.sh").read_text()
PATCH = (ROOT / "patches/0001-rocminfo-cross-system-processor.patch").read_text()
ROCR_PATCH = (ROOT / "patches/0002-rocr-runtime-aarch64-intrinsics.patch").read_text()
DEVICELIBS_PATCH = (ROOT / "patches/0003-device-libs-cmake4-cmp0053.patch").read_text()
COMGR_PATCH = (ROOT / "patches/0004-comgr-cross-host-tools.patch").read_text()
GITIGNORE = (ROOT / ".gitignore").read_text().splitlines()

checks = {
    "ignores only the repository-root build directory": "/build/" in GITIGNORE,
    "patch uses target rather than host processor in rocminfo": (
        "CMAKE_HOST_SYSTEM_PROCESSOR" in PATCH and "CMAKE_SYSTEM_PROCESSOR" in PATCH
    ),
    "preflight requires ld.lld by its executable name": "command -v ld.lld" in SCRIPT,
    "preflight verifies host AMDGPU assembly and AArch64 backend": (
        "amdgcn-amd-amdhsa -mcpu=gfx906" in SCRIPT and "--target=aarch64-linux-gnu" in SCRIPT
    ),
    "workspace mount is verified before creating build directories": (
        "findmnt -T" in SCRIPT and "REQUIRE_MOUNT_POINT" in SCRIPT and "REQUIRED_MOUNT_FSTYPE" in SCRIPT
    ),
    "partial sysroot is never removed automatically": (
        'rm -rf "$SYSROOT"' not in SCRIPT and "refusing to delete or overwrite it" in SCRIPT
    ),
    "sysroot tar extraction does not preserve foreign ownership": "tar --no-same-owner -xf" in SCRIPT,
    "image sysroot mode mounts read-only with noload and cleans up loop device": (
        "SYSROOT_SOURCE_IMG" in SCRIPT and "ro,noload" in SCRIPT and "losetup -d" in SCRIPT
    ),
    "binfmt-free deb overlay verifies sha256 and keeps usrmerge symlinks": (
        "install_noble_deb_overlays" in SCRIPT and "hashlib.sha256" in SCRIPT and "--keep-directory-symlink" in SCRIPT
    ),
    "sysroot permissions normalized before absolute symlinks": (
        'chmod -R u+rwX "$staging"' in SCRIPT and "normalize_sysroot_symlinks \"$staging\"" in SCRIPT
    ),
    "sysroot includes GCC 13 C++ runtime and ROCR dependencies": (
        "libstdc++-13-dev" in SCRIPT and "libgcc-13-dev" in SCRIPT and "libdrm-dev" in SCRIPT
    ),
    "minimal imported executable shims avoid host LLVM dependency graph": (
        "LLVMConfig.cmake" in SCRIPT and "ClangConfig.cmake" in SCRIPT
        and "add_executable(llvm-objcopy IMPORTED GLOBAL)" in SCRIPT
        and "add_executable(clang IMPORTED GLOBAL)" in SCRIPT
    ),
    "CMake packages, libraries and headers are isolated to declared roots": (
        "set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)" in SCRIPT
        and "set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)" in SCRIPT
        and "set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)" in SCRIPT
        and 'set(ENV{PKG_CONFIG_PATH} "")' in SCRIPT
    ),
    "Clang uses Noble GCC 13 and linker-only lld flags": (
        "--gcc-install-dir=$gcc_dir" in SCRIPT
        and "CMAKE_C_FLAGS_INIT \"--gcc-install-dir=$gcc_dir\"" in SCRIPT
        and "-fuse-ld=lld" in SCRIPT
    ),
    "rocminfo Release mode and target-processor patch are applied": (
        "-DROCRTST_BLD_TYPE=Release" in SCRIPT
        and "0001-rocminfo-cross-system-processor.patch" in SCRIPT
    ),
    "ROCR AArch64 intrinsics patch is wired into fetch and emits dsb st and yield": (
        "0002-rocr-runtime-aarch64-intrinsics.patch" in SCRIPT
        and "CpuPause" in ROCR_PATCH
        and "StoreFence" in ROCR_PATCH
        and "dsb st" in ROCR_PATCH
        and "yield" in ROCR_PATCH
    ),
    "ELF validation checks architecture, dependency closure, ORIGIN rpaths and Noble ABI ceilings": (
        "DT_NEEDED" in SCRIPT and "GLIBCXX': (3, 4, 32)" in SCRIPT
        and "GLIBC': (2, 39)" in SCRIPT and "AArch64" in SCRIPT
        and "$ORIGIN" in SCRIPT and "rpath_dirs" in SCRIPT
    ),
    "Milestone 2 host LLVM builds X86/AArch64/AMDGPU with lld and installs device-libs": (
        "LLVM_TARGETS_TO_BUILD=\"X86;AArch64;AMDGPU\"" in SCRIPT
        and "stage_device_libs" in SCRIPT
        and "llvm-strip" in SCRIPT
    ),
    "device-libs CMake 4 policy patch is wired into fetch and device_libs stages": (
        "0003-device-libs-cmake4-cmp0053.patch" in SCRIPT
        and "CMP0053" in DEVICELIBS_PATCH
        and 'VERSION_LESS "4.0"' in DEVICELIBS_PATCH
    ),
    "Milestone 3 cross-builds target LLVM (AArch64;AMDGPU), comgr with host tools, and hipcc": (
        "stage_target_llvm" in SCRIPT
        and 'LLVM_TARGETS_TO_BUILD="AArch64;AMDGPU"' in SCRIPT
        and "LLVM_NATIVE_TOOL_DIR" in SCRIPT
        and "0004-comgr-cross-host-tools.patch" in SCRIPT
        and "COMGR_HOST_BC2H" in COMGR_PATCH
        and "COMGR_HOST_CLANG" in COMGR_PATCH
        and "stage_hipcc" in SCRIPT
    ),
    "QEMU accepts only HSA success, absent-KFD diagnostics, or verified unemulated KFD ioctl": (
        "Unable to open /dev/kfd read-write:" in SCRIPT
        and "ROCk module is NOT loaded" in SCRIPT
        and "0x80084b01" in SCRIPT
        and "errno=25" in SCRIPT
        and "Unexpected QEMU result" in SCRIPT
    ),
}

failed = []
for label, passed in checks.items():
    print(f"[{'PASS' if passed else 'FAIL'}] {label}")
    if not passed:
        failed.append(label)
if failed:
    raise SystemExit("Failed checks: " + "; ".join(failed))
