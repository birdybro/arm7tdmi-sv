#!/usr/bin/env python3
"""Fail-hard tests for the Chapter 8/Table 8-1 FPGA timing disposition."""

from __future__ import annotations

import copy
import json
import pathlib
import unittest

import ac_timing


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
MANIFEST_PATH = REPO_ROOT / "verification" / "ac_timing.json"
SDC_PATH = REPO_ROOT / "fpga" / "arm7tdmis_conformance.sdc"


class AcTimingContractTest(unittest.TestCase):
    def setUp(self) -> None:
        self.contract = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
        self.sdc = SDC_PATH.read_text(encoding="utf-8")

    def test_complete_revision_locked_table_and_sdc_pass(self) -> None:
        summary = ac_timing.validate_contract(
            self.contract,
            sdc_text=self.sdc,
        )
        self.assertEqual(summary["table_row_count"], 37)
        self.assertEqual(summary["figure_count"], 5)
        self.assertEqual(summary["sdc_mapped_row_count"], 37)
        self.assertEqual(summary["positive_hold_row_count"], 9)
        self.assertEqual(summary["replacement_signal_count"], 2)
        self.assertEqual(summary["integration_owner_count"], 5)

    def test_missing_reordered_and_modified_source_rows_fail(self) -> None:
        missing = copy.deepcopy(self.contract)
        missing["rows"].pop()
        with self.assertRaisesRegex(ValueError, "exactly 37 rows"):
            ac_timing.validate_contract(
                missing, sdc_text=self.sdc, verify_source=False
            )

        reordered = copy.deepcopy(self.contract)
        reordered["rows"][0], reordered["rows"][1] = (
            reordered["rows"][1], reordered["rows"][0]
        )
        with self.assertRaisesRegex(ValueError, "row order/set changed"):
            ac_timing.validate_contract(
                reordered, sdc_text=self.sdc, verify_source=False
            )

        percentage = copy.deepcopy(self.contract)
        percentage["rows"][1]["source_min"] = "39%"
        with self.assertRaisesRegex(ValueError, "tisclken source_min changed"):
            ac_timing.validate_contract(
                percentage, sdc_text=self.sdc, verify_source=False
            )

    def test_scope_figure_and_integration_ownership_are_fail_closed(self) -> None:
        scope = copy.deepcopy(self.contract)
        scope["scope"]["fpga_claim"] = "portable guarantee"
        with self.assertRaisesRegex(ValueError, "physical scope lost"):
            ac_timing.validate_contract(
                scope, sdc_text=self.sdc, verify_source=False
            )

        figure = copy.deepcopy(self.contract)
        figure["figure_groups"][3]["rows"].remove("tohdbgstat")
        with self.assertRaisesRegex(ValueError, "figure-to-row mapping changed"):
            ac_timing.validate_contract(
                figure, sdc_text=self.sdc, verify_source=False
            )

        ownership = copy.deepcopy(self.contract)
        ownership["integration_owned"][3]["signals"].remove("SCANOUT")
        with self.assertRaisesRegex(ValueError, "ownership changed"):
            ac_timing.validate_contract(
                ownership, sdc_text=self.sdc, verify_source=False
            )

    def test_missing_marker_and_weakened_sdc_constraint_fail(self) -> None:
        missing_marker = self.sdc.replace("AC-T8:tovtrans", "AC-T8:deleted", 1)
        with self.assertRaisesRegex(ValueError, "AC-T8:tovtrans marker"):
            ac_timing.validate_contract(
                self.contract, sdc_text=missing_marker, verify_source=False
            )

        weakened = self.sdc.replace(
            "set_output_delay -clock CLK -max 31.250 "
            "[get_ports {TRANS[*]}]",
            "set_output_delay -clock CLK -max 32.250 "
            "[get_ports {TRANS[*]}]",
            1,
        )
        with self.assertRaisesRegex(ValueError, "constraint for tovtrans changed"):
            ac_timing.validate_contract(
                self.contract, sdc_text=weakened, verify_source=False
            )

        reset = self.sdc.replace("nRESET DBGnTRST", "nRESET", 1)
        with self.assertRaisesRegex(ValueError, "DBGnTRST"):
            ac_timing.validate_contract(
                self.contract, sdc_text=reset, verify_source=False
            )

        dbgen = self.sdc.replace(
            "set_false_path -from [get_ports {DBGEN}]",
            "",
            1,
        )
        with self.assertRaisesRegex(ValueError, "DBGEN static"):
            ac_timing.validate_contract(
                self.contract, sdc_text=dbgen, verify_source=False
            )

    def test_report_regression_release_and_documentation_wiring(self) -> None:
        report = ac_timing.build_report(MANIFEST_PATH)
        ac_timing.validate_report(report)
        self.assertEqual(report["schema"], "arm7tdmis-ac-timing-v1")
        self.assertEqual(report["table_row_count"], 37)

        makefile = (REPO_ROOT / "scripts" / "Makefile").read_text(encoding="utf-8")
        harness = (REPO_ROOT / "scripts" / "regression_harness.py").read_text(
            encoding="utf-8"
        )
        release = (REPO_ROOT / "scripts" / "release_evidence.py").read_text(
            encoding="utf-8"
        )
        workflow = (
            REPO_ROOT / ".github" / "workflows" / "verification.yml"
        ).read_text(encoding="utf-8")
        docs = (REPO_ROOT / "docs" / "AC_TIMING.md").read_text(encoding="utf-8")
        tasks = (REPO_ROOT / "TASKS.md").read_text(encoding="utf-8")

        self.assertIn("ac-timing:", makefile)
        self.assertIn('"ac-timing"', harness)
        self.assertIn("ac-timing-report.json", release)
        self.assertIn("ac-timing-report.json", workflow)
        self.assertIn("arm7tdmis-ac-timing-v1", docs)
        self.assertIn("make -C scripts ac-timing", docs)
        self.assertIn("verification/ac_timing.json", tasks)
        self.assertIn("- [x] **FPGA-009:**", tasks)


if __name__ == "__main__":
    unittest.main()
