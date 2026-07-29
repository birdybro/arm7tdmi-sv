#!/usr/bin/env python3
"""Machine-readable coverage and release-evidence contract tests."""

from __future__ import annotations

import json
import pathlib
import tempfile
import unittest

import coverage_report
import release_evidence


def coverage_point(
    source: str, point_type: str, count: int, description: str
) -> str:
    fields = (
        f"\x01f\x02{source}"
        f"\x01l\x0210"
        f"\x01t\x02{point_type}"
        f"\x01o\x02{description}"
    )
    return f"C '{fields}' {count}\n"


class CoverageReportTest(unittest.TestCase):
    def test_raw_points_and_lcov_are_summarized_without_invention(self) -> None:
        raw = "".join(
            (
                coverage_point("rtl/core/example.sv", "line", 4, "hit"),
                coverage_point("rtl/core/example.sv", "line", 0, "miss"),
                coverage_point("rtl/core/example.sv", "toggle", 2, "0->1"),
                coverage_point("tb/example_tb.sv", "branch", 0, "else"),
            )
        )
        lcov = "\n".join(
            (
                "TN:verilator_coverage",
                "SF:rtl/core/example.sv",
                "LF:2",
                "LH:1",
                "BRF:1",
                "BRH:0",
                "end_of_record",
                "",
            )
        )

        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            raw_path = root / "coverage.dat"
            lcov_path = root / "coverage.info"
            raw_path.write_text(raw, encoding="utf-8")
            lcov_path.write_text(lcov, encoding="utf-8")
            report = coverage_report.build_report(
                raw_path=raw_path,
                lcov_path=lcov_path,
                tests=("alpha", "beta"),
                git_commit="a" * 40,
                source_sha256="b" * 64,
                tool_version="Verilator unit",
            )

        self.assertEqual(report["schema"], "arm7tdmis-coverage-v1")
        self.assertEqual(report["tests"], ["alpha", "beta"])
        self.assertEqual(
            report["points"]["all"]["line"], {"covered": 1, "total": 2}
        )
        self.assertEqual(
            report["points"]["rtl"]["toggle"], {"covered": 1, "total": 1}
        )
        self.assertEqual(
            report["points"]["all"]["branch"], {"covered": 0, "total": 1}
        )
        self.assertEqual(
            report["lcov"]["rtl/core/example.sv"]["lines"],
            {"covered": 1, "total": 2},
        )

    def test_release_validation_rejects_bad_or_mismatched_evidence(self) -> None:
        commit = "c" * 40
        regression = {
            "schema": "arm7tdmis-regression-v1",
            "status": "passed",
            "git": {"commit": commit, "dirty": False},
        }
        coverage = {
            "schema": "arm7tdmis-coverage-v1",
            "git": {"commit": commit, "dirty": False},
        }

        release_evidence.validate_evidence(
            regression, coverage, expected_commit=commit
        )

        failed = json.loads(json.dumps(regression))
        failed["status"] = "failed"
        with self.assertRaisesRegex(ValueError, "not passed"):
            release_evidence.validate_evidence(
                failed, coverage, expected_commit=commit
            )

        dirty = json.loads(json.dumps(coverage))
        dirty["git"]["dirty"] = True
        with self.assertRaisesRegex(ValueError, "dirty"):
            release_evidence.validate_evidence(
                regression, dirty, expected_commit=commit
            )

        with self.assertRaisesRegex(ValueError, "commit"):
            release_evidence.validate_evidence(
                regression, coverage, expected_commit="d" * 40
            )


if __name__ == "__main__":
    unittest.main()
