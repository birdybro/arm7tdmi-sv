#!/usr/bin/env python3
"""Contracts for the portable ROM/RAM/timer/UART integration example."""

from __future__ import annotations

import pathlib
import unittest

import check_generic_soc_rom as rom_check


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]


class GenericSocContractTest(unittest.TestCase):
    def test_example_is_synthesizable_and_uses_only_the_public_cpu_api(
        self,
    ) -> None:
        source_path = (
            REPO_ROOT / "examples" / "generic_soc" / "arm7tdmi_generic_soc.sv"
        )
        self.assertTrue(source_path.is_file())
        source = source_path.read_text(encoding="utf-8")

        self.assertIn("module arm7tdmi_generic_soc", source)
        self.assertIn("arm7tdmi_mister", source)
        self.assertNotIn("u_cpu.", source)
        self.assertNotIn("`include", source)
        for peripheral in (
            "ROM_BASE",
            "RAM_BASE",
            "TIMER_BASE",
            "UART_BASE",
            "TEST_BASE",
            "TEST_STATUS",
            "TEST_SIGNATURE",
        ):
            self.assertIn(peripheral, source)
        for nonsynthesizable in ("initial begin", "$readmem", "#"):
            self.assertNotIn(nonsynthesizable, source)

    def test_program_test_proves_ram_uart_timer_interrupt_and_backpressure(
        self,
    ) -> None:
        testbench_path = (
            REPO_ROOT
            / "examples"
            / "generic_soc"
            / "arm7tdmi_generic_soc_tb.sv"
        )
        self.assertTrue(testbench_path.is_file())
        testbench = testbench_path.read_text(encoding="utf-8")

        for evidence in (
            "UART_TX_READY",
            "UART_TX_VALID",
            "8'h47",
            "8'h49",
            "8'h50",
            "saw_timer_irq",
            "saw_test",
            "TEST_STATUS",
            "TEST_SIGNATURE",
            "32'ha7d1_c0de",
            "CPU_CE",
            "backpressure",
        ):
            self.assertIn(evidence, testbench)
        self.assertIn("$fatal", testbench)
        self.assertIn("[generic_soc] PASS", testbench)

    def test_two_open_source_frontends_and_simulation_are_release_checks(
        self,
    ) -> None:
        makefile = (REPO_ROOT / "scripts" / "Makefile").read_text(
            encoding="utf-8"
        )
        regression = (
            REPO_ROOT / "scripts" / "regression_harness.py"
        ).read_text(encoding="utf-8")
        workflow = (
            REPO_ROOT / ".github" / "workflows" / "verification.yml"
        ).read_text(encoding="utf-8")

        for target in (
            "lint-generic-soc:",
            "lint-generic-soc-slang:",
            "generic-soc-rom-check:",
            "sim-generic-soc:",
        ):
            self.assertIn(target, makefile)
        self.assertIn("lint-generic-soc-slang", regression)
        self.assertIn("generic-soc-rom-check", regression)
        self.assertIn("sim-generic-soc", regression)
        self.assertIn("v11.0/slang-linux-x86_64.tar.gz", workflow)
        self.assertIn(
            "951a170e10e25e54c91565030acfdfc11c3226714ebf225a18ad4166a898d8a4",
            workflow,
        )

    def test_documentation_freezes_map_and_closes_mist_010(self) -> None:
        documentation_path = REPO_ROOT / "docs" / "GENERIC_SOC.md"
        self.assertTrue(documentation_path.is_file())
        documentation = documentation_path.read_text(encoding="utf-8")
        tasks = (REPO_ROOT / "TASKS.md").read_text(encoding="utf-8")

        for address in (
            "0x0000_0000",
            "0x1000_0000",
            "0x2000_0000",
            "0x2000_1000",
            "0x2000_2000",
        ):
            self.assertIn(address, documentation)
        self.assertIn("UART_TX_READY", documentation)
        self.assertIn("0xa7d1_c0de", documentation)
        self.assertIn("timer", documentation.lower())
        self.assertIn("- [x] **MIST-010:**", tasks)

    def test_armv4t_source_covers_board_smoke_paths(self) -> None:
        program = rom_check.PROGRAM_SOURCE.read_text(encoding="utf-8")
        linker = rom_check.LINKER_SCRIPT.read_text(encoding="utf-8")

        for evidence in (
            ".arch armv4t",
            "ldrb",
            "strb",
            "strh",
            "ldrh",
            "ldrsb",
            "umull",
            "stmdb",
            "ldmia",
            "swp",
            "bx",
            "irq_handler",
            "thumb_test",
            "0xa7d1c0de",
            "0x50415353",
            "0x4641494c",
        ):
            self.assertIn(evidence, program)
        self.assertNotIn("blx", program.lower())
        self.assertIn("SIZEOF(.text) <= 0x400", linker)

    def test_rom_equivalence_checker_is_pinned_and_detects_mutation(self) -> None:
        checker = (
            REPO_ROOT / "scripts" / "check_generic_soc_rom.py"
        ).read_text(encoding="utf-8")
        rtl = rom_check.RTL_SOURCE.read_text(encoding="utf-8")
        words = rom_check.parse_rtl_words(rtl)

        self.assertEqual(rom_check.EXPECTED_BYTES, 812)
        self.assertEqual(rom_check.EXPECTED_WORDS, 203)
        self.assertEqual(
            rom_check.EXPECTED_SHA256,
            "ee9c06bc1720ce9e4f9f57da3e162acdfc0e42df403766f6d98bbeb9249c4900",
        )
        self.assertEqual(words[0], 0xEA00000E)
        self.assertEqual(words[0xCA], 0x4641494C)
        self.assertIn("-march=armv4t", checker)
        self.assertIn("Tag_CPU_arch: v4T", checker)
        self.assertIn("compare_rom(binary, rtl_words)", checker)

        with self.assertRaisesRegex(ValueError, "compiled/RTL ROM mismatch"):
            rom_check.compare_rom(b"\x00\x00\x00\x00", words)


if __name__ == "__main__":
    unittest.main()
