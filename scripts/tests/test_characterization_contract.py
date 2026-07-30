#!/usr/bin/env python3
"""Contract checks for checked FPGA performance and resource evidence."""

from __future__ import annotations

import hashlib
import json
import pathlib
import re
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]


def _read(relative: str) -> str:
    return (REPO_ROOT / relative).read_text(encoding="utf-8")


class CharacterizationContractTest(unittest.TestCase):
    def test_published_characterization_is_bound_to_hashed_inputs(self) -> None:
        baseline_path = REPO_ROOT / "verification/fpga_characterization.json"
        baseline = json.loads(baseline_path.read_text(encoding="utf-8"))

        self.assertEqual(baseline["schema"], "arm7tdmis-fpga-characterization-v1")
        self.assertEqual(baseline["status"], "passed")
        self.assertEqual(baseline["device"], "5CSEBA6U23I7")
        self.assertEqual(baseline["clock_mhz"], 25)

        manifest_sources: set[str] = set()
        manifest = REPO_ROOT / "fpga/arm7tdmi_mister.f"
        for raw_line in manifest.read_text(encoding="utf-8").splitlines():
            line = raw_line.strip()
            if not line or line.startswith(("#", "+")):
                continue
            manifest_sources.add(
                str((manifest.parent / line).resolve().relative_to(REPO_ROOT))
            )

        expected_inputs = manifest_sources | {
            "fpga/arm7tdmi_mister.f",
            "fpga/arm7tdmi_mister.qip",
            "fpga/arm7tdmi_mister.qsf",
            "fpga/arm7tdmi_mister.sdc",
            "fpga/arm7tdmis_conformance.qsf",
            "fpga/arm7tdmis_conformance.sdc",
            "fpga/arm7tdmi_option_none.qsf",
            "fpga/arm7tdmi_option_debug.qsf",
            "fpga/arm7tdmi_option_coprocessor.qsf",
            "fpga/arm7tdmi_option_both.qsf",
            "fpga/arm7tdmi_options.sdc",
            "fpga/example/arm7tdmi_mister_example_top.sv",
            "scripts/quartus_option_characterization.py",
            "scripts/quartus_report_check.py",
        }
        self.assertEqual(set(baseline["inputs"]), expected_inputs)
        for relative, expected_sha256 in baseline["inputs"].items():
            with self.subTest(input=relative):
                actual = hashlib.sha256((REPO_ROOT / relative).read_bytes()).hexdigest()
                self.assertEqual(actual, expected_sha256)

        profiles = baseline["profiles"]
        self.assertEqual(
            set(profiles),
            {"trimmed", "conformance", "none", "debug", "coprocessor", "both"},
        )
        for name, profile in profiles.items():
            with self.subTest(profile=name):
                self.assertGreater(profile["fmax_mhz"], baseline["clock_mhz"])
                self.assertGreaterEqual(profile["minimum_setup_slack_ns"], 0)
                self.assertGreaterEqual(profile["minimum_hold_slack_ns"], 0)
                self.assertEqual(profile["resources"]["memory_bit"], 0)
                self.assertEqual(profile["resources"]["dsp"], 6)
                self.assertIn("Low", profile["power_confidence"])

        performance = _read("docs/PERFORMANCE.md")
        integration = _read("docs/INTEGRATION.md")
        tasks = _read("TASKS.md")
        for document in (performance, integration, tasks):
            self.assertIn("verification/fpga_characterization.json", document)
        for name in ("trimmed", "conformance"):
            profile = profiles[name]
            for value in (
                f'{profile["resources"]["alm"]:,}',
                f'{profile["resources"]["register"]:,}',
                f'{profile["clock_enable_registers"]:,}',
                f'{profile["fmax_mhz"]:.2f} MHz',
                f'{profile["power_mw"]["total"]:.2f} mW',
            ):
                with self.subTest(document="performance", profile=name, value=value):
                    self.assertIn(value, performance)
        for name in ("none", "debug", "coprocessor", "both"):
            profile = profiles[name]
            for value in (
                f'{profile["resources"]["alm"]:,}',
                f'{profile["resources"]["register"]:,}',
                f'{profile["clock_enable_registers"]:,}',
                f'{profile["fmax_mhz"]:.2f} MHz',
                f'{profile["power_mw"]["core_dynamic"]:.2f} mW',
            ):
                with self.subTest(document="performance", profile=name, value=value):
                    self.assertIn(value, performance)

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
            "5,000 ALMs",
            "7,500 ALMs",
            "verification/fpga_characterization.json",
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
