#!/usr/bin/env python3
"""Fail-hard checks that public documentation matches the audited ledger."""

from __future__ import annotations

import pathlib
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
README = REPO_ROOT / "README.md"
AGENTS = REPO_ROOT / "AGENTS.md"
TASKS = REPO_ROOT / "TASKS.md"


def _read(relative: str) -> str:
    return (REPO_ROOT / relative).read_text(encoding="utf-8")


class DocumentationContractTest(unittest.TestCase):
    def test_public_status_does_not_repeat_known_stale_claims(self) -> None:
        public_status = README.read_text(encoding="utf-8") + AGENTS.read_text(
            encoding="utf-8"
        )
        stale_claims = (
            "accepted-operation and busy/data protocols do not",
            "complete exception/abort release gate remains open",
            "broader exception/abort release gate remains open",
            "§31.6 remains the sign-off ledger",
            "No Quartus on the build box yet",
            "Known open categories still include exact debug-pin sampling",
            "synthesis/timing evidence, and MiSTer/PocketStation packaging",
            "per-module SystemVerilog testbenches (10 tests)",
            "15 `make integ` benches",
            "The goal is a **cycle-accurate, synthesizable**",
        )
        for claim in stale_claims:
            with self.subTest(claim=claim):
                self.assertNotIn(claim, public_status)

    def test_release_status_uses_the_canonical_ledger(self) -> None:
        readme = README.read_text(encoding="utf-8")
        agents = AGENTS.read_text(encoding="utf-8")
        tasks = TASKS.read_text(encoding="utf-8")

        self.assertIn("Not sign-off ready", readme)
        self.assertIn("Not sign-off ready", agents)
        self.assertIn("TASKS.md", readme)
        self.assertIn("TASKS.md", agents)
        for status in ("VERIFIED", "IMPLEMENTED-UNVERIFIED", "PARTIAL"):
            with self.subTest(status=status):
                self.assertIn(status, tasks)
                self.assertIn(status, readme)

    def test_corrected_architectural_contracts_remain_documented(self) -> None:
        required_evidence = {
            "docs/EXCEPTIONS.md": (
                "DABT",
                "FIQ > IRQ > PABT > UNDEF > SWI",
                "source instruction address plus 4",
                "source instruction address plus 8",
                "LDM/STM Data Abort completion",
                "LDM Base Updated result",
                "STM writeback and stores",
            ),
            "docs/PSR.md": (
                "There is no Q flag in ARMv4T",
                "leaves the complete CPSR unchanged",
            ),
            "docs/PIPELINE.md": (
                "instruction PC `+ 12`",
                "STM has no I cycle",
            ),
            "docs/COPROCESSOR.md": (
                "It does not contain CP15",
                "Internal CP14 accepts only these exact",
                "Present but busy",
                "Base Updated abort model",
            ),
            "docs/RAW_BUS.md": (
                "Little endian (`CFGBIGEND=0`)",
                "Big endian (`CFGBIGEND=1`)",
            ),
            "docs/DEBUG.md": (
                "monitor-mode restrictions are enforced fail-closed",
                "CP14 DCC and Debug Abort Status",
            ),
            "docs/TRACE.md": (
                "It does not implement an Embedded Trace Macrocell",
                "Table 6-1 adapter",
            ),
            "docs/INTEGRATION.md": (
                "arm7tdmis_no_dft",
                "does not provide a scan-insertion flow",
            ),
        }
        for relative, phrases in required_evidence.items():
            text = _read(relative)
            for phrase in phrases:
                with self.subTest(path=relative, phrase=phrase):
                    self.assertIn(phrase, text)

    def test_registered_test_inventory_is_not_hard_coded_in_readme(self) -> None:
        readme = README.read_text(encoding="utf-8")
        self.assertNotIn("## Current test inventory", readme)
        self.assertIn("scripts/Makefile", readme)
        self.assertIn("machine-readable", readme)

    def test_verified_comments_do_not_preserve_obsolete_milestone_language(self) -> None:
        stale_comments = {
            "tb/integration/arm7tdmis_memory.sv": "unused at this scaffold level",
            "rtl/jtag/arm7tdmis_jtag_tap.sv": (
                "off-chip Multi-ICE synchronizer is deferred to a later milestone"
            ),
        }
        for relative, phrase in stale_comments.items():
            with self.subTest(path=relative):
                self.assertNotIn(phrase, _read(relative))


if __name__ == "__main__":
    unittest.main()
