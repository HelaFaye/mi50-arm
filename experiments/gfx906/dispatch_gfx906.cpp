#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <fstream>
#include <unistd.h>
#include <vector>

#include "gfx9_pm4.hpp"
#include "gfx9_code_object_v5.hpp"

#include <elf.h>
#include <libdrm/amdgpu.h>
#include <libdrm/amdgpu_drm.h>
#include <xf86drm.h>

// GFX9 (Vega 20 / gfx906) SH Register DWORD Offsets
constexpr uint32_t SH_REG_BASE                = 0x2C00;
constexpr uint32_t mmCOMPUTE_NUM_THREAD_X     = 0x2E07;
constexpr uint32_t mmCOMPUTE_NUM_THREAD_Y     = 0x2E08;
constexpr uint32_t mmCOMPUTE_NUM_THREAD_Z     = 0x2E09;
constexpr uint32_t mmCOMPUTE_PGM_LO           = 0x2E0C;
constexpr uint32_t mmCOMPUTE_PGM_HI           = 0x2E0D;
constexpr uint32_t mmCOMPUTE_PGM_RSRC1        = 0x2E12;
constexpr uint32_t mmCOMPUTE_PGM_RSRC2        = 0x2E13;
constexpr uint32_t mmCOMPUTE_RESOURCE_LIMITS  = 0x2E15;
constexpr uint32_t mmCOMPUTE_TMPRING_SIZE     = 0x2E18;
constexpr uint32_t mmCOMPUTE_USER_DATA_0      = 0x2E40;

// PM4 Type-3 Opcodes

// SDMA v4.2 (Vega 20 / gfx906) Opcodes
constexpr uint32_t SDMA_OP_NOP                = 0x0;
constexpr uint32_t SDMA_OP_COPY               = 0x1;
constexpr uint32_t SDMA_SUBOP_COPY_LINEAR     = 0x0;
constexpr size_t   SDMA_MAX_COPY_BYTES        = (1u << 22); // 4 MiB per packet (count = bytes - 1)

// LLVM AMDGPU HSA Kernel Descriptor (64 bytes, Code Object V3/V4/V5)
struct alignas(64) amd_kernel_descriptor_t {
    uint32_t group_segment_fixed_size;
    uint32_t private_segment_fixed_size;
    uint32_t kernarg_size;
    uint8_t  reserved0[4];
    int64_t  kernel_code_entry_byte_offset;
    uint8_t  reserved1[20];
    uint32_t compute_pgm_rsrc3;
    uint32_t compute_pgm_rsrc1;
    uint32_t compute_pgm_rsrc2;
    uint16_t kernel_code_properties;
    uint8_t  reserved2[6];
};

// kernel_code_properties bit masks (LLVM AMDGPUUsage)
enum KernelCodeProps : uint16_t {
    ENABLE_SGPR_PRIVATE_SEGMENT_BUFFER = 1u << 0, // 4 SGPRs
    ENABLE_SGPR_DISPATCH_PTR           = 1u << 1, // 2 SGPRs
    ENABLE_SGPR_QUEUE_PTR              = 1u << 2, // 2 SGPRs
    ENABLE_SGPR_KERNARG_SEGMENT_PTR    = 1u << 3, // 2 SGPRs
    ENABLE_SGPR_DISPATCH_ID            = 1u << 4, // 2 SGPRs
    ENABLE_SGPR_FLAT_SCRATCH_INIT      = 1u << 5, // 2 SGPRs
    ENABLE_SGPR_PRIVATE_SEGMENT_SIZE   = 1u << 6, // 1 SGPR
};

struct GpuBuffer {
    amdgpu_bo_handle bo        = nullptr;
    amdgpu_va_handle va_handle = nullptr;
    uint64_t         gpu_va    = 0;
    void*            cpu_ptr   = nullptr;
    size_t           size      = 0;
};

static inline void arm64_dsb_sy() {
#if defined(__aarch64__)
    asm volatile("dsb sy" ::: "memory");
#else
    __sync_synchronize();
#endif
}

static inline uint32_t sdma_header(uint32_t op, uint32_t sub_op) {
    return ((sub_op & 0xFFu) << 8) | (op & 0xFFu);
}

