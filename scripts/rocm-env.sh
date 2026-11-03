# shellcheck shell=sh
# rocm-env.sh - source this (or copy to /etc/profile.d/) after building ROCm.
#   . ./scripts/rocm-env.sh
export ROCM_PATH="${ROCM_PATH:-/opt/rocm}"
export HIP_PATH="$ROCM_PATH"
export HIP_PLATFORM=amd
export PATH="$ROCM_PATH/bin:$ROCM_PATH/llvm/bin:$PATH"
export LD_LIBRARY_PATH="$ROCM_PATH/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export CMAKE_PREFIX_PATH="$ROCM_PATH${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"

# Non-coherent PCIe hosts (RK3588 and similar): by default libhsakmt backs all
# pageable host memory (AQL queues, signals, kernel arguments, hipHostMalloc)
# with *userptr* BOs, i.e. ordinary cached user pages that the GPU cannot see
# coherently. Setting this to 0 makes it allocate GTT BOs from the kernel
# instead, which patches/0001 maps write-combined. Harmless on coherent hosts.
export HSA_USERPTR_FOR_PAGED_MEM=0

# The MI50 *is* gfx906, so HSA_OVERRIDE_GFX_VERSION is not needed (that knob is
# for spoofing unsupported cards as supported ones). Leave it unset.

# Only set these if you hit trouble (see docs/ROCM.md "Troubleshooting"):
# export HSA_DISABLE_CACHE=1      # allocate host memory as GPU-uncached + coherent
# export HSA_ENABLE_SDMA=0        # use shader blits instead of SDMA engines
# export AMD_LOG_LEVEL=3          # verbose HIP runtime logging
