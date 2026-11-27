#include <array>
#include <cstdint>
#include <cstdio>
#include <cstring>

#include "../experiments/gfx906/gfx9_code_object_v5.hpp"

namespace {

bool expect(bool condition, const char* message) {
    if (!condition) {
        std::fprintf(stderr, "FAIL: %s\n", message);
        return false;
    }
    std::printf("PASS: %s\n", message);
    return true;
}

} // namespace

int main() {
    using namespace mi50::gfx906;
    std::array<uint8_t, VEC_ADD_KERNARG_CAPACITY> kernarg{};
    kernarg.fill(0xA5u);

    constexpr uint32_t workgroups_x = 1024u / 64u;
    constexpr uint16_t workgroup_size_x = 64u;
    bool ok = true;

    ok &= expect(
        populate_vec_add_code_object_v5_implicit_args(
            kernarg.data(), kernarg.size(),
            static_cast<uint32_t>(VEC_ADD_KERNARG_REQUIRED_BYTES),
            workgroups_x, workgroup_size_x),
        "COv5 implicit args accept exact 42-byte kernarg descriptor");

    uint32_t block_counts[3]{};
    uint16_t group_sizes[3]{};
    std::memcpy(block_counts,
                kernarg.data() + VEC_ADD_EXPLICIT_KERNARG_BYTES,
                sizeof(block_counts));
    std::memcpy(group_sizes,
                kernarg.data() + VEC_ADD_EXPLICIT_KERNARG_BYTES +
                    CODE_OBJECT_V5_BLOCK_COUNTS_BYTES,
                sizeof(group_sizes));
    ok &= expect(block_counts[0] == 16u && block_counts[1] == 1u &&
                 block_counts[2] == 1u,
                 "block_count xyz are {16, 1, 1} at byte offsets 24..35");
    ok &= expect(group_sizes[0] == 64u && group_sizes[1] == 1u &&
                 group_sizes[2] == 1u,
                 "group_size xyz are {64, 1, 1} at byte offsets 36..41");
    ok &= expect(kernarg[23] == 0xA5u && kernarg[42] == 0xA5u,
                 "implicit-arg write preserves bytes outside offsets 24..41");

    const auto unchanged = kernarg;
    ok &= expect(
        !populate_vec_add_code_object_v5_implicit_args(
            kernarg.data(), kernarg.size(),
            static_cast<uint32_t>(VEC_ADD_KERNARG_REQUIRED_BYTES - 1u),
            workgroups_x, workgroup_size_x) && kernarg == unchanged,
        "rejects descriptor kernarg_size too small without modifying memory");
    ok &= expect(
        !populate_vec_add_code_object_v5_implicit_args(
            kernarg.data(), kernarg.size(),
            static_cast<uint32_t>(VEC_ADD_KERNARG_CAPACITY + 1u),
            workgroups_x, workgroup_size_x) && kernarg == unchanged,
        "rejects descriptor kernarg_size above the 256-byte capacity");
    ok &= expect(
        !populate_vec_add_code_object_v5_implicit_args(
            kernarg.data(), VEC_ADD_KERNARG_REQUIRED_BYTES - 1u,
            static_cast<uint32_t>(VEC_ADD_KERNARG_REQUIRED_BYTES),
            workgroups_x, workgroup_size_x) && kernarg == unchanged,
        "rejects an undersized kernarg allocation");
    ok &= expect(
        !populate_vec_add_code_object_v5_implicit_args(
            nullptr, kernarg.size(),
            static_cast<uint32_t>(VEC_ADD_KERNARG_REQUIRED_BYTES),
            workgroups_x, workgroup_size_x),
        "rejects a null kernarg pointer");
    ok &= expect(
        !populate_vec_add_code_object_v5_implicit_args(
            kernarg.data(), kernarg.size(),
            static_cast<uint32_t>(VEC_ADD_KERNARG_REQUIRED_BYTES), 0u,
            workgroup_size_x),
        "rejects a zero X workgroup count");
    ok &= expect(
        !populate_vec_add_code_object_v5_implicit_args(
            kernarg.data(), kernarg.size(),
            static_cast<uint32_t>(VEC_ADD_KERNARG_REQUIRED_BYTES),
            workgroups_x, 0u),
        "rejects a zero X workgroup size");

    return ok ? 0 : 1;
}
