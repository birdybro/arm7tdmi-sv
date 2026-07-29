#!/usr/bin/env python3
"""Release contract for deterministic sanitizing soak validation."""

from __future__ import annotations

import json
import pathlib
import sys
import tempfile
import unittest
from unittest import mock


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import soak_harness  # noqa: E402


class SoakContractTest(unittest.TestCase):
    def test_seed_sequence_is_repeatable_unique_and_nonzero(self) -> None:
        first = soak_harness._seeds(0, 256)
        second = soak_harness._seeds(0, 256)
        self.assertEqual(first, second)
        self.assertEqual(len(first), 256)
        self.assertEqual(len(set(first)), 256)
        self.assertNotIn(0, first)

    def test_minimizer_preserves_failure_while_clearing_seed_bits(self) -> None:
        with mock.patch.object(
            soak_harness, "_still_fails", return_value=True
        ) as still_fails:
            minimized = soak_harness.minimize(
                pathlib.Path("/unused/simulator"),
                0xFFFF,
                1.0,
            )
        self.assertEqual(minimized, 1)
        self.assertEqual(still_fails.call_count, 15)

    def test_minimizer_rejects_a_different_failure_signature(self) -> None:
        observed = {
            "status": "failed",
            "failure_signature": "testbench:request changed",
        }
        with mock.patch.object(
            soak_harness,
            "_execute",
            return_value=(False, observed, "different failure"),
        ):
            self.assertFalse(
                soak_harness._still_fails(
                    pathlib.Path("/unused/simulator"),
                    7,
                    1.0,
                    "sanitizer:address",
                )
            )
            self.assertTrue(
                soak_harness._still_fails(
                    pathlib.Path("/unused/simulator"),
                    7,
                    1.0,
                    "testbench:request changed",
                )
            )

    def test_failure_artifacts_support_external_directories(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            binary = root / "simulator"
            binary.write_bytes(b"simulator")
            artifacts = soak_harness._failure_artifacts(
                binary=binary,
                failing_seed=0xFFFF,
                minimized_seed=1,
                timeout_seconds=2.0,
                output="synthetic failure\n",
                directory=root / "failures",
            )
            reproducer = pathlib.Path(artifacts["reproducer"])
            self.assertTrue(reproducer.is_file())
            self.assertTrue(pathlib.Path(artifacts["log"]).is_file())
            self.assertEqual(
                json.loads(
                    reproducer.read_text(encoding="utf-8")
                )["minimized_seed"],
                1,
            )

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
