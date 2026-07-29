#!/usr/bin/env python3
"""Fail-first release contract for VAL-003 public ARMv4T suites."""

from __future__ import annotations

import json
import pathlib
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]


def _read(relative: str) -> str:
    return (REPO_ROOT / relative).read_text(encoding="utf-8")


class PublicSuiteContractTest(unittest.TestCase):
    def test_manifest_pins_redistributable_source_and_expected_signatures(
        self,
    ) -> None:
        manifest_path = (
            REPO_ROOT / "verification" / "public_suites.json"
        )
        self.assertTrue(manifest_path.is_file())
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

        self.assertEqual(manifest["schema"], "arm7tdmis-public-suites-v1")
        upstream = manifest["upstream"]
        self.assertEqual(
            upstream["url"],
            "https://github.com/jsmolka/gba-suite.git",
        )
        self.assertRegex(upstream["commit"], r"^[0-9a-f]{40}$")
        self.assertRegex(upstream["tree"], r"^[0-9a-f]{40}$")
        self.assertEqual(upstream["license_spdx"], "MIT")
        self.assertEqual(upstream["license_path"], "LICENSE")
        self.assertRegex(upstream["license_sha256"], r"^[0-9a-f]{64}$")

        suites = manifest["suites"]
        self.assertEqual(set(suites), {"arm", "thumb"})
        for name, expected_register in (("arm", 12), ("thumb", 7)):
            suite = suites[name]
            self.assertRegex(suite["upstream_sha256"], r"^[0-9a-f]{64}$")
            self.assertRegex(suite["patched_sha256"], r"^[0-9a-f]{64}$")
            self.assertRegex(suite["idle_pc"], r"^0x08[0-9a-f]{6}$")
            self.assertEqual(suite["result_register"], expected_register)
            self.assertRegex(
                suite["expected_vram_signature"], r"^0x[0-9a-f]{8}$"
            )
            self.assertGreater(suite["minimum_retirements"], 100)
        self.assertIn("zero", manifest["patches"][0]["operation"])
        self.assertIn("0x00000004..0x000000bf", manifest["patches"][0]["range"])

    def test_fetch_runner_is_pinned_fail_hard_and_records_provenance(
        self,
    ) -> None:
        runner_path = REPO_ROOT / "verification" / "public_suite.py"
        self.assertTrue(runner_path.is_file())
        runner = runner_path.read_text(encoding="utf-8")
        for evidence in (
            "public_suites.json",
            "git",
            "fetch",
            "--depth=1",
            "rev-parse",
            "sha256",
            "license_sha256",
            "patched_sha256",
            "expected_vram_signature",
            "arm7tdmis-public-suite-v1",
            "subprocess.run",
            "check=False",
            "reproducer",
            "[public-suite] PASS",
        ):
            self.assertIn(evidence, runner)
        for forbidden in (
            "ARM Validation Suite",
            "arm7tdmis_instr_pkg",
            "u_dut.u_core",
        ):
            self.assertNotIn(forbidden, runner)

    def test_public_port_scoreboard_runs_both_unmodified_test_payloads(
        self,
    ) -> None:
        testbench_path = (
            REPO_ROOT
            / "tb"
            / "integration"
            / "arm7tdmis_public_suite_tb.sv"
        )
        self.assertTrue(testbench_path.is_file())
        testbench = testbench_path.read_text(encoding="utf-8")
        for evidence in (
            "ARM7TDMIS_VERIFICATION",
            "VER_RETIRE_VALID",
            "VER_RETIRE_PC",
            "VER_RETIRE_GPRS",
            "ROM_HEX",
            "IDLE_PC",
            "RESULT_REGISTER",
            "EXPECTED_VRAM_SIGNATURE",
            "REG_DISPSTAT",
            "vblank",
            "boot_words",
            "[public_suite] PASS",
            "$fatal",
        ):
            self.assertIn(evidence, testbench)
        self.assertNotIn("u_dut.u_core", testbench)

    def test_suite_is_mandatory_documented_and_release_validated(self) -> None:
        makefile = _read("scripts/Makefile")
        regression = _read("scripts/regression_harness.py")
        release = _read("scripts/release_evidence.py")
        workflow = _read(".github/workflows/verification.yml")
        tasks = _read("TASKS.md")
        verification = _read("docs/VERIFICATION.md")
        provenance = _read("docs/PROVENANCE.md")
        limitations = _read("docs/LIMITATIONS.md")

        for evidence in (
            "public-suite:",
            "arm7tdmis_public_suite_tb",
            "public_suite.py",
            "public-suite-report.json",
        ):
            self.assertIn(evidence, makefile)
        self.assertIn('"public-suite"', regression)
        self.assertIn("arm7tdmis-public-suite-v1", release)
        self.assertIn("public-suite-report.json", release)
        self.assertIn("public_suite/", workflow)
        self.assertIn("- [x] **VAL-003:**", tasks)
        block = tasks[tasks.index("**VAL-003:**"):tasks.index("**VAL-004:**")]
        for evidence in (
            "gba-suite",
            "MIT",
            "a7113b67e63f83a9b321696ddd7042ccfad6c881",
            "ARM Validation Suite",
            "not",
        ):
            self.assertIn(evidence, block)
        self.assertIn("Public ARMv4T suite", verification)
        self.assertIn("jsmolka/gba-suite", provenance)
        self.assertNotIn("Third-party ARMv4T suites", limitations)


if __name__ == "__main__":
    unittest.main()
