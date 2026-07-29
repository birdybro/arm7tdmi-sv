#!/usr/bin/env python3
"""Contract checks for checked FPGA performance and resource evidence."""

from __future__ import annotations

import pathlib
import re
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]


def _read(relative: str) -> str:
    return (REPO_ROOT / relative).read_text(encoding="utf-8")


class CharacterizationContractTest(unittest.TestCase):
    def test_full_flows_run_power_before_fail_hard_report_check(self) -> None:
        makefile = _read("scripts/Makefile")
        self.assertIn("QUARTUS_POW ?= quartus_pow", makefile)
        for target in ("quartus-compile", "quartus-conformance-compile"):
            match = re.search(
                rf"(?ms)^{re.escape(target)}:.*?(?=^[a-zA-Z][^:]*:|\Z)",
                makefile,
            )
            self.assertIsNotNone(match, target)
            body = match.group(0)
            self.assertIn("$(QUARTUS_POW)", body)
            self.assertLess(
                body.index("$(QUARTUS_POW)"),
                body.index("quartus_report_check.py"),
            )

    def test_performance_document_publishes_checked_limits(self) -> None:
        text = _read("docs/PERFORMANCE.md")
        for heading in (
            "Clock and CPU enable",
            "Request latency",
            "Resources and clock enables",
            "Power estimate",
            "Reset and endian configuration",
            "Reproducing characterization",
        ):
            self.assertRegex(text, rf"(?m)^## .*{re.escape(heading)}")
        for evidence in (
            "5CSEBA6U23I7",
            "Quartus Lite 17.0.2",
            "25 MHz",
            "28.79 MHz",
            "27.24 MHz",
            "3,491",
            "2,512",
            "2,109",
            "4,889",
            "3,823",
            "3,099",
            "450.07 mW",
            "457.79 mW",
            "Low",
            "vectorless",
            "not a board-power estimate",
            "BIG_ENDIAN",
            "MEM_READY",
        ):
            with self.subTest(evidence=evidence):
                self.assertIn(evidence, text)

    def test_fpga_005_is_checked_with_report_and_document_evidence(self) -> None:
        tasks = _read("TASKS.md")
        self.assertIn("- [x] **FPGA-005:**", tasks)
        block = tasks[tasks.index("**FPGA-005:**"):tasks.index("**FPGA-006:**")]
        for evidence in (
            "docs/PERFORMANCE.md",
            "quartus_report_check.py",
            "PowerPlay",
            "clock-enable",
            "Fmax",
            "test_characterization_contract.py",
        ):
            self.assertIn(evidence, block)


if __name__ == "__main__":
    unittest.main()
