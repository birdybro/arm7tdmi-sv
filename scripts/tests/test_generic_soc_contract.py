#!/usr/bin/env python3
"""Contracts for the portable ROM/RAM/timer/UART integration example."""

from __future__ import annotations

import pathlib
import unittest


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
            "saw_timer_irq",
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
            "sim-generic-soc:",
        ):
            self.assertIn(target, makefile)
        self.assertIn("lint-generic-soc-slang", regression)
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
        ):
            self.assertIn(address, documentation)
        self.assertIn("UART_TX_READY", documentation)
        self.assertIn("timer", documentation.lower())
        self.assertIn("- [x] **MIST-010:**", tasks)


if __name__ == "__main__":
    unittest.main()
