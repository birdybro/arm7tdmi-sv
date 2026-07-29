#!/usr/bin/env python3
"""Fail-first release contract for VAL-002 constrained-random validation."""

from __future__ import annotations

import pathlib
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]


def _read(relative: str) -> str:
    return (REPO_ROOT / relative).read_text(encoding="utf-8")


class ConstrainedRandomContractTest(unittest.TestCase):
    def test_seeded_generator_has_independent_and_arm7_policy_lanes(self) -> None:
        runner_path = REPO_ROOT / "verification" / "constrained_random.py"
        self.assertTrue(runner_path.is_file())
        runner = runner_path.read_text(encoding="utf-8")

        for evidence in (
            'SCHEMA = "arm7tdmis-constrained-random-v1"',
            "random.Random",
            "qemu-system-arm",
            "one-insn-per-tb=on",
            ".cpu arm7tdmi",
            ".arm",
            ".thumb",
            "MODE_FIQ",
            "MODE_IRQ",
            "MODE_SUPERVISOR",
            "MODE_ABORT",
            "MODE_UNDEFINED",
            "svc",
            "undefined",
            "little",
            "big",
            "unaligned",
            "dependency",
            "permitted_memory",
            "reproducer",
            "sha256",
            "--seeds",
            "--instructions",
        ):
            self.assertIn(evidence, runner)
        for forbidden in (
            "arm7tdmis_instr_pkg",
            "arm7tdmis_decoder",
            "rtl/",
        ):
            self.assertNotIn(forbidden, runner)

    def test_scoreboards_compare_retirement_and_memory_without_peeking(self) -> None:
        differential_path = (
            REPO_ROOT
            / "tb"
            / "integration"
            / "arm7tdmis_random_diff_tb.sv"
        )
        policy_path = (
            REPO_ROOT
            / "tb"
            / "integration"
            / "arm7tdmis_random_policy_tb.sv"
        )
        self.assertTrue(differential_path.is_file())
        self.assertTrue(policy_path.is_file())
        differential = differential_path.read_text(encoding="utf-8")
        policy = policy_path.read_text(encoding="utf-8")

        for evidence in (
            "ARM7TDMIS_VERIFICATION",
            "VER_RETIRE_VALID",
            "VER_RETIRE_EXCEPTION_VALID",
            "VER_RETIRE_GPRS",
            "VER_RETIRE_CPSR",
            "EXPECTED_EVENTS",
            "EXPECTED_HEX",
            "active_physical_index",
            "PERMITTED_MEMORY_HEX",
            "$readmemh",
            "[random_diff] PASS",
            "$fatal",
        ):
            self.assertIn(evidence, differential)
        for evidence in (
            "BIG_ENDIAN",
            "EXPECTED_MEMORY_HEX",
            "EXPECTED_WORDS",
            "$readmemh",
            "[random_policy] PASS",
            "$fatal",
        ):
            self.assertIn(evidence, policy)
        for text in (differential, policy):
            self.assertNotIn("u_dut.u_core", text)

    def test_release_campaign_is_long_reproducible_and_mandatory(self) -> None:
        makefile = _read("scripts/Makefile")
        regression = _read("scripts/regression_harness.py")
        release = _read("scripts/release_evidence.py")
        workflow = _read(".github/workflows/verification.yml")
        tasks = _read("TASKS.md")
        verification = _read("docs/VERIFICATION.md")
        limitations = _read("docs/LIMITATIONS.md")

        for evidence in (
            "RANDOM_SEEDS ?= 32",
            "RANDOM_INSTRUCTIONS ?= 256",
            "random-validation:",
            "arm7tdmis_random_diff_tb",
            "arm7tdmis_random_policy_tb",
            "constrained_random.py",
        ):
            self.assertIn(evidence, makefile)
        self.assertIn('"random-validation"', regression)
        self.assertIn('"random-validation-quick"', regression)
        self.assertIn("arm7tdmis-constrained-random-v1", release)
        self.assertIn("constrained-random-report.json", release)
        self.assertIn("random-validation-quick", workflow)

        self.assertIn("- [x] **VAL-002:**", tasks)
        block = tasks[tasks.index("**VAL-002:**"):tasks.index("**VAL-003:**")]
        for evidence in (
            "32",
            "256",
            "8,192",
            "QEMU",
            "ARM926",
            "big-endian",
            "unaligned",
            "reproducer",
        ):
            self.assertIn(evidence, block)
        self.assertIn("Constrained-random", verification)
        self.assertIn("arm7tdmis-constrained-random-v1", verification)
        self.assertNotIn(
            "Constrained-random generation",
            limitations,
        )


if __name__ == "__main__":
    unittest.main()
