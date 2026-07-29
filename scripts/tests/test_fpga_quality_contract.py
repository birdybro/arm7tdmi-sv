#!/usr/bin/env python3
"""Fail-first contract for independent lint and structural CDC/RDC closure."""

from __future__ import annotations

import json
import pathlib
import sys
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import cdc_rdc_check  # noqa: E402
import independent_lint  # noqa: E402


class FpgaQualityContractTest(unittest.TestCase):
    def test_checked_tree_has_one_clock_and_no_cdc_rdc_violations(self) -> None:
        manifest_path = REPO_ROOT / "verification/cdc_rdc_manifest.json"
        report = cdc_rdc_check.build_report(
            repo_root=REPO_ROOT,
            manifest_path=manifest_path,
        )
        cdc_rdc_check.validate_report(report)
        self.assertEqual(report["schema"], "arm7tdmis-cdc-rdc-v1")
        self.assertEqual(report["status"], "passed")
        self.assertEqual(report["clock_domains"], ["CLK"])
        self.assertEqual(report["violations"], [])
        self.assertEqual(report["synchronizer_count"], 6)
        self.assertEqual(
            report["reset_synchronizer_primitive"]["status"],
            "verified",
        )
        self.assertGreater(report["sequential_block_count"], 20)
        self.assertGreater(report["async_reset_block_count"], 5)

    def test_structural_analyzer_rejects_unsafe_crossings(self) -> None:
        safe_source = """
module crossing(
  input logic CLK, RESET_N, EVENT_ASYNC,
  output logic EVENT_SYNC
);
  logic event_meta_q;
  always_ff @(posedge CLK or negedge RESET_N) begin
    if (!RESET_N) begin
      event_meta_q <= 1'b0;
      EVENT_SYNC <= 1'b0;
    end else begin
      event_meta_q <= EVENT_ASYNC;
      EVENT_SYNC <= event_meta_q;
    end
  end
endmodule
"""
        manifest = {
            "clock_domains": ["CLK"],
            "allowed_async_resets": ["RESET_N"],
            "synchronizers": [
                {
                    "file": "rtl/crossing.sv",
                    "source": "EVENT_ASYNC",
                    "first_stage": "event_meta_q",
                    "second_stage": "EVENT_SYNC",
                }
            ],
        }
        safe = cdc_rdc_check.analyze_sources(
            {"rtl/crossing.sv": safe_source},
            manifest,
        )
        self.assertEqual(safe["violations"], [])

        mutations = {
            "extra-clock": safe_source.replace("posedge CLK", "posedge AUX_CLK"),
            "generated-reset": safe_source.replace(
                "negedge RESET_N", "negedge reset_comb"
            ),
            "meta-fanout": safe_source.replace(
                "endmodule",
                "assign unsafe = event_meta_q;\nendmodule",
            ),
        }
        for name, source in mutations.items():
            with self.subTest(name=name):
                result = cdc_rdc_check.analyze_sources(
                    {"rtl/crossing.sv": source},
                    manifest,
                )
                self.assertTrue(result["violations"])

    def test_independent_lint_covers_every_public_synthesis_top(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / "independent-lint.json"
            commands = independent_lint.build_commands(
                slang=pathlib.Path("/tools/slang"),
                output=output,
            )
        tops = {
            command[command.index("--top") + 1]
            for command in commands
        }
        self.assertEqual(
            tops,
            {
                "arm7tdmis_top",
                "arm7tdmi_mister",
                "arm7tdmis_no_dft",
                "arm7tdmi_mister_example_top",
                "arm7tdmi_generic_soc",
            },
        )
        source = (REPO_ROOT / "scripts/independent_lint.py").read_text(
            encoding="utf-8"
        )
        for evidence in (
            "arm7tdmis-independent-lint-v1",
            "check=True",
            "sha256",
            "warning_count",
            "error_count",
        ):
            self.assertIn(evidence, source)

    def test_fpga_quality_is_mandatory_documented_release_evidence(self) -> None:
        makefile = (REPO_ROOT / "scripts/Makefile").read_text(
            encoding="utf-8"
        )
        regression = (
            REPO_ROOT / "scripts/regression_harness.py"
        ).read_text(encoding="utf-8")
        release = (REPO_ROOT / "scripts/release_evidence.py").read_text(
            encoding="utf-8"
        )
        verification = (REPO_ROOT / "docs/VERIFICATION.md").read_text(
            encoding="utf-8"
        )
        tasks = (REPO_ROOT / "TASKS.md").read_text(encoding="utf-8")
        manifest = json.loads(
            (REPO_ROOT / "verification/cdc_rdc_manifest.json").read_text(
                encoding="utf-8"
            )
        )

        for evidence in (
            "lint-independent:",
            "cdc-rdc:",
            "fpga-quality:",
            "independent_lint.py",
            "cdc_rdc_check.py",
        ):
            self.assertIn(evidence, makefile)
        self.assertIn('"lint-independent"', regression)
        self.assertIn('"cdc-rdc"', regression)
        self.assertIn("independent-lint.json", release)
        self.assertIn("cdc-rdc.json", release)
        self.assertIn("arm7tdmis-cdc-rdc-v1", verification)
        self.assertIn("make -C scripts fpga-quality", verification)
        self.assertEqual(manifest["schema"], "arm7tdmis-cdc-rdc-manifest-v1")
        self.assertIn("- [x] **FPGA-004:**", tasks)


if __name__ == "__main__":
    unittest.main()
