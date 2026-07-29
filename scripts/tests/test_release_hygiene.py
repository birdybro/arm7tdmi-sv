#!/usr/bin/env python3
"""Fail-hard checks for public API and release-document completeness."""

from __future__ import annotations

import pathlib
import re
import unittest

import release_evidence


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]


def _read(relative: str) -> str:
    return (REPO_ROOT / relative).read_text(encoding="utf-8")


class ReleaseHygieneTest(unittest.TestCase):
    def test_semantic_version_and_release_documents_exist(self) -> None:
        version = _read("VERSION").strip()
        self.assertRegex(
            version,
            r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"
            r"(?:-[0-9A-Za-z.-]+)?$",
        )
        required = {
            "CHANGELOG.md": ("Unreleased", version),
            "docs/SUPPORT.md": ("Support matrix", "Verilator", "Quartus"),
            "docs/LIMITATIONS.md": ("Known limitations", "TASKS.md"),
            "SECURITY.md": ("Security", "debug"),
            "docs/PROVENANCE.md": ("SPDX", "GPL-3.0-only", "NOASSERTION"),
        }
        for relative, phrases in required.items():
            text = _read(relative)
            for phrase in phrases:
                with self.subTest(path=relative, phrase=phrase):
                    self.assertIn(phrase, text)

    def test_both_public_apis_have_complete_versioned_contracts(self) -> None:
        required_sections = {
            "docs/INTEGRATION.md": (
                "Clock and reset",
                "Memory request",
                "Event CDC",
                "Optional interfaces",
                "Public memory-bus adapters",
                "Portable FPGA package",
                "Error behavior",
                "Version and compatibility",
            ),
            "docs/RAW_BUS.md": (
                "Edge and phase model",
                "Clock enable and wait states",
                "Address, size, and lanes",
                "ABORT",
                "LOCK and DMORE",
                "Coprocessor mirrors",
                "Integration example",
                "Version and compatibility",
            ),
        }
        for relative, headings in required_sections.items():
            text = _read(relative)
            for heading in headings:
                with self.subTest(path=relative, heading=heading):
                    self.assertRegex(text, rf"(?m)^## .*{re.escape(heading)}")

    def test_release_manifest_hashes_source_tools_spec_and_files(self) -> None:
        tools = {
            "verilator": "Verilator unit",
            "quartus": "Quartus unit",
            "python": "Python unit",
        }
        manifest = release_evidence.build_manifest(
            candidates=[REPO_ROOT / "LICENSE"],
            git_commit="a" * 40,
            source_sha256="b" * 64,
            tools=tools,
            created_utc="2026-01-01T00:00:00+00:00",
        )

        self.assertEqual(manifest["schema"], "arm7tdmis-release-evidence-v1")
        self.assertEqual(manifest["version"], _read("VERSION").strip())
        self.assertEqual(manifest["source"]["git_commit"], "a" * 40)
        self.assertEqual(manifest["source"]["source_sha256"], "b" * 64)
        self.assertRegex(manifest["source"]["git_tree_sha256"], r"^[0-9a-f]{64}$")
        self.assertEqual(manifest["tools"]["versions"], tools)
        self.assertRegex(manifest["tools"]["versions_sha256"], r"^[0-9a-f]{64}$")
        self.assertEqual(
            manifest["tools"]["versions_sha256"],
            release_evidence._json_sha256(tools),
        )
        specifications = {
            entry["path"]: entry["sha256"]
            for entry in manifest["specifications"]
        }
        self.assertEqual(
            specifications["ARM_DDI_0234B_ARM7TDMI-S_r4p3_TRM.pdf"],
            "bb9cd0e3f2b7e2fdca4ff961cdfc5c9c85c063842e491f8997a504d3241baa14",
        )
        self.assertRegex(specifications["LICENSE"], r"^[0-9a-f]{64}$")
        self.assertEqual(manifest["files"][0]["path"], "LICENSE")

        # Canonical JSON hashing must not depend on dictionary insertion order.
        reversed_tools = dict(reversed(tuple(tools.items())))
        self.assertEqual(
            release_evidence._json_sha256(tools),
            release_evidence._json_sha256(reversed_tools),
        )

    def test_task_ledger_links_release_hygiene_evidence(self) -> None:
        tasks = _read("TASKS.md")
        for task in ("DOC-004", "DOC-005", "DOC-006"):
            self.assertIn(f"- [x] **{task}:**", tasks)
        for evidence in (
            "PROVENANCE.md",
            "SUPPORT.md",
            "LIMITATIONS.md",
            "SECURITY.md",
            "release-manifest.json",
            "test_release_hygiene.py",
        ):
            self.assertIn(evidence, tasks)


if __name__ == "__main__":
    unittest.main()
