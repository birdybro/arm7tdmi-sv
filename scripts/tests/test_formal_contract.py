#!/usr/bin/env python3
"""Fail-first completeness and release contract for VAL-007/VAL-008."""

from __future__ import annotations

import copy
import json
import pathlib
import sys
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import release_evidence  # noqa: E402


OSS_CAD_SUITE_VERSION = "2026-07-29"
OSS_CAD_SUITE_SHA256 = (
    "89ea1152ea84bc600f18cc685f721d534d1f018e09831662787865a3d79ce4aa"
)
PROOF_IDS = (
    "no_ghost_commits",
    "condition_suppression",
    "mode_bank_isolation",
    "pc_alignment",
    "flag_preservation",
    "bus_stability_clken",
    "one_completion_per_request",
    "lock_lifetime",
    "exception_priority",
    "abort_suppression",
    "tap_transitions",
    "cdc_reset_assumptions",
    "forward_progress",
    "no_deadlock",
)
FSM_STATES = (
    "S_EXEC",
    "S_DDATA",
    "S_BLOCK_DATA",
    "S_SWP_RDATA",
    "S_SWP_WDATA",
    "S_MULL_HI",
    "S_MUL_BUSY",
    "S_MULL_ACC",
    "S_BLOCK_WB",
    "S_DP_SHIFT",
    "S_LOAD_WB",
    "S_SWP_WB",
    "S_CP_WAIT",
    "S_CP_MCR_DATA",
    "S_CP_MRC_DATA",
    "S_CP_MRC_WB",
    "S_UNDEF_WAIT",
)
FSM_TRANSITIONS = (
    "S_EXEC->S_EXEC",
    "S_EXEC->S_DDATA",
    "S_EXEC->S_BLOCK_DATA",
    "S_EXEC->S_SWP_RDATA",
    "S_EXEC->S_MUL_BUSY",
    "S_EXEC->S_MULL_ACC",
    "S_EXEC->S_DP_SHIFT",
    "S_EXEC->S_CP_WAIT",
    "S_EXEC->S_CP_MCR_DATA",
    "S_EXEC->S_CP_MRC_DATA",
    "S_EXEC->S_UNDEF_WAIT",
    "S_DDATA->S_EXEC",
    "S_DDATA->S_LOAD_WB",
    "S_LOAD_WB->S_EXEC",
    "S_BLOCK_DATA->S_BLOCK_DATA",
    "S_BLOCK_DATA->S_BLOCK_WB",
    "S_BLOCK_DATA->S_EXEC",
    "S_BLOCK_WB->S_BLOCK_WB",
    "S_BLOCK_WB->S_EXEC",
    "S_SWP_RDATA->S_EXEC",
    "S_SWP_RDATA->S_SWP_WDATA",
    "S_SWP_WDATA->S_SWP_WB",
    "S_SWP_WB->S_EXEC",
    "S_MUL_BUSY->S_MUL_BUSY",
    "S_MUL_BUSY->S_MULL_HI",
    "S_MUL_BUSY->S_EXEC",
    "S_MULL_ACC->S_MUL_BUSY",
    "S_MULL_HI->S_EXEC",
    "S_DP_SHIFT->S_EXEC",
    "S_CP_WAIT->S_CP_WAIT",
    "S_CP_WAIT->S_CP_MCR_DATA",
    "S_CP_WAIT->S_CP_MRC_DATA",
    "S_CP_WAIT->S_EXEC",
    "S_CP_MCR_DATA->S_CP_MCR_DATA",
    "S_CP_MCR_DATA->S_CP_MRC_WB",
    "S_CP_MCR_DATA->S_EXEC",
    "S_CP_MRC_DATA->S_CP_MRC_DATA",
    "S_CP_MRC_DATA->S_CP_MRC_WB",
    "S_CP_MRC_WB->S_EXEC",
    "S_UNDEF_WAIT->S_EXEC",
)
EXCEPTION_COVERS = (
    "entry.reset",
    "entry.undefined",
    "entry.swi",
    "entry.prefetch_abort",
    "entry.data_abort",
    "entry.irq",
    "entry.fiq",
    "return.undefined",
    "return.swi",
    "return.prefetch_abort",
    "return.data_abort",
    "return.irq",
    "return.fiq",
)
DEBUG_COVERS = (
    "entry.breakpoint",
    "entry.watchpoint",
    "entry.dbgrq",
    "entry.external_break",
    "return.restart",
    "return.pc_resume",
    "return.system_speed",
)


def _read(relative: str) -> str:
    return (REPO_ROOT / relative).read_text(encoding="utf-8")


