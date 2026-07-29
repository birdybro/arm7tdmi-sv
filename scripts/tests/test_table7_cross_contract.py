#!/usr/bin/env python3
"""Fail-first contract for VAL-004 Chapter 7 cross-coverage closure."""

from __future__ import annotations

import json
import pathlib
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]


def _read(relative: str) -> str:
    return (REPO_ROOT / relative).read_text(encoding="utf-8")


class Table7CrossContractTest(unittest.TestCase):
    def test_manifest_defines_every_required_legal_cross(self) -> None:
        path = REPO_ROOT / "verification" / "table7_cross.json"
        self.assertTrue(path.is_file())
        manifest = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(manifest["schema"], "arm7tdmis-table7-cross-map-v1")
        self.assertEqual(
            set(manifest["required_crosses"]),
            {
                "class_waveform_endian_stall",
                "class_condition_mode",
                "register_pc_state",
                "multiply_class_m",
                "block_class_n",
                "coprocessor_class_b_n",
                "memory_class_endian_alignment",
                "memory_class_abort",
                "class_interrupt_exception",
            },
        )
        self.assertEqual(
            set(manifest["crosses"]),
            set(manifest["required_crosses"]),
        )
        for name, cross in manifest["crosses"].items():
            with self.subTest(cross=name):
                self.assertGreater(cross["minimum_rows"], 0)
                self.assertTrue(cross["dimensions"])
                self.assertTrue(cross["evidence"])
                for evidence in cross["evidence"]:
                    self.assertRegex(
                        evidence["phase"], r"^integration-[a-z0-9_]+$"
                    )
                    self.assertIn("PASS", evidence["marker"])
                    self.assertTrue(
                        (REPO_ROOT / evidence["source"]).is_file()
                    )

    def test_runner_is_fail_hard_same_commit_and_hash_validated(self) -> None:
        runner = _read("verification/table7_cross.py")
        for evidence in (
            'SCHEMA = "arm7tdmis-table7-cross-v1"',
            "arm7tdmis-regression-v1",
            "arm7tdmis-table7-cross-map-v1",
            "required_crosses",
            "minimum_rows",
            "log_sha256",
            "source_sha256",
            "expected full regression",
            "[table7-cross] PASS",
        ):
            self.assertIn(evidence, runner)

    def test_cross_gate_is_full_regression_release_evidence(self) -> None:
        makefile = _read("scripts/Makefile")
        regression = _read("scripts/regression_harness.py")
        release = _read("scripts/release_evidence.py")
        tasks = _read("TASKS.md")
        verification = _read("docs/VERIFICATION.md")
        table7 = _read("docs/TABLE7_MATRIX.md")

        for evidence in (
            "table7-cross:",
            "table7_cross.py",
            "table7-cross-report.json",
        ):
            self.assertIn(evidence, makefile)
        self.assertIn('"table7-cross"', regression)
        self.assertIn("if not quick", regression)
        self.assertIn("arm7tdmis-table7-cross-v1", release)
        self.assertIn("table7-cross-report.json", release)
        self.assertIn("- [x] **VAL-004:**", tasks)
        self.assertIn("Chapter 7 cross coverage", verification)
        self.assertIn("zero missing required cross bins", table7)


if __name__ == "__main__":
    unittest.main()
