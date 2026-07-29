#!/usr/bin/env python3
"""Release contract for independent QEMU architectural comparison."""

from __future__ import annotations

import pathlib
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]


class QemuDifferentialContractTest(unittest.TestCase):
    def test_reference_runner_is_independent_and_fail_hard(self) -> None:
        runner_path = (
            REPO_ROOT / "verification" / "qemu_armv4t_reference.py"
        )
        self.assertTrue(runner_path.is_file())
        runner = runner_path.read_text(encoding="utf-8")

        for evidence in (
            "qemu-system-arm",
            "one-insn-per-tb=on",
            "QEMU emulator version",
            "subprocess.run",
            "check=True",
            "expected.hex",
            "program.hex",
            "metadata.json",
            "sha256",
        ):
            self.assertIn(evidence, runner)
        for forbidden in (
            "arm7tdmis_instr_pkg",
            "arm7tdmis_decoder",
            "rtl/",
        ):
            self.assertNotIn(forbidden, runner)

    def test_program_and_rtl_scoreboard_cross_arm_thumb_and_memory(self) -> None:
        program_path = (
            REPO_ROOT / "verification" / "programs" / "qemu_diff.S"
        )
        testbench_path = (
            REPO_ROOT / "tb" / "integration" / "arm7tdmis_qemu_diff_tb.sv"
        )
        self.assertTrue(program_path.is_file())
        self.assertTrue(testbench_path.is_file())
        program = program_path.read_text(encoding="utf-8")
        testbench = testbench_path.read_text(encoding="utf-8")

        for evidence in (
            ".cpu arm7tdmi",
            ".arm",
            ".thumb",
            "mul",
            "ldr",
            "str",
            "ldrh",
            "strh",
            "bx",
            "measure_begin",
            "measure_end",
        ):
            self.assertIn(evidence, program.lower())
        for evidence in (
            "ARM7TDMIS_VERIFICATION",
            "VER_RETIRE_VALID",
            "VER_RETIRE_GPRS",
            "VER_RETIRE_CPSR",
            "$readmemh",
            "EXPECTED_EVENTS",
            "expected_memory",
            "[qemu_diff] PASS",
            "$fatal",
        ):
            self.assertIn(evidence, testbench)

    def test_differential_is_mandatory_in_local_and_ci_regression(self) -> None:
        makefile = (REPO_ROOT / "scripts" / "Makefile").read_text(
            encoding="utf-8"
        )
        workflow = (
            REPO_ROOT / ".github" / "workflows" / "verification.yml"
        ).read_text(encoding="utf-8")
        tasks = (REPO_ROOT / "TASKS.md").read_text(encoding="utf-8")
        verification = (
            REPO_ROOT / "docs" / "VERIFICATION.md"
        ).read_text(encoding="utf-8")

        self.assertIn("INTEG_TESTS := qemu_diff ", makefile)
        self.assertIn("INTEG_EXTRA_FLAGS_qemu_diff := "
                      "-DARM7TDMIS_VERIFICATION", makefile)
        self.assertIn("qemu_armv4t_reference.py", makefile)
        for package in ("qemu-system-arm", "clang", "lld"):
            self.assertIn(package, workflow)
        self.assertIn("- [x] **VAL-001:**", tasks)
        block = tasks[tasks.index("**VAL-001:**"):tasks.index("**VAL-002:**")]
        self.assertIn("qemu_armv4t_reference.py", block)
        self.assertIn("arm7tdmis_qemu_diff_tb.sv", block)
        self.assertIn("QEMU", verification)
        self.assertIn("integ-qemu_diff", verification)


if __name__ == "__main__":
    unittest.main()
