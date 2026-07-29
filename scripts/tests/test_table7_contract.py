#!/usr/bin/env python3
"""Fail-hard completeness checks for the ARM7TDMI-S Chapter 7 matrix."""

from __future__ import annotations

import pathlib
import re
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
MATRIX = REPO_ROOT / "docs" / "TABLE7_MATRIX.md"
MAKEFILE = REPO_ROOT / "scripts" / "Makefile"
TASKS = REPO_ROOT / "TASKS.md"
CORE_ORACLE = (
    REPO_ROOT
    / "tb"
    / "integration"
    / "arm7tdmis_table7_core_phase_matrix_tb.sv"
)


class Table7ContractTest(unittest.TestCase):
    def test_every_detailed_table_has_an_evidence_row(self) -> None:
        self.assertTrue(MATRIX.is_file(), "missing docs/TABLE7_MATRIX.md")
        text = MATRIX.read_text(encoding="utf-8")
        self.assertIn("Table 7-2", text)
        for table in range(3, 24):
            marker = f"| 7-{table} |"
            with self.subTest(table=table):
                self.assertEqual(
                    text.count(marker),
                    1,
                    f"expected one evidence row for Table 7-{table}",
                )

    def test_every_cited_bench_exists_and_is_registered(self) -> None:
        self.assertTrue(MATRIX.is_file(), "missing docs/TABLE7_MATRIX.md")
        text = MATRIX.read_text(encoding="utf-8")
        makefile = MAKEFILE.read_text(encoding="utf-8")
        benches = set(re.findall(r"`(arm7tdmis_[a-z0-9_]+_tb\.sv)`", text))
        self.assertGreaterEqual(len(benches), 12)
        for filename in benches:
            name = filename.removeprefix("arm7tdmis_").removesuffix("_tb.sv")
            path = REPO_ROOT / "tb" / "integration" / filename
            with self.subTest(bench=filename):
                self.assertTrue(path.is_file(), f"missing cited bench: {path}")
                self.assertRegex(
                    makefile,
                    rf"\b{re.escape(name)}\b",
                    f"{name} is not in the integration manifest",
                )

    def test_core_oracle_scores_the_complete_bus_and_state_contract(self) -> None:
        text = CORE_ORACLE.read_text(encoding="utf-8")
        required_observations = (
            "ADDR",
            "WRITE",
            "SIZE",
            "PROT",
            "LOCK",
            "TRANS",
            "WDATA",
            "RDATA",
            "ABORT",
            "DMORE",
            "CPnMREQ",
            "CPSEQ",
            "CPnTRANS",
            "CPnOPC",
            "CPTBIT",
            "CPnI",
            "CLKEN",
            "pc_q",
            "cpsr",
            "state_q",
            "de_q.instr",
            "any_exc_fires",
            "DBGACK",
            "DBGnEXEC",
            "DBGINSTRVALID",
        )
        for observation in required_observations:
            with self.subTest(observation=observation):
                self.assertIn(observation, text)

    def test_core_oracle_crosses_endian_and_waits_at_every_phase(self) -> None:
        text = CORE_ORACLE.read_text(encoding="utf-8")
        for evidence in (
            "ENDIAN_COUNT = 2",
            "STALL_PROFILE_COUNT = 2",
            ".CFGBIGEND(CFGBIGEND)",
            "stall_cycles",
            "check_stalled_phase",
            "endian x %0d stall profiles",
        ):
            with self.subTest(evidence=evidence):
                self.assertIn(evidence, text)
        self.assertNotIn(".CFGBIGEND(1'b0)", text)

    def test_bus_closure_is_tied_to_the_executable_matrix(self) -> None:
        tasks = TASKS.read_text(encoding="utf-8")
        self.assertIn("- [x] **BUS-002:**", tasks)
        self.assertIn("- [x] **BUS-003:**", tasks)
        self.assertIn("TABLE7_MATRIX.md", tasks)
        self.assertIn("table7_core_phase_matrix", tasks)


if __name__ == "__main__":
    unittest.main()
