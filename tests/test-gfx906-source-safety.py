#!/usr/bin/env python3
"""Static regression checks for the risky gfx906 loader/dispatch boundaries."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

pm4 = (ROOT / "experiments/gfx906/gfx9_pm4.hpp").read_text()
implicit_args = (ROOT / "experiments/gfx906/gfx9_code_object_v5.hpp").read_text()
dispatch = (ROOT / "experiments/gfx906/dispatch_gfx906.cpp").read_text()
shim = (ROOT / "experiments/gfx906/hsa_drm_shim.cpp").read_text()
bnb_patch = (ROOT / "patches/0001-bitsandbytes-disable-hipblaslt-gfx906.patch").read_text()
bnb_script = (ROOT / "scripts/build-bitsandbytes-gfx906.sh").read_text()
trainer = (ROOT / "examples/train_qwen14b_qlora.py").read_text()

checks = {
    "TC_WB_ACTION_ENA is GFX9 bit 18": "ACQUIRE_MEM_TC_WB_ACTION_ENA = 1u << 18" in pm4,
    "legacy bit-15 writeback encoding is absent": "ACQUIRE_MEM_TC_WB_ACTION_ENA = 1u << 15" not in pm4,
    "GTT memory pool exposes a CPU mapping": "*ptr = rec.cpu_ptr;" in shim,
    "CPU GTT pointers resolve to their GPU VA for dispatch/copy": "find_buffer_for_pointer" in shim,
    "AQL compute IB is fenced before reuse": "wait_queue_ib_idle(q)" in shim and "q->ib_in_flight     = true" in shim,
    "queue compute IB is resident in the submission BO list": "AMDGPU_GEM_DOMAIN_GTT, true, false, true, q->ib_bo" in shim,
    "GOT relocations fail closed": "unsupported GOT relocation type" in shim,
    "unsupported hidden SGPR layouts fail closed": "unsupported hidden SGPR properties" in shim,
    "bitsandbytes patch disables hipBLASLt": "OR BNB_DISABLE_HIPBLASLT" in bnb_patch,
    "bitsandbytes patch has standard three-line context": (
        "@@ -452,7 +452,7 @@" in bnb_patch
        and " set_source_files_properties(${GPU_FILES} PROPERTIES LANGUAGE HIP)" in bnb_patch
        and " \ttarget_compile_definitions(bitsandbytes PUBLIC NO_HIPBLASLT)" in bnb_patch
        and " \tfind_package(hipblaslt)" in bnb_patch
    ),
    "bitsandbytes activation script is checked as a file": (
        'if [ ! -f "$VENV/bin/activate" ]; then' in bnb_script
        and 'if [ ! -d "$VENV/bin/activate" ]; then' not in bnb_script
    ),
    "QLoRA uses the accumulation-window token mean without a GAS multiplier": (
        "loss = loss_sum / denominator" in trainer
        and "loss_sum * self.args.gradient_accumulation_steps" not in trainer
    ),
    "QLoRA keeps Transformers 4.46.3 training_step backward scaling intact": (
        "def training_step(" not in trainer
    ),
    "QLoRA pins Accelerator-side gradient accumulation division to one": (
        'os.environ["ACCELERATE_GRADIENT_ACCUMULATION_STEPS"] = "1"' in trainer
    ),
    "QLoRA counts shifted labels across the accumulation window": (
        '(batch["labels"][..., 1:] != -100)' in trainer
        and "trainer.model_accepts_loss_kwargs = True" in trainer
    ),
    "any nonzero effective private segment enables GFX9 SCRATCH_EN": (
        "if (priv_size > 0)" in shim
        and "rsrc2 |= mi50::gfx906::COMPUTE_PGM_RSRC2_SCRATCH_EN;" in shim
    ),
    "shim diagnostics contain real newline escapes, not literal backslash-n": r"\\n" not in shim,
    "COv5 hidden-argument layout is 24-byte explicit args plus 18-byte implicit args": (
        "VEC_ADD_EXPLICIT_KERNARG_BYTES == 24u" in implicit_args
        and "CODE_OBJECT_V5_BLOCK_COUNTS_BYTES == 12u" in implicit_args
        and "CODE_OBJECT_V5_GROUP_SIZES_BYTES == 6u" in implicit_args
        and "VEC_ADD_KERNARG_REQUIRED_BYTES == 42u" in implicit_args
    ),
    "COv5 implicit args are checked against descriptor and 256-byte capacity": (
        "descriptor_kernarg_size > kernarg_capacity" in implicit_args
        and "descriptor_kernarg_size < VEC_ADD_KERNARG_REQUIRED_BYTES" in implicit_args
        and "VEC_ADD_KERNARG_CAPACITY = 256u" in implicit_args
    ),
    "dispatcher populates COv5 workgroup counts and sizes after explicit pointers": (
        '#include "gfx9_code_object_v5.hpp"' in dispatch
        and "populate_vec_add_code_object_v5_implicit_args" in dispatch
        and "kd->kernarg_size" in dispatch
        and "static_cast<uint32_t>(N / 64u), 64u" in dispatch
    ),
}
failed = [label for label, ok in checks.items() if not ok]
for label, ok in checks.items():
    print(("PASS" if ok else "FAIL") + ": " + label)
if failed:
    raise SystemExit("gfx906 source-safety regression checks failed: " + "; ".join(failed))
