#!/usr/bin/env python3
"""Validate the exhaustive ARM DDI 0234B r4p3 coverage inventory."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import pathlib
import re
import subprocess
from typing import Any


REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
TASKS_PATH = REPO_ROOT / "TASKS.md"
DEFAULT_MANIFEST = REPO_ROOT / "verification" / "trm_coverage.json"
DEFAULT_OUTPUT = REPO_ROOT / "reports" / "generated" / "trm-coverage-report.json"
SCHEMA = "arm7tdmis-trm-coverage-map-v1"
REPORT_SCHEMA = "arm7tdmis-trm-coverage-v1"
SOURCE_IDENTITY = {
    "document": "ARM DDI 0234B",
    "revision": "ARM7TDMI-S r4p3",
    "path": "ARM_DDI_0234B_ARM7TDMI-S_r4p3_TRM.pdf",
    "pages": 242,
    "bytes": 1477711,
    "sha256": "bb9cd0e3f2b7e2fdca4ff961cdfc5c9c85c063842e491f8997a504d3241baa14",
}
DISPOSITIONS = {
    "implemented-and-tested",
    "integration-obligation",
    "erratum-corrected",
    "external-out-of-scope",
    "open-requirement",
}
REQUIREMENT_LINE = re.compile(
    r"(?m)^- \[(?P<status>[ xX])\] \*\*(?P<id>[A-Z]+-\d{3}):\*\*"
)


def _numbered(prefix: str, count: int, separator: str) -> set[str]:
    return {f"{prefix}{separator}{index}" for index in range(1, count + 1)}


def _expected_sections() -> set[str]:
    top_counts = {
        "1": 5,
        "2": 11,
        "3": 6,
        "4": 8,
        "5": 27,
        "6": 5,
        "7": 20,
        "8": 2,
        "A": 1,
        "B": 4,
    }
    subsection_counts = {
        "1.1": 3,
        "1.2": 2,
        "1.4": 2,
        "1.5": 5,
        "2.2": 1,
        "2.3": 2,
        "2.7": 4,
        "2.8": 3,
        "2.9": 10,
        "2.10": 2,
        "3.3": 5,
        "3.4": 6,
        "3.5": 4,
        "4.1": 1,
        "4.4": 7,
        "4.5": 2,
        "5.1": 1,
        "5.2": 2,
        "5.3": 5,
        "5.4": 1,
        "5.9": 2,
        "5.10": 2,
        "5.11": 2,
        "5.12": 1,
        "5.13": 5,
        "5.14": 5,
        "5.15": 1,
        "5.16": 2,
        "5.18": 6,
        "5.19": 3,
        "5.20": 3,
        "5.21": 2,
        "5.24": 3,
        "5.26": 2,
        "8.1": 5,
        "B.4": 6,
    }
    sections: set[str] = set()
    for chapter, count in top_counts.items():
        sections.update(_numbered(chapter, count, "."))
    for parent, count in subsection_counts.items():
        sections.update(_numbered(parent, count, "."))
    return sections


EXPECTED_INVENTORY = {
    "sections": _expected_sections(),
    "tables": set().union(
        _numbered("1", 12, "-"),
        _numbered("2", 4, "-"),
        _numbered("3", 9, "-"),
        _numbered("4", 4, "-"),
        _numbered("5", 8, "-"),
        _numbered("6", 1, "-"),
        _numbered("7", 23, "-"),
        _numbered("8", 1, "-"),
        _numbered("A", 1, "-"),
        _numbered("B", 2, "-"),
    ),
    "figures": set().union(
        _numbered("1", 4, "-"),
        _numbered("2", 6, "-"),
        _numbered("3", 7, "-"),
        _numbered("4", 5, "-"),
        _numbered("5", 17, "-"),
        _numbered("8", 5, "-"),
    ),
    "signals": {
        "ABORT",
        "ADDR[31:0]",
        "CFGBIGEND",
        "CLK",
        "CLKEN",
        "CPA",
        "CPB",
        "CPnI",
        "CPnMREQ",
        "CPnOPC",
        "CPSEQ",
        "CPTBIT",
        "CPnTRANS",
        "DBGACK",
        "DBGBREAK",
        "DBGCOMMRX",
        "DBGCOMMTX",
        "DBGEN",
        "DBGnEXEC",
        "DBGEXT[1:0]",
        "DBGINSTRVALID",
        "DBGRNG[1:0]",
        "DBGRQ",
        "DBGTCKEN",
        "DBGTDI",
        "DBGTDO",
        "DBGnTDOEN",
        "DBGTMS",
        "DBGnTRST",
        "DMORE",
        "nFIQ",
        "nIRQ",
        "LOCK",
        "PROT[1:0]",
        "RDATA[31:0]",
        "nRESET",
        "SCANENABLE",
        "SCANIN",
        "SCANOUT",
        "SIZE[1:0]",
        "TRANS[1:0]",
        "VDD",
        "VSS",
        "WDATA[31:0]",
        "WRITE",
    },
}


def _sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _git(*arguments: str) -> str:
    return subprocess.run(
        ("git", *arguments),
        cwd=REPO_ROOT,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    ).stdout.strip()


def _requirements() -> dict[str, str]:
    requirements: dict[str, str] = {}
    for match in REQUIREMENT_LINE.finditer(TASKS_PATH.read_text(encoding="utf-8")):
        requirements[match.group("id")] = (
            "checked" if match.group("status").lower() == "x" else "open"
        )
    return requirements


def _inventory_sets(manifest: dict[str, Any]) -> dict[str, set[str]]:
    inventory = manifest.get("inventory")
    if not isinstance(inventory, dict) or set(inventory) != set(EXPECTED_INVENTORY):
        raise ValueError("TRM inventory categories changed")
    result: dict[str, set[str]] = {}
    for category, expected in EXPECTED_INVENTORY.items():
        values = inventory.get(category)
        if not isinstance(values, list) or not all(
            isinstance(value, str) and value for value in values
        ):
            raise ValueError(f"{category} inventory is malformed")
        if len(values) != len(set(values)):
            raise ValueError(f"{category} inventory contains duplicates")
        actual = set(values)
        if actual != expected:
            missing = sorted(expected - actual)
            extra = sorted(actual - expected)
            raise ValueError(
                f"{category} inventory mismatch; missing={missing}, extra={extra}"
            )
        result[category] = actual
    return result


def _selector_items(
    selector: dict[str, Any], inventory: dict[str, set[str]]
) -> set[tuple[str, str]]:
    category = selector.get("category")
    if category not in inventory:
        raise ValueError(f"coverage selector has unknown category: {category}")
    modes = [key for key in ("items", "prefix", "all") if key in selector]
    if len(modes) != 1:
        raise ValueError("coverage selector must use exactly one selection mode")
    values = inventory[category]
    if "items" in selector:
        requested = selector["items"]
        if not isinstance(requested, list) or not all(
            isinstance(value, str) for value in requested
        ):
            raise ValueError("coverage selector items are malformed")
        selected = set(requested)
        if not selected <= values:
            raise ValueError(
                f"coverage selector references unknown {category}: "
                f"{sorted(selected - values)}"
            )
    elif "prefix" in selector:
        prefix = selector["prefix"]
        if not isinstance(prefix, str) or not prefix:
            raise ValueError("coverage selector prefix is malformed")
        selected = {value for value in values if value.startswith(prefix)}
    else:
        if selector["all"] is not True:
            raise ValueError("coverage selector all mode must be true")
        selected = set(values)
    excluded = selector.get("exclude", [])
    if not isinstance(excluded, list) or not all(
        isinstance(value, str) for value in excluded
    ):
        raise ValueError("coverage selector exclusion is malformed")
    unknown_exclusions = set(excluded) - selected
    if unknown_exclusions:
        raise ValueError(
            f"coverage selector excludes unmatched items: {sorted(unknown_exclusions)}"
        )
    selected -= set(excluded)
    if not selected:
        raise ValueError("coverage selector matched no inventory items")
    return {(category, value) for value in selected}


def validate_manifest(manifest: dict[str, Any]) -> dict[str, Any]:
    if manifest.get("schema") != SCHEMA:
        raise ValueError("TRM coverage manifest has wrong schema")
    if manifest.get("source") != SOURCE_IDENTITY:
        raise ValueError("TRM source identity changed")
    source_path = REPO_ROOT / SOURCE_IDENTITY["path"]
    if (
        not source_path.is_file()
        or source_path.stat().st_size != SOURCE_IDENTITY["bytes"]
        or _sha256(source_path) != SOURCE_IDENTITY["sha256"]
    ):
        raise ValueError("TRM PDF identity does not match the audited revision")

    inventory = _inventory_sets(manifest)
    requirements = _requirements()
    groups = manifest.get("coverage_groups")
    if not isinstance(groups, list) or not groups:
        raise ValueError("TRM coverage groups are missing")

    assigned: dict[tuple[str, str], str] = {}
    disposition_counts = {disposition: 0 for disposition in DISPOSITIONS}
    group_ids: set[str] = set()
    normalized_groups: list[dict[str, Any]] = []
    for group in groups:
        if not isinstance(group, dict):
            raise ValueError("TRM coverage group is malformed")
        group_id = group.get("id")
        if not isinstance(group_id, str) or not group_id or group_id in group_ids:
            raise ValueError(f"TRM coverage group ID is invalid or duplicate: {group_id}")
        group_ids.add(group_id)
        disposition = group.get("disposition")
        if disposition not in DISPOSITIONS:
            raise ValueError(f"{group_id} has unknown disposition: {disposition}")
        rationale = group.get("rationale")
        if not isinstance(rationale, str) or not rationale.strip():
            raise ValueError(f"{group_id} has no rationale")
        evidence = group.get("evidence")
        if not isinstance(evidence, list) or not evidence:
            raise ValueError(f"{group_id} has no evidence paths")
        for path_text in evidence:
            if (
                not isinstance(path_text, str)
                or not path_text
                or not (REPO_ROOT / path_text).is_file()
            ):
                raise ValueError(f"{group_id} evidence path is missing: {path_text}")
        requirement_ids = group.get("requirements")
        if not isinstance(requirement_ids, list) or not requirement_ids:
            raise ValueError(f"{group_id} has no requirement references")
        unknown_requirements = set(requirement_ids) - set(requirements)
        if unknown_requirements:
            raise ValueError(
                f"{group_id} references unknown requirements: "
                f"{sorted(unknown_requirements)}"
            )
        statuses = {requirements[value] for value in requirement_ids}
        if disposition == "open-requirement":
            if "open" not in statuses:
                raise ValueError(f"{group_id} has no open owning requirement")
        elif "open" in statuses:
            raise ValueError(
                f"{group_id} claims {disposition} with an unchecked requirement"
            )

        selectors = group.get("selectors")
        if not isinstance(selectors, list) or not selectors:
            raise ValueError(f"{group_id} has no inventory selectors")
        selected: set[tuple[str, str]] = set()
        for selector in selectors:
            if not isinstance(selector, dict):
                raise ValueError(f"{group_id} has a malformed selector")
            selector_items = _selector_items(selector, inventory)
            overlap = selected & selector_items
            if overlap:
                raise ValueError(
                    f"{group_id} selects inventory more than once: {sorted(overlap)}"
                )
            selected.update(selector_items)
        for item in selected:
            if item in assigned:
                raise ValueError(
                    f"{item[0]}:{item[1]} assigned by both "
                    f"{assigned[item]} and {group_id}"
                )
            assigned[item] = group_id
        disposition_counts[disposition] += len(selected)
        normalized_groups.append(
            {
                "id": group_id,
                "disposition": disposition,
                "item_count": len(selected),
                "requirements": list(requirement_ids),
                "evidence": list(evidence),
            }
        )

    expected_items = {
        (category, value)
        for category, values in inventory.items()
        for value in values
    }
    missing = expected_items - set(assigned)
    if missing:
        raise ValueError(
            "TRM inventory has no disposition: "
            + ", ".join(f"{category}:{value}" for category, value in sorted(missing))
        )
    if set(assigned) - expected_items:
        raise ValueError("TRM coverage assigns unknown inventory")

    return {
        "inventory_counts": {
            category: len(values) for category, values in inventory.items()
        },
        "total_inventory_items": len(expected_items),
        "coverage_group_count": len(normalized_groups),
        "disposition_counts": disposition_counts,
        "groups": normalized_groups,
    }


def build_report(manifest_path: pathlib.Path = DEFAULT_MANIFEST) -> dict[str, Any]:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    summary = validate_manifest(manifest)
    status = _git("status", "--porcelain=v1", "--untracked-files=all")
    input_paths = {
        "manifest": manifest_path,
        "tasks": TASKS_PATH,
        "validator": pathlib.Path(__file__).resolve(),
        "documentation": REPO_ROOT / "docs" / "TRM_COVERAGE.md",
        "manual": REPO_ROOT / SOURCE_IDENTITY["path"],
    }
    return {
        "schema": REPORT_SCHEMA,
        "status": "passed",
        "created_utc": dt.datetime.now(dt.UTC).isoformat(timespec="seconds"),
        "git": {
            "commit": _git("rev-parse", "HEAD"),
            "dirty": bool(status),
        },
        "source": dict(SOURCE_IDENTITY),
        "inputs": {
            name: {
                "path": path.relative_to(REPO_ROOT).as_posix(),
                "bytes": path.stat().st_size,
                "sha256": _sha256(path),
            }
            for name, path in input_paths.items()
        },
        **summary,
    }


def validate_report(
    report: dict[str, Any],
    *,
    expected_commit: str | None = None,
    require_clean: bool = False,
) -> None:
    if report.get("schema") != REPORT_SCHEMA or report.get("status") != "passed":
        raise ValueError("TRM coverage report is not a passing known schema")
    if report.get("source") != SOURCE_IDENTITY:
        raise ValueError("TRM coverage report source identity changed")
    if report.get("inventory_counts") != {
        category: len(values) for category, values in EXPECTED_INVENTORY.items()
    }:
        raise ValueError("TRM coverage report inventory counts changed")
    if report.get("total_inventory_items") != sum(
        len(values) for values in EXPECTED_INVENTORY.values()
    ):
        raise ValueError("TRM coverage report total changed")
    if require_clean and report.get("git", {}).get("dirty"):
        raise ValueError("TRM coverage report describes a dirty source tree")
    if (
        expected_commit is not None
        and report.get("git", {}).get("commit") != expected_commit
    ):
        raise ValueError("TRM coverage report commit does not match regression")
    inputs = report.get("inputs")
    if not isinstance(inputs, dict) or set(inputs) != {
        "manifest",
        "tasks",
        "validator",
        "documentation",
        "manual",
    }:
        raise ValueError("TRM coverage report input manifest changed")
    for entry in inputs.values():
        if not isinstance(entry, dict):
            raise ValueError("TRM coverage report input entry is malformed")
        path = REPO_ROOT / str(entry.get("path", ""))
        if (
            not path.is_file()
            or path.stat().st_size != entry.get("bytes")
            or _sha256(path) != entry.get("sha256")
        ):
            raise ValueError(f"TRM coverage report input hash mismatch: {path}")


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=pathlib.Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--output", type=pathlib.Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--check", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    report = build_report(args.manifest.resolve())
    if args.check:
        validate_report(report)
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(output.suffix + ".tmp")
    temporary.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, output)
    counts = report["inventory_counts"]
    print(
        "[trm-coverage] PASS "
        f"({counts['sections']} sections/subsections, "
        f"{counts['tables']} tables, {counts['figures']} figures, "
        f"{counts['signals']} signals; "
        f"{report['coverage_group_count']} disposition groups)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
