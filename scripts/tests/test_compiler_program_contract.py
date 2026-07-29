#!/usr/bin/env python3
"""Release contract for pinned ARMv4T compiler-built programs."""

from __future__ import annotations

import pathlib
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]


class CompilerProgramContractTest(unittest.TestCase):
    def test_toolchain_download_is_versioned_and_hash_verified(self) -> None:
        installer_path = REPO_ROOT / "scripts/install_arm_toolchain.py"
        self.assertTrue(installer_path.is_file())
        installer = installer_path.read_text(encoding="utf-8")
        for evidence in (
            "14.3.rel1",
            "arm-none-eabi",
            "8f6903f8ceb084d9227b9ef991490413014d991874a1e34074443c2a72b14dbd",
            "sha256",
            "urllib.request",
            "tarfile",
            "metadata.json",
        ):
            self.assertIn(evidence, installer)

    def test_sources_build_arm_thumb_and_bidirectional_interworking(self) -> None:
        source_directory = REPO_ROOT / "verification" / "compiler"
        required = (
            "startup.S",
            "arm_program.c",
            "thumb_program.c",
            "linker.ld",
        )
        for name in required:
            self.assertTrue((source_directory / name).is_file(), name)

        arm_source = (source_directory / "arm_program.c").read_text(
            encoding="utf-8"
        )
        thumb_source = (source_directory / "thumb_program.c").read_text(
            encoding="utf-8"
        )
        startup = (source_directory / "startup.S").read_text(encoding="utf-8")
        self.assertIn("thumb_accumulate", arm_source)
        self.assertIn("arm_mix", thumb_source)
        self.assertIn(".arm", startup)
        self.assertIn("arm_main", startup)

        builder_path = REPO_ROOT / "scripts/build_compiler_program.py"
        self.assertTrue(builder_path.is_file())
        builder = builder_path.read_text(encoding="utf-8")
        for evidence in (
            "-march=armv4t",
            "-marm",
            "-mthumb",
            "-mthumb-interwork",
            "-ffreestanding",
            "-nostdlib",
            "program.hex",
            "disassembly.txt",
        ):
            self.assertIn(evidence, builder)

    def test_compiler_execution_is_fail_hard_and_always_regressed(self) -> None:
        testbench_path = (
            REPO_ROOT / "tb" / "integration" / "arm7tdmis_compiler_tb.sv"
        )
        self.assertTrue(testbench_path.is_file())
        testbench = testbench_path.read_text(encoding="utf-8")
        for evidence in (
            "$readmemh",
            "VER_RETIRE_THUMB",
            "saw_arm",
            "saw_thumb",
            "MAILBOX_DONE",
            "[compiler] PASS",
            "$fatal",
        ):
            self.assertIn(evidence, testbench)

        makefile = (REPO_ROOT / "scripts" / "Makefile").read_text(
            encoding="utf-8"
        )
        regression = (
            REPO_ROOT / "scripts" / "regression_harness.py"
        ).read_text(encoding="utf-8")
        workflow = (
            REPO_ROOT / ".github/workflows/verification.yml"
        ).read_text(encoding="utf-8")
        tasks = (REPO_ROOT / "TASKS.md").read_text(encoding="utf-8")
        self.assertIn("compiler", makefile)
        self.assertIn("install_arm_toolchain.py", makefile)
        self.assertIn("build_compiler_program.py", makefile)
        self.assertIn("REQUIRED_QUICK_INTEGRATION", regression)
        self.assertIn('"compiler"', regression)
        self.assertIn("curl", workflow)
        self.assertIn("xz-utils", workflow)
        self.assertIn("- [x] **VAL-009:**", tasks)
        block = tasks[tasks.index("**VAL-009:**"):tasks.index("**VAL-010:**")]
        self.assertIn("arm7tdmis_compiler_tb.sv", block)
        self.assertIn("14.3.Rel1", block)


if __name__ == "__main__":
    unittest.main()
