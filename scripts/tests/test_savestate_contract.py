#!/usr/bin/env python3
"""Contracts for the versioned MiSTer architectural save-state interface."""

from __future__ import annotations

import pathlib
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]


class SaveStateContractTest(unittest.TestCase):
    def test_state_interface_is_opt_in_and_has_a_frozen_word_schema(self) -> None:
        wrapper = (
            REPO_ROOT / "rtl" / "top" / "arm7tdmi_mister.sv"
        ).read_text(encoding="utf-8")
        documentation_path = REPO_ROOT / "docs" / "SAVESTATE.md"
        self.assertTrue(documentation_path.is_file())
        documentation = documentation_path.read_text(encoding="utf-8")

        self.assertIn("ARM7TDMIS_SAVE_STATE", wrapper)
        for signal in (
            "STATE_REQUEST",
            "STATE_READY",
            "STATE_WRITE",
            "STATE_INDEX",
            "STATE_WDATA",
            "STATE_RDATA",
        ):
            self.assertIn(signal, wrapper)
            self.assertIn(signal, documentation)
        self.assertIn("STATE_SCHEMA_VERSION", wrapper)
        self.assertIn("STATE_WORDS", wrapper)
        self.assertIn("37", documentation)
        self.assertIn("Thumb BL", documentation)

    def test_determinism_test_covers_every_word_and_difficult_boundaries(
        self,
    ) -> None:
        testbench_path = (
            REPO_ROOT
            / "tb"
            / "integration"
            / "arm7tdmis_mister_savestate_tb.sv"
        )
        self.assertTrue(testbench_path.is_file())
        testbench = testbench_path.read_text(encoding="utf-8")

        for evidence in (
            "STATE_WORDS",
            "snapshot",
            "mutated",
            "trace_first",
            "trace_second",
            "MEM_READY",
            "CPU_CE",
            "THUMB_SUFFIX_PC",
            "32'h0000_0084",
            "32'h0000_0085",
        ):
            self.assertIn(evidence, testbench)
        self.assertIn("[mister_savestate] PASS", testbench)
        self.assertIn("$fatal", testbench)

    def test_save_state_test_is_registered_with_the_feature_define(self) -> None:
        makefile = (REPO_ROOT / "scripts" / "Makefile").read_text(
            encoding="utf-8"
        )
        regression = (
            REPO_ROOT / "scripts" / "regression_harness.py"
        ).read_text(encoding="utf-8")
        tasks = (REPO_ROOT / "TASKS.md").read_text(encoding="utf-8")

        self.assertIn("mister_savestate", makefile)
        self.assertIn(
            "INTEG_EXTRA_FLAGS_mister_savestate := "
            "-DARM7TDMIS_SAVE_STATE",
            makefile,
        )
        self.assertIn("mister_savestate", regression)
        self.assertIn("- [x] **MIST-006:**", tasks)
        block = tasks[tasks.index("**MIST-006:**"):tasks.index("**MIST-007:**")]
        self.assertIn("arm7tdmis_mister_savestate_tb.sv", block)
        self.assertIn("docs/SAVESTATE.md", block)


if __name__ == "__main__":
    unittest.main()
