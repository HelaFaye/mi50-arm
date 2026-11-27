#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>

namespace mi50::gfx906 {

// The vec_add kernel has three explicit 64-bit global-buffer arguments.
// Code Object V5 implicit arguments follow those 24 explicit-argument bytes.
constexpr size_t VEC_ADD_EXPLICIT_KERNARG_BYTES = 3u * sizeof(uint64_t);
constexpr size_t VEC_ADD_KERNARG_CAPACITY = 256u;
constexpr size_t CODE_OBJECT_V5_BLOCK_COUNTS_BYTES = 3u * sizeof(uint32_t);
constexpr size_t CODE_OBJECT_V5_GROUP_SIZES_BYTES = 3u * sizeof(uint16_t);
constexpr size_t CODE_OBJECT_V5_IMPLICIT_ARGS_BYTES =
    CODE_OBJECT_V5_BLOCK_COUNTS_BYTES + CODE_OBJECT_V5_GROUP_SIZES_BYTES;
constexpr size_t VEC_ADD_KERNARG_REQUIRED_BYTES =
    VEC_ADD_EXPLICIT_KERNARG_BYTES + CODE_OBJECT_V5_IMPLICIT_ARGS_BYTES;

static_assert(VEC_ADD_EXPLICIT_KERNARG_BYTES == 24u);
static_assert(CODE_OBJECT_V5_BLOCK_COUNTS_BYTES == 12u);
static_assert(CODE_OBJECT_V5_GROUP_SIZES_BYTES == 6u);
static_assert(VEC_ADD_KERNARG_REQUIRED_BYTES == 42u);

// Populate the Code Object V5 hidden arguments consumed by
// __ockl_get_local_size() and related work-group queries. The field sequence
// is written as two byte arrays to avoid host-structure padding: three uint32
// block counts at +0..+11, followed by three uint16 group sizes at +12..+17.
// This helper is intentionally specific to vec_add's three explicit pointer
// arguments and fails closed on descriptor/allocation sizes that do not cover
// the complete layout.
inline bool populate_vec_add_code_object_v5_implicit_args(
    void* kernarg,
    size_t kernarg_capacity,
    uint32_t descriptor_kernarg_size,
    uint32_t block_count_x,
    uint16_t group_size_x) noexcept {
    if (kernarg == nullptr || block_count_x == 0u || group_size_x == 0u ||
        descriptor_kernarg_size < VEC_ADD_KERNARG_REQUIRED_BYTES ||
        descriptor_kernarg_size > kernarg_capacity ||
        kernarg_capacity < VEC_ADD_KERNARG_REQUIRED_BYTES) {
        return false;
    }

    const uint32_t block_counts[3] = { block_count_x, 1u, 1u };
    const uint16_t group_sizes[3] = { group_size_x, 1u, 1u };
    auto* bytes = static_cast<uint8_t*>(kernarg);
    std::memcpy(bytes + VEC_ADD_EXPLICIT_KERNARG_BYTES,
                block_counts, sizeof(block_counts));
    std::memcpy(bytes + VEC_ADD_EXPLICIT_KERNARG_BYTES +
                    CODE_OBJECT_V5_BLOCK_COUNTS_BYTES,
                group_sizes, sizeof(group_sizes));
    return true;
}

} // namespace mi50::gfx906
