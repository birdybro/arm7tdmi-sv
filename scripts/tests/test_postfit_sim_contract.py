#!/usr/bin/env python3
"""Release contract for fitted-netlist architectural simulation."""

from __future__ import annotations

import pathlib
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]


class PostfitSimulationContractTest(unittest.TestCase):
    def test_runner_builds_two_fitted_endian_profiles_fail_hard(self) -> None:
        runner_path = REPO_ROOT / "scripts" / "postfit_sim.py"
        self.assertTrue(runner_path.is_file())
        runner = runner_path.read_text(encoding="utf-8")

        for evidence in (
            "arm7tdmis-postfit-v1",
            "5CSEBA6U23I7",
            "AUTO_DSP_RECOGNITION OFF",
            "BIG_ENDIAN",
            '"little"',
            '"big"',
            "quartus_map",
            "quartus_fit",
            "quartus_eda",
            "--functional",
            "--write_settings_files=off",
            "verilator",
            "check=True",
            "timeout=",
            "sha256",
            "git",
            "postfit-report.json",
            "[postfit] PASS",
        ):
            self.assertIn(evidence, runner)

    def test_netlist_dependencies_are_checked_and_clean_room_modeled(self) -> None:
        runner = (
            REPO_ROOT / "scripts" / "postfit_sim.py"
        ).read_text(encoding="utf-8")
        primitives_path = (
            REPO_ROOT
            / "verification"
            / "intel_cyclonev_postfit_primitives.sv"
        )
        self.assertTrue(primitives_path.is_file())
        primitives = primitives_path.read_text(encoding="utf-8")

        for primitive in (
            "dffeas",
            "cyclonev_lcell_comb",
            "cyclonev_io_ibuf",
            "cyclonev_io_obuf",
            "cyclonev_clkena",
        ):
            self.assertIn(f"module {primitive}", primitives)
            self.assertIn(primitive, runner)
        for forbidden in (
            "cyclonev_mac",
            "_encrypted",
            "altera_mf",
        ):
            self.assertIn(forbidden, runner)
        self.assertIn("clean-room", primitives.lower())
        self.assertNotIn("Copyright (C) 2017", primitives)

    def test_scoreboard_covers_architecture_and_wrapper_boundary(self) -> None:
        testbench_path = (
            REPO_ROOT / "tb" / "postfit" / "arm7tdmi_postfit_tb.sv"
        )
        self.assertTrue(testbench_path.is_file())
        testbench = testbench_path.read_text(encoding="utf-8")

        for evidence in (
            "module arm7tdmi_postfit_tb",
            "arm7tdmi_mister",
            "POSTFIT_BIG_ENDIAN",
            "RESET_N",
            "CPU_CE",
            "IRQ_ASYNC",
            "MEM_VALID",
            "MEM_READY",
            "MEM_BYTE_ENABLE",
            "MEM_WDATA",
            "request_payload",
            "request payload changed before ready",
            "accepted_while_ce_low",
            "longest_wait",
            "saw_irq_vector",
            "saw_reset_vector",
            "saw_byte_write",
            "saw_halfword_write",
            "endian lane",
            "[postfit] PASS",
            "$fatal",
        ):
            self.assertIn(evidence, testbench)

    def test_full_regression_and_release_evidence_require_postfit_result(
        self,
    ) -> None:
        makefile = (REPO_ROOT / "scripts" / "Makefile").read_text(
            encoding="utf-8"
        )
        harness = (REPO_ROOT / "scripts" / "regression_harness.py").read_text(
            encoding="utf-8"
        )
        release = (REPO_ROOT / "scripts" / "release_evidence.py").read_text(
            encoding="utf-8"
        )
        tasks = (REPO_ROOT / "TASKS.md").read_text(encoding="utf-8")
        verification = (REPO_ROOT / "docs" / "VERIFICATION.md").read_text(
            encoding="utf-8"
        )
        provenance = (REPO_ROOT / "docs" / "PROVENANCE.md").read_text(
            encoding="utf-8"
        )

        self.assertIn("postfit-sim:", makefile)
        self.assertIn("postfit_sim.py", makefile)
        self.assertIn('"postfit-sim"', harness)
        self.assertIn("arm7tdmis-postfit-v1", release)
        self.assertIn("postfit-report.json", release)
        self.assertIn("- [x] **FPGA-006:**", tasks)
        self.assertIn("postfit-sim", verification)
        self.assertIn("clean-room", provenance.lower())


if __name__ == "__main__":
    unittest.main()
