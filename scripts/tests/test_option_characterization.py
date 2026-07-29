#!/usr/bin/env python3
"""Contracts for like-for-like optional-feature FPGA characterization."""

from __future__ import annotations

import importlib
import pathlib
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]


class OptionCharacterizationTest(unittest.TestCase):
    def _result(
        self,
        *,
        alm: int,
        registers: int,
        fmax: float,
        dynamic_power: float,
    ) -> dict[str, object]:
        return {
            "status": "passed",
            "device": "5CSEBA6U23I7",
            "top": "arm7tdmi_mister",
            "resources": {
                "alm": alm,
                "register": registers,
                "memory_bit": 0,
                "dsp": 6,
            },
            "fmax_mhz": {"minimum": fmax},
            "power_mw": {"core_dynamic": dynamic_power},
        }

    def test_summary_computes_each_delta_from_the_same_baseline(self) -> None:
        module = importlib.import_module("quartus_option_characterization")
        summary = module.summarize_profiles(
            {
                "none": self._result(
                    alm=3000,
                    registers=2400,
                    fmax=30.0,
                    dynamic_power=25.0,
                ),
                "debug": self._result(
                    alm=3600,
                    registers=3300,
                    fmax=29.0,
                    dynamic_power=29.0,
                ),
                "coprocessor": self._result(
                    alm=3200,
                    registers=2500,
                    fmax=28.5,
                    dynamic_power=27.0,
                ),
                "both": self._result(
                    alm=3800,
                    registers=3400,
                    fmax=28.0,
                    dynamic_power=31.0,
                ),
            }
        )

        self.assertEqual(
            summary["schema"],
            "arm7tdmis-quartus-options-v1",
        )
        self.assertEqual(summary["status"], "passed")
        self.assertEqual(summary["deltas"]["debug"]["alm"], 600)
        self.assertEqual(summary["deltas"]["debug"]["register"], 900)
        self.assertEqual(summary["deltas"]["coprocessor"]["alm"], 200)
        self.assertEqual(summary["deltas"]["both"]["register"], 1000)
        self.assertEqual(summary["deltas"]["both"]["fmax_mhz"], -2.0)
        self.assertEqual(
            summary["deltas"]["coprocessor"]["core_dynamic_power_mw"],
            2.0,
        )

    def test_all_four_checked_projects_share_top_device_sources_and_sdc(
        self,
    ) -> None:
        expected = {
            "none": ("0", "0"),
            "debug": ("1", "0"),
            "coprocessor": ("0", "1"),
            "both": ("1", "1"),
        }
        for profile, (debug, coprocessor) in expected.items():
            qsf = (
                REPO_ROOT / "fpga" / f"arm7tdmi_option_{profile}.qsf"
            ).read_text(encoding="utf-8")
            with self.subTest(profile=profile):
                self.assertIn(
                    "TOP_LEVEL_ENTITY arm7tdmi_mister",
                    qsf,
                )
                self.assertIn("DEVICE 5CSEBA6U23I7", qsf)
                self.assertIn("QIP_FILE arm7tdmi_mister.qip", qsf)
                self.assertIn("SDC_FILE arm7tdmi_options.sdc", qsf)
                self.assertIn(
                    'FITTER_EFFORT "AUTO FIT"',
                    qsf,
                    "option-cost builds must retry placement when a "
                    "single standard fit misses timing",
                )
                self.assertIn(
                    f"set_parameter -name ENABLE_DEBUG {debug}",
                    qsf,
                )
                self.assertIn(
                    "set_parameter -name ENABLE_COPROCESSOR "
                    f"{coprocessor}",
                    qsf,
                )
        self.assertTrue((REPO_ROOT / "fpga" / "arm7tdmi_options.sdc").is_file())

    def test_release_regression_and_docs_require_option_evidence(self) -> None:
        makefile = (REPO_ROOT / "scripts" / "Makefile").read_text(
            encoding="utf-8"
        )
        regression = (
            REPO_ROOT / "scripts" / "regression_harness.py"
        ).read_text(encoding="utf-8")
        performance = (REPO_ROOT / "docs" / "PERFORMANCE.md").read_text(
            encoding="utf-8"
        )
        tasks = (REPO_ROOT / "TASKS.md").read_text(encoding="utf-8")

        self.assertIn("quartus-option-characterization:", makefile)
        self.assertIn("quartus-option-characterization", regression)
        for profile in ("none", "debug", "coprocessor", "both"):
            self.assertIn(f"arm7tdmi_option_{profile}", makefile)
            self.assertIn(f"`{profile}`", performance)
        self.assertIn("quartus-options.json", performance)
        self.assertIn("- [x] **MIST-011:**", tasks)
        block = tasks[tasks.index("**MIST-011:**"):tasks.index("**MIST-012:**")]
        self.assertIn("quartus_option_characterization.py", block)
        self.assertIn("test_option_characterization.py", block)


if __name__ == "__main__":
    unittest.main()
