#!/usr/bin/env python3
"""Keep warning suppressions narrow, owned, and mechanically auditable."""

from __future__ import annotations

import pathlib
import re
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
MAKEFILE = REPO_ROOT / "scripts" / "Makefile"
POLICY = REPO_ROOT / "docs" / "WARNING_POLICY.md"


class WarningPolicyTest(unittest.TestCase):
    def test_command_line_suppressions_match_the_reviewed_allowlist(self) -> None:
        make_text = MAKEFILE.read_text(encoding="utf-8")
        suppressions = set(re.findall(r"-Wno-([A-Z0-9_]+)", make_text))

        self.assertEqual({"UNUSEDPARAM", "SYNCASYNCNET"}, suppressions)
        self.assertIn("-Wall", make_text)
        self.assertIn("--assert", make_text)
        self.assertNotIn("--Wno-fatal", make_text)

    def test_inline_suppressions_are_paired_and_reviewed(self) -> None:
        seen: set[str] = set()
        for path in sorted((REPO_ROOT / "rtl").rglob("*.sv")) + sorted(
            (REPO_ROOT / "tb").rglob("*.sv")
        ):
            text = path.read_text(encoding="utf-8")
            off = re.findall(r"verilator lint_off ([A-Z0-9_]+)", text)
            on = re.findall(r"verilator lint_on ([A-Z0-9_]+)", text)
            self.assertEqual(
                sorted(off), sorted(on), f"unpaired lint pragma in {path}"
            )
            seen.update(off)

        self.assertEqual(
            {"DECLFILENAME", "SYNCASYNCNET", "UNUSEDSIGNAL"}, seen
        )

    def test_policy_assigns_owner_rationale_and_review_trigger(self) -> None:
        text = POLICY.read_text(encoding="utf-8")
        for warning_class in (
            "UNUSEDPARAM",
            "SYNCASYNCNET",
            "DECLFILENAME",
            "UNUSEDSIGNAL",
        ):
            self.assertIn(f"`{warning_class}`", text)
        self.assertIn("Owner", text)
        self.assertIn("Rationale", text)
        self.assertIn("Review trigger", text)

    def test_tests_never_use_nonfatal_systemverilog_error(self) -> None:
        offenders: list[str] = []
        for root in ("rtl", "verification", "tb"):
            for path in sorted((REPO_ROOT / root).rglob("*.sv")):
                if "$error" in path.read_text(encoding="utf-8"):
                    offenders.append(str(path.relative_to(REPO_ROOT)))
        self.assertEqual([], offenders)


if __name__ == "__main__":
    unittest.main()
