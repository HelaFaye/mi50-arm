#!/usr/bin/env python3
"""Guard the source-build recipe against known ROCm/PyTorch dependency gaps."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
script = (ROOT / "scripts/build-rocm-math-and-torch.sh").read_text()
requirements = (ROOT / "requirements-qlora.txt").read_text()
bnb = (ROOT / "scripts/build-bitsandbytes-gfx906.sh").read_text()
workflow = (ROOT / ".github/workflows/gfx906-compile.yml").read_text()

checks = {
    "one ROCm release is pinned for all upstream clones": 'git clone --branch rocm-6.3.3' in script,
    "non-coherent RK3588 HSA userptr mode is disabled": 'export HSA_USERPTR_FOR_PAGED_MEM=0' in script,
    "PyTorch required rocThrust package is built": "clone_rocm rocThrust" in script,
    "PyTorch required hipSOLVER package is built": "clone_rocm hipSOLVER" in script,
    "PyTorch required hipBLASLt host package is built": "clone_rocm hipBLASLt" in script,
    "hipBLASLt is built without gfx906 Tensile kernels": "-DBUILD_WITH_TENSILE=OFF" in script,
    "rocBLAS Tensile worker count is capped by MAX_JOBS": '-DTensile_CPU_THREADS="$MAX_JOBS"' in script,
    "MIOpen uses dynamically linked Boost libraries": "-DBoost_USE_STATIC_LIBS=OFF" in script,
    "PyTorch GPU smoke test avoids host-only hipBLASLt": "export TORCH_BLAS_PREFER_HIPBLASLT=0" in script,
    "MIOpen avoids hipBLASLt": "-DMIOPEN_USE_HIPBLASLT=OFF" in script,
    "MIOpen AI tuning/fallback deps are disabled": (
        "-DMIOPEN_ENABLE_AI_IMMED_MODE_FALLBACK=OFF" in script
        and "-DMIOPEN_ENABLE_AI_KERNEL_TUNING=OFF" in script
    ),
    "MIOpen header/build dependencies are installed": all(
        p in script for p in ("libboost-filesystem-dev", "nlohmann-json3-dev", "libfmt-dev", "clone_rocm half")
    ),
    "PyTorch Kineto is disabled without roctracer": "export USE_KINETO=0" in script,
    "bitsandbytes disables HIPBLASLt via its pinned CMake patch": (
        "BNB_DISABLE_HIPBLASLT=ON" in bnb
        and "0001-bitsandbytes-disable-hipblaslt-gfx906.patch" in bnb
    ),
    "bitsandbytes smoke test avoids host-only hipBLASLt": "export TORCH_BLAS_PREFER_HIPBLASLT=0" in bnb,
    "Hugging Face dependency pins preserve the custom torch": (
        "transformers==4.46.3" in requirements
        and "datasets==3.1.0" in requirements
        and "pyarrow==" in requirements
        and "multiprocess==" in requirements
        and "fsspec[http]==" in requirements
    ),
    "ROCm container installs git, CMake, and Ninja before checkout": (
        (lambda section: (
            section.index("apt-get install -y --no-install-recommends")
            < section.index("- uses: actions/checkout@v4")
            and "git cmake ninja-build" in section
        ))(workflow.split("  rocm-gfx906:", 1)[1].split("\n  full-arm64-mi50-stack:", 1)[0])
    ),
    "gfx906 HSACO inspection uses the explicit ROCm llvm-readelf path": (
        '"$ROCM_PATH/llvm/bin/llvm-readelf" -h vec_add.hsaco' in workflow
        and '"$ROCM_PATH/llvm/bin/llvm-readelf" -s vec_add.hsaco' in workflow
    ),
    "heavy self-hosted build is opt-in": "inputs.run_full_arm64_stack" in workflow,
}

failed = []
for label, ok in checks.items():
    print(("PASS" if ok else "FAIL") + ": " + label)
    if not ok:
        failed.append(label)
if failed:
    raise SystemExit("ROCm build-plan checks failed: " + "; ".join(failed))
