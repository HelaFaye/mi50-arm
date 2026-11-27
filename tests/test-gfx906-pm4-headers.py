#!/usr/bin/env python3
"""Source-level checks that both dispatch paths use the common PM4 helpers."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
for rel in (
    "experiments/gfx906/dispatch_gfx906.cpp",
    "experiments/gfx906/hsa_drm_shim.cpp",
):
    source = (ROOT / rel).read_text()
    if '#include "gfx9_pm4.hpp"' not in source:
        raise SystemExit(f"{rel}: missing shared GFX9 PM4 definitions")
    if "mi50::gfx906::ACQUIRE_MEM_CACHE_WRITEBACK_INVALIDATE" not in source:
        raise SystemExit(f"{rel}: missing L2 writeback + L1/L2 invalidate flags")
    if "pm4_pkt3(" in source:
        raise SystemExit(f"{rel}: old ambiguous count-minus-one helper remains")

header = (ROOT / "experiments/gfx906/gfx9_pm4.hpp").read_text()
if "ACQUIRE_MEM_TC_WB_ACTION_ENA = 1u << 18" not in header:
    raise SystemExit("GFX9 TC_WB_ACTION_ENA must be bit 18 per Linux GFX9 register definitions")
if "ACQUIRE_MEM_TC_WB_ACTION_ENA = 1u << 15" in header:
    raise SystemExit("bit 15 is not ACQUIRE_MEM TC_WB_ACTION_ENA")

print("both dispatch paths use the shared PM4 encoder and GFX9 cache-control bits")
