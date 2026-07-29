#!/usr/bin/env python3
"""Mutation tests for VAL-004 Chapter 7 cross-coverage evidence."""

from __future__ import annotations

import copy
import pathlib
import sys
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import release_evidence  # noqa: E402


COMMIT = "a" * 40
REQUIRED_CROSSES = (
    "class_waveform_endian_stall",
    "class_condition_mode",
    "register_pc_state",
    "multiply_class_m",
    "block_class_n",
    "coprocessor_class_b_n",
    "memory_class_endian_alignment",
    "memory_class_abort",
    "class_interrupt_exception",
)


class Table7CrossEvidenceTest(unittest.TestCase):
    @staticmethod
    def _manifest() -> dict[str, object]:
        crosses = {}
        for index, name in enumerate(REQUIRED_CROSSES, start=1):
            crosses[name] = {
                "description": f"required cross {name}",
                "dimensions": {
                    "instruction_class": [f"class_{index}"],
                    "policy": ["applicable"],
                },
                "minimum_rows": index,
                "evidence": [
                    {
                        "phase": f"integration-evidence_{index}",
                        "source": f"tb/integration/evidence_{index}_tb.sv",
                        "marker": rf"\[evidence_{index}\] PASS",
                        "expected_rows": index,
                    }
                ],
            }
        return {
            "schema": "arm7tdmis-table7-cross-map-v1",
            "required_crosses": list(REQUIRED_CROSSES),
            "crosses": crosses,
        }

    @classmethod
    def _report(cls) -> dict[str, object]:
        manifest = cls._manifest()
        crosses = {}
        for index, name in enumerate(REQUIRED_CROSSES, start=1):
            definition = manifest["crosses"][name]
            evidence = definition["evidence"][0]
            crosses[name] = {
                "description": definition["description"],
                "dimensions": copy.deepcopy(definition["dimensions"]),
                "minimum_rows": index,
                "observed_rows": index,
                "evidence": [
                    {
                        **copy.deepcopy(evidence),
                        "status": "passed",
                        "log": {
                            "path": f"reports/generated/logs/evidence_{index}.log",
                            "bytes": 100 + index,
                            "sha256": f"{index:x}" * 64,
                        },
                        "source_artifact": {
                            "path": evidence["source"],
                            "bytes": 1_000 + index,
                            "sha256": "abcdef0123456789"[index] * 64,
                        },
                    }
                ],
            }
        return {
            "schema": "arm7tdmis-table7-cross-v1",
            "status": "passed",
            "failure": None,
            "git": {"commit": COMMIT, "dirty": False},
            "required_crosses": list(REQUIRED_CROSSES),
            "covered_crosses": list(REQUIRED_CROSSES),
            "missing_crosses": [],
            "cross_count": len(REQUIRED_CROSSES),
            "total_minimum_rows": sum(range(1, 10)),
            "total_observed_rows": sum(range(1, 10)),
            "crosses": crosses,
        }

    def test_release_validation_accepts_complete_cross_evidence(self) -> None:
        release_evidence.validate_table7_cross_evidence(
            self._report(),
            self._manifest(),
            expected_commit=COMMIT,
        )

    def test_release_validation_rejects_weakened_cross_evidence(self) -> None:
        report = self._report()
        mutations = {
            "wrong schema": lambda value: value.update({"schema": "wrong"}),
            "failed": lambda value: value.update({"status": "failed"}),
            "dirty": lambda value: value["git"].update({"dirty": True}),
            "stale commit": lambda value: value["git"].update(
                {"commit": "f" * 40}
            ),
            "missing required cross": lambda value: value[
                "required_crosses"
            ].pop(),
            "missing covered cross": lambda value: value[
                "covered_crosses"
            ].pop(),
            "claimed missing cross": lambda value: value[
                "missing_crosses"
            ].append(REQUIRED_CROSSES[0]),
            "wrong cross count": lambda value: value.update(
                {"cross_count": 8}
            ),
            "weak observed rows": lambda value: value["crosses"][
                REQUIRED_CROSSES[0]
            ].update({"observed_rows": 0}),
            "changed dimensions": lambda value: value["crosses"][
                REQUIRED_CROSSES[1]
            ].update({"dimensions": {"policy": ["weakened"]}}),
            "changed evidence": lambda value: value["crosses"][
                REQUIRED_CROSSES[2]
            ]["evidence"][0].update({"phase": "integration-untrusted"}),
            "failed evidence": lambda value: value["crosses"][
                REQUIRED_CROSSES[3]
            ]["evidence"][0].update({"status": "failed"}),
            "missing log digest": lambda value: value["crosses"][
                REQUIRED_CROSSES[4]
            ]["evidence"][0]["log"].update({"sha256": ""}),
            "missing source digest": lambda value: value["crosses"][
                REQUIRED_CROSSES[5]
            ]["evidence"][0]["source_artifact"].update({"sha256": ""}),
            "wrong minimum total": lambda value: value.update(
                {"total_minimum_rows": 44}
            ),
            "wrong observed total": lambda value: value.update(
                {"total_observed_rows": 44}
            ),
        }
        for name, mutate in mutations.items():
            weakened = copy.deepcopy(report)
            mutate(weakened)
            with self.subTest(name=name), self.assertRaises(ValueError):
                release_evidence.validate_table7_cross_evidence(
                    weakened,
                    self._manifest(),
                    expected_commit=COMMIT,
                )

    def test_release_validation_rejects_untrusted_manifest(self) -> None:
        mutations = {
            "wrong schema": lambda value: value.update({"schema": "wrong"}),
            "missing cross definition": lambda value: value["crosses"].pop(
                REQUIRED_CROSSES[0]
            ),
            "zero minimum": lambda value: value["crosses"][
                REQUIRED_CROSSES[1]
            ].update({"minimum_rows": 0}),
            "empty dimensions": lambda value: value["crosses"][
                REQUIRED_CROSSES[2]
            ].update({"dimensions": {}}),
            "empty evidence": lambda value: value["crosses"][
                REQUIRED_CROSSES[3]
            ].update({"evidence": []}),
        }
        for name, mutate in mutations.items():
            manifest = self._manifest()
            mutate(manifest)
            with self.subTest(name=name), self.assertRaises(ValueError):
                release_evidence.validate_table7_cross_evidence(
                    self._report(),
                    manifest,
                    expected_commit=COMMIT,
                )


if __name__ == "__main__":
    unittest.main()
