#pragma once

#include <cstdint>

// Small, reviewed subset of the GFX9 PM4 packet encoding used by the
// gfx906 direct-dispatch experiment.  The second argument is the number of
// payload DWORDs (not the encoded count field).
namespace mi50::gfx906 {

constexpr uint32_t pm4_type3(uint32_t opcode, uint32_t payload_dwords) {
    return (3u << 30) |
           (((payload_dwords - 1u) & 0x3FFFu) << 16) |
           ((opcode & 0xFFu) << 8);
}

constexpr uint32_t PKT3_DISPATCH_DIRECT = 0x15;
constexpr uint32_t PKT3_ACQUIRE_MEM = 0x58;
constexpr uint32_t PKT3_SET_SH_REG = 0x76;

// COMPUTE_PGM_RSRC2.SCRATCH_EN: enable the wavefront private-segment scratch path.
constexpr uint32_t COMPUTE_PGM_RSRC2_SCRATCH_EN = 1u << 0;

// GFX9 CP_COHER_CNTL fields from gc_9_0_sh_mask.h.  Set both writeback and
// invalidation: TC_WB_ACTION_ENA is bit 18, TCL1_ACTION_ENA bit 22, and
// TC_ACTION_ENA bit 23.  The old (22 | 23) mask omitted the L2 writeback.
constexpr uint32_t ACQUIRE_MEM_TC_WB_ACTION_ENA = 1u << 18;
constexpr uint32_t ACQUIRE_MEM_TCL1_ACTION_ENA = 1u << 22;
constexpr uint32_t ACQUIRE_MEM_TC_ACTION_ENA = 1u << 23;
constexpr uint32_t ACQUIRE_MEM_CACHE_WRITEBACK_INVALIDATE =
    ACQUIRE_MEM_TC_WB_ACTION_ENA |
    ACQUIRE_MEM_TCL1_ACTION_ENA |
    ACQUIRE_MEM_TC_ACTION_ENA;

static_assert(((pm4_type3(PKT3_DISPATCH_DIRECT, 4) >> 16) & 0x3FFFu) == 3u,
              "DISPATCH_DIRECT has four payload DWORDs");
static_assert(((pm4_type3(PKT3_ACQUIRE_MEM, 6) >> 16) & 0x3FFFu) == 5u,
              "ACQUIRE_MEM has six payload DWORDs");
static_assert((ACQUIRE_MEM_CACHE_WRITEBACK_INVALIDATE & (1u << 18)) != 0,
              "ACQUIRE_MEM must request TC_WB_ACTION_ENA at bit 18");
static_assert(COMPUTE_PGM_RSRC2_SCRATCH_EN == 1u,
              "COMPUTE_PGM_RSRC2.SCRATCH_EN is bit 0");

} // namespace mi50::gfx906
