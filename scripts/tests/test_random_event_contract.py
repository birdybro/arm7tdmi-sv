#!/usr/bin/env python3
"""Fail-first release contract for VAL-005 randomized external events."""

from __future__ import annotations

import copy
import pathlib
import sys
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "verification"))
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import random_events  # noqa: E402
import release_evidence  # noqa: E402


CLASS_BINS = [
    "undef",
    "dp",
    "msr",
    "mrs",
    "mul",
    "mull",
    "branch",
    "bx",
    "ldr_str",
    "ldrh_strh",
    "ldm_stm",
    "swp",
    "swi",
    "cdp",
    "mcr_mrc",
    "ldc_stc",
]
EVENT_BINS = [
    "abort_opcode_read",
    "abort_data_read",
    "abort_data_write",
    "irq",
    "fiq",
    "reset",
    "dbgrq",
    "cp_ready",
    "cp_busy",
    "cp_absent",
]


def _read(relative: str) -> str:
    return (REPO_ROOT / relative).read_text(encoding="utf-8")


class RandomEventContractTest(unittest.TestCase):
    @staticmethod
    def _release_report() -> dict[str, object]:
        seed_results = []
        for seed in range(1, 33):
            seed_results.append(
                {
                    "seed": seed,
                    "status": "passed",
                    "exit_code": 0,
                    "pass_marker_found": True,
                    "decision_count": 512,
                    "class_bins": CLASS_BINS,
                    "class_stall_bins": CLASS_BINS,
                    "event_bins": EVENT_BINS,
                    "reproducer": [
                        "simulator",
                        f"+SEED={seed}",
                    ],
                }
            )
        return {
            "schema": "arm7tdmis-random-events-v1",
            "status": "passed",
            "git": {"commit": "abc123", "dirty": False},
            "configuration": {
                "seed_count": 32,
                "minimum_decisions_per_seed": 256,
            },
            "required_class_bins": CLASS_BINS,
            "required_event_bins": EVENT_BINS,
            "covered_class_bins": CLASS_BINS,
            "covered_class_stall_bins": CLASS_BINS,
            "covered_event_bins": EVENT_BINS,
            "completed_seed_count": 32,
            "total_decision_count": 32 * 512,
            "seeds": seed_results,
            "failures": [],
        }

    def test_pass_marker_parser_is_exact_and_fail_hard(self) -> None:
        parsed = random_events.parse_pass_marker(
            "[random_events] PASS seed=17 classes=ffff stalls=ffff "
            "events=03ff decisions=512\n",
            expected_seed=17,
        )
        self.assertEqual(parsed["class_mask"], 0xFFFF)
        self.assertEqual(parsed["class_stall_mask"], 0xFFFF)
        self.assertEqual(parsed["event_mask"], 0x03FF)
        self.assertEqual(parsed["decision_count"], 512)

        for mutation in (
            "seed=18",
            "classes=fffe",
            "stalls=7fff",
            "events=01ff",
            "decisions=oops",
            "FAIL seed=17",
        ):
            marker = (
                "[random_events] PASS seed=17 classes=ffff stalls=ffff "
                "events=03ff decisions=512\n"
            )
            with self.assertRaises(ValueError):
                random_events.parse_pass_marker(
                    marker.replace(
                        {
                            "seed=18": "seed=17",
                            "classes=fffe": "classes=ffff",
                            "stalls=7fff": "stalls=ffff",
                            "events=01ff": "events=03ff",
                            "decisions=oops": "decisions=512",
                            "FAIL seed=17": "PASS seed=17",
                        }[mutation],
                        mutation,
                    ),
                    expected_seed=17,
                )

    def test_release_validation_rejects_weakened_evidence(self) -> None:
        report = self._release_report()
        release_evidence.validate_random_event_evidence(
            report,
            expected_commit="abc123",
        )

        for mutation in (
            "dirty",
            "wrong_commit",
            "weak_seed_count",
            "duplicate_seed",
            "short_run",
            "missing_class",
            "missing_stall",
            "missing_event",
            "failed_seed",
            "bad_total",
        ):
            weakened = copy.deepcopy(report)
            if mutation == "dirty":
                weakened["git"]["dirty"] = True
            elif mutation == "wrong_commit":
                weakened["git"]["commit"] = "def456"
            elif mutation == "weak_seed_count":
                weakened["configuration"]["seed_count"] = 31
            elif mutation == "duplicate_seed":
                weakened["seeds"][1]["seed"] = 1
            elif mutation == "short_run":
                weakened["seeds"][0]["decision_count"] = 255
            elif mutation == "missing_class":
                weakened["covered_class_bins"] = CLASS_BINS[:-1]
            elif mutation == "missing_stall":
                weakened["seeds"][0]["class_stall_bins"] = CLASS_BINS[:-1]
            elif mutation == "missing_event":
                weakened["covered_event_bins"] = EVENT_BINS[:-1]
            elif mutation == "failed_seed":
                weakened["seeds"][0]["status"] = "failed"
            elif mutation == "bad_total":
                weakened["total_decision_count"] -= 1
            with self.subTest(mutation=mutation):
                with self.assertRaises(ValueError):
                    release_evidence.validate_random_event_evidence(
                        weakened,
                        expected_commit="abc123",
                    )

    def test_testbench_randomizes_only_legal_external_events(self) -> None:
        testbench = _read(
            "tb/integration/arm7tdmis_random_event_matrix_tb.sv"
        )
        for evidence in (
            '$value$plusargs("SEED=%d"',
            "INSTR_CLASS_COUNT = 16",
            "REQUIRED_CLASS_MASK",
            "REQUIRED_EVENT_MASK",
            "class_stall_mask",
            "lfsr",
            "CLKEN",
            "inject_abort",
            "u_mem.is_active_q",
            "nIRQ",
            "nFIQ",
            "nRESET",
            "DBGRQ",
            "CP_PRESENT_READY",
            "CP_PRESENT_BUSY",
            "CP_ABSENT",
            "ABORT && !u_mem.is_active_q",
            "[random_events] PASS",
            "$fatal",
        ):
            self.assertIn(evidence, testbench)
        self.assertNotIn("CPA = 1'b1;\n        CPB = 1'b0;", testbench)

    def test_release_campaign_is_mandatory_documented_and_traceable(
        self,
    ) -> None:
        makefile = _read("scripts/Makefile")
        regression = _read("scripts/regression_harness.py")
        release = _read("scripts/release_evidence.py")
        traceability = _read("verification/traceability.json")
        workflow = _read(".github/workflows/verification.yml")
        tasks = _read("TASKS.md")
        verification = _read("docs/VERIFICATION.md")

        for evidence in (
            "RANDOM_EVENT_SEEDS ?= 32",
            "random-events-build:",
            "random-events:",
            "random_events.py",
            "arm7tdmis_random_event_matrix_tb",
        ):
            self.assertIn(evidence, makefile)
        self.assertIn('"random-events"', regression)
        self.assertIn("if not quick", regression)
        self.assertIn("random-events-report.json", release)
        self.assertIn("validate_random_event_evidence", release)
        self.assertIn("make -C scripts random-events", workflow)
        self.assertIn("random-events-report.json", workflow)
        self.assertIn("VAL-005", traceability)
        self.assertIn("- [x] **VAL-005:**", tasks)
        block = tasks[tasks.index("**VAL-005:**"):tasks.index("**VAL-006:**")]
        for evidence in ("32", "16", "ABORT", "IRQ", "FIQ", "DBGRQ"):
            self.assertIn(evidence, block)
        self.assertIn("arm7tdmis-random-events-v1", verification)


if __name__ == "__main__":
    unittest.main()
