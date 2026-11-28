# Applying the MI50 image rebuild workflow

Extract this overlay at the root of the `mi50-arm` checkout. It contains two
new scripts, a manual workflow, a source-level policy test, updated push/PR CI,
and runner setup documentation.

```bash
cd ~/Desktop/mi50-arm
unzip -o ~/Downloads/mi50-image-ci-overlay.zip -d .

git diff --check
bash -n scripts/ci-build-mi50-resolute-image.sh
bash -n scripts/verify-mi50-resolute-image.sh
python3 tests/test-mi50-resolute-ci.py

shellcheck -x scripts/*.sh

git status --short
```

Review the diff, then commit and push the listed workflow, script, test, and
documentation files. Do not stage unrelated files in the worktree.

Before starting a rebuild, register one trusted self-hosted x86-64 runner with
the `mi50-image-builder` label and prepare its persistent storage as described
in `docs/MI50-IMAGE-CI.md`. Configure the repository Actions variable
`MI50_BUILDER_ROOT` to the mounted storage path when it is not `/mnt/mi50-builder`.

Then open **Actions → MI50 Resolute image rebuild → Run workflow**. The default
rebuilds the ARM64 ROCm/HIP prefix. Select `rebuild_rocm=false` only when a
previous successful run has populated that runner's persistent prefix cache.
