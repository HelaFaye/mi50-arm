# The host CPU, and checking the GPU against it

The MI50 does the heavy work, but the board's CPU still matters. It reads prompts while layers load, samples every
token, and runs any layers or experts left on the CPU (`-ot exps=CPU` for a large mixture of experts). It is also
the reference the GPU's results are checked against.

The tools here borrow from [Llaminar](https://github.com/Llaminar/llaminar)'s native ARM port
(`feat/arm64-native-kernels`). Llaminar is its own inference engine, and its NEON kernels can't be dropped into
llama.cpp, but two of its rules carry over:

1. **Trust the CPU, not the compiler flags.** Llaminar reads what the executing CPU supports from the kernel, and
   refuses code compiled for an instruction the machine lacks (`ARMCPUFeatures.h`, `requireEnvelope`).
2. **Parity before speed.** Every kernel is checked against a reference before it counts.

## `scripts/arm-cpu.sh`

```bash
./scripts/arm-cpu.sh                                   # cores, instructions, build arch, thread flags
./scripts/arm-cpu.sh --check-build ~/llama.cpp/build-hip
```

It reads each core's features from `/proc/cpuinfo` and its capacity from sysfs.

| | RK3588 |
| --- | --- |
| Cores | 4 × Cortex-A55 (capacity 414), 4 × Cortex-A76 (1024) |
| dotprod, fp16 | yes, on every core |
| i8mm, bf16, SVE | no |
| Portable llama.cpp build | `-DGGML_NATIVE=OFF -DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod+fp16` |
| Thread flags | `-t 4 -tb 4 -C 0xF0 -Cb 0xF0 --cpu-strict 1` |

- **Building:** on the board itself, `GGML_NATIVE=ON` (the default in `build-llamacpp.sh`) is right. When building
  somewhere else for the board, such as a container image or another machine, set
  `LLAMA_ARM_ARCH=armv8.2-a+dotprod+fp16`.
- **Before running a build made elsewhere,** `--check-build` reads its `CMakeCache.txt` and fails if it was made
  for instructions this CPU lacks. ARMv8.4 and later imply dotprod, ARMv8.6 implies i8mm and bf16, and ARMv9
  implies SVE2. Such a build would otherwise die with SIGILL partway through a model. A build that only the fast
  cores could run gets a warning to pin it to them.
- **Threads:** pin llama.cpp to the fast cores with its own affinity flags rather than `taskset`. Each thread is
  then placed on one A76 core (`--cpu-strict 1`), and the A55 cores stay free for the GPU driver and the system.
  `-tb` and `-Cb` do the same for prompt processing. That is a safe start, not the proven best: measure it with
  `cpu-threads-bench.sh` (below).

## `scripts/cpu-threads-bench.sh`

```bash
./scripts/cpu-threads-bench.sh ~/models/model.gguf                          # CPU only
./scripts/cpu-threads-bench.sh ~/models/moe.gguf -- -ngl 99 -ot exps=CPU    # experts on the CPU
```

Which thread setup is fastest for a model on this board, measured with `llama-bench`. It times prompt processing
and generation for:

| Setup | Threads |
| --- | --- |
| `fast` | the fast cores only, one thread pinned to each (what `arm-cpu.sh` suggests) |
| `all` | every core, one thread pinned to each |
| `all-free` | every core, placed by the kernel's scheduler |
| `…+spin` | the same, with threads that wait longer before sleeping between jobs: `GOMP_SPINCOUNT=3000000` (libgomp's default is 300000), or `--poll 100` for a build without OpenMP |

Arguments after `--` go to every run, so the GPU setup you actually use is the one measured. `ROUNDS` (default 2)
and `REPS` (default 3) set how long it takes.

Why measure rather than assume: Llaminar measured on NVIDIA's GB10 (10 fast and 10 slower cores) that every core
beat the fast cores alone by 22.8%, and that the longer spin raised one model's generation from 13.2 to 18.7
tokens/s (`docs/v2/projects/2026-11/arm-perf-review`, ideas 05 and 13, on its `codex/arm-perf-review` branch).
llama.cpp hands out matrix work in small pieces the same way, so the A55 cores can help. But it splits the smaller
operations evenly between threads, an A55 is 3–4× slower than an A76, and RK3588's memory bandwidth may be the
limit anyway. The spin matters most when several CPU jobs run per token, as with partial GPU offload.

The script keeps Llaminar's method: the setups run in order, then in reverse in the next round (A B B A), and the
rounds are averaged, so a board heating up doesn't favour whichever setup ran first. A difference of a few percent
is noise; use `ROUNDS=4` before changing your setup on it.

## `scripts/gpu-parity.sh`

```bash
LLAMA_BIN=~/llama.cpp/build-vulkan/bin ./scripts/gpu-parity.sh       # the operations inference uses
./scripts/gpu-parity.sh --all -b ROCm0                               # everything, one backend
```

It runs llama.cpp's `test-backend-ops`, which executes each operation on the GPU and compares the result with the
CPU: matrix products for every quantization, attention, normalisation, RoPE and the rest.

On RK3588 this is the check that matters most. A missing coherency patch (patches/0001), or a missing
`HSA_USERPTR_FOR_PAGED_MEM=0` for ROCm, lets the GPU read stale data. That produces wrong numbers rather than a
crash, and this run finds them. The exit status says what happened:

| Exit | Meaning |
| --- | --- |
| 0 | every GPU backend matched the CPU |
| 1 | a mismatch; the failing cases are in the kept log |
| 3 | llama.cpp saw no GPU, so nothing was compared |

`test-backend-ops` alone reports success in that last case.

Run it after building, after any kernel or driver change, and before trusting a new quantization type on the card.
