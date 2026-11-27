extern "C" __global__ void vec_add(const float* a, const float* b, float* c) {
    const unsigned int i = blockIdx.x * blockDim.x + threadIdx.x;
    c[i] = a[i] + b[i];
}
