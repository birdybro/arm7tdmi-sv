#!/usr/bin/env python3
"""Generate and validate bidirectional ARM7TDMI-S release traceability."""

from __future__ import annotations

import argparse
import datetime as dt
import fnmatch
import hashlib
import json
import pathlib
import re
import subprocess
from collections.abc import Iterable
from typing import Any


REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
TASKS_PATH = REPO_ROOT / "TASKS.md"
MAPPING_PATH = REPO_ROOT / "verification/traceability.json"
DEFAULT_OUTPUT = REPO_ROOT / "reports/generated/traceability-report.json"
REPORT_SCHEMA = "arm7tdmis-traceability-v1"
MAPPING_SCHEMA = "arm7tdmis-traceability-map-v1"

REQUIREMENT_LINE = re.compile(
    r"^- \[(?P<status>[ xX])\] \*\*(?P<id>[A-Z]+-\d{3}):\*\*"
)
SECTION_LINE = re.compile(r"^## (?P<section>31(?:\.\d+)? .+)$")
PATH_TOKEN = re.compile(
    r"`((?:rtl|tb|verification|scripts|fpga|examples|docs)/[^` ]+)`"
)


def _git(*arguments: str) -> str:
    return subprocess.run(
        ("git", *arguments),
        cwd=REPO_ROOT,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    ).stdout.strip()


