#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <elf.h>
#include <fcntl.h>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unistd.h>
#include <unordered_map>
#include <vector>

#include <libdrm/amdgpu.h>
#include <libdrm/amdgpu_drm.h>
#include <xf86drm.h>

#include "gfx9_pm4.hpp"

// ============================================================================
// Standard HSA / ROCR ABI Types & Constants (hsa.h / hsa_ext_amd.h)
// ============================================================================
extern "C" {

typedef int hsa_status_t;
enum {
    HSA_STATUS_SUCCESS                      = 0x0,
    HSA_STATUS_INFO_BREAK                   = 0x1,
    HSA_STATUS_ERROR                        = 0x1000,
    HSA_STATUS_ERROR_INVALID_ARGUMENT       = 0x1001,
    HSA_STATUS_ERROR_INVALID_QUEUE_CREATION = 0x1002,
    HSA_STATUS_ERROR_INVALID_ALLOCATION     = 0x1003,
    HSA_STATUS_ERROR_INVALID_AGENT          = 0x1004,
    HSA_STATUS_ERROR_INVALID_ISA            = 0x1008,
    HSA_STATUS_ERROR_OUT_OF_RESOURCES       = 0x100E,
    HSA_STATUS_ERROR_NOT_INITIALIZED        = 0x100F,
    HSA_STATUS_ERROR_INVALID_SYMBOL_NAME    = 0x1016,
};

typedef struct { uint64_t handle; } hsa_agent_t;
typedef struct { uint64_t handle; } hsa_signal_t;
typedef struct { uint64_t handle; } hsa_isa_t;
typedef struct { uint64_t handle; } hsa_amd_memory_pool_t;
typedef struct { uint64_t handle; } hsa_code_object_reader_t;
typedef struct { uint64_t handle; } hsa_executable_t;
typedef struct { uint64_t handle; } hsa_executable_symbol_t;
typedef struct { uint64_t handle; } hsa_region_t;
typedef enum { HSA_PROFILE_BASE = 0, HSA_PROFILE_FULL = 1 } hsa_profile_t;
typedef enum {
    HSA_DEFAULT_FLOAT_ROUNDING_MODE_DEFAULT = 0,
    HSA_DEFAULT_FLOAT_ROUNDING_MODE_ZERO = 1,
    HSA_DEFAULT_FLOAT_ROUNDING_MODE_NEAR = 2,
} hsa_default_float_rounding_mode_t;

typedef int64_t hsa_signal_value_t;

typedef enum {
    HSA_SIGNAL_CONDITION_EQ = 0,
    HSA_SIGNAL_CONDITION_NE = 1,
    HSA_SIGNAL_CONDITION_LT = 2,
    HSA_SIGNAL_CONDITION_GTE = 3,
} hsa_signal_condition_t;

typedef enum {
    HSA_WAIT_STATE_BLOCKED = 0,
    HSA_WAIT_STATE_ACTIVE  = 1,
} hsa_wait_state_t;

typedef enum {
    HSA_DEVICE_TYPE_CPU = 0,
    HSA_DEVICE_TYPE_GPU = 1,
} hsa_device_type_t;

typedef enum {
    HSA_QUEUE_TYPE_MULTI  = 0,
    HSA_QUEUE_TYPE_SINGLE = 1,
} hsa_queue_type32_t;

typedef enum {
    HSA_PACKET_TYPE_VENDOR_SPECIFIC = 0,
    HSA_PACKET_TYPE_INVALID         = 1,
    HSA_PACKET_TYPE_KERNEL_DISPATCH = 2,
    HSA_PACKET_TYPE_BARRIER_AND     = 3,
    HSA_PACKET_TYPE_AGENT_DISPATCH  = 4,
    HSA_PACKET_TYPE_BARRIER_OR      = 5,
} hsa_packet_type_t;

typedef struct {
    hsa_queue_type32_t type;
    uint32_t           features;
    void*              base_address;
    hsa_signal_t       doorbell_signal;
    uint32_t           size;
    uint32_t           reserved1;
    uint64_t           id;
} hsa_queue_t;

typedef struct {
    uint16_t     header;
    uint16_t     setup;
    uint16_t     workgroup_size_x;
    uint16_t     workgroup_size_y;
    uint16_t     workgroup_size_z;
    uint16_t     reserved0;
    uint32_t     grid_size_x;
    uint32_t     grid_size_y;
    uint32_t     grid_size_z;
    uint32_t     private_segment_size;
    uint32_t     group_segment_size;
    uint64_t     kernel_object;
    void*        kernarg_address;
    uint64_t     reserved2;
    hsa_signal_t completion_signal;
} hsa_kernel_dispatch_packet_t;

typedef struct {
    uint16_t     header;
    uint16_t     reserved0[3];
    hsa_signal_t dep_signal[5];
    uint64_t     reserved1;
    hsa_signal_t completion_signal;
} hsa_barrier_packet_t;

} // extern "C"

// ============================================================================
// GFX9 (Vega 20 / gfx906) Hardware & ELF Constants
// ============================================================================
namespace {

constexpr uint32_t SH_REG_BASE               = 0x2C00;
constexpr uint32_t mmCOMPUTE_NUM_THREAD_X    = 0x2E07;
constexpr uint32_t mmCOMPUTE_NUM_THREAD_Y    = 0x2E08;
constexpr uint32_t mmCOMPUTE_NUM_THREAD_Z    = 0x2E09;
constexpr uint32_t mmCOMPUTE_PGM_LO          = 0x2E0C;
constexpr uint32_t mmCOMPUTE_PGM_HI          = 0x2E0D;
constexpr uint32_t mmCOMPUTE_PGM_RSRC1       = 0x2E12;
constexpr uint32_t mmCOMPUTE_PGM_RSRC2       = 0x2E13;
constexpr uint32_t mmCOMPUTE_RESOURCE_LIMITS = 0x2E15;
constexpr uint32_t mmCOMPUTE_TMPRING_SIZE    = 0x2E18;
constexpr uint32_t mmCOMPUTE_USER_DATA_0     = 0x2E40;


constexpr uint32_t SDMA_OP_NOP               = 0x0;
constexpr uint32_t SDMA_OP_COPY              = 0x1;
constexpr uint32_t SDMA_SUBOP_COPY_LINEAR    = 0x0;
constexpr size_t   SDMA_MAX_COPY_BYTES       = (1u << 22); // 4 MiB

// AMDGPU ELF Relocations (LLVM AMDGPUUsage)
constexpr uint32_t R_AMDGPU_NONE             = 0;
constexpr uint32_t R_AMDGPU_ABS32_LO         = 1;
constexpr uint32_t R_AMDGPU_ABS32_HI         = 2;
constexpr uint32_t R_AMDGPU_ABS64            = 3;
constexpr uint32_t R_AMDGPU_REL32            = 4;
constexpr uint32_t R_AMDGPU_REL64            = 5;
constexpr uint32_t R_AMDGPU_ABS32            = 6;
constexpr uint32_t R_AMDGPU_GOTPCREL         = 7;
constexpr uint32_t R_AMDGPU_GOTPCREL32_LO    = 8;
constexpr uint32_t R_AMDGPU_GOTPCREL32_HI    = 9;
constexpr uint32_t R_AMDGPU_REL32_LO         = 10;
constexpr uint32_t R_AMDGPU_REL32_HI         = 11;

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

enum KernelCodeProps : uint16_t {
    ENABLE_SGPR_PRIVATE_SEGMENT_BUFFER = 1u << 0, // 4 SGPRs
    ENABLE_SGPR_DISPATCH_PTR           = 1u << 1, // 2 SGPRs
    ENABLE_SGPR_QUEUE_PTR              = 1u << 2, // 2 SGPRs
    ENABLE_SGPR_KERNARG_SEGMENT_PTR    = 1u << 3, // 2 SGPRs
    ENABLE_SGPR_DISPATCH_ID            = 1u << 4, // 2 SGPRs
    ENABLE_SGPR_FLAT_SCRATCH_INIT      = 1u << 5, // 2 SGPRs
    ENABLE_SGPR_PRIVATE_SEGMENT_SIZE   = 1u << 6, // 1 SGPR
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

// ============================================================================
// Internal Runtime Structures
// ============================================================================
struct BufferRecord {
    amdgpu_bo_handle bo        = nullptr;
    amdgpu_va_handle va_handle = nullptr;
    uint64_t         gpu_va    = 0;
    void*            cpu_ptr   = nullptr;
    size_t           size      = 0;
    uint32_t         domain    = 0;
};

struct SignalRecord {
    std::atomic<int64_t> value{0};
    std::mutex           fence_mtx;
    bool                 has_fence = false;
    amdgpu_cs_fence      fence{};
    uint64_t             owner_queue_id = 0; // non-zero if this is a queue doorbell
};

struct KernelSymbolRecord {
    std::string name;
    uint64_t    descriptor_va = 0;
    uint64_t    entry_va      = 0;
    uint32_t    kernarg_size  = 0;
    uint32_t    group_size    = 0;
    uint32_t    private_size  = 0;
    uint32_t    rsrc1         = 0;
    uint32_t    rsrc2         = 0;
    uint16_t    code_props    = 0;
};

struct QueueRecord {
    hsa_queue_t           public_queue{};
    std::atomic<uint64_t> read_index{0};
    std::atomic<uint64_t> write_index{0};
    std::mutex            submit_mtx;
    BufferRecord          ring_bo;
    BufferRecord          ib_bo;
    BufferRecord          scratch_bo;
    uint32_t              scratch_bytes_per_wave = 0;
    amdgpu_cs_fence       ib_fence{};
    bool                  ib_in_flight = false; // q->ib_bo may not be overwritten before this retires
};

struct CodeObjectBlob {
    std::vector<uint8_t> bytes;
};

struct ExecutableRecord {
    std::vector<BufferRecord>                              code_bos;
    std::unordered_map<std::string, KernelSymbolRecord>    symbols_by_name;
    std::unordered_map<uint64_t, KernelSymbolRecord>       symbols_by_kd_va;
};

constexpr uint64_t HANDLE_CPU_AGENT  = 0x1001;
constexpr uint64_t HANDLE_GPU_AGENT  = 0x1002;
constexpr uint64_t HANDLE_GPU_ISA    = 0x2001;
constexpr uint64_t HANDLE_POOL_VRAM  = 0x3001;
constexpr uint64_t HANDLE_POOL_GTT   = 0x3002;

struct ShimState {
    std::mutex                                          mtx;
    int                                                 ref_count = 0;
    int                                                 drm_fd    = -1;
    amdgpu_device_handle                                dev       = nullptr;
    amdgpu_context_handle                               comp_ctx  = nullptr;
    amdgpu_context_handle                               dma_ctx   = nullptr;
    amdgpu_gpu_info                                     gpu_info{};
    uint64_t                                            vram_size = 32ULL * 1024 * 1024 * 1024;
    uint64_t                                            vis_vram  = 0;
    bool                                                full_rebar = false;

