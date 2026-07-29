#!/usr/bin/env python3
"""Mutation tests for VAL-003 public-suite release evidence."""

from __future__ import annotations

import copy
import pathlib
import sys
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

import release_evidence  # noqa: E402


COMMIT = "a" * 40
TREE = "b" * 40
LICENSE_SHA256 = "c" * 64
ARM_UPSTREAM_SHA256 = "d" * 64
THUMB_UPSTREAM_SHA256 = "e" * 64
ARM_PATCHED_SHA256 = "1" * 64
THUMB_PATCHED_SHA256 = "2" * 64
SIGNATURE = "0xe8d71fb2"


class PublicSuiteEvidenceTest(unittest.TestCase):
    @staticmethod
    def _manifest() -> dict[str, object]:
        return {
            "schema": "arm7tdmis-public-suites-v1",
            "upstream": {
                "url": "https://github.com/jsmolka/gba-suite.git",
                "commit": COMMIT,
                "tree": TREE,
                "license_path": "LICENSE",
                "license_spdx": "MIT",
                "license_sha256": LICENSE_SHA256,
            },
            "patches": [
                {
                    "operation": "zero header",
                    "range": "0x00000004..0x000000bf",
                    "reason": "remove non-executable metadata",
                }
            ],
            "suites": {
                "arm": {
                    "path": "arm/arm.gba",
                    "upstream_sha256": ARM_UPSTREAM_SHA256,
                    "patched_sha256": ARM_PATCHED_SHA256,
                    "idle_pc": "0x08001ec4",
                    "result_register": 12,
                    "expected_vram_signature": SIGNATURE,
                    "minimum_retirements": 8_000,
                    "word_patches": [
                        {
                            "offset": "0x00000cd4",
                            "expected_word": "0xe3a08020",
                            "replacement_word": "0xea000016",
                        }
                    ],
                },
                "thumb": {
                    "path": "thumb/thumb.gba",
                    "upstream_sha256": THUMB_UPSTREAM_SHA256,
                    "patched_sha256": THUMB_PATCHED_SHA256,
                    "idle_pc": "0x08000aac",
                    "result_register": 7,
                    "expected_vram_signature": SIGNATURE,
                    "minimum_retirements": 6_000,
                    "word_patches": [],
                },
            },
        }

    @classmethod
    def _report(cls) -> dict[str, object]:
        manifest = cls._manifest()
        suites = manifest["suites"]
        upstream = dict(manifest["upstream"])
        upstream["acquisition_commands"] = [
            ["git", "fetch", "--depth=1", "origin", COMMIT]
        ]
        upstream["license_artifact"] = {
            "path": "upstream-LICENSE",
            "bytes": 1_070,
            "sha256": LICENSE_SHA256,
        }
        return {
            "schema": "arm7tdmis-public-suite-v1",
            "status": "passed",
            "failure": None,
            "git": {"commit": COMMIT, "dirty": False},
            "upstream": upstream,
            "patches": copy.deepcopy(manifest["patches"]),
            "suite_count": 2,
            "total_retirements": 15_287,
            "suites": {
                "arm": {
                    "status": "passed",
                    "upstream_path": suites["arm"]["path"],
                    "upstream_sha256": ARM_UPSTREAM_SHA256,
                    "patched_sha256": ARM_PATCHED_SHA256,
                    "idle_pc": suites["arm"]["idle_pc"],
                    "result_register": 12,
                    "expected_vram_signature": SIGNATURE,
                    "word_patches": copy.deepcopy(
                        suites["arm"]["word_patches"]
                    ),
                    "metrics": {
                        "retirements": 8_596,
                        "arm_retirements": 8_588,
                        "thumb_retirements": 8,
                        "rom_words": 2_206,
                    },
                    "reproducer": ["simulator", "+ROM_HEX=arm.hex"],
                    "artifacts": {
                        "arm.hex": {
                            "path": "arm/arm.hex",
                            "bytes": 19_854,
                            "sha256": "3" * 64,
                        }
                    },
                },
                "thumb": {
                    "status": "passed",
                    "upstream_path": suites["thumb"]["path"],
                    "upstream_sha256": THUMB_UPSTREAM_SHA256,
                    "patched_sha256": THUMB_PATCHED_SHA256,
                    "idle_pc": suites["thumb"]["idle_pc"],
                    "result_register": 7,
                    "expected_vram_signature": SIGNATURE,
                    "word_patches": [],
                    "metrics": {
                        "retirements": 6_691,
                        "arm_retirements": 6_152,
                        "thumb_retirements": 539,
                        "rom_words": 920,
                    },
                    "reproducer": ["simulator", "+ROM_HEX=thumb.hex"],
                    "artifacts": {
                        "thumb.hex": {
                            "path": "thumb/thumb.hex",
                            "bytes": 8_280,
                            "sha256": "4" * 64,
                        }
                    },
                },
            },
        }

    def test_release_validation_accepts_complete_public_suite(self) -> None:
        release_evidence.validate_public_suite_evidence(
            self._report(),
            self._manifest(),
            expected_commit=COMMIT,
        )

    def test_release_validation_rejects_weakened_public_suite(self) -> None:
        report = self._report()
        mutations = {
            "wrong schema": lambda value: value.update({"schema": "wrong"}),
            "dirty": lambda value: value["git"].update({"dirty": True}),
            "stale commit": lambda value: value["git"].update(
                {"commit": "f" * 40}
            ),
            "changed upstream": lambda value: value["upstream"].update(
                {"tree": "f" * 40}
            ),
            "altered patches": lambda value: value.update({"patches": []}),
            "weak retirement": lambda value: value["suites"]["arm"][
                "metrics"
            ].update({"retirements": 7_999}),
            "wrong signature": lambda value: value["suites"]["thumb"].update(
                {"expected_vram_signature": "0x00000000"}
            ),
            "no thumb execution": lambda value: value["suites"]["thumb"][
                "metrics"
            ].update({"thumb_retirements": 0}),
            "no reproducer": lambda value: value["suites"]["arm"].update(
                {"reproducer": []}
            ),
            "no artifacts": lambda value: value["suites"]["thumb"].update(
                {"artifacts": {}}
            ),
            "wrong total": lambda value: value.update(
                {"total_retirements": 15_286}
            ),
        }
        for name, mutate in mutations.items():
            weakened = copy.deepcopy(report)
            mutate(weakened)
            with self.subTest(name=name), self.assertRaises(ValueError):
                release_evidence.validate_public_suite_evidence(
                    weakened,
                    self._manifest(),
                    expected_commit=COMMIT,
                )

    def test_release_validation_rejects_untrusted_manifest(self) -> None:
        for name, mutation in {
            "schema": ("schema", "wrong"),
            "license": ("license_spdx", "unknown"),
        }.items():
            manifest = self._manifest()
            key, value = mutation
            if key == "schema":
                manifest[key] = value
            else:
                manifest["upstream"][key] = value
            with self.subTest(name=name), self.assertRaises(ValueError):
                release_evidence.validate_public_suite_evidence(
                    self._report(),
                    manifest,
                    expected_commit=COMMIT,
                )


if __name__ == "__main__":
    unittest.main()
