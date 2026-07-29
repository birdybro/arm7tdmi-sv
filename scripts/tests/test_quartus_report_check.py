#!/usr/bin/env python3
"""Unit tests for fail-hard Quartus report acceptance."""

from __future__ import annotations

import pathlib
import tempfile
import unittest

import quartus_report_check


class QuartusReportCheckTest(unittest.TestCase):
    def _write_clean_reports(
        self,
        directory: pathlib.Path,
        *,
        project: str = "arm7tdmi_mister",
        top: str = "arm7tdmi_mister_example_top",
    ) -> None:
        prefix = directory / project
        prefix.with_suffix(".flow.rpt").write_text(
            "Flow Status ; Successful\n", encoding="utf-8"
        )
        prefix.with_suffix(".map.summary").write_text(
            "Analysis & Synthesis Status : Successful\n", encoding="utf-8"
        )
        prefix.with_suffix(".fit.summary").write_text(
            "\n".join(
                (
                    "Fitter Status : Successful",
                    f"Top-level Entity Name : {top}",
                    "Device : 5CSEBA6U23I7",
                    "Logic utilization (in ALMs) : 3283 / 41910",
                    "Total registers : 2706",
                    "Total block memory bits : 0 / 5662720",
                    "Total DSP Blocks : 6 / 112",
                )
            )
            + "\n",
            encoding="utf-8",
        )
        prefix.with_suffix(".fit.rpt").write_text(
            "Fitter was successful\n", encoding="utf-8"
        )
        prefix.with_suffix(".asm.rpt").write_text(
            "Assembler was successful\n", encoding="utf-8"
        )
        prefix.with_suffix(".sta.summary").write_text(
            "Type  : Slow Setup 'CLK'\nSlack : 1.250\n"
            "Type  : Fast Hold 'CLK'\nSlack : 0.100\n",
            encoding="utf-8",
        )
        prefix.with_suffix(".sta.rpt").write_text(
            "Design is fully constrained for setup requirements\n"
            "Design is fully constrained for hold requirements\n"
            "TimeQuest Timing Analyzer was successful\n",
            encoding="utf-8",
        )
        prefix.with_suffix(".sof").write_bytes(b"non-empty")

    def test_accepts_clean_complete_flow(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            self._write_clean_reports(directory)
            result, errors = quartus_report_check.validate_reports(directory)

        self.assertEqual(errors, [])
        self.assertEqual(result["status"], "passed")
        self.assertEqual(result["resources"]["alm"], 3283)
        self.assertEqual(result["device"], "5CSEBA6U23I7")

    def test_rejects_timing_critical_warning_and_missing_image(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            self._write_clean_reports(directory)
            prefix = directory / "arm7tdmi_mister"
            prefix.with_suffix(".sta.summary").write_text(
                "Type  : Slow Setup 'CLK'\nSlack : -0.250\n",
                encoding="utf-8",
            )
            prefix.with_suffix(".fit.rpt").write_text(
                "Critical Warning (169085): pins are not assigned\n",
                encoding="utf-8",
            )
            prefix.with_suffix(".sof").unlink()

            result, errors = quartus_report_check.validate_reports(directory)

        self.assertEqual(result["status"], "failed")
        self.assertTrue(any("negative slack" in error for error in errors))
        self.assertTrue(any("Critical Warning" in error for error in errors))
        self.assertTrue(any("programming image" in error for error in errors))

    def test_accepts_named_conformance_profile_and_budget(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            self._write_clean_reports(
                directory,
                project="arm7tdmis_conformance",
                top="arm7tdmis_top",
            )
            (directory / "arm7tdmis_conformance.sof").write_bytes(b"full image")
            result, errors = quartus_report_check.validate_reports(
                directory,
                project="arm7tdmis_conformance",
                expected_top="arm7tdmis_top",
                expected_device="5CSEBA6U23I7",
                resource_limits={
                    "alm": 7_500,
                    "register": 6_000,
                    "dsp": 8,
                    "memory_bit": 0,
                },
            )

        self.assertEqual(errors, [])
        self.assertEqual(result["status"], "passed")
        self.assertEqual(result["project"], "arm7tdmis_conformance")
        self.assertEqual(result["top"], "arm7tdmis_top")
        self.assertEqual(result["resource_limits"]["alm"], 7_500)


if __name__ == "__main__":
    unittest.main()
