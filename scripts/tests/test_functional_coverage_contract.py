#!/usr/bin/env python3
"""Fail-first required-bin and release contract for VAL-006."""

from __future__ import annotations

import copy
import json
import pathlib
import sys
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "verification"))
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import functional_coverage  # noqa: E402
import release_evidence  # noqa: E402


def _read(relative: str) -> str:
    return (REPO_ROOT / relative).read_text(encoding="utf-8")


class FunctionalCoverageContractTest(unittest.TestCase):
    @staticmethod
    def _manifest() -> dict[str, object]:
        return json.loads(
            _read("verification/functional_coverage.json")
        )

    @classmethod
    def _release_report(
        cls,
    ) -> tuple[dict[str, object], dict[str, object]]:
        manifest = cls._manifest()
        required = functional_coverage.required_bin_ids(manifest)
        reference = functional_coverage.enumerate_reference_coverage(manifest)
        report = {
            "schema": "arm7tdmis-functional-coverage-v1",
            "status": "passed",
            "git": {"commit": "abc123", "dirty": False},
            "domains": reference["domains"],
            "required_bin_count": len(required),
            "required_bins": required,
            "covered_bin_count": len(required),
            "covered_bins": required,
            "uncovered_bins": [],
            "exclusions": manifest["exclusions"],
            "evidence": {
                evidence["phase"]: {"status": "passed"}
                for evidence in manifest["evidence"]
            },
        }
        return report, manifest

    def test_manifest_has_complete_valid_and_exception_foundations(
        self,
    ) -> None:
        manifest = self._manifest()
        functional_coverage.validate_manifest(manifest)
        groups = {
            group["id"]: set(group["members"])
            for group in manifest["required_bin_groups"]
        }
        self.assertEqual(
            groups["arm.class"],
            {
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
            },
        )
        self.assertEqual(
            groups["arm.dp_opcode"],
            {
                "and",
                "eor",
                "sub",
                "rsb",
                "add",
                "adc",
                "sbc",
                "rsc",
                "tst",
                "teq",
                "cmp",
                "cmn",
                "orr",
                "mov",
                "bic",
                "mvn",
            },
        )
        self.assertEqual(len(groups["arm.condition"]), 15)
        self.assertEqual(len(groups["thumb.format"]), 19)
        self.assertEqual(len(groups["thumb.alu"]), 16)
        self.assertEqual(len(groups["thumb.condition"]), 14)
        for required_group in (
            "arm.shifter",
            "arm.multiply",
            "arm.psr",
            "arm.branch",
            "arm.single_transfer",
            "arm.extra_transfer",
            "arm.block_transfer",
            "arm.swap",
            "arm.coprocessor",
            "thumb.subfamily",
            "exception.reserved",
            "exception.policy",
        ):
            self.assertIn(required_group, groups)
            self.assertTrue(groups[required_group])

        required = functional_coverage.required_bin_ids(manifest)
        self.assertGreaterEqual(len(required), 180)
        self.assertEqual(len(required), len(set(required)))
        for exclusion in manifest["exclusions"]:
            self.assertIn("citation", exclusion)
            self.assertRegex(
                exclusion["citation"],
                r"(ARM DDI 0100|ARM DDI 0234|ARMv4T)",
            )
            self.assertTrue(exclusion["rationale"])

    def test_independent_enumerator_hits_every_required_encoding_bin(
        self,
    ) -> None:
        manifest = self._manifest()
        result = functional_coverage.enumerate_reference_coverage(manifest)
        self.assertEqual(
            result["domains"],
            {
                "arm_decode_rows": {
                    "expected": 4096,
                    "observed": 4096,
                },
                "arm_nv_rows": {
                    "expected": 4096,
                    "observed": 4096,
                },
                "thumb_words": {
                    "expected": 65536,
                    "observed": 65536,
                },
                "arm_static_policy_rows": {
                    "expected": 1066,
                    "observed": 1066,
                },
                "thumb_static_policy_rows": {
                    "expected": 448,
                    "observed": 448,
                },
            },
        )
        encoding_bins = {
            bin_id
            for group in manifest["required_bin_groups"]
            if group["coverage"] == "enumerated"
            for bin_id in (
                f"{group['id']}.{member}"
                for member in group["members"]
            )
        }
        self.assertFalse(encoding_bins - set(result["covered_bins"]))

    def test_release_validation_rejects_every_coverage_weakening(
        self,
    ) -> None:
        report, manifest = self._release_report()
        release_evidence.validate_functional_coverage_evidence(
            report,
            manifest,
            expected_commit="abc123",
        )
        for mutation in (
            "dirty",
            "wrong_commit",
            "missing_required",
            "missing_covered",
            "uncovered",
            "bad_count",
            "short_domain",
            "missing_evidence",
            "uncited_exclusion",
            "removed_group",
        ):
            weakened_report = copy.deepcopy(report)
            weakened_manifest = copy.deepcopy(manifest)
            if mutation == "dirty":
                weakened_report["git"]["dirty"] = True
            elif mutation == "wrong_commit":
                weakened_report["git"]["commit"] = "def456"
            elif mutation == "missing_required":
                weakened_report["required_bins"].pop()
            elif mutation == "missing_covered":
                weakened_report["covered_bins"].pop()
            elif mutation == "uncovered":
                weakened_report["uncovered_bins"] = [
                    weakened_report["required_bins"][0]
                ]
            elif mutation == "bad_count":
                weakened_report["covered_bin_count"] -= 1
            elif mutation == "short_domain":
                weakened_report["domains"]["thumb_words"]["observed"] -= 1
            elif mutation == "missing_evidence":
                weakened_report["evidence"].pop(
                    next(iter(weakened_report["evidence"]))
                )
            elif mutation == "uncited_exclusion":
                weakened_manifest["exclusions"][0]["citation"] = ""
            elif mutation == "removed_group":
                weakened_manifest["required_bin_groups"].pop()
            with self.subTest(mutation=mutation):
                with self.assertRaises(ValueError):
                    release_evidence.validate_functional_coverage_evidence(
                        weakened_report,
                        weakened_manifest,
                        expected_commit="abc123",
                    )

    def test_exhaustive_simulations_and_aggregate_gate_are_mandatory(
        self,
    ) -> None:
        reserved = _read("tb/unit/reserved_decode_tb.sv")
        unpredictable = _read("tb/unit/unpredictable_decode_tb.sv")
        makefile = _read("scripts/Makefile")
        regression = _read("scripts/regression_harness.py")
        release = _read("scripts/release_evidence.py")
        traceability = _read("verification/traceability.json")
        tasks = _read("TASKS.md")
        verification = _read("docs/VERIFICATION.md")

        for evidence in (
            "4096 ARM decode rows",
            "65536 Thumb words",
            "448 policy traps",
        ):
            self.assertIn(evidence, reserved)
        for evidence in (
            "1066 ARM traps",
            "448 Thumb traps",
            "12 deterministic rows",
        ):
            self.assertIn(evidence, unpredictable)
        self.assertIn("functional-coverage:", makefile)
        self.assertIn("functional_coverage.py", makefile)
        self.assertIn('"functional-coverage"', regression)
        self.assertIn("if not quick", regression)
        self.assertIn("functional-coverage-report.json", release)
        self.assertIn("validate_functional_coverage_evidence", release)
        self.assertIn("VAL-006", traceability)
        self.assertIn("- [x] **VAL-006:**", tasks)
        self.assertIn("arm7tdmis-functional-coverage-v1", verification)


if __name__ == "__main__":
    unittest.main()