class FormalContractTest(unittest.TestCase):
    @staticmethod
    def _manifest() -> dict[str, object]:
        return json.loads(_read("verification/formal_requirements.json"))

    @classmethod
    def _report(cls) -> dict[str, object]:
        manifest = cls._manifest()
        proof_ids = sorted(PROOF_IDS)
        cover_ids = sorted(
            [f"fsm.state.{value}" for value in FSM_STATES]
            + [f"fsm.transition.{value}" for value in FSM_TRANSITIONS]
            + [f"exception.{value}" for value in EXCEPTION_COVERS]
            + [f"debug.{value}" for value in DEBUG_COVERS]
        )
        result = {
            bin_id: {
                "status": "passed",
                "engine": "smtbmc boolector",
                "depth": 32,
                "log": {
                    "path": f"reports/generated/formal/{bin_id}.log",
                    "bytes": 100,
                    "sha256": "1" * 64,
                },
                "source": {
                    "path": "tb/formal/arm7tdmis_core_formal.sv",
                    "bytes": 100,
                    "sha256": "2" * 64,
                },
            }
            for bin_id in proof_ids + cover_ids
        }
        for index, bin_id in enumerate(cover_ids):
            result[bin_id]["witnesses"] = [
                {
                    "path": (
                        f"reports/generated/formal/{index}/trace.vcd"
                    ),
                    "bytes": 100,
                    "sha256": "3" * 64,
                },
                {
                    "path": (
                        f"reports/generated/formal/{index}/trace.yw"
                    ),
                    "bytes": 100,
                    "sha256": "4" * 64,
                },
            ]
        return {
            "schema": "arm7tdmis-formal-v1",
            "status": "passed",
            "failure": None,
            "git": {"commit": "a" * 40, "dirty": False},
            "toolchain": copy.deepcopy(manifest["toolchain"]),
            "required_proofs": proof_ids,
            "proven_proofs": proof_ids,
            "required_covers": cover_ids,
            "covered_covers": cover_ids,
            "uncovered_covers": [],
            "results": result,
        }

    def test_manifest_freezes_every_proof_and_cover_obligation(self) -> None:
        manifest = self._manifest()
        self.assertEqual(manifest["schema"], "arm7tdmis-formal-map-v1")
        self.assertEqual(
            manifest["toolchain"],
            {
                "name": "oss-cad-suite",
                "version": OSS_CAD_SUITE_VERSION,
                "archive_sha256": OSS_CAD_SUITE_SHA256,
            },
        )
        self.assertEqual(
            {entry["id"] for entry in manifest["proofs"]},
            set(PROOF_IDS),
        )
        self.assertEqual(
            set(manifest["covers"]["fsm_states"]),
            set(FSM_STATES),
        )
        self.assertEqual(
            set(manifest["covers"]["fsm_transitions"]),
            set(FSM_TRANSITIONS),
        )
        self.assertEqual(
            set(manifest["covers"]["exceptions"]),
            set(EXCEPTION_COVERS),
        )
        self.assertEqual(
            set(manifest["covers"]["debug"]),
            set(DEBUG_COVERS),
        )
        for entry in manifest["proofs"]:
            self.assertIn(entry["mode"], {"prove", "live"})
            self.assertTrue(entry["property"])
            self.assertRegex(entry["citation"], r"(ARM DDI 0234|VAL-007)")
            self.assertTrue((REPO_ROOT / entry["source"]).is_file())
        for source in manifest["sources"]:
            self.assertTrue((REPO_ROOT / source).is_file())

    def test_formal_flow_is_pinned_mandatory_and_release_archived(self) -> None:
        installer = _read("scripts/install_oss_cad_suite.py")
        makefile = _read("scripts/Makefile")
        regression = _read("scripts/regression_harness.py")
        release = _read("scripts/release_evidence.py")
        workflow = _read(".github/workflows/verification.yml")
        traceability = _read("verification/traceability.json")
        tasks = _read("TASKS.md")
        verification = _read("docs/VERIFICATION.md")

        self.assertIn(OSS_CAD_SUITE_VERSION, installer)
        self.assertIn(OSS_CAD_SUITE_SHA256, installer)
        self.assertIn("formal:", makefile)
        self.assertIn("formal_report.py", makefile)
        self.assertIn('"formal"', regression)
        self.assertIn("if not quick", regression)
        self.assertIn("formal-report.json", release)
        self.assertIn("validate_formal_evidence", release)
        self.assertIn("formal", workflow)
        self.assertIn("install_oss_cad_suite.py", workflow)
        self.assertIn('"VAL-007"', traceability)
        self.assertIn('"VAL-008"', traceability)
        self.assertIn("- [x] **VAL-007:**", tasks)
        self.assertIn("- [x] **VAL-008:**", tasks)
        self.assertIn("arm7tdmis-formal-v1", verification)

    def test_release_validation_rejects_every_formal_weakening(self) -> None:
        report = self._report()
        manifest = self._manifest()
        release_evidence.validate_formal_evidence(
            report,
            manifest,
            expected_commit="a" * 40,
        )
        mutations = {
            "failed": lambda value: value.update({"status": "failed"}),
            "dirty": lambda value: value["git"].update({"dirty": True}),
            "stale": lambda value: value["git"].update({"commit": "b" * 40}),
            "wrong tool": lambda value: value["toolchain"].update(
                {"version": "latest"}
            ),
            "missing proof": lambda value: value["proven_proofs"].pop(),
            "missing cover": lambda value: value["covered_covers"].pop(),
            "uncovered": lambda value: value["uncovered_covers"].append(
                value["required_covers"][0]
            ),
            "failed result": lambda value: value["results"][
                value["required_proofs"][0]
            ].update({"status": "failed"}),
            "missing log hash": lambda value: value["results"][
                value["required_proofs"][1]
            ]["log"].update({"sha256": ""}),
            "missing source hash": lambda value: value["results"][
                value["required_covers"][0]
            ]["source"].update({"sha256": ""}),
            "missing cover witness": lambda value: value["results"][
                value["required_covers"][1]
            ]["witnesses"].pop(),
            "unhashed cover witness": lambda value: value["results"][
                value["required_covers"][2]
            ]["witnesses"][0].update({"sha256": ""}),
        }
        for name, mutate in mutations.items():
            weakened = copy.deepcopy(report)
            mutate(weakened)
            with self.subTest(name=name), self.assertRaises(ValueError):
                release_evidence.validate_formal_evidence(
                    weakened,
                    manifest,
                    expected_commit="a" * 40,
                )


if __name__ == "__main__":
    unittest.main()
