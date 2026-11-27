#include "../experiments/gfx906/gfx9_pm4.hpp"

#include <cstdint>

using mi50::gfx906::pm4_type3;

constexpr uint32_t count_field(uint32_t header) {
    return (header >> 16) & 0x3FFFu;
}

static_assert(count_field(pm4_type3(mi50::gfx906::PKT3_DISPATCH_DIRECT, 4)) == 3,
              "DISPATCH_DIRECT count must encode four payload DWORDs");
static_assert(count_field(pm4_type3(mi50::gfx906::PKT3_ACQUIRE_MEM, 6)) == 5,
              "ACQUIRE_MEM count must encode six payload DWORDs");
static_assert(count_field(pm4_type3(mi50::gfx906::PKT3_SET_SH_REG, 3)) == 2,
              "SET_SH_REG with one register and two values is three payload DWORDs");
static_assert((mi50::gfx906::ACQUIRE_MEM_CACHE_WRITEBACK_INVALIDATE & (1u << 18)) != 0,
              "must include TC_WB_ACTION_ENA");
static_assert((mi50::gfx906::ACQUIRE_MEM_CACHE_WRITEBACK_INVALIDATE & (1u << 22)) != 0,
              "must include TCL1_ACTION_ENA");
static_assert((mi50::gfx906::ACQUIRE_MEM_CACHE_WRITEBACK_INVALIDATE & (1u << 23)) != 0,
              "must include TC_ACTION_ENA");
static_assert(mi50::gfx906::COMPUTE_PGM_RSRC2_SCRATCH_EN == 1u,
              "GFX9 scratch enable is COMPUTE_PGM_RSRC2 bit 0");

int main() { return 0; }