GpuBuffer alloc_gpu_buf(amdgpu_device_handle dev, size_t size, uint32_t domain,
                        bool cpu_map = false, bool exec = false) {
    GpuBuffer buf{};
    buf.size = (size + 4095) & ~4095ULL;

    struct amdgpu_bo_alloc_request req{};
    req.alloc_size     = buf.size;
    req.phys_alignment = 4096;
    req.preferred_heap = domain;
    if (domain == AMDGPU_GEM_DOMAIN_GTT) {
        req.flags = AMDGPU_GEM_CREATE_CPU_ACCESS_REQUIRED | AMDGPU_GEM_CREATE_CPU_GTT_USWC;
    } else if (cpu_map) {
        req.flags = AMDGPU_GEM_CREATE_CPU_ACCESS_REQUIRED;
    } else {
        // Pure device VRAM without requiring BAR0 CPU visibility
        req.flags = AMDGPU_GEM_CREATE_NO_CPU_ACCESS;
    }

    if (amdgpu_bo_alloc(dev, &req, &buf.bo) != 0) {
        perror("amdgpu_bo_alloc failed");
        std::exit(1);
    }
    if (amdgpu_va_range_alloc(dev, amdgpu_gpu_va_range_general, buf.size, 4096, 0,
                              &buf.gpu_va, &buf.va_handle, 0) != 0) {
        perror("amdgpu_va_range_alloc failed");
        std::exit(1);
    }

    uint64_t vm_flags = AMDGPU_VM_PAGE_READABLE | AMDGPU_VM_PAGE_WRITEABLE |
                        (exec ? AMDGPU_VM_PAGE_EXECUTABLE : 0);
    if (amdgpu_bo_va_op(buf.bo, 0, buf.size, buf.gpu_va, vm_flags, AMDGPU_VA_OP_MAP) != 0) {
        perror("amdgpu_bo_va_op failed");
        std::exit(1);
    }

    if (cpu_map || domain == AMDGPU_GEM_DOMAIN_GTT) {
        if (amdgpu_bo_cpu_map(buf.bo, &buf.cpu_ptr) != 0) {
            perror("amdgpu_bo_cpu_map failed");
            std::exit(1);
        }
    }
    return buf;
}

void free_gpu_buf(GpuBuffer& buf) {
    if (buf.cpu_ptr) {
        amdgpu_bo_cpu_unmap(buf.bo);
    }
    if (buf.va_handle) {
        amdgpu_bo_va_op(buf.bo, 0, buf.size, buf.gpu_va, 0, AMDGPU_VA_OP_UNMAP);
        amdgpu_va_range_free(buf.va_handle);
    }
    if (buf.bo) {
        amdgpu_bo_free(buf.bo);
    }
    buf = {};
}

// Asynchronous/synchronous SDMA v4.2 linear copy over AMDGPU_HW_IP_DMA (bypasses BAR0 limits)
void sdma_copy(amdgpu_device_handle dev, amdgpu_context_handle ctx,
               const GpuBuffer& ib_buf, const GpuBuffer& src, uint64_t src_offset,
               const GpuBuffer& dst, uint64_t dst_offset, size_t bytes) {
    auto* ib = static_cast<uint32_t*>(ib_buf.cpu_ptr);
    uint32_t idx = 0;

    size_t remaining = bytes;
    uint64_t cur_src = src.gpu_va + src_offset;
    uint64_t cur_dst = dst.gpu_va + dst_offset;

    while (remaining > 0) {
        size_t chunk = std::min(remaining, SDMA_MAX_COPY_BYTES);
        if ((idx + 8) * sizeof(uint32_t) > ib_buf.size) {
            fprintf(stderr, "SDMA IB buffer overflow\n");
            std::exit(1);
        }

        // SDMA_PKT_COPY_LINEAR (7 DWORDs on GFX9 / Vega 20)
        ib[idx++] = sdma_header(SDMA_OP_COPY, SDMA_SUBOP_COPY_LINEAR);
        ib[idx++] = static_cast<uint32_t>(chunk - 1); // SDMA v4 encodes byte count as (N - 1)
        ib[idx++] = 0;                                // swizzle / tmz / broadcast = 0
        ib[idx++] = static_cast<uint32_t>(cur_src);
        ib[idx++] = static_cast<uint32_t>(cur_src >> 32);
        ib[idx++] = static_cast<uint32_t>(cur_dst);
        ib[idx++] = static_cast<uint32_t>(cur_dst >> 32);

        cur_src   += chunk;
        cur_dst   += chunk;
        remaining -= chunk;
    }

    // Pad SDMA IB to 8-DWORD boundary with NOPs
    while (idx % 8 != 0) {
        ib[idx++] = sdma_header(SDMA_OP_NOP, 0);
    }

    // Flush ARM64 write-combining buffers for staging data + IB before DMA engine reads them
    arm64_dsb_sy();

    amdgpu_bo_handle handles[] = { src.bo, dst.bo, ib_buf.bo };
    amdgpu_bo_list_handle bo_list;
    if (amdgpu_bo_list_create(dev, 3, handles, nullptr, &bo_list) != 0) {
        perror("amdgpu_bo_list_create (SDMA) failed");
        std::exit(1);
    }

    struct amdgpu_cs_ib_info ib_info{};
    ib_info.ib_mc_address = ib_buf.gpu_va;
    ib_info.size          = idx;

    struct amdgpu_cs_request cs_req{};
    cs_req.ip_type       = AMDGPU_HW_IP_DMA;
    cs_req.ring          = 0;
    cs_req.number_of_ibs = 1;
    cs_req.ibs           = &ib_info;
    cs_req.resources     = bo_list;

    if (amdgpu_cs_submit(ctx, 0, &cs_req, 1) != 0) {
        perror("amdgpu_cs_submit (SDMA) failed");
        std::exit(1);
    }

    struct amdgpu_cs_fence fence{};
    fence.context = ctx;
    fence.ip_type = AMDGPU_HW_IP_DMA;
    fence.ring    = 0;
    fence.fence   = cs_req.seq_no;

    uint32_t expired = 0;
    if (amdgpu_cs_query_fence_status(&fence, AMDGPU_TIMEOUT_INFINITE, 0, &expired) != 0 || !expired) {
        fprintf(stderr, "SDMA fence wait timed out or failed\n");
        std::exit(1);
    }

    amdgpu_bo_list_destroy(bo_list);
    arm64_dsb_sy();
}

