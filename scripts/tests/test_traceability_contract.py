#!/usr/bin/env python3
"""Fail-hard contract for bidirectional release traceability."""

from __future__ import annotations

import json
import pathlib
import re
import subprocess
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
REQUIREMENT_PATTERN = re.compile(r"\*\*([A-Z]+-\d{3}):\*\*")


class TraceabilityContractTest(unittest.TestCase):
    def test_report_covers_every_requirement_rtl_and_verification_file(self) -> None:
        tool = REPO_ROOT / "scripts/traceability_report.py"
        mapping = REPO_ROOT / "verification/traceability.json"
        self.assertTrue(tool.is_file())
        self.assertTrue(mapping.is_file())

        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / "traceability-report.json"
            subprocess.run(
                (
                    "python3",
                    str(tool),
                    "--check",
                    "--output",
                    str(output),
                ),
                cwd=REPO_ROOT,
                check=True,
            )
            report = json.loads(output.read_text(encoding="utf-8"))

        task_text = (REPO_ROOT / "TASKS.md").read_text(encoding="utf-8")
        requirement_ids = set(REQUIREMENT_PATTERN.findall(task_text))
        self.assertEqual(report["schema"], "arm7tdmis-traceability-v1")
        self.assertEqual(set(report["requirements"]), requirement_ids)
        self.assertEqual(report["unmapped_rtl"], [])
        self.assertEqual(report["unmapped_verification"], [])
        self.assertEqual(report["unknown_requirement_references"], [])
        for requirement_id, row in report["requirements"].items():
            with self.subTest(requirement=requirement_id):
                for field in (
                    "source_sections",
                    "rtl",
                    "tests",
                    "coverage_bins",
                    "latest_result",
                    "ledger_status",
                ):
                    self.assertTrue(row[field], field)

    def test_traceability_is_mandatory_release_evidence(self) -> None:
        makefile = (REPO_ROOT / "scripts/Makefile").read_text(encoding="utf-8")
        harness = (REPO_ROOT / "scripts/regression_harness.py").read_text(
            encoding="utf-8"
        )
        release = (REPO_ROOT / "scripts/release_evidence.py").read_text(
            encoding="utf-8"
        )
        documentation = (REPO_ROOT / "docs/TRACEABILITY.md").read_text(
            encoding="utf-8"
        )
        tasks = (REPO_ROOT / "TASKS.md").read_text(encoding="utf-8")

        self.assertIn("traceability:", makefile)
        self.assertIn('"traceability"', harness)
        self.assertIn("traceability-report.json", release)
        self.assertIn("arm7tdmis-traceability-v1", documentation)
        self.assertIn("bidirectional", documentation.lower())
        self.assertIn("make -C scripts traceability", documentation)
        self.assertIn("- [x] **DOC-003:**", tasks)


if __name__ == "__main__":
    unittest.main()
