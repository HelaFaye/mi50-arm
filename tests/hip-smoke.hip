// HIP smoke test for an MI50 (gfx906). Exits non-zero on any failure.
//   . scripts/rocm-env.sh
//   hipcc --offload-arch=gfx906 tests/hip-smoke.hip -o /tmp/hip-smoke && /tmp/hip-smoke
#include <hip/hip_runtime.h>
#include <cstdio>
#include <cstdlib>

#define CHECK(x) do { hipError_t e = (x); if (e != hipSuccess) { \
  std::fprintf(stderr, "FAIL %s: %s\n", #x, hipGetErrorString(e)); std::exit(1); } } while (0)

__global__ void fill(int *p, int n) {
  int i = blockIdx.x * blockDim.x + threadIdx.x;
  if (i < n) p[i] = i * 2;
}

int main() {
  int ndev = 0;
  CHECK(hipGetDeviceCount(&ndev));
  hipDeviceProp_t prop;
  CHECK(hipGetDeviceProperties(&prop, 0));
  std::printf("device 0: %s (%s), %zu MiB\n", prop.name, prop.gcnArchName, prop.totalGlobalMem >> 20);

  const int n = 1 << 20;
  int *d = nullptr, *h = static_cast<int *>(std::malloc(n * sizeof(int)));
  CHECK(hipMalloc(&d, n * sizeof(int)));
  fill<<<(n + 255) / 256, 256>>>(d, n);
  CHECK(hipGetLastError());
  CHECK(hipMemcpy(h, d, n * sizeof(int), hipMemcpyDeviceToHost));
  for (int i = 0; i < n; ++i)
    if (h[i] != i * 2) { std::fprintf(stderr, "FAIL: h[%d] = %d, want %d\n", i, h[i], i * 2); return 1; }
  std::printf("PASS: %d values round-tripped through the GPU\n", n);
  CHECK(hipFree(d));
  std::free(h);
  return 0;
}
