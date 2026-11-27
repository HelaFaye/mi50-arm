#!/usr/bin/env python3
"""Static regression checks for the MI50 ARM64 Milestone 4 stages."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/build-rocm-arm64-cross.sh"
TEXT = SCRIPT.read_text()


class Milestone4Tests(unittest.TestCase):
    def test_gl_overlay_imports_regex_for_egl_normalization(self):
        gl_stage = TEXT.split("stage_gl_dev_overlay() {", 1)[1].split(
            "stage_toolchain() {", 1
        )[0]
        self.assertIn("import re", gl_stage)


    def test_gl_overlay_adopts_only_metadata_different_egl_header(self):
        self.assertIn("replaced_metadata_headers: list[dict[str, object]] = []", TEXT)
        self.assertIn("if current_hash == new_hash:", TEXT)
        self.assertIn("normalize_egl_header(backup.read_bytes())", TEXT)
        self.assertIn('package != "libegl-dev"', TEXT)
        self.assertIn('"usr/include/EGL/egl.h"', TEXT)
        self.assertIn("normalize_egl_header(existing_bytes)", TEXT)
        self.assertIn("normalize_egl_header(incoming_bytes)", TEXT)
        self.assertIn('"original_sha256": backup_hash', TEXT)
        self.assertIn('"installed_sha256": new_hash', TEXT)
        self.assertIn('"replaced_metadata_headers": replaced_metadata_headers', TEXT)

    def test_gl_overlay_adopts_only_two_exact_pinned_egl_api_headers(self):
        self.assertIn("API_HEADER_REPLACEMENTS = {", TEXT)
        self.assertIn("replaced_api_headers: list[dict[str, object]] = []", TEXT)
        self.assertIn("def adopt_pinned_egl_api_header(", TEXT)
        self.assertIn('package != "libegl-dev"', TEXT)
        self.assertIn('"usr/include/EGL/eglext.h"', TEXT)
        self.assertIn('"usr/include/EGL/eglplatform.h"', TEXT)
        self.assertIn(
            "fbc70471a706d5c36427f032fa528de72bb0cfa2efb278d82b6bf2f675543295",
            TEXT,
        )
        self.assertIn(
            "a5f574a0074001400c6c50232235ee00e9a67b2168bfd1c364ba0f6f52e5a75c",
            TEXT,
        )
        self.assertIn(
            "1081d0dd1099f5f0367d21c2949e3be344d3fe37c41e7cab907b12ef71f95703",
            TEXT,
        )
        self.assertIn(
            "25b5391655effcf363a38fa00c3154f356a3eab3d35dc067847875513cf1e441",
            TEXT,
        )
        self.assertIn("if current_hash == expected_old_hash:", TEXT)
        self.assertIn("elif current_hash == expected_new_hash:", TEXT)
        self.assertIn('"replaced_api_headers": replaced_api_headers', TEXT)
        self.assertIn(
            "adopt_pinned_egl_api_header(package, relative, dst, src)",
            TEXT,
        )

    def test_gl_overlay_recovers_api_header_audit_before_identical_file_shortcut(self):
        merge = TEXT.split(
            "def merge_tree(source: Path, package: str) -> None:", 1
        )[1].split("for relative in REQUIRED:", 1)[0]
        file_branch = merge.split("elif src.is_file():", 1)[1]
        adopter = file_branch.index(
            "adopt_pinned_egl_api_header(package, relative, dst, src)"
        )
        identical_shortcut = file_branch.index("sha256(dst) == sha256(src)")
        self.assertLess(adopter, identical_shortcut)

    def test_gl_overlay_recovers_both_egl_header_audits_before_identical_shortcut(self):
        merge = TEXT.split(
            "def merge_tree(source: Path, package: str) -> None:", 1
        )[1].split("for relative in REQUIRED:", 1)[0]
        file_branch = merge.split("elif src.is_file():", 1)[1]
        api_adopter = file_branch.index(
            "adopt_pinned_egl_api_header(package, relative, dst, src)"
        )
        metadata_adopter = file_branch.index(
            "adopt_generated_egl_header(package, relative, dst, src)"
        )
        identical_shortcut = file_branch.index("sha256(dst) == sha256(src)")
        self.assertLess(api_adopter, identical_shortcut)
        self.assertLess(metadata_adopter, identical_shortcut)

    def test_gl_overlay_preserves_and_audits_documentation_conflicts(self):
        self.assertIn('relative.parts[:3] == ("usr", "share", "doc")', TEXT)
        self.assertIn("preserved_documentation_conflicts", TEXT)
        self.assertIn("preserve_documentation_conflict(package, relative, dst, src)", TEXT)
        self.assertIn("merge_tree(package_root, package)", TEXT)
        self.assertIn("skipped_doc_prefixes", TEXT)

    def test_gl_overlay_decodes_tar_member_names_before_path_validation(self):
        self.assertIn("safe_member_path(os.fsdecode(name))", TEXT)

    def test_gl_overlay_is_a_distinct_stage_after_sysroot(self):
        stages = re.search(r"^STAGES=\(([^)]*)\)", TEXT, re.M)
        self.assertIsNotNone(stages)
        names = stages.group(1).split()
        self.assertLess(names.index("sysroot"), names.index("gl_dev_overlay"))
        self.assertIn("gl_dev_overlay) stage_gl_dev_overlay ;;", TEXT)

    def test_gl_overlay_uses_noble_updates_for_x11_dev_and_runtime(self):
        self.assertIn(
            'NOBLE_UPDATES_INDEX = deb_cache / "noble-updates-main-arm64-Packages.xz"',
            TEXT,
        )
        self.assertIn(
            '("libx11-dev", "noble-updates", X11_UPDATES_VERSION, '
            '"c67aedaed249c629628c24e717c5b550a066e246c678aa98098002ed0a8017e9", {"arm64"})',
            TEXT,
        )
        self.assertIn('"libx11-6": X11_UPDATES_VERSION', TEXT)
        self.assertIn('"noble-updates": noble_updates_records', TEXT)
        self.assertIn('"noble-updates": UBUNTU_BASE', TEXT)

    def test_gl_overlay_reconciles_only_verified_x11_runtime_metadata(self):
        self.assertIn("def reconcile_libx11_runtime_metadata(", TEXT)
        self.assertIn(
            "reconcile_libx11_runtime_metadata(noble_updates_records, status)",
            TEXT,
        )
        self.assertIn(
            "57f0bee78ea23caa31520a565fb12fcbea1ee5ecfd4f2055f12dd0ac3698f439",
            TEXT,
        )
        self.assertIn(
            "91829f6a89670eaee581a594f0f796c4c87f24ccb58c43f842b1462545cfa9cc",
            TEXT,
        )
        self.assertIn(
            "e733ad656f12dbe25ee0f399b1e9489d8da004f253bd25a6aac34189023366bf",
            TEXT,
        )
        self.assertIn("preserved_status_backup", TEXT)
        self.assertIn("preserved_md5sums_backup", TEXT)
        self.assertIn('"reconciled_runtime_packages": reconciled_runtime_packages', TEXT)
        self.assertIn("runtime binaries unchanged", TEXT)

    def test_gl_overlay_uses_split_pinned_origins(self):
        self.assertIn("ppa.launchpadcontent.net_ernstp_mesarc_ubuntu_dists_noble_main_binary-arm64_Packages", TEXT)
        self.assertIn("noble-main-arm64-Packages.xz", TEXT)
        self.assertIn("PPA_BASE = \"https://ppa.launchpadcontent.net/ernstp/mesarc/ubuntu/\"", TEXT)
        self.assertIn("UBUNTU_BASE = \"https://ports.ubuntu.com/ubuntu-ports/\"", TEXT)
        self.assertIn("1b09bc3142ca54f8e888f6f499c4df58a3ab327345b806d872d029d887602362", TEXT)
        self.assertIn("c67aedaed249c629628c24e717c5b550a066e246c678aa98098002ed0a8017e9", TEXT)
        self.assertIn(".mi50-gl-dev-overlay.json", TEXT)
        self.assertIn("libegl-dev", TEXT)
        self.assertIn("f0b89ca01bdf15090fc2ae6d90998e181b0e469e47454b16dcd7f183b544be04", TEXT)
        self.assertIn('"libegl1": PPA_VERSION', TEXT)
        self.assertIn("usr/include/EGL/egl.h", TEXT)
        self.assertIn("usr/include/GL/glx.h", TEXT)
        self.assertIn("usr/include/X11/Xlib.h", TEXT)
        self.assertIn("usr/include/X11/Xutil.h", TEXT)
        self.assertIn("usr/include/xcb/xcb.h", TEXT)
        self.assertIn("usr/lib/aarch64-linux-gnu/libEGL.so", TEXT)
        self.assertIn("Overlay would replace an existing non-identical path", TEXT)

    def test_base_noble_overlay_does_not_install_glvnd_packages(self):
        helper = TEXT.split("install_noble_deb_overlays() {", 1)[1].split("stage_sysroot() {", 1)[0]
        self.assertNotRegex(helper, r'"lib(?:gl|glx|opengl|egl|glvnd)[^" ]*"')
        self.assertNotRegex(helper, r'"libx(?:11|au|dmcp|cb)[^" ]*"')

    def test_base_sysroot_verifier_does_not_require_gl_development_files(self):
        verifier = TEXT.split("verify_sysroot_contents() {", 1)[1].split("normalize_sysroot_symlinks() {", 1)[0]
        for path in (
            "usr/include/GL/", "usr/include/EGL/", "usr/include/X11/",
            "usr/include/xcb/", "usr/lib/aarch64-linux-gnu/libGL.so",
        ):
            self.assertNotIn(path, verifier)
        self.assertIn("usr/include/libelf.h", verifier)
        self.assertIn("usr/include/numa.h", verifier)

    def test_sysroot_creation_leaves_gl_dev_packages_to_dedicated_overlay(self):
        stage = TEXT.split("stage_sysroot() {", 1)[1].split("stage_gl_dev_overlay() {", 1)[0]
        helper = TEXT.split("install_noble_deb_overlays() {", 1)[1].split("stage_sysroot() {", 1)[0]
        for package in ("libgl-dev", "libegl-dev", "libopengl-dev", "libx11-dev"):
            self.assertNotIn(package, stage)
            self.assertNotIn(package, helper)
        self.assertNotIn('install_noble_deb_overlays "$SYSROOT"', stage)
        self.assertIn('verify_sysroot_contents "$SYSROOT"', stage)

    def test_gl_overlay_adopts_only_byte_identical_preexisting_files(self):
        self.assertIn("if dst.is_symlink() and os.readlink(dst) == link:", TEXT)
        self.assertIn("sha256(dst) == sha256(src)", TEXT)
        self.assertIn("Overlay would replace an existing non-identical path", TEXT)
        overlay = TEXT.split("stage_gl_dev_overlay() {", 1)[1].split("stage_toolchain() {", 1)[0]
        self.assertIn('verify_sysroot_contents "$SYSROOT"', overlay)
        self.assertIn('".mi50-gl-dev-overlay.json"', overlay)
        self.assertIn('log "OpenGL development overlay is ready"', overlay)

    def test_toolchain_has_aarch64_asm_and_compiler_rt_host_package_mode(self):
        self.assertIn("set(CMAKE_ASM_COMPILER \"$host_clang\")", TEXT)
        self.assertIn("set(CMAKE_ASM_COMPILER_TARGET aarch64-linux-gnu)", TEXT)
        self.assertIn("set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE NEVER)", TEXT)

    def test_compiler_rt_uses_host_llvm_and_tools(self):
        stage = TEXT.split("stage_compiler_rt() {", 1)[1].split("stage_hip() {", 1)[0]
        self.assertIn('CROSS_COMPILER" = clang', stage)
        self.assertIn('LLVM_DIR="$HOST_LLVM/lib/cmake/llvm"', stage)
        self.assertIn('LLVM_CMAKE_DIR="$HOST_LLVM"', stage)
        self.assertIn('compiler-rt-aarch64-toolchain.cmake', stage)
        self.assertIn('set(CMAKE_C_COMPILER "$HOST_LLVM/bin/clang")', stage)
        self.assertIn('set(CMAKE_ASM_COMPILER "$HOST_LLVM/bin/clang")', stage)
        self.assertIn('COMPILER_RT_INSTALL_LIBRARY_DIR', stage)
        self.assertIn('compiler-rt-builtins-hostclang', stage)
        self.assertIn('target_rt="$res_dir/lib/linux/libclang_rt.builtins-aarch64.a"', stage)
        self.assertIn('CMAKE_TOOLCHAIN_FILE="$compiler_rt_tc"', stage)
        self.assertIn('CMAKE_C_COMPILER_TARGET', stage)
        self.assertIn('CMAKE_ASM_COMPILER_TARGET', stage)
        self.assertIn('for tool in llvm-ar llvm-nm llvm-ranlib llvm-config', stage)
        self.assertIn('sort -u', stage)

    def test_clr_aarch64_memory_barrier_patch_is_wired_and_complete(self):
        patch_path = ROOT / "patches/0007-clr-aarch64-memory-barriers.patch"
        self.assertTrue(patch_path.is_file())
        patch = patch_path.read_text()

        apply_call = (
            'apply_patch_idempotent "$SRC/clr" '
            '"$REPO_ROOT/patches/0007-clr-aarch64-memory-barriers.patch"'
        )
        self.assertEqual(TEXT.count(apply_call), 2)

        self.assertEqual(patch.count("_mm_sfence();"), 2)
        self.assertEqual(patch.count("_mm_mfence();"), 2)
        self.assertEqual(
            patch.count('asm volatile("dsb st" ::: "memory");'), 2
        )
        self.assertEqual(
            patch.count('asm volatile("dsb sy" ::: "memory");'), 2
        )
        self.assertEqual(
            patch.count('asm volatile("eieio" ::: "memory");'), 2
        )
        self.assertEqual(
            patch.count('asm volatile("sync" ::: "memory");'), 2
        )

        self.assertIn("hipamd/src/hip_graph_internal.cpp", patch)
        self.assertIn("rocclr/device/rocm/rocvirtual.cpp", patch)

    def test_hip_requires_overlay_and_compiler_rt(self):
        stage = TEXT.split("stage_hip() {", 1)[1].split("check_elf_tree() {", 1)[0]
        self.assertIn('CROSS_COMPILER" = clang', stage)
        self.assertIn('.mi50-gl-dev-overlay.json', stage)
        self.assertIn('libclang_rt.builtins-aarch64.a', stage)
        self.assertIn('HIPRTC_MC_TRIPLE=aarch64-linux-gnu', stage)
        self.assertIn('$BLD/clr/hipamd/new_header.h.i', stage)
        self.assertNotIn('$BLD/clr/new_header.h.i', stage)
        self.assertIn('--target=aarch64-linux-gnu;--sysroot=$SYSROOT;--gcc-install-dir=$gcc_dir', stage)


if __name__ == "__main__":
    unittest.main(verbosity=2)
