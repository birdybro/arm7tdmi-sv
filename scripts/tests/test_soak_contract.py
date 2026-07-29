#!/usr/bin/env python3
"""Release contract for deterministic sanitizing soak validation."""

from __future__ import annotations

import pathlib
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]


class SoakContractTest(unittest.TestCase):
    def test_harness_is_deterministic_fail_hard_and_reproducible(self) -> None:
        harness_path = REPO_ROOT / "scripts/soak_harness.py"
        self.assertTrue(harness_path.is_file())
        harness = harness_path.read_text(encoding="utf-8")
        for evidence in (
            "arm7tdmis-soak-v1",
            "ASAN_OPTIONS",
            "UBSAN_OPTIONS",
            "timeout=",
            "sha256",
            "failing_seed",
            "minimize",
            "reproducer",
            "+SEED=",
            "check=True",
        ):
            self.assertIn(evidence, harness)

    def test_randomized_workload_and_sanitizing_build_are_registered(self) -> None:
        testbench = (
            REPO_ROOT / "tb/integration/arm7tdmis_mister_wrapper_tb.sv"
        ).read_text(encoding="utf-8")
        makefile = (REPO_ROOT / "scripts/Makefile").read_text(
            encoding="utf-8"
        )
        regression = (
            REPO_ROOT / "scripts/regression_harness.py"
        ).read_text(encoding="utf-8")

        for evidence in (
            '$value$plusargs("SEED=%d"',
            "lfsr_seed",
            "[mister_wrapper] PASS seed=",
        ):
            self.assertIn(evidence, testbench)
        for evidence in (
            "SOAK_SEEDS ?= 256",
            "--x-assign unique",
            "--x-initial unique",
            "-fsanitize=address,undefined",
            "soak-build:",
            "soak:",
            "soak_harness.py",
        ):
            self.assertIn(evidence, makefile)
        self.assertIn('"soak"', regression)
        self.assertIn("if not quick", regression)

    def test_soak_is_scheduled_documented_and_archived(self) -> None:
        workflow = (
            REPO_ROOT / ".github/workflows/verification.yml"
        ).read_text(encoding="utf-8")
        release = (REPO_ROOT / "scripts/release_evidence.py").read_text(
            encoding="utf-8"
        )
        verification = (
            REPO_ROOT / "docs/VERIFICATION.md"
        ).read_text(encoding="utf-8")
        tasks = (REPO_ROOT / "TASKS.md").read_text(encoding="utf-8")

        self.assertIn("make -C scripts soak", workflow)
        self.assertIn("soak-report.json", release)
        self.assertIn("arm7tdmis-soak-v1", verification)
        self.assertIn("make -C scripts soak", verification)
        self.assertIn("- [x] **VAL-010:**", tasks)
        block = tasks[tasks.index("**VAL-010:**"):tasks.index("**VAL-011:**")]
        self.assertIn("soak_harness.py", block)
        self.assertIn("256", block)


if __name__ == "__main__":
    unittest.main()
