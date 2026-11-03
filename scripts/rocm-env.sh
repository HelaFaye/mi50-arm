# rocm-env.sh - source this (or copy to /etc/profile.d/) after building ROCm.
#   . ./scripts/rocm-env.sh
export ROCM_PATH=${ROCM_PATH:-/opt/rocm}
export HIP_PATH=$ROCM_PATH
export PATH=$ROCM_PATH/bin:$ROCM_PATH/llvm/bin:$PATH
export LD_LIBRARY_PATH=$ROCM_PATH/lib:$ROCM_PATH/llvm/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
export CMAKE_PREFIX_PATH=$ROCM_PATH${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}

# The MI50 *is* gfx906, so HSA_OVERRIDE_GFX_VERSION is not needed (that knob is
# for spoofing unsupported cards as supported ones). Leave it unset.

# Only set these if you hit trouble (see docs/ROCM.md "Troubleshooting"):
# export HSA_ENABLE_SDMA=0        # use shader blits instead of SDMA engines
# export HSA_NO_SCRATCH_RECLAIM=1
# export AMD_LOG_LEVEL=3          # verbose HIP runtime logging
