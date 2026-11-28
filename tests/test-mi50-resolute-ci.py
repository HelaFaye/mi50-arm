#!/usr/bin/env python3
"""Static safety checks for the manual self-hosted Resolute rebuild workflow."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/mi50-resolute-image.yml"
BUILDER = ROOT / "scripts/ci-build-mi50-resolute-image.sh"
VERIFIER = ROOT / "scripts/verify-mi50-resolute-image.sh"
DOC = ROOT / "docs/MI50-IMAGE-CI.md"

for path in (WORKFLOW, BUILDER, VERIFIER, DOC):
    if not path.is_file():
        raise SystemExit(f"Required MI50 CI file is missing: {path.relative_to(ROOT)}")

workflow = WORKFLOW.read_text()
builder = BUILDER.read_text()
verifier = VERIFIER.read_text()
doc = DOC.read_text()

for token in (
    "workflow_dispatch:",
    "rebuild_rocm:",
    "needs: validate_source",
    "needs: [validate_source, rebuild_rocm]",
    "self-hosted, linux, x64, mi50-image-builder",
    "timeout-minutes: 360",
    "actions/upload-artifact@v4",
):
    if token not in workflow:
        raise SystemExit(f"Workflow is missing required control: {token}")

for token in (
    "scripts/build-rocm-arm64-cross.sh",
    "scripts/prepare-mi50-resolute-image.sh",
    "./compile.sh mi50-resolute",
    "scripts/verify-mi50-resolute-image.sh",
    "0001-drm-amdgpu-use-write-combined-GTT-on-non-coherent-hosts",
    "amdgpu_gtt_mgr.o",
    "zstd -t",
    "120 * 1024 * 1024",
    ".mi50-ci-prefix-manifest",
    "PREFIX_INPUTS_SHA",
):
    if token not in builder:
        raise SystemExit(f"Builder is missing required operation or guard: {token}")

for token in (
    "sha256sum --check",
    "Disklabel type: gpt",
    "VERSION_CODENAME=resolute",
    "Machine:.*AArch64",
    "70-mi50-rocm.rules",
    "mi50-power-cap.service",
    "mi50-device-access.timer",
    "amdgpu.ko",
):
    if token not in verifier:
        raise SystemExit(f"Image verifier is missing required assertion: {token}")

if "not uploaded to Actions artifact storage" not in doc:
    raise SystemExit("Documentation must explain why the large disk image is retained on the builder")
if "exactly one online runner" not in doc:
    raise SystemExit("Documentation must explain the single-runner persistent-workspace constraint")

print("PASS: manual rebuild workflow is self-hosted, sequenced, and bounded")
print("PASS: cross-build and Armbian image stages are both wired")
print("PASS: image audit covers identity, integrity, ROCm, and MI50 integration")
print("PASS: build output retention and runner requirements are documented")
