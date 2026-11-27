#!/usr/bin/env python3

import os
from pathlib import Path
import re
import unittest

REPO = Path(__file__).resolve().parents[1]
CLR = Path(os.environ["MI50_CLR_SOURCE"])
MAP = CLR / "hipamd/src/hip_hcc.map.in"
BRIDGE = CLR / "hipamd/src/hip_table_interface.cpp"
SCRIPT = REPO / "scripts/build-rocm-arm64-cross.sh"

V53 = (
    "hipGraphAddExternalSemaphoresSignalNode",
    "hipGraphAddExternalSemaphoresWaitNode",
    "hipGraphExternalSemaphoresSignalNodeSetParams",
    "hipGraphExternalSemaphoresSignalNodeGetParams",
    "hipGraphExternalSemaphoresWaitNodeSetParams",
    "hipGraphExternalSemaphoresWaitNodeGetParams",
    "hipGraphExecExternalSemaphoresSignalNodeSetParams",
    "hipGraphExecExternalSemaphoresWaitNodeSetParams",
)

V62 = (
    "hipGraphExecGetFlags",
    "hipGraphNodeSetParams",
    "hipGraphExecNodeSetParams",
)

FORWARDERS = {
    "hipGraphAddExternalSemaphoresSignalNode": (
        "hipGraphAddExternalSemaphoresSignalNode_fn",
        "pGraphNode, graph, pDependencies, numDependencies, nodeParams",
    ),
    "hipGraphAddExternalSemaphoresWaitNode": (
        "hipGraphAddExternalSemaphoresWaitNode_fn",
        "pGraphNode, graph, pDependencies, numDependencies, nodeParams",
    ),
    "hipGraphExternalSemaphoresSignalNodeSetParams": (
        "hipGraphExternalSemaphoresSignalNodeSetParams_fn",
        "hNode, nodeParams",
    ),
    "hipGraphExternalSemaphoresSignalNodeGetParams": (
        "hipGraphExternalSemaphoresSignalNodeGetParams_fn",
        "hNode, params_out",
    ),
    "hipGraphExternalSemaphoresWaitNodeSetParams": (
        "hipGraphExternalSemaphoresWaitNodeSetParams_fn",
        "hNode, nodeParams",
    ),
    "hipGraphExternalSemaphoresWaitNodeGetParams": (
        "hipGraphExternalSemaphoresWaitNodeGetParams_fn",
        "hNode, params_out",
    ),
    "hipGraphExecExternalSemaphoresSignalNodeSetParams": (
        "hipGraphExecExternalSemaphoresSignalNodeSetParams_fn",
        "hGraphExec, hNode, nodeParams",
    ),
    "hipGraphExecExternalSemaphoresWaitNodeSetParams": (
        "hipGraphExecExternalSemaphoresWaitNodeSetParams_fn",
        "hGraphExec, hNode, nodeParams",
    ),
    "hipGraphExecGetFlags": (
        "hipGraphExecGetFlags_fn",
        "graphExec, flags",
    ),
    "hipGraphNodeSetParams": (
        "hipGraphNodeSetParams_fn",
        "node, nodeParams",
    ),
    "hipGraphExecNodeSetParams": (
        "hipGraphExecNodeSetParams_fn",
        "hGraphExec, node, nodeParams",
    ),
}


def section(text, start_marker, end_marker):
    lines = text.splitlines()
    starts = [i for i, line in enumerate(lines) if line.strip() == start_marker]
    ends = [i for i, line in enumerate(lines) if line.strip() == end_marker]
    if len(starts) != 1 or len(ends) != 1 or starts[0] >= ends[0]:
        raise AssertionError((start_marker, end_marker, starts, ends))
    return lines[starts[0]:ends[0] + 1]


def has_plain_entry(lines, symbol):
    return any(line.strip() == symbol + ";" for line in lines)


def wrapper_body(source, symbol):
    pattern = re.compile(
        r"(?ms)^hipError_t\s+" + re.escape(symbol)
        + r"\s*\([^{}]*\)\s*\{(?P<body>.*?)^\}"
    )
    matches = list(pattern.finditer(source))
    if len(matches) != 1:
        raise AssertionError(
            f"Expected exactly one global definition for {symbol}; found {len(matches)}"
        )
    return matches[0].group("body")


class VersionScriptTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.map = MAP.read_text()
        cls.bridge = BRIDGE.read_text()
        cls.script = SCRIPT.read_text()

    def test_pch_uses_optional_cpp_pattern_in_hip_42(self):
        v42 = section(self.map, "hip_4.2 {", "hip_4.3 {")
        self.assertIn("__hipGetPCH*;", "\n".join(v42))
        self.assertFalse(has_plain_entry(v42, "__hipGetPCH"))

    def test_all_eleven_graph_exports_are_plain_c_entries(self):
        v53 = section(self.map, "hip_5.3 {", "} hip_5.2;")
        v62 = section(self.map, "hip_6.2 {", "} hip_6.1;")

        for symbol in V53:
            with self.subTest(symbol=symbol):
                self.assertTrue(has_plain_entry(v53, symbol))
                self.assertNotIn(f"hip::{symbol}*;", "\n".join(v53))

        for symbol in V62:
            with self.subTest(symbol=symbol):
                self.assertTrue(has_plain_entry(v62, symbol))
                self.assertNotIn(f"hip::{symbol}*;", "\n".join(v62))

    def test_all_ten_missing_wrappers_forward_to_dispatch_table(self):
        for symbol in tuple(FORWARDERS)[:-1]:
            dispatch_member, args = FORWARDERS[symbol]
            with self.subTest(symbol=symbol):
                body = wrapper_body(self.bridge, symbol)
                compact = "".join(body.split())
                expected = (
                    "returnhip::GetHipDispatchTable()->"
                    + dispatch_member
                    + "(" + "".join(args.split()) + ");"
                )
                self.assertIn(expected, compact)

    def test_existing_exec_node_wrapper_is_preserved(self):
        symbol = "hipGraphExecNodeSetParams"
        dispatch_member, args = FORWARDERS[symbol]
        body = wrapper_body(self.bridge, symbol)
        compact = "".join(body.split())
        expected = (
            "returnhip::GetHipDispatchTable()->"
            + dispatch_member
            + "(" + "".join(args.split()) + ");"
        )
        self.assertIn(expected, compact)

    def test_both_build_paths_use_migration_helper(self):
        entry = 'apply_clr_hip_graph_api_patch "$SRC/clr"'
        self.assertEqual(self.script.count(entry), 2)

        self.assertIn(
            'local legacy_patch="$REPO_ROOT/patches/'
            '0010-clr-hip-version-script-combined.patch"',
            self.script,
        )
        self.assertIn(
            'local patch_file="$REPO_ROOT/patches/'
            '0011-clr-hip-graph-api-forwarders.patch"',
            self.script,
        )
        self.assertIn(
            'git -C "$dir" apply --reverse --check "$legacy_patch"',
            self.script,
        )
        self.assertIn(
            'apply_patch_idempotent "$dir" "$patch_file"',
            self.script,
        )

        self.assertNotIn(
            'apply_patch_idempotent "$SRC/clr" '
            '"$REPO_ROOT/patches/0010-clr-hip-version-script-combined.patch"',
            self.script,
        )
        self.assertNotIn("0008-clr-hip-cxx-version-script.patch", self.script)
        self.assertNotIn("0009-clr-cxx-version-glob-patterns.patch", self.script)


if __name__ == "__main__":
    unittest.main(verbosity=2)