    // Slab registry for fast BO list creation
    std::unordered_map<uint64_t, BufferRecord>          buffers; // keyed by gpu_va
    std::vector<amdgpu_bo_handle>                       cached_bo_handles;
    amdgpu_bo_list_handle                               cached_bo_list = nullptr;
    bool                                                bo_list_dirty  = true;

    // Dedicated SDMA staging ring & IB
    BufferRecord                                        sdma_ib;
    BufferRecord                                        sdma_stage;
    std::mutex                                          sdma_mtx;

    std::unordered_map<uint64_t, SignalRecord*>         signals;
    std::unordered_map<uint64_t, QueueRecord*>          queues;
    std::unordered_map<uint64_t, CodeObjectBlob*>       readers;
    std::unordered_map<uint64_t, ExecutableRecord*>     executables;
    uint64_t                                            next_id = 0x10000;
};

ShimState g_state;

// ============================================================================
// Buffer Allocation & Residency Management
// ============================================================================
bool alloc_bo_internal(size_t req_size, uint32_t domain, bool cpu_map, bool exec,
                       bool track_global, BufferRecord& out) {
    size_t aligned = (req_size + 4095) & ~4095ULL;
    if (aligned == 0) aligned = 4096;

    struct amdgpu_bo_alloc_request req{};
    req.alloc_size     = aligned;
    req.phys_alignment = 4096;
    req.preferred_heap = domain;

    if (domain == AMDGPU_GEM_DOMAIN_GTT) {
        req.flags = AMDGPU_GEM_CREATE_CPU_ACCESS_REQUIRED | AMDGPU_GEM_CREATE_CPU_GTT_USWC;
    } else if (cpu_map || g_state.full_rebar) {
        req.flags = AMDGPU_GEM_CREATE_CPU_ACCESS_REQUIRED;
    } else {
        req.flags = AMDGPU_GEM_CREATE_NO_CPU_ACCESS;
    }

    if (amdgpu_bo_alloc(g_state.dev, &req, &out.bo) != 0) {
        return false;
    }
    if (amdgpu_va_range_alloc(g_state.dev, amdgpu_gpu_va_range_general, aligned, 4096, 0,
                              &out.gpu_va, &out.va_handle, 0) != 0) {
        amdgpu_bo_free(out.bo);
        return false;
    }

    uint64_t vm_flags = AMDGPU_VM_PAGE_READABLE | AMDGPU_VM_PAGE_WRITEABLE |
                        (exec ? AMDGPU_VM_PAGE_EXECUTABLE : 0);
    if (amdgpu_bo_va_op(out.bo, 0, aligned, out.gpu_va, vm_flags, AMDGPU_VA_OP_MAP) != 0) {
        amdgpu_va_range_free(out.va_handle);
        amdgpu_bo_free(out.bo);
        return false;
    }

    if (domain == AMDGPU_GEM_DOMAIN_GTT || cpu_map || g_state.full_rebar) {
        if (amdgpu_bo_cpu_map(out.bo, &out.cpu_ptr) != 0 || out.cpu_ptr == nullptr) {
            amdgpu_bo_va_op(out.bo, 0, aligned, out.gpu_va, 0, AMDGPU_VA_OP_UNMAP);
            amdgpu_va_range_free(out.va_handle);
            amdgpu_bo_free(out.bo);
            out = {};
            return false;
        }
    }

    out.size   = aligned;
    out.domain = domain;

    if (track_global) {
        std::lock_guard<std::mutex> lk(g_state.mtx);
        g_state.buffers[out.gpu_va] = out;
        g_state.bo_list_dirty = true;
    }
    return true;
}

void free_bo_internal(BufferRecord& buf, bool track_global) {
    if (track_global) {
        std::lock_guard<std::mutex> lk(g_state.mtx);
        g_state.buffers.erase(buf.gpu_va);
        g_state.bo_list_dirty = true;
    }
    if (buf.cpu_ptr) amdgpu_bo_cpu_unmap(buf.bo);
    if (buf.va_handle) {
        amdgpu_bo_va_op(buf.bo, 0, buf.size, buf.gpu_va, 0, AMDGPU_VA_OP_UNMAP);
        amdgpu_va_range_free(buf.va_handle);
    }
    if (buf.bo) amdgpu_bo_free(buf.bo);
    buf = {};
}

bool find_buffer_containing(uint64_t ptr, BufferRecord& out, uint64_t& offset) {
    std::lock_guard<std::mutex> lk(g_state.mtx);
    for (const auto& kv : g_state.buffers) {
        const BufferRecord& b = kv.second;
        if (ptr >= b.gpu_va && ptr < b.gpu_va + b.size) {
            out    = b;
            offset = ptr - b.gpu_va;
            return true;
        }
    }
    return false;
}

// HSA fine-grained/kernarg allocations returned to the host must be CPU
// pointers, while PM4 USER_DATA registers require the corresponding GPU VA.
bool find_buffer_by_cpu_ptr(const void* ptr, BufferRecord& out, uint64_t& offset) {
    if (ptr == nullptr) return false;
    const uintptr_t address = reinterpret_cast<uintptr_t>(ptr);
    std::lock_guard<std::mutex> lk(g_state.mtx);
    for (const auto& kv : g_state.buffers) {
        const BufferRecord& b = kv.second;
        if (b.cpu_ptr == nullptr) continue;
        const uintptr_t base = reinterpret_cast<uintptr_t>(b.cpu_ptr);
        if (address >= base && address - base < b.size) {
            out = b;
            offset = static_cast<uint64_t>(address - base);
            return true;
        }
    }
    return false;
}

// Resolve either the CPU mapping returned for GTT allocations or a GPU VA
// returned for device allocations. The output offset is always relative to
// the underlying BO, so SDMA can use its GPU VA in either case.
bool find_buffer_for_pointer(const void* ptr, BufferRecord& out, uint64_t& offset) {
    if (find_buffer_by_cpu_ptr(ptr, out, offset)) return true;
    return find_buffer_containing(reinterpret_cast<uint64_t>(ptr), out, offset);
}

amdgpu_bo_list_handle get_global_bo_list() {
    std::lock_guard<std::mutex> lk(g_state.mtx);
    if (!g_state.bo_list_dirty && g_state.cached_bo_list) {
        return g_state.cached_bo_list;
    }
    if (g_state.cached_bo_list) {
        amdgpu_bo_list_destroy(g_state.cached_bo_list);
        g_state.cached_bo_list = nullptr;
    }
    g_state.cached_bo_handles.clear();
    g_state.cached_bo_handles.reserve(g_state.buffers.size());
    for (const auto& kv : g_state.buffers) {
        g_state.cached_bo_handles.push_back(kv.second.bo);
    }
    if (!g_state.cached_bo_handles.empty()) {
        amdgpu_bo_list_create(g_state.dev,
                              static_cast<uint32_t>(g_state.cached_bo_handles.size()),
                              g_state.cached_bo_handles.data(), nullptr,
                              &g_state.cached_bo_list);
    }
    g_state.bo_list_dirty = false;
    return g_state.cached_bo_list;
}

// ============================================================================
// SDMA v4.2 Linear Copy Engine (AMDGPU_HW_IP_DMA)
// ============================================================================
bool sdma_linear_copy(amdgpu_bo_handle src_bo, uint64_t src_va,
                      amdgpu_bo_handle dst_bo, uint64_t dst_va, size_t bytes) {
    if (bytes == 0) return true;
    std::lock_guard<std::mutex> lk(g_state.sdma_mtx);

    auto* ib = static_cast<uint32_t*>(g_state.sdma_ib.cpu_ptr);
    uint32_t idx = 0;
    size_t remaining = bytes;
    uint64_t cur_src = src_va;
    uint64_t cur_dst = dst_va;

    while (remaining > 0) {
        size_t chunk = std::min(remaining, SDMA_MAX_COPY_BYTES);
        if ((idx + 8) * sizeof(uint32_t) > g_state.sdma_ib.size) {
            return false;
        }
        ib[idx++] = sdma_header(SDMA_OP_COPY, SDMA_SUBOP_COPY_LINEAR);
        ib[idx++] = static_cast<uint32_t>(chunk - 1);
        ib[idx++] = 0;
        ib[idx++] = static_cast<uint32_t>(cur_src);
        ib[idx++] = static_cast<uint32_t>(cur_src >> 32);
        ib[idx++] = static_cast<uint32_t>(cur_dst);
        ib[idx++] = static_cast<uint32_t>(cur_dst >> 32);

        cur_src   += chunk;
        cur_dst   += chunk;
        remaining -= chunk;
    }

    while (idx % 8 != 0) {
        ib[idx++] = sdma_header(SDMA_OP_NOP, 0);
    }

    arm64_dsb_sy();

    amdgpu_bo_handle handles[3] = { src_bo, dst_bo, g_state.sdma_ib.bo };
    uint32_t num_handles = (src_bo == dst_bo) ? 2 : 3;
    if (src_bo == dst_bo) handles[1] = g_state.sdma_ib.bo;

    amdgpu_bo_list_handle bo_list;
    if (amdgpu_bo_list_create(g_state.dev, num_handles, handles, nullptr, &bo_list) != 0) {
        return false;
    }

    struct amdgpu_cs_ib_info ib_info{};
    ib_info.ib_mc_address = g_state.sdma_ib.gpu_va;
    ib_info.size          = idx;

    struct amdgpu_cs_request cs_req{};
    cs_req.ip_type       = AMDGPU_HW_IP_DMA;
    cs_req.ring          = 0;
    cs_req.number_of_ibs = 1;
    cs_req.ibs           = &ib_info;
    cs_req.resources     = bo_list;

    int rc = amdgpu_cs_submit(g_state.dma_ctx, 0, &cs_req, 1);
    if (rc == 0) {
        struct amdgpu_cs_fence fence{};
        fence.context = g_state.dma_ctx;
        fence.ip_type = AMDGPU_HW_IP_DMA;
        fence.ring    = 0;
        fence.fence   = cs_req.seq_no;
        uint32_t expired = 0;
        amdgpu_cs_query_fence_status(&fence, AMDGPU_TIMEOUT_INFINITE, 0, &expired);
    }

    amdgpu_bo_list_destroy(bo_list);
    arm64_dsb_sy();
    return rc == 0;
}

// ============================================================================
// Queue Scratch Configuration & PM4 Compute Dispatch
// ============================================================================
bool ensure_queue_scratch(QueueRecord* q, uint32_t private_bytes_per_lane) {
    if (private_bytes_per_lane == 0) return true;
    // Align per-wave scratch to 1024-byte granularity (Wave64)
    uint32_t wave_scratch = ((private_bytes_per_lane * 64) + 1023) & ~1023u;
    if (wave_scratch <= q->scratch_bytes_per_wave && q->scratch_bo.bo != nullptr) {
        return true;
    }

    if (q->scratch_bo.bo) {
        free_bo_internal(q->scratch_bo, true);
    }

    // 60 CUs on MI50 * 40 waves/CU max = 2400 waves
    uint32_t total_waves = 60 * 40;
    size_t total_bytes   = static_cast<size_t>(total_waves) * wave_scratch;
    if (!alloc_bo_internal(total_bytes, AMDGPU_GEM_DOMAIN_VRAM, false, false, true, q->scratch_bo)) {
        return false;
    }
    q->scratch_bytes_per_wave = wave_scratch;
    return true;
}

uint32_t compute_kernarg_sgpr_offset(uint16_t props) {
    uint32_t sgpr = 0;
    if (props & ENABLE_SGPR_PRIVATE_SEGMENT_BUFFER) sgpr += 4;
    if (props & ENABLE_SGPR_DISPATCH_PTR)           sgpr += 2;
    if (props & ENABLE_SGPR_QUEUE_PTR)              sgpr += 2;
    return sgpr;
}

bool wait_queue_ib_idle(QueueRecord* q) {
    if (!q || !q->ib_in_flight) return true;
    uint32_t expired = 0;
    const int rc = amdgpu_cs_query_fence_status(
        &q->ib_fence, AMDGPU_TIMEOUT_INFINITE, 0, &expired);
    if (rc != 0 || !expired) {
        fprintf(stderr, "[hsa-shim] could not retire the previous queue IB (rc=%d)\n", rc);
        return false;
    }
    q->ib_in_flight = false;
    arm64_dsb_sy();
    return true;
}

// Retire a GPU completion fence at most once. The mutex protects the fence
// object and has_fence from concurrent host polling and queue submission.
bool retire_signal_fence(SignalRecord* sig, uint64_t timeout_ns) {
    if (!sig) return false;
    std::lock_guard<std::mutex> lk(sig->fence_mtx);
    if (!sig->has_fence) return true;

    uint32_t expired = 0;
    const int rc = amdgpu_cs_query_fence_status(&sig->fence, timeout_ns, 0, &expired);
    if (rc == 0 && expired) {
        sig->has_fence = false;
        sig->value.fetch_sub(1, std::memory_order_acq_rel);
        arm64_dsb_sy();
        return true;
    }
    return false;
}

void wait_signal_blocking(SignalRecord* sig) {
    (void)retire_signal_fence(sig, AMDGPU_TIMEOUT_INFINITE);
}

bool dispatch_kernel_packet(QueueRecord* q, const hsa_kernel_dispatch_packet_t* pkt) {
    KernelSymbolRecord sym{};
    {
        std::lock_guard<std::mutex> lk(g_state.mtx);
        for (const auto& kv : g_state.executables) {
            auto it = kv.second->symbols_by_kd_va.find(pkt->kernel_object);
            if (it != kv.second->symbols_by_kd_va.end()) {
                sym = it->second;
                break;
            }
        }
    }
    if (sym.entry_va == 0) {
        fprintf(stderr, "[hsa-shim] Unknown kernel_object VA 0x%lx\n", pkt->kernel_object);
        return false;
    }

    // This shim does not yet materialize the HSA dispatch/queue pointer or
    // dispatch-id ABI objects in GPU-visible memory. Do not launch a kernel
    // whose descriptor says it will dereference those hidden arguments.
    constexpr uint16_t unsupported_sgprs = ENABLE_SGPR_DISPATCH_PTR |
        ENABLE_SGPR_QUEUE_PTR | ENABLE_SGPR_DISPATCH_ID |
        ENABLE_SGPR_FLAT_SCRATCH_INIT | ENABLE_SGPR_PRIVATE_SEGMENT_SIZE;
    if ((sym.code_props & unsupported_sgprs) != 0) {
        fprintf(stderr, "[hsa-shim] unsupported hidden SGPR properties 0x%x for %s\n",
                sym.code_props & unsupported_sgprs, sym.name.c_str());
        return false;
    }

    if (!wait_queue_ib_idle(q)) return false;

    uint32_t priv_size = std::max(sym.private_size, pkt->private_segment_size);
    if (priv_size > 0 && !ensure_queue_scratch(q, priv_size)) {
        fprintf(stderr, "[hsa-shim] Failed to allocate scratch VRAM (%u B/lane)\n", priv_size);
        return false;
    }

    auto* ib = static_cast<uint32_t*>(q->ib_bo.cpu_ptr);
    uint32_t idx = 0;

    // 1. Shader entry point (>> 8)
    ib[idx++] = mi50::gfx906::pm4_type3(mi50::gfx906::PKT3_SET_SH_REG, 3);
    ib[idx++] = mmCOMPUTE_PGM_LO - SH_REG_BASE;
    ib[idx++] = static_cast<uint32_t>(sym.entry_va >> 8);
    ib[idx++] = static_cast<uint32_t>(sym.entry_va >> 40);

    // 2. RSRC1 & RSRC2 (patch LDS_SIZE if dynamic group_segment_size requested)
    uint32_t total_lds = std::max(sym.group_size, pkt->group_segment_size);
    uint32_t lds_blocks = (total_lds + 511) / 512; // GFX9 encodes LDS in 128-DWORD (512B) units
    uint32_t rsrc2 = (sym.rsrc2 & ~(0x1FFu << 15)) | ((lds_blocks & 0x1FFu) << 15);
    if (priv_size > 0) {
        // Any effective per-work-item private storage requires scratch mode.
        rsrc2 |= mi50::gfx906::COMPUTE_PGM_RSRC2_SCRATCH_EN;
    }

    ib[idx++] = mi50::gfx906::pm4_type3(mi50::gfx906::PKT3_SET_SH_REG, 3);
    ib[idx++] = mmCOMPUTE_PGM_RSRC1 - SH_REG_BASE;
    ib[idx++] = sym.rsrc1;
    ib[idx++] = rsrc2;

    // 3. Scratch TMPRING_SIZE & 128-bit SQ_BUF_RSRC descriptor in USER_DATA_0..3
    uint32_t tmpring = 0;
    if (priv_size > 0 && q->scratch_bo.bo) {
        uint32_t waves = 60 * 40;
        uint32_t units = q->scratch_bytes_per_wave / 1024;
        tmpring = (waves & 0xFFFu) | ((units & 0x1FFFu) << 12);

        uint64_t scratch_va = q->scratch_bo.gpu_va;
        uint32_t desc[4] = {
            static_cast<uint32_t>(scratch_va),
            static_cast<uint32_t>((scratch_va >> 32) & 0xFFFFu) | (1u << 30), // SWIZZLE_ENABLE
            static_cast<uint32_t>(q->scratch_bo.size),
            0x00027000u // DST_SEL_XYZW, NUM_FORMAT_FLOAT, DATA_FORMAT_32, ADD_TID_ENABLE
        };
        ib[idx++] = mi50::gfx906::pm4_type3(mi50::gfx906::PKT3_SET_SH_REG, 5);
        ib[idx++] = mmCOMPUTE_USER_DATA_0 - SH_REG_BASE;
        ib[idx++] = desc[0];
        ib[idx++] = desc[1];
        ib[idx++] = desc[2];
        ib[idx++] = desc[3];
    }

    ib[idx++] = mi50::gfx906::pm4_type3(mi50::gfx906::PKT3_SET_SH_REG, 2);
    ib[idx++] = mmCOMPUTE_TMPRING_SIZE - SH_REG_BASE;
    ib[idx++] = tmpring;

    // 4. Workgroup dimensions
    ib[idx++] = mi50::gfx906::pm4_type3(mi50::gfx906::PKT3_SET_SH_REG, 4);
    ib[idx++] = mmCOMPUTE_NUM_THREAD_X - SH_REG_BASE;
    ib[idx++] = pkt->workgroup_size_x;
    ib[idx++] = pkt->workgroup_size_y;
    ib[idx++] = pkt->workgroup_size_z;

    // 5. Kernarg segment pointer at dynamic USER_DATA SGPR offset
    if (sym.code_props & ENABLE_SGPR_KERNARG_SEGMENT_PTR) {
        uint32_t k_sgpr = compute_kernarg_sgpr_offset(sym.code_props);
        BufferRecord kernarg_bo{};
        uint64_t kernarg_offset = 0;
        uint64_t k_va = 0;
        if (find_buffer_by_cpu_ptr(pkt->kernarg_address, kernarg_bo, kernarg_offset)) {
            k_va = kernarg_bo.gpu_va + kernarg_offset;
        } else if (find_buffer_containing(reinterpret_cast<uint64_t>(pkt->kernarg_address),
                                          kernarg_bo, kernarg_offset)) {
            // Accept a GPU VA only for callers that already use GPU-address
            // semantics; host-side kernarg writes must use the CPU mapping.
            k_va = kernarg_bo.gpu_va + kernarg_offset;
        } else {
            fprintf(stderr, "[hsa-shim] kernarg pointer %p is not a tracked GTT/VRAM allocation\n",
                    pkt->kernarg_address);
            return false;
        }
        if (sym.kernarg_size > kernarg_bo.size - kernarg_offset) {
            fprintf(stderr, "[hsa-shim] kernarg segment exceeds its allocation\n");
            return false;
        }
        ib[idx++] = mi50::gfx906::pm4_type3(mi50::gfx906::PKT3_SET_SH_REG, 3);
        ib[idx++] = (mmCOMPUTE_USER_DATA_0 + k_sgpr) - SH_REG_BASE;
        ib[idx++] = static_cast<uint32_t>(k_va);
        ib[idx++] = static_cast<uint32_t>(k_va >> 32);
    }

    // 6. Dispatch Direct (AQL grid_size is total work-items; divide by workgroup_size)
    uint32_t gx = std::max(1u, pkt->grid_size_x / std::max<uint16_t>(1, pkt->workgroup_size_x));
    uint32_t gy = std::max(1u, pkt->grid_size_y / std::max<uint16_t>(1, pkt->workgroup_size_y));
    uint32_t gz = std::max(1u, pkt->grid_size_z / std::max<uint16_t>(1, pkt->workgroup_size_z));

    ib[idx++] = mi50::gfx906::pm4_type3(mi50::gfx906::PKT3_DISPATCH_DIRECT, 4);
    ib[idx++] = gx;
    ib[idx++] = gy;
    ib[idx++] = gz;
    ib[idx++] = 0x1; // COMPUTE_SHADER_EN = 1 (Wave64)

    // 7. L1/L2 Cache write-back & invalidate
    ib[idx++] = mi50::gfx906::pm4_type3(mi50::gfx906::PKT3_ACQUIRE_MEM, 6);
    ib[idx++] = mi50::gfx906::ACQUIRE_MEM_CACHE_WRITEBACK_INVALIDATE;
    ib[idx++] = 0xFFFFFFFF;
    ib[idx++] = 0xFF;
    ib[idx++] = 0;
    ib[idx++] = 0;
    ib[idx++] = 10;

    arm64_dsb_sy();

    amdgpu_bo_list_handle bo_list = get_global_bo_list();
    if (bo_list == nullptr) {
        fprintf(stderr, "[hsa-shim] could not construct the resident BO list\n");
        return false;
    }
    struct amdgpu_cs_ib_info ib_info{};
    ib_info.ib_mc_address = q->ib_bo.gpu_va;
    ib_info.size          = idx;

    struct amdgpu_cs_request cs_req{};
    cs_req.ip_type       = AMDGPU_HW_IP_COMPUTE;
    cs_req.ring          = 0;
    cs_req.number_of_ibs = 1;
    cs_req.ibs           = &ib_info;
    cs_req.resources     = bo_list;

    if (amdgpu_cs_submit(g_state.comp_ctx, 0, &cs_req, 1) != 0) {
        perror("[hsa-shim] amdgpu_cs_submit failed");
        return false;
    }

    q->ib_fence.context = g_state.comp_ctx;
    q->ib_fence.ip_type = AMDGPU_HW_IP_COMPUTE;
    q->ib_fence.ring    = 0;
    q->ib_fence.fence   = cs_req.seq_no;
    q->ib_in_flight     = true;

    if (pkt->completion_signal.handle != 0) {
        auto* sig = reinterpret_cast<SignalRecord*>(pkt->completion_signal.handle);
        std::lock_guard<std::mutex> lk(sig->fence_mtx);
        sig->fence.context = g_state.comp_ctx;
        sig->fence.ip_type = AMDGPU_HW_IP_COMPUTE;
        sig->fence.ring    = 0;
        sig->fence.fence   = cs_req.seq_no;
        sig->has_fence     = true;
    }
    return true;
}

void drain_aql_queue(QueueRecord* q) {
    std::lock_guard<std::mutex> lk(q->submit_mtx);
    uint64_t r = q->read_index.load(std::memory_order_acquire);
    uint64_t w = q->write_index.load(std::memory_order_acquire);
    uint32_t mask = q->public_queue.size - 1;
    auto* ring = static_cast<uint8_t*>(q->public_queue.base_address);

    while (r < w) {
        uint8_t* slot = ring + ((r & mask) * 64);
        uint16_t header = *reinterpret_cast<uint16_t*>(slot);
        uint8_t pkt_type = header & 0xFFu;

        if (pkt_type == HSA_PACKET_TYPE_KERNEL_DISPATCH) {
            const auto* dispatch = reinterpret_cast<const hsa_kernel_dispatch_packet_t*>(slot);
            if (!dispatch_kernel_packet(q, dispatch) && dispatch->completion_signal.handle != 0) {
                // Negative terminal value distinguishes a rejected packet from
                // the normal successful completion value of zero.
                auto* signal = reinterpret_cast<SignalRecord*>(dispatch->completion_signal.handle);
                signal->value.store(-static_cast<int64_t>(HSA_STATUS_ERROR), std::memory_order_release);
            }
        } else if (pkt_type == HSA_PACKET_TYPE_BARRIER_AND ||
                   pkt_type == HSA_PACKET_TYPE_BARRIER_OR) {
            auto* bp = reinterpret_cast<const hsa_barrier_packet_t*>(slot);
            for (int i = 0; i < 5; i++) {
                if (bp->dep_signal[i].handle != 0) {
                    wait_signal_blocking(reinterpret_cast<SignalRecord*>(bp->dep_signal[i].handle));
                }
            }
            if (bp->completion_signal.handle != 0) {
                auto* csig = reinterpret_cast<SignalRecord*>(bp->completion_signal.handle);
                csig->value.fetch_sub(1, std::memory_order_acq_rel);
            }
        }

        // Invalidate processed AQL slot header per HSA spec
        *reinterpret_cast<uint16_t*>(slot) = HSA_PACKET_TYPE_INVALID;
        r++;
        q->read_index.store(r, std::memory_order_release);
    }
}

} // namespace

// ============================================================================
// Exported HSA / ROCR C ABI Symbols
// ============================================================================
extern "C" {

hsa_status_t hsa_init(void) {
    std::lock_guard<std::mutex> lk(g_state.mtx);
    if (g_state.ref_count > 0) {
        ++g_state.ref_count;
        return HSA_STATUS_SUCCESS;
    }

    g_state.drm_fd = open("/dev/dri/renderD128", O_RDWR | O_CLOEXEC);
    if (g_state.drm_fd < 0) return HSA_STATUS_ERROR;

    auto cleanup_partial_init = []() {
        free_bo_internal(g_state.sdma_stage, false);
        free_bo_internal(g_state.sdma_ib, false);
        if (g_state.dma_ctx) amdgpu_cs_ctx_free(g_state.dma_ctx);
        if (g_state.comp_ctx) amdgpu_cs_ctx_free(g_state.comp_ctx);
        if (g_state.dev) amdgpu_device_deinitialize(g_state.dev);
        if (g_state.drm_fd >= 0) close(g_state.drm_fd);
        g_state.drm_fd = -1;
        g_state.dev = nullptr;
        g_state.comp_ctx = nullptr;
        g_state.dma_ctx = nullptr;
    };

    uint32_t major = 0, minor = 0;
    if (amdgpu_device_initialize(g_state.drm_fd, &major, &minor, &g_state.dev) != 0) {
        cleanup_partial_init();
        return HSA_STATUS_ERROR;
    }

    amdgpu_query_gpu_info(g_state.dev, &g_state.gpu_info);
    amdgpu_heap_info vram_heap{};
    if (amdgpu_query_heap_info(g_state.dev, AMDGPU_GEM_DOMAIN_VRAM, 0, &vram_heap) == 0) {
        g_state.vram_size = vram_heap.heap_size;
        g_state.vis_vram = vram_heap.max_allocation;
    }
    amdgpu_heap_info vis_heap{};
    if (amdgpu_query_heap_info(g_state.dev, AMDGPU_GEM_DOMAIN_VRAM,
                               AMDGPU_GEM_CREATE_CPU_ACCESS_REQUIRED, &vis_heap) == 0) {
        g_state.vis_vram = vis_heap.heap_size;
        g_state.full_rebar = (g_state.vis_vram >= (31ULL << 30));
    }

    int ctx_rc = amdgpu_cs_ctx_create2(g_state.dev, AMDGPU_CTX_PRIORITY_HIGH, &g_state.comp_ctx);
    if (ctx_rc != 0) ctx_rc = amdgpu_cs_ctx_create(g_state.dev, &g_state.comp_ctx);
    if (ctx_rc != 0 || amdgpu_cs_ctx_create(g_state.dev, &g_state.dma_ctx) != 0) {
        cleanup_partial_init();
        return HSA_STATUS_ERROR_OUT_OF_RESOURCES;
    }

    // Pre-allocate a GTT staging area and SDMA IB. Fail closed when either
    // allocation cannot be CPU-mapped; the runtime must not advertise success.
    if (!alloc_bo_internal(64 * 1024, AMDGPU_GEM_DOMAIN_GTT, true, false, false, g_state.sdma_ib) ||
        !alloc_bo_internal(64 * 1024 * 1024, AMDGPU_GEM_DOMAIN_GTT, true, false, false, g_state.sdma_stage)) {
        cleanup_partial_init();
        return HSA_STATUS_ERROR_OUT_OF_RESOURCES;
    }

    g_state.ref_count = 1;
    return HSA_STATUS_SUCCESS;
}

hsa_status_t hsa_shut_down(void) {
    std::lock_guard<std::mutex> lk(g_state.mtx);
    if (g_state.ref_count <= 0) return HSA_STATUS_ERROR_NOT_INITIALIZED;
    if (--g_state.ref_count > 0) return HSA_STATUS_SUCCESS;

    if (g_state.cached_bo_list) amdgpu_bo_list_destroy(g_state.cached_bo_list);
    free_bo_internal(g_state.sdma_ib, false);
    free_bo_internal(g_state.sdma_stage, false);
    if (g_state.comp_ctx) amdgpu_cs_ctx_free(g_state.comp_ctx);
    if (g_state.dma_ctx) amdgpu_cs_ctx_free(g_state.dma_ctx);
    if (g_state.dev) amdgpu_device_deinitialize(g_state.dev);
    if (g_state.drm_fd >= 0) close(g_state.drm_fd);
    g_state.comp_ctx = nullptr;
    g_state.dma_ctx = nullptr;
    g_state.dev = nullptr;
    g_state.drm_fd = -1;
    g_state.cached_bo_list = nullptr;
    g_state.cached_bo_handles.clear();
    g_state.bo_list_dirty = true;
    g_state.full_rebar = false;
    return HSA_STATUS_SUCCESS;
}

hsa_status_t hsa_system_get_info(int attribute, void* value) {
    if (!value) return HSA_STATUS_ERROR_INVALID_ARGUMENT;
    switch (attribute) {
        case 0: *static_cast<uint16_t*>(value) = 1; break; // VERSION_MAJOR
        case 1: *static_cast<uint16_t*>(value) = 1; break; // VERSION_MINOR
        case 2: *static_cast<uint64_t*>(value) = 0; break; // TIMESTAMP
        case 3: *static_cast<uint64_t*>(value) = 25000000ULL; break; // TIMESTAMP_FREQUENCY
        default: *static_cast<uint32_t*>(value) = 0; break;
    }
    return HSA_STATUS_SUCCESS;
}

hsa_status_t hsa_iterate_agents(hsa_status_t (*cb)(hsa_agent_t, void*), void* data) {
    if (!cb) return HSA_STATUS_ERROR_INVALID_ARGUMENT;
    hsa_status_t st = cb(hsa_agent_t{HANDLE_CPU_AGENT}, data);
    if (st != HSA_STATUS_SUCCESS) return st;
    return cb(hsa_agent_t{HANDLE_GPU_AGENT}, data);
}

hsa_status_t hsa_agent_get_info(hsa_agent_t agent, int attribute, void* value) {
    if (!value) return HSA_STATUS_ERROR_INVALID_ARGUMENT;
    bool is_gpu = (agent.handle == HANDLE_GPU_AGENT);
    switch (attribute) {
        case 0: // NAME
            std::strncpy(static_cast<char*>(value), is_gpu ? "gfx906" : "aarch64", 64);
            break;
        case 1: // VENDOR_NAME
            std::strncpy(static_cast<char*>(value), is_gpu ? "AMD" : "ARM", 64);
            break;
        case 2: // FEATURE
            *static_cast<uint32_t*>(value) = is_gpu ? 1 : 0; // KERNEL_DISPATCH
            break;
        case 3: // MACHINE_MODEL
            *static_cast<uint32_t*>(value) = 1; // LARGE (64-bit)
            break;
        case 4: // PROFILE
            *static_cast<uint32_t*>(value) = 0; // BASE
            break;
        case 5: // DEFAULT_FLOAT_ROUNDING_MODE
            *static_cast<hsa_default_float_rounding_mode_t*>(value) = HSA_DEFAULT_FLOAT_ROUNDING_MODE_NEAR;
            break;
        case 6: // WAVEFRONT_SIZE
            *static_cast<uint32_t*>(value) = 64;
            break;
        case 7: // WORKGROUP_MAX_DIM
            static_cast<uint16_t*>(value)[0] = 1024;
            static_cast<uint16_t*>(value)[1] = 1024;
            static_cast<uint16_t*>(value)[2] = 1024;
            break;
        case 8: // WORKGROUP_MAX_SIZE
            *static_cast<uint32_t*>(value) = 1024;
            break;
        case 9: // GRID_MAX_DIM
            static_cast<uint32_t*>(value)[0] = UINT32_MAX;
            static_cast<uint32_t*>(value)[1] = UINT32_MAX;
            static_cast<uint32_t*>(value)[2] = UINT32_MAX;
            break;
        case 10: // GRID_MAX_SIZE
            *static_cast<uint32_t*>(value) = UINT32_MAX;
            break;
        case 12: // QUEUES_MAX
            *static_cast<uint32_t*>(value) = 128;
            break;
        case 13: // QUEUE_MIN_SIZE
            *static_cast<uint32_t*>(value) = 64;
            break;
        case 14: // QUEUE_MAX_SIZE
            *static_cast<uint32_t*>(value) = 131072;
            break;
        case 15: // QUEUE_TYPE
            *static_cast<uint32_t*>(value) = HSA_QUEUE_TYPE_MULTI;
            break;
        case 16: // NODE (single host/GPU NUMA node in this narrow shim)
            *static_cast<uint32_t*>(value) = 0;
            break;
        case 17: // DEVICE
            *static_cast<uint32_t*>(value) = is_gpu ? HSA_DEVICE_TYPE_GPU : HSA_DEVICE_TYPE_CPU;
            break;
        case 19: // ISA
            static_cast<hsa_isa_t*>(value)->handle = is_gpu ? HANDLE_GPU_ISA : 0;
            break;
        case 23: // BASE_PROFILE_DEFAULT_FLOAT_ROUNDING_MODES
            *static_cast<uint32_t*>(value) = (1u << HSA_DEFAULT_FLOAT_ROUNDING_MODE_NEAR);
            break;
        default:
            *static_cast<uint32_t*>(value) = 0;
            break;
    }
    return HSA_STATUS_SUCCESS;
}

hsa_status_t hsa_agent_iterate_isas(hsa_agent_t agent,
                                    hsa_status_t (*cb)(hsa_isa_t, void*), void* data) {
    if (agent.handle != HANDLE_GPU_AGENT || !cb) return HSA_STATUS_ERROR_INVALID_ARGUMENT;
    return cb(hsa_isa_t{HANDLE_GPU_ISA}, data);
}

hsa_status_t hsa_isa_get_info_alt(hsa_isa_t isa, int attribute, void* value) {
    if (isa.handle != HANDLE_GPU_ISA || !value) return HSA_STATUS_ERROR_INVALID_ISA;
    const char* name = "amdgcn-amd-amdhsa--gfx906";
    if (attribute == 0) { // NAME_LENGTH
        *static_cast<uint32_t*>(value) = static_cast<uint32_t>(std::strlen(name));
    } else if (attribute == 1) { // NAME
        std::memcpy(value, name, std::strlen(name));
    }
    return HSA_STATUS_SUCCESS;
}

hsa_status_t hsa_isa_from_name(const char* name, hsa_isa_t* isa) {
    if (!name || !isa) return HSA_STATUS_ERROR_INVALID_ARGUMENT;
    if (std::strstr(name, "gfx906")) {
        isa->handle = HANDLE_GPU_ISA;
        return HSA_STATUS_SUCCESS;
    }
    return HSA_STATUS_ERROR_INVALID_ISA;
}

// ============================================================================
// AMD Memory Pool Extensions
// ============================================================================
hsa_status_t hsa_amd_agent_iterate_memory_pools(
    hsa_agent_t agent, hsa_status_t (*cb)(hsa_amd_memory_pool_t, void*), void* data) {
    if (!cb) return HSA_STATUS_ERROR_INVALID_ARGUMENT;
    if (agent.handle == HANDLE_GPU_AGENT) {
        hsa_status_t st = cb(hsa_amd_memory_pool_t{HANDLE_POOL_VRAM}, data);
        if (st != HSA_STATUS_SUCCESS) return st;
    }
    return cb(hsa_amd_memory_pool_t{HANDLE_POOL_GTT}, data);
}

hsa_status_t hsa_amd_memory_pool_get_info(hsa_amd_memory_pool_t pool, int attribute, void* value) {
    if (!value) return HSA_STATUS_ERROR_INVALID_ARGUMENT;
    bool is_vram = (pool.handle == HANDLE_POOL_VRAM);
    switch (attribute) {
        case 0: // SEGMENT (GLOBAL = 0)
            *static_cast<uint32_t*>(value) = 0;
            break;
        case 1: // GLOBAL_FLAGS: COARSE_GRAINED (4) for VRAM; KERNARG_INIT (1) | FINE_GRAINED (2) for GTT
            *static_cast<uint32_t*>(value) = is_vram ? 4u : (1u | 2u);
            break;
        case 2: // SIZE
            *static_cast<size_t*>(value) = is_vram ? g_state.vram_size : (16ULL << 30);
            break;
        case 3: // RUNTIME_ALLOC_ALLOWED
            *static_cast<bool*>(value) = true;
            break;
        case 4: // RUNTIME_ALLOC_GRANULE
            *static_cast<size_t*>(value) = 4096;
            break;
        case 5: // RUNTIME_ALLOC_ALIGNMENT
            *static_cast<size_t*>(value) = 4096;
            break;
        case 6: // ACCESSIBLE_BY_ALL
            *static_cast<bool*>(value) = !is_vram;
            break;
        default:
            *static_cast<uint32_t*>(value) = 0;
            break;
    }
    return HSA_STATUS_SUCCESS;
}

hsa_status_t hsa_amd_memory_pool_allocate(hsa_amd_memory_pool_t pool, size_t size,
                                          uint32_t flags, void** ptr) {
    if (!ptr || size == 0) return HSA_STATUS_ERROR_INVALID_ARGUMENT;
    if (pool.handle != HANDLE_POOL_VRAM && pool.handle != HANDLE_POOL_GTT)
        return HSA_STATUS_ERROR_INVALID_ARGUMENT;
    (void)flags; // Only the default allocation flags are supported by this experiment.
    uint32_t domain = (pool.handle == HANDLE_POOL_VRAM) ? AMDGPU_GEM_DOMAIN_VRAM
                                                        : AMDGPU_GEM_DOMAIN_GTT;
    BufferRecord rec{};
    if (!alloc_bo_internal(size, domain, false, true, true, rec)) {
        return HSA_STATUS_ERROR_OUT_OF_RESOURCES;
    }
    if (domain == AMDGPU_GEM_DOMAIN_GTT) {
        if (rec.cpu_ptr == nullptr) {
            free_bo_internal(rec, true);
            return HSA_STATUS_ERROR_OUT_OF_RESOURCES;
        }
        *ptr = rec.cpu_ptr;
    } else {
        *ptr = reinterpret_cast<void*>(rec.gpu_va);
    }
    return HSA_STATUS_SUCCESS;
}

hsa_status_t hsa_amd_memory_pool_free(void* ptr) {
    if (!ptr) return HSA_STATUS_SUCCESS;
    BufferRecord rec{};
    bool found = false;
    const uint64_t maybe_gpu_va = reinterpret_cast<uint64_t>(ptr);
    {
        std::lock_guard<std::mutex> lk(g_state.mtx);
        auto it = g_state.buffers.find(maybe_gpu_va);
        if (it != g_state.buffers.end()) {
            rec = it->second;
            found = true;
        } else {
            const uintptr_t address = reinterpret_cast<uintptr_t>(ptr);
            for (const auto& kv : g_state.buffers) {
                const BufferRecord& candidate = kv.second;
                if (candidate.cpu_ptr != nullptr && address == reinterpret_cast<uintptr_t>(candidate.cpu_ptr)) {
                    rec = candidate;
                    found = true;
                    break;
                }
            }
        }
    }
    if (!found) return HSA_STATUS_ERROR_INVALID_ALLOCATION;
    free_bo_internal(rec, true);
    return HSA_STATUS_SUCCESS;
}

hsa_status_t hsa_amd_agents_allow_access(uint32_t, const hsa_agent_t*, const uint32_t*, const void*) {
    return HSA_STATUS_SUCCESS;
}

hsa_status_t hsa_amd_memory_async_copy(void* dst, hsa_agent_t, const void* src, hsa_agent_t,
                                       size_t size, uint32_t num_dep, const hsa_signal_t* deps,
                                       hsa_signal_t completion_signal) {
    for (uint32_t i = 0; i < num_dep; i++) {
        wait_signal_blocking(reinterpret_cast<SignalRecord*>(deps[i].handle));
    }

    BufferRecord dst_bo{}, src_bo{};
    uint64_t dst_off = 0, src_off = 0;
    const bool dst_is_alloc = find_buffer_for_pointer(dst, dst_bo, dst_off);
    const bool src_is_alloc = find_buffer_for_pointer(src, src_bo, src_off);
    if ((dst_is_alloc && size > dst_bo.size - dst_off) ||
        (src_is_alloc && size > src_bo.size - src_off)) {
        return HSA_STATUS_ERROR_INVALID_ALLOCATION;
    }

    bool ok = false;
    if (dst_is_alloc && src_is_alloc) {
        // Both CPU pointers and GPU VAs resolve to their BO GPU VAs. Ensure
        // host WC writes have reached the memory controller before SDMA reads.
        arm64_dsb_sy();
        ok = sdma_linear_copy(src_bo.bo, src_bo.gpu_va + src_off,
                              dst_bo.bo, dst_bo.gpu_va + dst_off, size);
    } else if (dst_is_alloc && !src_is_alloc) {
        // HtoD: either direct CPU map (GTT / ReBAR) or chunked SDMA via sdma_stage
        if (dst_bo.cpu_ptr) {
            std::memcpy(static_cast<uint8_t*>(dst_bo.cpu_ptr) + dst_off, src, size);
            arm64_dsb_sy();
            ok = true;
        } else {
            size_t done = 0;
            while (done < size) {
                size_t chunk = std::min(size - done, g_state.sdma_stage.size);
                std::memcpy(g_state.sdma_stage.cpu_ptr,
                            static_cast<const uint8_t*>(src) + done, chunk);
                if (!sdma_linear_copy(g_state.sdma_stage.bo, g_state.sdma_stage.gpu_va,
                                      dst_bo.bo, dst_bo.gpu_va + dst_off + done, chunk)) {
                    ok = false;
                    break;
                }
                done += chunk;
                ok = true;
            }
        }
    } else if (!dst_is_alloc && src_is_alloc) {
        // DtoH: either direct CPU map or chunked SDMA via sdma_stage
        if (src_bo.cpu_ptr) {
            arm64_dsb_sy();
            std::memcpy(dst, static_cast<const uint8_t*>(src_bo.cpu_ptr) + src_off, size);
            ok = true;
        } else {
            size_t done = 0;
            while (done < size) {
                size_t chunk = std::min(size - done, g_state.sdma_stage.size);
                if (!sdma_linear_copy(src_bo.bo, src_bo.gpu_va + src_off + done,
                                      g_state.sdma_stage.bo, g_state.sdma_stage.gpu_va, chunk)) {
                    ok = false;
                    break;
                }
                std::memcpy(static_cast<uint8_t*>(dst) + done,
                            g_state.sdma_stage.cpu_ptr, chunk);
                done += chunk;
                ok = true;
            }
        }
    } else {
        std::memcpy(dst, src, size);
        ok = true;
    }

    if (completion_signal.handle != 0) {
        auto* sig = reinterpret_cast<SignalRecord*>(completion_signal.handle);
        sig->value.fetch_sub(1, std::memory_order_acq_rel);
    }
    return ok ? HSA_STATUS_SUCCESS : HSA_STATUS_ERROR;
}

// ============================================================================
// Signals & AQL Queue Doorbell Interception
// ============================================================================
hsa_status_t hsa_signal_create(hsa_signal_value_t initial_value, uint32_t,
                               const hsa_agent_t*, hsa_signal_t* signal) {
    if (!signal) return HSA_STATUS_ERROR_INVALID_ARGUMENT;
    auto* rec = new SignalRecord();
    rec->value.store(initial_value, std::memory_order_relaxed);
    std::lock_guard<std::mutex> lk(g_state.mtx);
    uint64_t h = reinterpret_cast<uint64_t>(rec);
    g_state.signals[h] = rec;
    signal->handle = h;
    return HSA_STATUS_SUCCESS;
}

hsa_status_t hsa_signal_destroy(hsa_signal_t signal) {
    std::lock_guard<std::mutex> lk(g_state.mtx);
    auto it = g_state.signals.find(signal.handle);
    if (it != g_state.signals.end()) {
        delete it->second;
        g_state.signals.erase(it);
    }
    return HSA_STATUS_SUCCESS;
}

hsa_signal_value_t hsa_signal_load_scacquire(hsa_signal_t signal) {
    auto* sig = reinterpret_cast<SignalRecord*>(signal.handle);
    if (!sig) return 0;
    (void)retire_signal_fence(sig, 0);
    return sig->value.load(std::memory_order_acquire);
}
hsa_signal_value_t hsa_signal_load_relaxed(hsa_signal_t s) { return hsa_signal_load_scacquire(s); }

void hsa_signal_store_screlease(hsa_signal_t signal, hsa_signal_value_t value) {
    auto* sig = reinterpret_cast<SignalRecord*>(signal.handle);
    if (!sig) return;
    sig->value.store(value, std::memory_order_release);
    if (sig->owner_queue_id != 0) {
        QueueRecord* q = nullptr;
        {
            std::lock_guard<std::mutex> lk(g_state.mtx);
            auto it = g_state.queues.find(sig->owner_queue_id);
            if (it != g_state.queues.end()) q = it->second;
        }
        if (q) drain_aql_queue(q);
    }
}
void hsa_signal_store_relaxed(hsa_signal_t s, hsa_signal_value_t v) { hsa_signal_store_screlease(s, v); }

void hsa_signal_subtract_screlease(hsa_signal_t signal, hsa_signal_value_t value) {
    auto* sig = reinterpret_cast<SignalRecord*>(signal.handle);
    if (sig) sig->value.fetch_sub(value, std::memory_order_release);
}
void hsa_signal_subtract_relaxed(hsa_signal_t s, hsa_signal_value_t v) { hsa_signal_subtract_screlease(s, v); }

hsa_signal_value_t hsa_signal_wait_scacquire(hsa_signal_t signal, hsa_signal_condition_t cond,
                                             hsa_signal_value_t compare_value,
                                             uint64_t timeout_hint, hsa_wait_state_t) {
    auto* sig = reinterpret_cast<SignalRecord*>(signal.handle);
    if (!sig) return 0;
    auto start = std::chrono::steady_clock::now();
    while (true) {
        hsa_signal_value_t cur = hsa_signal_load_scacquire(signal);
        bool met = (cond == HSA_SIGNAL_CONDITION_EQ  && cur == compare_value) ||
                   (cond == HSA_SIGNAL_CONDITION_NE  && cur != compare_value) ||
                   (cond == HSA_SIGNAL_CONDITION_LT  && cur <  compare_value) ||
                   (cond == HSA_SIGNAL_CONDITION_GTE && cur >= compare_value);
        if (met) return cur;
        if (timeout_hint == 0) return cur;
        auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(
                           std::chrono::steady_clock::now() - start).count();
        if (static_cast<uint64_t>(elapsed) >= timeout_hint) return cur;
        std::this_thread::yield();
    }
}
hsa_signal_value_t hsa_signal_wait_relaxed(hsa_signal_t s, hsa_signal_condition_t c,
                                           hsa_signal_value_t v, uint64_t t, hsa_wait_state_t w) {
    return hsa_signal_wait_scacquire(s, c, v, t, w);
}

hsa_status_t hsa_queue_create(hsa_agent_t agent, uint32_t size, hsa_queue_type32_t type,
                              void (*)(hsa_status_t, hsa_queue_t*, void*), void*,
                              uint32_t, uint32_t, hsa_queue_t** queue) {
    if (agent.handle != HANDLE_GPU_AGENT || !queue || size < 64 || size > 131072 ||
        (size & (size - 1)) != 0 ||
        (type != HSA_QUEUE_TYPE_MULTI && type != HSA_QUEUE_TYPE_SINGLE)) {
        return HSA_STATUS_ERROR_INVALID_QUEUE_CREATION;
    }

    auto* q = new QueueRecord();
    if (!alloc_bo_internal(size * 64ULL, AMDGPU_GEM_DOMAIN_GTT, true, false, false, q->ring_bo)) {
        delete q;
        return HSA_STATUS_ERROR_OUT_OF_RESOURCES;
    }
    // The compute IB must be in the CS residency list. Track it globally so
    // get_global_bo_list() includes this queue's IB BO on every submission.
    if (!alloc_bo_internal(64 * 1024, AMDGPU_GEM_DOMAIN_GTT, true, false, true, q->ib_bo)) {
        free_bo_internal(q->ring_bo, false);
        delete q;
        return HSA_STATUS_ERROR_OUT_OF_RESOURCES;
    }

    std::memset(q->ring_bo.cpu_ptr, 0, size * 64ULL);

    hsa_signal_t doorbell{};
    hsa_signal_create(0, 0, nullptr, &doorbell);

    uint64_t qid = 0;
    {
        std::lock_guard<std::mutex> lk(g_state.mtx);
        qid = g_state.next_id++;
        g_state.queues[qid] = q;
    }
    reinterpret_cast<SignalRecord*>(doorbell.handle)->owner_queue_id = qid;

    q->public_queue.type            = type;
    q->public_queue.features        = 1; // KERNEL_DISPATCH
    q->public_queue.base_address    = q->ring_bo.cpu_ptr;
    q->public_queue.doorbell_signal = doorbell;
    q->public_queue.size            = size;
    q->public_queue.id              = qid;

    *queue = &q->public_queue;
    return HSA_STATUS_SUCCESS;
}

hsa_status_t hsa_queue_destroy(hsa_queue_t* queue) {
    if (!queue) return HSA_STATUS_ERROR_INVALID_ARGUMENT;
    QueueRecord* q = nullptr;
    {
        std::lock_guard<std::mutex> lk(g_state.mtx);
        auto it = g_state.queues.find(queue->id);
        if (it != g_state.queues.end()) {
            q = it->second;
            g_state.queues.erase(it);
        }
    }
    if (q) {
        (void)wait_queue_ib_idle(q);
        hsa_signal_destroy(q->public_queue.doorbell_signal);
        free_bo_internal(q->ring_bo, false);
        free_bo_internal(q->ib_bo, true);
        if (q->scratch_bo.bo) free_bo_internal(q->scratch_bo, true);
        delete q;
    }
    return HSA_STATUS_SUCCESS;
}

uint64_t hsa_queue_load_read_index_scacquire(const hsa_queue_t* q) {
    return reinterpret_cast<const QueueRecord*>(q)->read_index.load(std::memory_order_acquire);
}
uint64_t hsa_queue_load_read_index_relaxed(const hsa_queue_t* q) {
    return reinterpret_cast<const QueueRecord*>(q)->read_index.load(std::memory_order_relaxed);
}
uint64_t hsa_queue_load_write_index_scacquire(const hsa_queue_t* q) {
    return reinterpret_cast<const QueueRecord*>(q)->write_index.load(std::memory_order_acquire);
}
uint64_t hsa_queue_load_write_index_relaxed(const hsa_queue_t* q) {
    return reinterpret_cast<const QueueRecord*>(q)->write_index.load(std::memory_order_relaxed);
}
void hsa_queue_store_write_index_screlease(const hsa_queue_t* q, uint64_t v) {
    const_cast<QueueRecord*>(reinterpret_cast<const QueueRecord*>(q))
        ->write_index.store(v, std::memory_order_release);
}
void hsa_queue_store_write_index_relaxed(const hsa_queue_t* q, uint64_t v) {
    hsa_queue_store_write_index_screlease(q, v);
}
uint64_t hsa_queue_add_write_index_scacq_screl(const hsa_queue_t* q, uint64_t v) {
    return const_cast<QueueRecord*>(reinterpret_cast<const QueueRecord*>(q))
        ->write_index.fetch_add(v, std::memory_order_acq_rel);
}
uint64_t hsa_queue_add_write_index_relaxed(const hsa_queue_t* q, uint64_t v) {
    return hsa_queue_add_write_index_scacq_screl(q, v);
}

// ============================================================================
// ELF64 .hsaco / .co Code Object Loader & .rela.dyn Relocation Patcher
// ============================================================================
hsa_status_t hsa_code_object_reader_create_from_memory(const void* code_object, size_t size,
                                                       hsa_code_object_reader_t* reader) {
    if (!code_object || size == 0 || !reader) return HSA_STATUS_ERROR_INVALID_ARGUMENT;
    auto* blob = new CodeObjectBlob();
    blob->bytes.resize(size);
    std::memcpy(blob->bytes.data(), code_object, size);
    std::lock_guard<std::mutex> lk(g_state.mtx);
    uint64_t h = reinterpret_cast<uint64_t>(blob);
    g_state.readers[h] = blob;
    reader->handle = h;
    return HSA_STATUS_SUCCESS;
}

hsa_status_t hsa_code_object_reader_destroy(hsa_code_object_reader_t reader) {
    std::lock_guard<std::mutex> lk(g_state.mtx);
    auto it = g_state.readers.find(reader.handle);
    if (it != g_state.readers.end()) {
        delete it->second;
        g_state.readers.erase(it);
    }
    return HSA_STATUS_SUCCESS;
}

hsa_status_t hsa_executable_create_alt(hsa_profile_t, hsa_default_float_rounding_mode_t,
                                       const char*, hsa_executable_t* executable) {
    if (!executable) return HSA_STATUS_ERROR_INVALID_ARGUMENT;
    auto* exec = new ExecutableRecord();
    std::lock_guard<std::mutex> lk(g_state.mtx);
    uint64_t h = reinterpret_cast<uint64_t>(exec);
    g_state.executables[h] = exec;
    executable->handle = h;
    return HSA_STATUS_SUCCESS;
}

hsa_status_t hsa_executable_destroy(hsa_executable_t executable) {
    ExecutableRecord* exec = nullptr;
    {
        std::lock_guard<std::mutex> lk(g_state.mtx);
        auto it = g_state.executables.find(executable.handle);
        if (it != g_state.executables.end()) {
            exec = it->second;
            g_state.executables.erase(it);
        }
    }
    if (exec) {
        for (auto& bo : exec->code_bos) free_bo_internal(bo, true);
        delete exec;
    }
    return HSA_STATUS_SUCCESS;
}

hsa_status_t hsa_executable_load_agent_code_object(hsa_executable_t executable, hsa_agent_t agent,
                                                   hsa_code_object_reader_t reader,
                                                   const char*, void*) {
    if (agent.handle != HANDLE_GPU_AGENT) return HSA_STATUS_ERROR_INVALID_AGENT;

    ExecutableRecord* exec = nullptr;
    const CodeObjectBlob* blob = nullptr;
    {
        std::lock_guard<std::mutex> lk(g_state.mtx);
        auto eit = g_state.executables.find(executable.handle);
        auto rit = g_state.readers.find(reader.handle);
        if (eit == g_state.executables.end() || rit == g_state.readers.end()) {
            return HSA_STATUS_ERROR_INVALID_ARGUMENT;
        }
        exec = eit->second;
        blob = rit->second;
    }

    const auto in_blob = [size = blob->bytes.size()](uint64_t offset, uint64_t length) {
        return offset <= size && length <= size - offset;
    };
    if (!in_blob(0, sizeof(Elf64_Ehdr))) {
        fprintf(stderr, "[hsa-shim] code object is shorter than an ELF64 header\n");
        return HSA_STATUS_ERROR;
    }

    const uint8_t* elf = blob->bytes.data();
    const auto* ehdr = reinterpret_cast<const Elf64_Ehdr*>(elf);
    if (std::memcmp(ehdr->e_ident, ELFMAG, SELFMAG) != 0 ||
        ehdr->e_ident[EI_CLASS] != ELFCLASS64 || ehdr->e_ident[EI_DATA] != ELFDATA2LSB ||
        ehdr->e_machine != 224 /* EM_AMDGPU */ ||
        ehdr->e_phentsize != sizeof(Elf64_Phdr) || ehdr->e_shentsize != sizeof(Elf64_Shdr) ||
        ehdr->e_phnum == 0 || ehdr->e_shnum == 0 ||
        !in_blob(ehdr->e_phoff, static_cast<uint64_t>(ehdr->e_phnum) * sizeof(Elf64_Phdr)) ||
        !in_blob(ehdr->e_shoff, static_cast<uint64_t>(ehdr->e_shnum) * sizeof(Elf64_Shdr))) {
        fprintf(stderr, "[hsa-shim] unsupported or malformed AMDGPU ELF64 code object\n");
        return HSA_STATUS_ERROR;
    }

    const auto* phdrs = reinterpret_cast<const Elf64_Phdr*>(elf + ehdr->e_phoff);
    const auto* shdrs = reinterpret_cast<const Elf64_Shdr*>(elf + ehdr->e_shoff);

    uint64_t min_vaddr = UINT64_MAX;
    uint64_t max_vaddr = 0;
    for (uint16_t i = 0; i < ehdr->e_phnum; i++) {
        if (phdrs[i].p_type != PT_LOAD) continue;
        if (phdrs[i].p_filesz > phdrs[i].p_memsz ||
            !in_blob(phdrs[i].p_offset, phdrs[i].p_filesz) ||
            phdrs[i].p_vaddr > UINT64_MAX - phdrs[i].p_memsz) {
            fprintf(stderr, "[hsa-shim] malformed PT_LOAD segment %u\n", i);
            return HSA_STATUS_ERROR;
        }
        min_vaddr = std::min(min_vaddr, phdrs[i].p_vaddr);
        max_vaddr = std::max(max_vaddr, phdrs[i].p_vaddr + phdrs[i].p_memsz);
    }
    if (min_vaddr == UINT64_MAX || max_vaddr <= min_vaddr ||
        max_vaddr - min_vaddr > SIZE_MAX - 4095) {
        fprintf(stderr, "[hsa-shim] code object has no valid PT_LOAD image\n");
        return HSA_STATUS_ERROR;
    }

    const size_t span = static_cast<size_t>((max_vaddr - min_vaddr + 4095) & ~4095ULL);
    std::vector<uint8_t> image(span, 0);
    for (uint16_t i = 0; i < ehdr->e_phnum; i++) {
        if (phdrs[i].p_type == PT_LOAD) {
            std::memcpy(image.data() + (phdrs[i].p_vaddr - min_vaddr),
                        elf + phdrs[i].p_offset, phdrs[i].p_filesz);
        }
    }

    BufferRecord code_vram{};
    if (!alloc_bo_internal(span, AMDGPU_GEM_DOMAIN_VRAM, false, true, true, code_vram)) {
        return HSA_STATUS_ERROR_OUT_OF_RESOURCES;
    }
    const uint64_t base_va = code_vram.gpu_va;

    // Apply the small relocation subset implemented by this experiment. GOT
    // relocations need a real GOT allocation/loader and are rejected, not
    // silently skipped (the previous behavior could launch with stale globals).
    for (uint16_t i = 0; i < ehdr->e_shnum; i++) {
        const Elf64_Shdr& relsec = shdrs[i];
        if (relsec.sh_type != SHT_RELA) continue;
        if (relsec.sh_entsize != sizeof(Elf64_Rela) ||
            relsec.sh_size % sizeof(Elf64_Rela) != 0 ||
            !in_blob(relsec.sh_offset, relsec.sh_size) || relsec.sh_link >= ehdr->e_shnum) {
            fprintf(stderr, "[hsa-shim] malformed SHT_RELA section %u\n", i);
            free_bo_internal(code_vram, true);
            return HSA_STATUS_ERROR;
        }

        const Elf64_Shdr& symsec = shdrs[relsec.sh_link];
        if ((symsec.sh_type != SHT_SYMTAB && symsec.sh_type != SHT_DYNSYM) ||
            symsec.sh_entsize != sizeof(Elf64_Sym) ||
            symsec.sh_size % sizeof(Elf64_Sym) != 0 ||
            !in_blob(symsec.sh_offset, symsec.sh_size)) {
            fprintf(stderr, "[hsa-shim] relocation section %u has an invalid symbol table\n", i);
            free_bo_internal(code_vram, true);
            return HSA_STATUS_ERROR;
        }

        const auto* relas = reinterpret_cast<const Elf64_Rela*>(elf + relsec.sh_offset);
        const auto* syms = reinterpret_cast<const Elf64_Sym*>(elf + symsec.sh_offset);
        const size_t sym_count = symsec.sh_size / sizeof(Elf64_Sym);
        const size_t rela_count = relsec.sh_size / sizeof(Elf64_Rela);

        for (size_t r = 0; r < rela_count; r++) {
            const uint32_t r_type = ELF64_R_TYPE(relas[r].r_info);
            const uint32_t r_sym = ELF64_R_SYM(relas[r].r_info);
            if (r_type == R_AMDGPU_NONE) continue;
            if (r_type == R_AMDGPU_GOTPCREL || r_type == R_AMDGPU_GOTPCREL32_LO ||
                r_type == R_AMDGPU_GOTPCREL32_HI) {
                fprintf(stderr,
                        "[hsa-shim] unsupported GOT relocation type %u; this code object needs a real GOT loader\n",
                        r_type);
                free_bo_internal(code_vram, true);
                return HSA_STATUS_ERROR;
            }

            const bool is_64 = (r_type == R_AMDGPU_ABS64 || r_type == R_AMDGPU_REL64);
            const bool known_32 = (r_type == R_AMDGPU_ABS32_LO || r_type == R_AMDGPU_ABS32_HI ||
                                   r_type == R_AMDGPU_REL32 || r_type == R_AMDGPU_ABS32 ||
                                   r_type == R_AMDGPU_REL32_LO || r_type == R_AMDGPU_REL32_HI);
            if (!is_64 && !known_32) {
                fprintf(stderr, "[hsa-shim] unsupported AMDGPU relocation type %u\n", r_type);
                free_bo_internal(code_vram, true);
                return HSA_STATUS_ERROR;
            }
            const uint64_t width = is_64 ? 8 : 4;
            if (relas[r].r_offset < min_vaddr ||
                relas[r].r_offset - min_vaddr > span ||
                width > span - (relas[r].r_offset - min_vaddr) || r_sym >= sym_count) {
                fprintf(stderr, "[hsa-shim] relocation %zu is outside the loaded image or symbol table\n", r);
                free_bo_internal(code_vram, true);
                return HSA_STATUS_ERROR;
            }

            uint64_t symbol_address = 0;
            if (r_sym != 0) {
                const Elf64_Sym& sym = syms[r_sym];
                if (sym.st_shndx == SHN_UNDEF ||
                    (sym.st_shndx != SHN_ABS && sym.st_value < min_vaddr)) {
                    fprintf(stderr, "[hsa-shim] relocation %zu references an unresolved/out-of-image symbol\n", r);
                    free_bo_internal(code_vram, true);
                    return HSA_STATUS_ERROR;
                }
                symbol_address = (sym.st_shndx == SHN_ABS)
                    ? sym.st_value : base_va + (sym.st_value - min_vaddr);
            }

            const uint64_t addend = static_cast<uint64_t>(relas[r].r_addend);
            const uint64_t place = base_va + (relas[r].r_offset - min_vaddr);
            const uint64_t target = symbol_address + addend;
            uint8_t* location = image.data() + (relas[r].r_offset - min_vaddr);

            switch (r_type) {
                case R_AMDGPU_ABS64: {
                    const uint64_t value = target;
                    std::memcpy(location, &value, sizeof(value));
                    break;
                }
                case R_AMDGPU_REL64: {
                    const uint64_t value = target - place;
                    std::memcpy(location, &value, sizeof(value));
                    break;
                }
                case R_AMDGPU_ABS32:
                case R_AMDGPU_ABS32_LO: {
                    const uint32_t value = static_cast<uint32_t>(target & 0xFFFFFFFFULL);
                    std::memcpy(location, &value, sizeof(value));
                    break;
                }
                case R_AMDGPU_ABS32_HI: {
                    const uint32_t value = static_cast<uint32_t>((target >> 32) & 0xFFFFFFFFULL);
                    std::memcpy(location, &value, sizeof(value));
                    break;
                }
                case R_AMDGPU_REL32:
                case R_AMDGPU_REL32_LO: {
                    const uint32_t value = static_cast<uint32_t>((target - place) & 0xFFFFFFFFULL);
                    std::memcpy(location, &value, sizeof(value));
                    break;
                }
                case R_AMDGPU_REL32_HI: {
                    const uint32_t value = static_cast<uint32_t>(((target - place) >> 32) & 0xFFFFFFFFULL);
                    std::memcpy(location, &value, sizeof(value));
                    break;
                }
                default:
                    break;
            }
        }
    }

    bool found_kernel = false;
    for (uint16_t i = 0; i < ehdr->e_shnum; i++) {
        const Elf64_Shdr& symsec = shdrs[i];
        if (symsec.sh_type != SHT_DYNSYM && symsec.sh_type != SHT_SYMTAB) continue;
        if (symsec.sh_entsize != sizeof(Elf64_Sym) ||
            symsec.sh_size % sizeof(Elf64_Sym) != 0 ||
            !in_blob(symsec.sh_offset, symsec.sh_size) || symsec.sh_link >= ehdr->e_shnum) {
            fprintf(stderr, "[hsa-shim] malformed symbol table %u\n", i);
            free_bo_internal(code_vram, true);
            return HSA_STATUS_ERROR;
        }
        const Elf64_Shdr& strsec = shdrs[symsec.sh_link];
        if (strsec.sh_type != SHT_STRTAB || !in_blob(strsec.sh_offset, strsec.sh_size)) {
            fprintf(stderr, "[hsa-shim] malformed string table for symbol table %u\n", i);
            free_bo_internal(code_vram, true);
            return HSA_STATUS_ERROR;
        }
        const auto* syms = reinterpret_cast<const Elf64_Sym*>(elf + symsec.sh_offset);
        const char* strtab = reinterpret_cast<const char*>(elf + strsec.sh_offset);
        const size_t symbol_count = symsec.sh_size / sizeof(Elf64_Sym);
        for (size_t j = 0; j < symbol_count; j++) {
            if (syms[j].st_name >= strsec.sh_size) continue;
            const char* raw_name = strtab + syms[j].st_name;
            const size_t remaining = strsec.sh_size - syms[j].st_name;
            const size_t nlen = strnlen(raw_name, remaining);
            if (nlen == remaining || nlen <= 3 ||
                std::strcmp(raw_name + nlen - 3, ".kd") != 0) continue;
            if (syms[j].st_value < min_vaddr) continue;
            const uint64_t kd_off = syms[j].st_value - min_vaddr;
            if (kd_off > span || sizeof(amd_kernel_descriptor_t) > span - kd_off) continue;

            const auto* kd = reinterpret_cast<const amd_kernel_descriptor_t*>(image.data() + kd_off);
            const int64_t entry_offset = kd->kernel_code_entry_byte_offset;
            uint64_t entry_image_offset = kd_off;
            if (entry_offset < 0) {
                const uint64_t magnitude = static_cast<uint64_t>(-entry_offset);
                if (magnitude > entry_image_offset) continue;
                entry_image_offset -= magnitude;
            } else {
                if (static_cast<uint64_t>(entry_offset) > span - entry_image_offset) continue;
                entry_image_offset += static_cast<uint64_t>(entry_offset);
            }

            KernelSymbolRecord rec{};
            rec.name = std::string(raw_name, nlen - 3);
            rec.descriptor_va = base_va + kd_off;
            rec.entry_va = base_va + entry_image_offset;
            rec.kernarg_size = kd->kernarg_size;
            rec.group_size = kd->group_segment_fixed_size;
            rec.private_size = kd->private_segment_fixed_size;
            rec.rsrc1 = kd->compute_pgm_rsrc1;
            rec.rsrc2 = kd->compute_pgm_rsrc2;
            rec.code_props = kd->kernel_code_properties;

            exec->symbols_by_name[rec.name] = rec;
            exec->symbols_by_kd_va[rec.descriptor_va] = rec;
            found_kernel = true;
        }
    }
    if (!found_kernel) {
        fprintf(stderr, "[hsa-shim] no in-range .kd kernel descriptor found in code object\n");
        free_bo_internal(code_vram, true);
        return HSA_STATUS_ERROR;
    }

    // Upload the fully relocated image to executable VRAM via SDMA.
    size_t done = 0;
    while (done < span) {
        const size_t chunk = std::min(span - done, g_state.sdma_stage.size);
        std::memcpy(g_state.sdma_stage.cpu_ptr, image.data() + done, chunk);
        if (!sdma_linear_copy(g_state.sdma_stage.bo, g_state.sdma_stage.gpu_va,
                              code_vram.bo, code_vram.gpu_va + done, chunk)) {
            free_bo_internal(code_vram, true);
            return HSA_STATUS_ERROR;
        }
        done += chunk;
    }

    exec->code_bos.push_back(code_vram);
    return HSA_STATUS_SUCCESS;
}

hsa_status_t hsa_executable_freeze(hsa_executable_t, const char*) {
    return HSA_STATUS_SUCCESS;
}

hsa_status_t hsa_executable_get_symbol_by_name(hsa_executable_t executable, const char* symbol_name,
                                               const hsa_agent_t*, hsa_executable_symbol_t* symbol) {
    if (!symbol_name || !symbol) return HSA_STATUS_ERROR_INVALID_ARGUMENT;
    std::string key(symbol_name);
    if (key.size() > 3 && key.substr(key.size() - 3) == ".kd") {
        key = key.substr(0, key.size() - 3);
    }
    std::lock_guard<std::mutex> lk(g_state.mtx);
    auto eit = g_state.executables.find(executable.handle);
    if (eit == g_state.executables.end()) return HSA_STATUS_ERROR_INVALID_ARGUMENT;
    auto sit = eit->second->symbols_by_name.find(key);
    if (sit == eit->second->symbols_by_name.end()) return HSA_STATUS_ERROR_INVALID_SYMBOL_NAME;
    symbol->handle = sit->second.descriptor_va;
    return HSA_STATUS_SUCCESS;
}

hsa_status_t hsa_executable_symbol_get_info(hsa_executable_symbol_t symbol, int attribute, void* value) {
    if (!value) return HSA_STATUS_ERROR_INVALID_ARGUMENT;
    std::lock_guard<std::mutex> lk(g_state.mtx);
    for (const auto& kv : g_state.executables) {
        auto it = kv.second->symbols_by_kd_va.find(symbol.handle);
        if (it != kv.second->symbols_by_kd_va.end()) {
            const KernelSymbolRecord& rec = it->second;
            switch (attribute) {
                case 0: *static_cast<uint32_t*>(value) = 2; break; // SYMBOL_TYPE_KERNEL
                case 1: *static_cast<uint32_t*>(value) = static_cast<uint32_t>(rec.name.size()); break;
                case 2: std::memcpy(value, rec.name.data(), rec.name.size()); break;
                case 22: *static_cast<uint64_t*>(value) = rec.descriptor_va; break; // KERNEL_OBJECT
                case 23: *static_cast<uint32_t*>(value) = rec.kernarg_size; break;  // KERNARG_SEGMENT_SIZE
                case 24: *static_cast<uint32_t*>(value) = 16; break;                // KERNARG_SEGMENT_ALIGNMENT
                case 25: *static_cast<uint32_t*>(value) = rec.group_size; break;    // GROUP_SEGMENT_SIZE
                case 26: *static_cast<uint32_t*>(value) = rec.private_size; break;  // PRIVATE_SEGMENT_SIZE
                default: *static_cast<uint32_t*>(value) = 0; break;
            }
            return HSA_STATUS_SUCCESS;
        }
    }
    return HSA_STATUS_ERROR_INVALID_SYMBOL_NAME;
}

} // extern "C"