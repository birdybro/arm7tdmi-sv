#!/usr/bin/env python3
"""Fail-hard unit tests for the release regression harness."""

from __future__ import annotations

import json
import pathlib
import tempfile
import unittest

import regression_harness


class RegressionHarnessTest(unittest.TestCase):
    def test_metadata_records_reproducibility_inputs(self) -> None:
        metadata = regression_harness.collect_metadata(
            unit_tests=("alpha", "beta"),
            integration_tests=("gamma",),
            variant="unit-test",
            seed=12345,
        )

        self.assertRegex(metadata["git"]["commit"], r"^[0-9a-f]{40}$")
        self.assertIsInstance(metadata["git"]["dirty"], bool)
        self.assertIn("Verilator", metadata["tools"]["verilator"])
        self.assertIn("clang", metadata["tools"]["clang"].lower())
        self.assertIn("QEMU emulator version", metadata["tools"]["qemu"])
        self.assertIn("Quartus", metadata["tools"]["quartus"])
        self.assertIn("Python", metadata["tools"]["python"])
        self.assertEqual(metadata["variant"], "unit-test")
        self.assertEqual(metadata["seed"], 12345)
        self.assertEqual(metadata["manifest"]["unit"], ["alpha", "beta"])
        self.assertEqual(metadata["manifest"]["integration"], ["gamma"])
        self.assertEqual(
            metadata["manifest"]["fpga"],
            [
                "quartus-analysis",
                "quartus-conformance-analysis",
                "quartus-compile",
                "quartus-conformance-compile",
                "quartus-option-characterization",
                "postfit-sim",
                "mister-framework-build",
            ],
        )
        self.assertEqual(metadata["manifest"]["smoke"], ["arm7tdmis_tb_top"])

    def test_full_regression_runs_both_quartus_profiles(self) -> None:
        quick = [
            name
            for name, _ in regression_harness._phases(
                ("unit",), ("integration",), quick=True
            )
        ]
        full = [
            name
            for name, _ in regression_harness._phases(
                ("unit",), ("integration",), quick=False
            )
        ]

        self.assertIn("quartus-analysis", quick)
        self.assertIn("quartus-conformance-analysis", quick)
        self.assertNotIn("quartus-compile", quick)
        self.assertNotIn("quartus-conformance-compile", quick)
        self.assertIn("quartus-compile", full)
        self.assertIn("quartus-conformance-compile", full)
        self.assertIn("quartus-option-characterization", full)
        self.assertNotIn("quartus-option-characterization", quick)
        self.assertIn("postfit-sim", full)
        self.assertNotIn("postfit-sim", quick)
        self.assertIn("mister-framework", full)
        self.assertNotIn("mister-framework", quick)

    def test_simulation_only_profile_omits_every_quartus_phase(self) -> None:
        phases = [
            name
            for name, _ in regression_harness._phases(
                ("unit",),
                ("integration",),
                quick=True,
                include_fpga=False,
            )
        ]

        self.assertFalse(any(name.startswith("quartus-") for name in phases))
        self.assertNotIn("postfit-sim", phases)
        self.assertIn("lint-rtl", phases)
        self.assertIn("harness-expected-failure", phases)
        self.assertIn("smoke", phases)

    def test_quick_profile_keeps_independent_and_compiler_programs(self) -> None:
        phases = [
            name
            for name, _ in regression_harness._phases(
                ("unit",),
                ("ordinary", "compiler", "qemu_diff", "later"),
                quick=True,
                include_fpga=False,
            )
        ]

        self.assertIn("integration-qemu_diff", phases)
        self.assertIn("integration-compiler", phases)
        self.assertNotIn("integration-ordinary", phases)
        self.assertNotIn("integration-later", phases)

    def test_full_aggregate_phases_consume_selected_report(self) -> None:
        alternate = (
            regression_harness.REPO_ROOT
            / "reports/generated/alternate-regression.json"
        )
        phases = dict(
            regression_harness._phases(
                ("unit",),
                ("integration",),
                quick=False,
                include_fpga=False,
                regression_report=alternate,
            )
        )

        assignment = f"REGRESSION_REPORT={alternate}"
        self.assertEqual(phases["table7-cross"][-1], assignment)
        self.assertEqual(phases["functional-coverage"][-1], assignment)
        self.assertNotIn(assignment, phases["formal"])

    def test_full_aggregate_report_must_be_repository_local(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            outside = pathlib.Path(directory) / "regression.json"
            with self.assertRaisesRegex(
                ValueError, "full regression report must be inside"
            ):
                regression_harness.resolve_report_path(
                    outside, require_repo_local=True
                )

            self.assertEqual(
                regression_harness.resolve_report_path(
                    outside, require_repo_local=False
                ),
                outside.resolve(),
            )

    def test_atomic_report_is_machine_readable(self) -> None:
        report = {
            "schema": "arm7tdmis-regression-v1",
            "status": "passed",
            "results": [{"name": "unit-example", "status": "passed"}],
        }
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "regression.json"
            regression_harness.write_report(path, report)
            decoded = json.loads(path.read_text(encoding="utf-8"))

        self.assertEqual(decoded, report)

    def test_expected_failure_must_really_fail(self) -> None:
        passed = regression_harness.expected_failure(
            ("python3", "-c", "raise SystemExit(7)")
        )
        self.assertTrue(passed)

        false_positive = regression_harness.expected_failure(
            ("python3", "-c", "raise SystemExit(0)")
        )
        self.assertFalse(false_positive)


if __name__ == "__main__":
    unittest.main()
