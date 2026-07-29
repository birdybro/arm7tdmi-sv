#!/usr/bin/env python3
"""Static contract checks for checked-in raw and FPGA timing constraints."""

from __future__ import annotations

import pathlib
import re
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
RAW_SDC = REPO_ROOT / "scripts" / "arm7tdmis.sdc"
FPGA_SDC = REPO_ROOT / "fpga" / "arm7tdmi_mister.sdc"


def _command_list(path: pathlib.Path) -> list[str]:
    """Return active Tcl commands with continuations/collections normalized."""
    commands: list[str] = []
    current = ""
    brace_depth = 0
    bracket_depth = 0
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.split("#", maxsplit=1)[0].strip()
        if not line:
            continue

        continued = line.endswith("\\")
        if continued:
            line = line[:-1].rstrip()
        current = f"{current} {line}".strip()
        brace_depth += line.count("{") - line.count("}")
        bracket_depth += line.count("[") - line.count("]")

        if not continued and brace_depth == 0 and bracket_depth == 0:
            commands.append(current)
            current = ""

    if current:
        commands.append(current)
    return commands


def _commands(path: pathlib.Path) -> str:
    return " ".join(_command_list(path))


class SdcContractTest(unittest.TestCase):
    def test_raw_top_sdc_uses_only_the_real_clock_and_ports(self) -> None:
        text = RAW_SDC.read_text(encoding="utf-8")
        commands = _commands(RAW_SDC)

        self.assertIn("arm7tdmis_top", text)
        self.assertRegex(commands, r"create_clock\b.*get_ports\s+\{?CLK\}?")
        self.assertNotRegex(commands, r"\bDBGTCK\b")
        self.assertNotRegex(commands, r"get_ports[^\]]*\b(?:SE|SI|SO)\b")

    def test_raw_synchronous_inputs_are_timed_not_false_pathed(self) -> None:
        false_paths = " ".join(
            command
            for command in _command_list(RAW_SDC)
            if command.startswith("set_false_path")
        )
        for port in ("nIRQ", "nFIQ", "DBGTCKEN"):
            with self.subTest(port=port):
                self.assertNotRegex(false_paths, rf"\b{port}\b")

    def test_fpga_sdc_constrains_only_real_clock_and_async_boundaries(self) -> None:
        commands = _commands(FPGA_SDC)
        false_paths = " ".join(
            command
            for command in _command_list(FPGA_SDC)
            if command.startswith("set_false_path")
        )

        self.assertRegex(commands, r"create_clock\b.*get_ports\s+\{?CLK\}?")
        self.assertNotRegex(commands, r"\bDBGTCK\b")
        for async_port in (
            "RESET_N",
            "IRQ_ASYNC",
            "FIQ_ASYNC",
            "DEBUG_ENABLE_ASYNC",
            "DBGRQ_ASYNC",
            "DBGBREAK_ASYNC",
            "DBGEXT_ASYNC",
        ):
            with self.subTest(async_port=async_port):
                self.assertRegex(false_paths, rf"\b{async_port}\b")

        for synchronous_port in ("CPU_CE", "MEM_READY", "MEM_RDATA", "MEM_ERROR"):
            with self.subTest(synchronous_port=synchronous_port):
                self.assertNotRegex(
                    false_paths,
                    rf"\b{synchronous_port}\b",
                )


if __name__ == "__main__":
    unittest.main()
