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
        self.assertIn("Python", metadata["tools"]["python"])
        self.assertEqual(metadata["variant"], "unit-test")
        self.assertEqual(metadata["seed"], 12345)
        self.assertEqual(metadata["manifest"]["unit"], ["alpha", "beta"])
        self.assertEqual(metadata["manifest"]["integration"], ["gamma"])
        self.assertEqual(metadata["manifest"]["smoke"], ["arm7tdmis_tb_top"])

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
