#!/usr/bin/env python3
"""Fail-hard tests for the exhaustive ARM DDI 0234B coverage inventory."""

from __future__ import annotations

import copy
import json
import pathlib
import unittest

import trm_coverage


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
MANIFEST_PATH = REPO_ROOT / "verification" / "trm_coverage.json"


class TrmCoverageContractTest(unittest.TestCase):
    def setUp(self) -> None:
        self.manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))

    def test_complete_revision_locked_inventory_passes(self) -> None:
        summary = trm_coverage.validate_manifest(self.manifest)
        self.assertEqual(
            summary["inventory_counts"],
            {"sections": 207, "tables": 65, "figures": 44, "signals": 45},
        )
        self.assertEqual(summary["total_inventory_items"], 361)
        self.assertEqual(sum(summary["disposition_counts"].values()), 361)
        self.assertEqual(
            summary["disposition_counts"],
            {
                "implemented-and-tested": 343,
                "external-out-of-scope": 8,
                "integration-obligation": 10,
                "erratum-corrected": 0,
                "open-requirement": 0,
            },
        )

    def test_missing_duplicate_unknown_and_unchecked_claims_fail(self) -> None:
        missing = copy.deepcopy(self.manifest)
        missing["inventory"]["sections"].remove("5.18.5")
        with self.assertRaisesRegex(ValueError, "sections inventory mismatch"):
            trm_coverage.validate_manifest(missing)

        duplicate = copy.deepcopy(self.manifest)
        duplicate["coverage_groups"][0]["selectors"].append(
            {"category": "sections", "items": ["1.1"]}
        )
        with self.assertRaisesRegex(ValueError, "selects inventory more than once"):
            trm_coverage.validate_manifest(duplicate)

        unknown = copy.deepcopy(self.manifest)
        unknown["coverage_groups"][0]["requirements"] = ["NOPE-999"]
        with self.assertRaisesRegex(ValueError, "unknown requirements"):
            trm_coverage.validate_manifest(unknown)

        unchecked = copy.deepcopy(self.manifest)
        unchecked["coverage_groups"][0]["requirements"] = ["MIST-007"]
        with self.assertRaisesRegex(ValueError, "unchecked requirement"):
            trm_coverage.validate_manifest(unchecked)

    def test_pdf_and_evidence_identity_are_fail_closed(self) -> None:
        wrong_pdf = copy.deepcopy(self.manifest)
        wrong_pdf["source"]["sha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "source identity changed"):
            trm_coverage.validate_manifest(wrong_pdf)

        missing_evidence = copy.deepcopy(self.manifest)
        missing_evidence["coverage_groups"][0]["evidence"] = [
            "docs/THIS_FILE_DOES_NOT_EXIST.md"
        ]
        with self.assertRaisesRegex(ValueError, "evidence path is missing"):
            trm_coverage.validate_manifest(missing_evidence)

    def test_report_and_release_wiring_are_mandatory(self) -> None:
        report = trm_coverage.build_report(MANIFEST_PATH)
        trm_coverage.validate_report(report)
        self.assertEqual(report["schema"], "arm7tdmis-trm-coverage-v1")
        self.assertEqual(report["total_inventory_items"], 361)

        makefile = (REPO_ROOT / "scripts" / "Makefile").read_text(encoding="utf-8")
        harness = (REPO_ROOT / "scripts" / "regression_harness.py").read_text(
            encoding="utf-8"
        )
        release = (REPO_ROOT / "scripts" / "release_evidence.py").read_text(
            encoding="utf-8"
        )
        docs = (REPO_ROOT / "docs" / "TRM_COVERAGE.md").read_text(encoding="utf-8")
        tasks = (REPO_ROOT / "TASKS.md").read_text(encoding="utf-8")
        self.assertIn("trm-coverage:", makefile)
        self.assertIn('"trm-coverage"', harness)
        self.assertIn("trm-coverage-report.json", release)
        self.assertIn("arm7tdmis-trm-coverage-v1", docs)
        self.assertIn("make -C scripts trm-coverage", docs)
        self.assertIn("- [x] **DOC-008:**", tasks)
        self.assertIn("- [x] **FPGA-009:**", tasks)


if __name__ == "__main__":
    unittest.main()
