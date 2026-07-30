#!/usr/bin/env python3
"""Fail-hard contract tests for the pinned real MiSTer framework build."""

from __future__ import annotations

import pathlib
import tempfile
import unittest

import mister_framework_build as framework


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]


def _write(path: pathlib.Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def _passing_reports(root: pathlib.Path) -> pathlib.Path:
    output = root / "output_files"
    output.mkdir()
    prefix = output / framework.FRAMEWORK_PROJECT
    _write(prefix.with_suffix(".flow.rpt"), "Flow Status : Successful\n")
    _write(
        prefix.with_suffix(".map.summary"),
        "Analysis & Synthesis Status : Successful\n",
    )
    _write(
        prefix.with_suffix(".map.rpt"),
        "arm7tdmi_generic_soc\narm7tdmi_mister\n",
    )
    _write(
        prefix.with_suffix(".fit.summary"),
        "\n".join(
            (
                "Fitter Status : Successful",
                "Top-level Entity Name : sys_top",
                "Device : 5CSEBA6U23I7",
                "Logic utilization (in ALMs) : 12,345 / 41,910",
                "Total registers : 6789",
                "Total block memory bits : 0 / 5,662,720",
                "Total DSP Blocks : 6 / 112",
                "Total PLLs : 4 / 6",
                "",
            )
        ),
    )
    _write(prefix.with_suffix(".fit.rpt"), "Fitter was successful\n")
    _write(prefix.with_suffix(".asm.rpt"), "Assembler was successful\n")
    _write(
        prefix.with_suffix(".sta.summary"),
        "\n".join(
            (
                "Type  : Slow Model Setup 'clk_sys'",
                "Slack : 1.250",
                "Type  : Fast Model Hold 'clk_sys'",
                "Slack : 0.125",
                "",
            )
        ),
    )
    unconstrained = "\n".join(
        f"; {label} ; 0 ; 0 ;"
        for label in framework.UNCONSTRAINED_LABELS
    )
    _write(
        prefix.with_suffix(".sta.rpt"),
        "TimeQuest Timing Analyzer was successful\n"
        "clk_sys 20.000 MHz\n"
        f"{unconstrained}\n",
    )
    prefix.with_suffix(".rbf").write_bytes(b"real-bitstream-fixture")
    return output


class MisterFrameworkContractTest(unittest.TestCase):
    def test_framework_revision_and_complete_local_overlay_are_pinned(self) -> None:
        self.assertEqual(
            framework.FRAMEWORK_URL,
            "https://github.com/MiSTer-devel/Template_MiSTer.git",
        )
        self.assertEqual(
            framework.FRAMEWORK_COMMIT,
            "69b8a2acc6d84dd313b5abcba6a17155287ed3d8",
        )
        self.assertEqual(
            framework.FRAMEWORK_TREE,
            "b8b642eae80716da93754a3e778a5daa3313350b",
        )
        sources = framework.manifest_sources()
        self.assertEqual(len(sources), len(set(sources)))
        self.assertIn(
            REPO_ROOT / "rtl" / "top" / "arm7tdmi_mister.sv",
            sources,
        )

        with tempfile.TemporaryDirectory() as directory:
            checkout = pathlib.Path(directory)
            framework.install_overlay(checkout)
            qip = (checkout / "files.qip").read_text(encoding="utf-8")
            emu = (checkout / "Template.sv").read_text(encoding="utf-8")
            sdc = (checkout / "Template.sdc").read_text(encoding="utf-8")

        for source in sources:
            self.assertIn(source.relative_to(REPO_ROOT).as_posix(), qip)
        self.assertIn("examples/generic_soc/arm7tdmi_generic_soc.sv", qip)
        self.assertIn("module emu", emu)
        self.assertIn("arm7tdmi_generic_soc u_soc", emu)
        self.assertIn("derive_pll_clocks", sdc)
        self.assertIn("derive_clock_uncertainty", sdc)
        self.assertIn("TIMEQUEST_MULTICORNER_ANALYSIS ON", qip)

    def test_report_parser_requires_fit_timing_constraints_and_bitstream(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = _passing_reports(pathlib.Path(directory))
            result, errors = framework.parse_reports(output)

            self.assertEqual(errors, [])
            self.assertEqual(result["status"], "passed")
            self.assertEqual(result["device"], "5CSEBA6U23I7")
            self.assertEqual(result["top"], "sys_top")
            self.assertEqual(result["core_clock_mhz"], 20.0)
            self.assertEqual(result["resources"]["alm"], 12345)
            self.assertEqual(result["timing"]["minimum_setup_slack_ns"], 1.25)
            self.assertEqual(result["timing"]["minimum_hold_slack_ns"], 0.125)
            self.assertTrue(
                all(
                    counts == {"setup": 0, "hold": 0}
                    for counts in result["unconstrained"].values()
                )
            )

    def test_report_parser_rejects_every_signoff_weakening(self) -> None:
        mutations = {
            "negative slack": (
                ".sta.summary",
                "Slack : 1.250",
                "Slack : -0.001",
            ),
            "unconstrained path": (
                ".sta.rpt",
                "; Unconstrained Clocks ; 0 ; 0 ;",
                "; Unconstrained Clocks ; 1 ; 0 ;",
            ),
            "missing core": (
                ".map.rpt",
                "arm7tdmi_mister",
                "removed_core",
            ),
            "critical warning": (
                ".fit.rpt",
                "Fitter was successful",
                "Critical Warning (999999): unsafe\nFitter was successful",
            ),
        }
        for name, (suffix, old, new) in mutations.items():
            with self.subTest(mutation=name):
                with tempfile.TemporaryDirectory() as directory:
                    output = _passing_reports(pathlib.Path(directory))
                    path = output / f"{framework.FRAMEWORK_PROJECT}{suffix}"
                    path.write_text(
                        path.read_text(encoding="utf-8").replace(old, new),
                        encoding="utf-8",
                    )
                    result, errors = framework.parse_reports(output)
                    self.assertEqual(result["status"], "failed")
                    self.assertTrue(errors)

    def test_full_regression_and_release_archive_require_framework_evidence(
        self,
    ) -> None:
        makefile = (REPO_ROOT / "scripts" / "Makefile").read_text(
            encoding="utf-8"
        )
        regression = (
            REPO_ROOT / "scripts" / "regression_harness.py"
        ).read_text(encoding="utf-8")
        release = (REPO_ROOT / "scripts" / "release_evidence.py").read_text(
            encoding="utf-8"
        )
        for text in (makefile, regression, release):
            self.assertIn("mister-framework", text)
        self.assertIn("validate_evidence", release)


if __name__ == "__main__":
    unittest.main()
