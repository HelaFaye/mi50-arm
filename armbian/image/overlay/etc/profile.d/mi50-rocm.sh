# MI50 ROCm environment for interactive login shells.
export ROCM_PATH=/opt/rocm
export HIP_PATH=/opt/rocm
export HIP_PLATFORM=amd
export HSA_USERPTR_FOR_PAGED_MEM=0
export TORCH_BLAS_PREFER_HIPBLASLT=0
case ":$PATH:" in
  *:/opt/rocm/bin:*) ;;
  *) PATH="/opt/rocm/bin:$PATH" ;;
esac
case ":$PATH:" in
  *:/opt/rocm/llvm/bin:*) ;;
  *) PATH="/opt/rocm/llvm/bin:$PATH" ;;
esac
export PATH