def _sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _load_json(path: pathlib.Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _tracked_files() -> tuple[str, ...]:
    output = _git("ls-files")
    return tuple(line for line in output.splitlines() if line)


def _requirement_entries() -> dict[str, dict[str, str]]:
    """Parse canonical §31 checkbox entries and their complete prose blocks."""
    lines = TASKS_PATH.read_text(encoding="utf-8").splitlines()
    requirements: dict[str, dict[str, str]] = {}
    current_section = ""
    active_id: str | None = None
    active_body: list[str] = []

    def finish_active() -> None:
        nonlocal active_id, active_body
        if active_id is not None:
            requirements[active_id]["body"] = "\n".join(active_body).strip()
        active_id = None
        active_body = []

    for line in lines:
        section_match = SECTION_LINE.match(line)
        if section_match:
            finish_active()
            current_section = section_match.group("section")
            continue
        requirement_match = REQUIREMENT_LINE.match(line)
        if requirement_match:
            finish_active()
            active_id = requirement_match.group("id")
            requirements[active_id] = {
                "ledger_status": (
                    "checked"
                    if requirement_match.group("status").lower() == "x"
                    else "open"
                ),
                "task_section": current_section,
                "body": "",
            }
            active_body = [line]
            continue
        if active_id is not None:
            if line.startswith("## "):
                finish_active()
            else:
                active_body.append(line)
    finish_active()
    return requirements


def _matching_requirements(
    path: str,
    rules: Iterable[dict[str, Any]],
) -> list[str]:
    mapped: set[str] = set()
    for rule in rules:
        if fnmatch.fnmatchcase(path, str(rule["glob"])):
            mapped.update(str(value) for value in rule["requirements"])
    return sorted(mapped)


def _unique_strings(values: Iterable[str]) -> list[str]:
    return sorted({value for value in values if value})


def _explicit_evidence_paths(
    body: str,
    *,
    tracked: set[str],
    roots: tuple[str, ...],
    suffixes: tuple[str, ...],
) -> list[str]:
    return _unique_strings(
        path
        for path in PATH_TOKEN.findall(body)
        if path in tracked
        and path.startswith(roots)
        and path.endswith(suffixes)
    )


def _phase_names_from_paths(paths: Iterable[str]) -> list[str]:
    phases: set[str] = set()
    for path in paths:
        name = pathlib.PurePosixPath(path).name
        if path.startswith("tb/unit/") and name.endswith("_tb.sv"):
            phases.add(f"unit-{name.removesuffix('_tb.sv')}")
        elif path.startswith("tb/integration/") and name.endswith("_tb.sv"):
            test_name = name.removeprefix("arm7tdmis_").removesuffix("_tb.sv")
            phases.add(f"integration-{test_name}")
    return sorted(phases)


def _regression_context(path: pathlib.Path | None) -> dict[str, Any] | None:
    if path is None or not path.is_file():
        return None
    try:
        report = _load_json(path)
    except (OSError, ValueError, TypeError):
        return None
    if report.get("schema") != "arm7tdmis-regression-v1":
        return None
    return report


def _latest_result(
    *,
    ledger_status: str,
    expected_phases: list[str],
    regression: dict[str, Any] | None,
) -> str:
    if ledger_status == "open":
        return "OPEN - no accepted sign-off result"
    if regression is None:
        return "ledger checked; no local regression report supplied"

    results = {
        str(result.get("name")): str(result.get("status"))
        for result in regression.get("results", [])
        if isinstance(result, dict)
    }
    matched = [
        f"{phase}={results[phase]}"
        for phase in expected_phases
        if phase in results
    ]
    commit = str(regression.get("git", {}).get("commit", "unknown"))[:12]
    aggregate = str(regression.get("status", "unknown"))
    if matched:
        return (
            f"regression {commit} {aggregate}; "
            + ", ".join(matched)
        )
    return f"ledger checked; regression {commit} {aggregate} has no cited phase"


def _verification_files(tracked: Iterable[str]) -> list[str]:
    selected: list[str] = []
    for path in tracked:
        suffix = pathlib.PurePosixPath(path).suffix
        if path.startswith("tb/") and suffix in {".sv", ".svh", ".hex"}:
            selected.append(path)
        elif path.startswith("verification/") and suffix in {
            ".sv",
            ".py",
            ".S",
            ".c",
            ".ld",
        }:
            selected.append(path)
        elif (
            path.startswith("scripts/tests/test_")
            and suffix == ".py"
        ):
            selected.append(path)
    return sorted(selected)


def build_report(
    *,
    mapping_path: pathlib.Path = MAPPING_PATH,
    regression_path: pathlib.Path | None = None,
) -> dict[str, Any]:
    mapping = _load_json(mapping_path)
    if mapping.get("schema") != MAPPING_SCHEMA:
        raise ValueError("traceability mapping has wrong schema")

    requirements = _requirement_entries()
    tracked = _tracked_files()
    tracked_set = set(tracked)
    prefix_defaults = mapping.get("prefix_defaults", {})
    overrides = mapping.get("requirement_overrides", {})
    rtl_rules = mapping.get("rtl_rules", [])
    verification_rules = mapping.get("verification_rules", [])
    regression = _regression_context(regression_path)

    known_ids = set(requirements)
    referenced_ids: set[str] = set(overrides)
    for rule in (*rtl_rules, *verification_rules):
        referenced_ids.update(str(value) for value in rule["requirements"])

    rtl_files = sorted(
        path
        for path in tracked
        if path.startswith("rtl/")
        and pathlib.PurePosixPath(path).suffix in {".sv", ".svh"}
    )
    verification_files = _verification_files(tracked)
    rtl_reverse = {
        path: _matching_requirements(path, rtl_rules)
        for path in rtl_files
    }
    verification_reverse = {
        path: _matching_requirements(path, verification_rules)
        for path in verification_files
    }

    rows: dict[str, dict[str, Any]] = {}
    for requirement_id in sorted(requirements):
        entry = requirements[requirement_id]
        prefix = requirement_id.split("-", 1)[0]
        if prefix not in prefix_defaults:
            raise ValueError(f"no prefix defaults for {requirement_id}")
        defaults = prefix_defaults[prefix]
        override = overrides.get(requirement_id, {})
        body = entry["body"]

        explicit_rtl = _explicit_evidence_paths(
            body,
            tracked=tracked_set,
            roots=("rtl/", "fpga/", "examples/"),
            suffixes=(".sv", ".svh", ".qsf", ".sdc", ".qip", ".f"),
        )
        explicit_tests = _explicit_evidence_paths(
            body,
            tracked=tracked_set,
            roots=("tb/", "verification/", "scripts/"),
            suffixes=(".sv", ".py", ".S", ".c", ".ld"),
        )
        rtl = _unique_strings(
            (*defaults["rtl"], *explicit_rtl, *override.get("rtl", []))
        )
        tests = _unique_strings(
            (*defaults["tests"], *explicit_tests, *override.get("tests", []))
        )
        expected_phases = _phase_names_from_paths(tests)

        rows[requirement_id] = {
            "source_sections": _unique_strings(
                (
                    entry["task_section"],
                    *defaults["source_sections"],
                    *override.get("source_sections", []),
                )
            ),
            "rtl": rtl,
            "tests": tests,
            "coverage_bins": [
                f"requirement:{requirement_id}:acceptance"
            ],
            "expected_regression_phases": expected_phases,
            "latest_result": _latest_result(
                ledger_status=entry["ledger_status"],
                expected_phases=expected_phases,
                regression=regression,
            ),
            "ledger_status": entry["ledger_status"],
        }

    git_status = _git("status", "--porcelain=v1", "--untracked-files=all")
    report: dict[str, Any] = {
        "schema": REPORT_SCHEMA,
        "created_utc": dt.datetime.now(dt.UTC).isoformat(timespec="seconds"),
        "git": {
            "commit": _git("rev-parse", "HEAD"),
            "dirty": bool(git_status),
        },
        "inputs": {
            "tasks": {
                "path": TASKS_PATH.relative_to(REPO_ROOT).as_posix(),
                "sha256": _sha256(TASKS_PATH),
            },
            "mapping": {
                "path": mapping_path.relative_to(REPO_ROOT).as_posix(),
                "sha256": _sha256(mapping_path),
            },
            "regression": (
                str(regression_path.relative_to(REPO_ROOT))
                if regression is not None
                and regression_path is not None
                and regression_path.is_relative_to(REPO_ROOT)
                else None
            ),
        },
        "requirements": rows,
        "rtl_to_requirements": rtl_reverse,
        "verification_to_requirements": verification_reverse,
        "unmapped_rtl": [
            path for path, values in rtl_reverse.items() if not values
        ],
        "unmapped_verification": [
            path
            for path, values in verification_reverse.items()
            if not values
        ],
        "unknown_requirement_references": sorted(
            referenced_ids - known_ids
        ),
        "summary": {
            "requirement_count": len(rows),
            "checked_requirement_count": sum(
                row["ledger_status"] == "checked"
                for row in rows.values()
            ),
            "open_requirement_count": sum(
                row["ledger_status"] == "open"
                for row in rows.values()
            ),
            "rtl_file_count": len(rtl_reverse),
            "verification_file_count": len(verification_reverse),
        },
    }
    return report


def validate_report(report: dict[str, Any]) -> None:
    errors: list[str] = []
    if report.get("schema") != REPORT_SCHEMA:
        errors.append("wrong report schema")
    if report.get("unmapped_rtl"):
        errors.append(
            "unmapped RTL: " + ", ".join(report["unmapped_rtl"])
        )
    if report.get("unmapped_verification"):
        errors.append(
            "unmapped verification: "
            + ", ".join(report["unmapped_verification"])
        )
    if report.get("unknown_requirement_references"):
        errors.append(
            "unknown requirements: "
            + ", ".join(report["unknown_requirement_references"])
        )
    for requirement_id, row in report.get("requirements", {}).items():
        for field in (
            "source_sections",
            "rtl",
            "tests",
            "coverage_bins",
            "latest_result",
            "ledger_status",
        ):
            if not row.get(field):
                errors.append(f"{requirement_id} has empty {field}")
    if errors:
        raise ValueError("; ".join(errors))


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mapping", type=pathlib.Path, default=MAPPING_PATH)
    parser.add_argument(
        "--regression",
        type=pathlib.Path,
        default=REPO_ROOT / "reports/generated/regression.json",
    )
    parser.add_argument("--output", type=pathlib.Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--check", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    regression_path = args.regression.resolve()
    report = build_report(
        mapping_path=args.mapping.resolve(),
        regression_path=regression_path,
    )
    if args.check:
        validate_report(report)
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(output.suffix + ".tmp")
    temporary.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    temporary.replace(output)
    summary = report["summary"]
    print(
        "[traceability] PASS "
        f"({summary['requirement_count']} requirements, "
        f"{summary['rtl_file_count']} RTL files, "
        f"{summary['verification_file_count']} verification files)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