// Compute starting USER_DATA SGPR index for kernarg_segment_ptr per LLVM AMDGPU ABI
uint32_t compute_kernarg_user_sgpr(uint16_t props) {
    if (!(props & ENABLE_SGPR_KERNARG_SEGMENT_PTR)) {
        fprintf(stderr, "Kernel descriptor missing ENABLE_SGPR_KERNARG_SEGMENT_PTR (props=0x%x)\n", props);
        std::exit(1);
    }
    uint32_t sgpr = 0;
    if (props & ENABLE_SGPR_PRIVATE_SEGMENT_BUFFER) sgpr += 4;
    if (props & ENABLE_SGPR_DISPATCH_PTR)           sgpr += 2;
    if (props & ENABLE_SGPR_QUEUE_PTR)              sgpr += 2;
    return sgpr;
}

int main() {
    int fd = open("/dev/dri/renderD128", O_RDWR | O_CLOEXEC);
    if (fd < 0) {
        perror("open /dev/dri/renderD128");
        return 1;
    }

    uint32_t major = 0, minor = 0;
    amdgpu_device_handle dev = nullptr;
    if (amdgpu_device_initialize(fd, &major, &minor, &dev) != 0) {
        fprintf(stderr, "amdgpu_device_initialize failed\n");
        return 1;
    }
    printf("Initialized amdgpu DRM %u.%u\n", major, minor);

    amdgpu_context_handle ctx = nullptr;
    if (amdgpu_cs_ctx_create(dev, &ctx) != 0) {
        perror("amdgpu_cs_ctx_create failed");
        return 1;
    }

    GpuBuffer sdma_ib = alloc_gpu_buf(dev, 4096, AMDGPU_GEM_DOMAIN_GTT, true);

    // 1. Read vec_add.hsaco ELF and upload PT_LOAD segments into unmapped VRAM via SDMA
    std::ifstream ifs("vec_add.hsaco", std::ios::binary);
    if (!ifs) {
        fprintf(stderr, "Failed to open vec_add.hsaco\n");
        return 1;
    }
    std::vector<uint8_t> elf((std::istreambuf_iterator<char>(ifs)), {});
    auto* ehdr  = reinterpret_cast<Elf64_Ehdr*>(elf.data());
    auto* phdrs = reinterpret_cast<Elf64_Phdr*>(elf.data() + ehdr->e_phoff);

    uint64_t min_vaddr = UINT64_MAX;
    uint64_t max_vaddr = 0;
    for (int i = 0; i < ehdr->e_phnum; i++) {
        if (phdrs[i].p_type == PT_LOAD) {
            min_vaddr = std::min(min_vaddr, phdrs[i].p_vaddr);
            max_vaddr = std::max(max_vaddr, phdrs[i].p_vaddr + phdrs[i].p_memsz);
        }
    }
    size_t code_span = (max_vaddr - min_vaddr + 4095) & ~4095ULL;

    GpuBuffer code_stage = alloc_gpu_buf(dev, code_span, AMDGPU_GEM_DOMAIN_GTT, true);
    GpuBuffer code_vram  = alloc_gpu_buf(dev, code_span, AMDGPU_GEM_DOMAIN_VRAM, false, true);
    std::memset(code_stage.cpu_ptr, 0, code_span);

    for (int i = 0; i < ehdr->e_phnum; i++) {
        if (phdrs[i].p_type == PT_LOAD) {
            std::memcpy(static_cast<uint8_t*>(code_stage.cpu_ptr) + (phdrs[i].p_vaddr - min_vaddr),
                        elf.data() + phdrs[i].p_offset, phdrs[i].p_filesz);
        }
    }

    // Locate "vec_add.kd" symbol in ELF .dynsym / .symtab
    uint64_t kd_vaddr = 0;
    auto* shdrs = reinterpret_cast<Elf64_Shdr*>(elf.data() + ehdr->e_shoff);
    for (int i = 0; i < ehdr->e_shnum; i++) {
        if (shdrs[i].sh_type == SHT_SYMTAB || shdrs[i].sh_type == SHT_DYNSYM) {
            auto* syms = reinterpret_cast<Elf64_Sym*>(elf.data() + shdrs[i].sh_offset);
            const char* strtab = reinterpret_cast<const char*>(elf.data() + shdrs[shdrs[i].sh_link].sh_offset);
            int count = shdrs[i].sh_size / sizeof(Elf64_Sym);
            for (int s = 0; s < count; s++) {
                if (std::strcmp(strtab + syms[s].st_name, "vec_add.kd") == 0) {
                    kd_vaddr = syms[s].st_value;
                }
            }
        }
    }

    auto* kd = reinterpret_cast<amd_kernel_descriptor_t*>(
        static_cast<uint8_t*>(code_stage.cpu_ptr) + (kd_vaddr - min_vaddr));

    if (kd->private_segment_fixed_size > 0) {
        fprintf(stderr, "Kernel requires %u bytes scratch; allocate scratch BO first.\n",
                kd->private_segment_fixed_size);
        return 1;
    }

    uint32_t kernarg_sgpr = compute_kernarg_user_sgpr(kd->kernel_code_properties);
    uint64_t entry_va     = code_vram.gpu_va + (kd_vaddr - min_vaddr) + kd->kernel_code_entry_byte_offset;

    printf("Loaded vec_add.kd @ 0x%lx | entry @ 0x%lx | RSRC1=0x%x | RSRC2=0x%x | props=0x%x | kernarg_sgpr=USER_DATA_%u..%u\n",
           kd_vaddr, entry_va, kd->compute_pgm_rsrc1, kd->compute_pgm_rsrc2,
           kd->kernel_code_properties, kernarg_sgpr, kernarg_sgpr + 1);

    // DMA the code object from GTT staging into executable VRAM
    sdma_copy(dev, ctx, sdma_ib, code_stage, 0, code_vram, 0, code_span);

    // 2. Allocate GTT staging buffers + unmapped VRAM device buffers
    constexpr size_t N     = 1024;
    constexpr size_t BYTES = N * sizeof(float);

    GpuBuffer stage_a = alloc_gpu_buf(dev, BYTES, AMDGPU_GEM_DOMAIN_GTT, true);
    GpuBuffer stage_b = alloc_gpu_buf(dev, BYTES, AMDGPU_GEM_DOMAIN_GTT, true);
    GpuBuffer stage_c = alloc_gpu_buf(dev, BYTES, AMDGPU_GEM_DOMAIN_GTT, true);

    GpuBuffer dev_a   = alloc_gpu_buf(dev, BYTES, AMDGPU_GEM_DOMAIN_VRAM, false);
    GpuBuffer dev_b   = alloc_gpu_buf(dev, BYTES, AMDGPU_GEM_DOMAIN_VRAM, false);
    GpuBuffer dev_c   = alloc_gpu_buf(dev, BYTES, AMDGPU_GEM_DOMAIN_VRAM, false);

    GpuBuffer kernarg = alloc_gpu_buf(dev, mi50::gfx906::VEC_ADD_KERNARG_CAPACITY,
                                      AMDGPU_GEM_DOMAIN_GTT, true);
    GpuBuffer comp_ib = alloc_gpu_buf(dev, 4096, AMDGPU_GEM_DOMAIN_GTT, true);

    auto* host_a = static_cast<float*>(stage_a.cpu_ptr);
    auto* host_b = static_cast<float*>(stage_b.cpu_ptr);
    auto* host_c = static_cast<float*>(stage_c.cpu_ptr);
    for (size_t i = 0; i < N; i++) {
        host_a[i] = static_cast<float>(i);
        host_b[i] = static_cast<float>(i * 2);
        host_c[i] = -1.0f;
    }

    // HtoD via SDMA
    sdma_copy(dev, ctx, sdma_ib, stage_a, 0, dev_a, 0, BYTES);
    sdma_copy(dev, ctx, sdma_ib, stage_b, 0, dev_b, 0, BYTES);
    sdma_copy(dev, ctx, sdma_ib, stage_c, 0, dev_c, 0, BYTES);

    // Populate the three explicit pointer args first.
    std::memset(kernarg.cpu_ptr, 0, mi50::gfx906::VEC_ADD_KERNARG_CAPACITY);
    auto* kargs = static_cast<uint64_t*>(kernarg.cpu_ptr);
    kargs[0] = dev_a.gpu_va;
    kargs[1] = dev_b.gpu_va;
    kargs[2] = dev_c.gpu_va;

    // ROCm 6.3.3 emits this kernel as AMDGPU Code Object V5. Its implicit
    // block_count/group_size fields immediately follow the 3 explicit pointers
    // at byte offset 24; the kernel's blockDim.x query reads group_size_x here.
    if (!mi50::gfx906::populate_vec_add_code_object_v5_implicit_args(
            kernarg.cpu_ptr, mi50::gfx906::VEC_ADD_KERNARG_CAPACITY,
            kd->kernarg_size, static_cast<uint32_t>(N / 64u), 64u)) {
        fprintf(stderr,
                "Unsupported vec_add kernarg layout: descriptor kernarg_size=%u, "
                "required=%zu, capacity=%zu\n",
                kd->kernarg_size,
                mi50::gfx906::VEC_ADD_KERNARG_REQUIRED_BYTES,
                mi50::gfx906::VEC_ADD_KERNARG_CAPACITY);
        return 1;
    }

    // 3. Build PM4 Indirect Buffer for Compute Ring
    auto* ib = static_cast<uint32_t*>(comp_ib.cpu_ptr);
    uint32_t idx = 0;

    // Shader entry point (256-byte aligned -> >> 8)
    ib[idx++] = mi50::gfx906::pm4_type3(mi50::gfx906::PKT3_SET_SH_REG, 3);
    ib[idx++] = mmCOMPUTE_PGM_LO - SH_REG_BASE;
    ib[idx++] = static_cast<uint32_t>(entry_va >> 8);
    ib[idx++] = static_cast<uint32_t>(entry_va >> 40);

    // RSRC1 & RSRC2 from kernel descriptor
    ib[idx++] = mi50::gfx906::pm4_type3(mi50::gfx906::PKT3_SET_SH_REG, 3);
    ib[idx++] = mmCOMPUTE_PGM_RSRC1 - SH_REG_BASE;
    ib[idx++] = kd->compute_pgm_rsrc1;
    ib[idx++] = kd->compute_pgm_rsrc2;

    // Explicitly zero TMPRING_SIZE (no scratch ring active)
    ib[idx++] = mi50::gfx906::pm4_type3(mi50::gfx906::PKT3_SET_SH_REG, 2);
    ib[idx++] = mmCOMPUTE_TMPRING_SIZE - SH_REG_BASE;
    ib[idx++] = 0;

    // Workgroup dimensions (64 x 1 x 1)
    ib[idx++] = mi50::gfx906::pm4_type3(mi50::gfx906::PKT3_SET_SH_REG, 4);
    ib[idx++] = mmCOMPUTE_NUM_THREAD_X - SH_REG_BASE;
    ib[idx++] = 64;
    ib[idx++] = 1;
    ib[idx++] = 1;

    // Dynamic kernarg pointer placement in USER_DATA SGPRs
    ib[idx++] = mi50::gfx906::pm4_type3(mi50::gfx906::PKT3_SET_SH_REG, 3);
    ib[idx++] = (mmCOMPUTE_USER_DATA_0 + kernarg_sgpr) - SH_REG_BASE;
    ib[idx++] = static_cast<uint32_t>(kernarg.gpu_va);
    ib[idx++] = static_cast<uint32_t>(kernarg.gpu_va >> 32);

    // Dispatch 16 workgroups * 64 threads = 1024 threads (Wave64)
    ib[idx++] = mi50::gfx906::pm4_type3(mi50::gfx906::PKT3_DISPATCH_DIRECT, 4);
    ib[idx++] = N / 64;
    ib[idx++] = 1;
    ib[idx++] = 1;
    ib[idx++] = 0x1; // COMPUTE_SHADER_EN = 1

    // Write-back and invalidate L1/L2 caches to HBM2
    ib[idx++] = mi50::gfx906::pm4_type3(mi50::gfx906::PKT3_ACQUIRE_MEM, 6);
    ib[idx++] = mi50::gfx906::ACQUIRE_MEM_CACHE_WRITEBACK_INVALIDATE; // L1/L2 writeback + invalidate
    ib[idx++] = 0xFFFFFFFF;
    ib[idx++] = 0xFF;
    ib[idx++] = 0;
    ib[idx++] = 0;
    ib[idx++] = 10;

    // Flush ARM64 write-combining buffers for kernarg + compute IB
    arm64_dsb_sy();

    // 4. Submit Compute IB
    amdgpu_bo_handle comp_handles[] = {
        code_vram.bo, dev_a.bo, dev_b.bo, dev_c.bo, kernarg.bo, comp_ib.bo
    };
    amdgpu_bo_list_handle comp_bo_list;
    if (amdgpu_bo_list_create(dev, 6, comp_handles, nullptr, &comp_bo_list) != 0) {
        perror("amdgpu_bo_list_create (Compute) failed");
        return 1;
    }

    struct amdgpu_cs_ib_info ib_info{};
    ib_info.ib_mc_address = comp_ib.gpu_va;
    ib_info.size          = idx;

    struct amdgpu_cs_request cs_req{};
    cs_req.ip_type       = AMDGPU_HW_IP_COMPUTE;
    cs_req.ring          = 0;
    cs_req.number_of_ibs = 1;
    cs_req.ibs           = &ib_info;
    cs_req.resources     = comp_bo_list;

    if (amdgpu_cs_submit(ctx, 0, &cs_req, 1) != 0) {
        perror("amdgpu_cs_submit (Compute) failed");
        return 1;
    }

    struct amdgpu_cs_fence fence{};
    fence.context = ctx;
    fence.ip_type = AMDGPU_HW_IP_COMPUTE;
    fence.ring    = 0;
    fence.fence   = cs_req.seq_no;

    uint32_t expired = 0;
    if (amdgpu_cs_query_fence_status(&fence, AMDGPU_TIMEOUT_INFINITE, 0, &expired) != 0 || !expired) {
        fprintf(stderr, "Compute fence wait timed out or failed\n");
        return 1;
    }
    amdgpu_bo_list_destroy(comp_bo_list);

    // 5. DtoH via SDMA and verify
    sdma_copy(dev, ctx, sdma_ib, dev_c, 0, stage_c, 0, BYTES);

    int errors = 0;
    for (size_t i = 0; i < N; i++) {
        float expected = static_cast<float>(i) + static_cast<float>(i * 2);
        if (host_c[i] != expected) {
            if (errors++ < 5) {
                printf("Mismatch at %zu: got %f, expected %f\n", i, host_c[i], expected);
            }
        }
    }

    if (errors == 0) {
        printf("SUCCESS! All %zu elements computed in VRAM on gfx906 via SDMA + PM4.\n", N);
    } else {
        printf("FAILED with %d errors.\n", errors);
    }

    free_gpu_buf(comp_ib);
    free_gpu_buf(kernarg);
    free_gpu_buf(dev_c);
    free_gpu_buf(dev_b);
    free_gpu_buf(dev_a);
    free_gpu_buf(stage_c);
    free_gpu_buf(stage_b);
    free_gpu_buf(stage_a);
    free_gpu_buf(code_vram);
    free_gpu_buf(code_stage);
    free_gpu_buf(sdma_ib);

    amdgpu_cs_ctx_free(ctx);
    amdgpu_device_deinitialize(dev);
    close(fd);
    return errors != 0;
}