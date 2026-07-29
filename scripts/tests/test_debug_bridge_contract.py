#!/usr/bin/env python3
"""Release contract for the JTAG-006 project-specific bridge alternative."""

from __future__ import annotations

import pathlib
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]


class DebugBridgeContractTest(unittest.TestCase):
    def test_bridge_is_public_synchronous_and_fail_closed(self) -> None:
        bridge = (
            REPO_ROOT / "rtl/jtag/arm7tdmis_sync_debug_port.sv"
        ).read_text(encoding="utf-8")
        wrapper = (
            REPO_ROOT / "rtl/top/arm7tdmi_mister.sv"
        ).read_text(encoding="utf-8")
        package = (REPO_ROOT / "fpga/arm7tdmi_mister.qip").read_text(
            encoding="utf-8"
        )

        for signal in (
            "STEP_VALID",
            "STEP_READY",
            "STEP_RSP_VALID",
            "STEP_RSP_READY",
            "STEP_TDO_OE",
            "DBGTCKEN",
            "PORT_ENABLE",
        ):
            self.assertIn(signal, bridge)
        self.assertIn("assign DBGTCKEN   = step_accept", bridge)
        self.assertIn("response_valid_q", bridge)
        self.assertIn("arm7tdmis_sync_debug_port u_debug_transport", wrapper)
        self.assertIn("DBG_STEP_VALID", wrapper)
        self.assertIn("arm7tdmis_sync_debug_port.sv", package)

    def test_bridge_protocol_and_full_scan_evidence_are_mandatory(self) -> None:
        transport_test = (
            REPO_ROOT / "tb/unit/sync_debug_port_tb.sv"
        ).read_text(encoding="utf-8")
        makefile = (REPO_ROOT / "scripts/Makefile").read_text(
            encoding="utf-8"
        )
        tasks = (REPO_ROOT / "TASKS.md").read_text(encoding="utf-8")

        for evidence in (
            "response was blocked",
            "duplicate clock",
            "response replacement",
            "disabled transport",
            "IDCODE mismatch",
            "$fatal",
            "PASS",
        ):
            self.assertIn(evidence, transport_test)
        self.assertIn("sync_debug_port", makefile)
        for system_test in (
            "debug_register_scan",
            "debug_system_speed",
            "debug_monitor_mode",
            "cp14_dcc",
        ):
            self.assertIn(system_test, makefile)
        self.assertIn("- [x] **JTAG-006:**", tasks)
        block = tasks[
            tasks.index("**JTAG-006:**"):tasks.index("**ETM-001:**")
        ]
        self.assertIn("project-specific bridge", block)
        self.assertIn("sync_debug_port_tb.sv", block)

    def test_documentation_states_why_a_physical_pod_needs_another_bridge(
        self,
    ) -> None:
        debug = (REPO_ROOT / "docs/DEBUG.md").read_text(encoding="utf-8")
        support = (REPO_ROOT / "docs/SUPPORT.md").read_text(encoding="utf-8")
        limitations = (REPO_ROOT / "docs/LIMITATIONS.md").read_text(
            encoding="utf-8"
        )
        for evidence in (
            "not a TCK synchronizer",
            "no RTCK claim",
            "asynchronous JTAG pod",
            "separately specified and verified CDC bridge",
            "same-clock",
        ):
            self.assertIn(evidence, debug)
        self.assertIn("Synchronous debug-step bridge", support)
        self.assertNotIn("JTAG-006", limitations)


if __name__ == "__main__":
    unittest.main()
