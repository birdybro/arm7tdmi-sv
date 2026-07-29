#!/usr/bin/env python3
"""Fail-hard structural clock-domain and reset-domain audit."""

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


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
DEFAULT_MANIFEST = REPO_ROOT / "verification/cdc_rdc_manifest.json"
DEFAULT_OUTPUT = REPO_ROOT / "reports/generated/cdc-rdc.json"
REPORT_SCHEMA = "arm7tdmis-cdc-rdc-v1"
MANIFEST_SCHEMA = "arm7tdmis-cdc-rdc-manifest-v1"

ALWAYS_FF_RE = re.compile(r"\balways_ff\s*@\s*\((?P<sensitivity>[^)]*)\)")
EDGE_RE = re.compile(r"\b(posedge|negedge)\s+([A-Za-z_]\w*)")
NONBLOCKING_ASSIGN_RE = re.compile(
    r"\b(?P<lhs>[A-Za-z_]\w*)(?:\s*\[[^]]+\])?\s*"
    r"<=\s*(?P<rhs>[^;]+);",
    re.DOTALL,
)
CONTINUOUS_ASSIGN_RE = re.compile(
    r"\bassign\s+(?P<lhs>[A-Za-z_]\w*)(?:\s*\[[^]]+\])?\s*"
    r"=\s*(?P<rhs>[^;]+);",
    re.DOTALL,
)


def _utc_now() -> str:
    return dt.datetime.now(dt.UTC).isoformat(timespec="seconds")


def _sha256_bytes(contents: bytes) -> str:
    return hashlib.sha256(contents).hexdigest()


def _strip_comments(source: str) -> str:
    without_blocks = re.sub(r"/\*.*?\*/", " ", source, flags=re.DOTALL)
    return re.sub(r"//[^\n]*", " ", without_blocks)


def _token_present(text: str, token: str) -> bool:
    return re.search(rf"\b{re.escape(token)}\b", text) is not None


def _assignments(source: str) -> list[tuple[str, str]]:
    matches = [
        (match.start(), match.group("lhs"), match.group("rhs"))
        for pattern in (NONBLOCKING_ASSIGN_RE, CONTINUOUS_ASSIGN_RE)
        for match in pattern.finditer(source)
    ]
    return [(lhs, rhs) for _, lhs, rhs in sorted(matches)]


def _attribute_marks(source: str, signal: str) -> bool:
    pattern = (
        r"SYNCHRONIZER_IDENTIFICATION\s+FORCED_IF_ASYNCHRONOUS"
        r"[^;]{0,240}\blogic\b[^;]*\b"
        + re.escape(signal)
        + r"\b"
    )
    return re.search(pattern, source, flags=re.DOTALL) is not None


def _violation(
    violations: list[dict[str, str]],
    *,
    rule: str,
    path: str,
    detail: str,
) -> None:
    violations.append({"rule": rule, "path": path, "detail": detail})


def analyze_sources(
    sources: dict[str, str],
    manifest: dict[str, Any],
) -> dict[str, Any]:
    """Analyze source text against an explicit reviewed CDC/RDC manifest."""
    clocks = {str(value) for value in manifest.get("clock_domains", [])}
    resets = {
        str(value) for value in manifest.get("allowed_async_resets", [])
    }
    violations: list[dict[str, str]] = []
    sequential_blocks: list[dict[str, Any]] = []

    for path, original_source in sorted(sources.items()):
        source = _strip_comments(original_source)
        if re.search(r"\balways_latch\b", source):
            _violation(
                violations,
                rule="inferred-latch-process",
                path=path,
                detail="always_latch is forbidden in production RTL",
            )
        if re.search(r"\balways\s*@", source):
            _violation(
                violations,
                rule="untyped-sequential-process",
                path=path,
                detail="use always_ff/always_comb so driver intent is checked",
            )

        for match in ALWAYS_FF_RE.finditer(source):
            sensitivity = match.group("sensitivity")
            edges = EDGE_RE.findall(sensitivity)
            positive = [signal for edge, signal in edges if edge == "posedge"]
            negative = [signal for edge, signal in edges if edge == "negedge"]
            line = source.count("\n", 0, match.start()) + 1
            sequential_blocks.append(
                {
                    "path": path,
                    "line": line,
                    "sensitivity": " ".join(sensitivity.split()),
                    "clocks": positive,
                    "async_resets": negative,
                }
            )
            if len(positive) != 1 or positive[0] not in clocks:
                _violation(
                    violations,
                    rule="unknown-clock-domain",
                    path=f"{path}:{line}",
                    detail=(
                        f"always_ff clocks {positive}, "
                        f"expected one of {sorted(clocks)}"
                    ),
                )
            for reset in negative:
                if reset not in resets:
                    _violation(
                        violations,
                        rule="unauthorized-async-reset",
                        path=f"{path}:{line}",
                        detail=f"{reset} is not an approved reset-release path",
                    )
            if len(negative) > 1:
                _violation(
                    violations,
                    rule="multiple-async-resets",
                    path=f"{path}:{line}",
                    detail=f"always_ff has async resets {negative}",
                )

    synchronizer_results: list[dict[str, Any]] = []
    for entry in manifest.get("synchronizers", []):
        path = str(entry["file"])
        source = _strip_comments(sources.get(path, ""))
        original_source = sources.get(path, "")
        async_source = str(entry["source"])
        first_stage = str(entry["first_stage"])
        second_stage = str(entry["second_stage"])
        assignments = _assignments(source)
        source_users = [
            lhs for lhs, rhs in assignments if _token_present(rhs, async_source)
        ]
        first_stage_users = [
            lhs for lhs, rhs in assignments if _token_present(rhs, first_stage)
        ]
        marked = (
            _attribute_marks(original_source, first_stage)
            and _attribute_marks(original_source, second_stage)
        )
        result = {
            "file": path,
            "source": async_source,
            "first_stage": first_stage,
            "second_stage": second_stage,
            "source_users": source_users,
            "first_stage_users": first_stage_users,
            "marked": marked,
        }
        synchronizer_results.append(result)
        if not source:
            _violation(
                violations,
                rule="missing-synchronizer-source",
                path=path,
                detail=f"source file for {async_source} is missing",
            )
            continue
        if source_users != [first_stage]:
            _violation(
                violations,
                rule="async-source-fanout",
                path=path,
                detail=f"{async_source} assignment users are {source_users}",
            )
        if first_stage_users != [second_stage]:
            _violation(
                violations,
                rule="first-stage-fanout",
                path=path,
                detail=f"{first_stage} assignment users are {first_stage_users}",
            )
        control_use = re.search(
            rf"\b(?:if|case|while)\s*\([^)]*\b{re.escape(async_source)}\b",
            source,
        )
        if control_use:
            _violation(
                violations,
                rule="async-source-control-use",
                path=path,
                detail=f"{async_source} is used directly in control logic",
            )
        if entry.get("require_attribute") and not marked:
            _violation(
                violations,
                rule="missing-synchronizer-attribute",
                path=path,
                detail=f"{first_stage}/{second_stage} are not both marked",
            )

    reset_primitive_entry = manifest.get("reset_synchronizer_primitive")
    reset_primitive_result: dict[str, Any] = {"status": "not-reviewed"}
    if isinstance(reset_primitive_entry, dict):
        path = str(reset_primitive_entry["file"])
        original_source = sources.get(path, "")
        source = _strip_comments(original_source)
        async_source = str(reset_primitive_entry["async_source"])
        first_stage = str(reset_primitive_entry["first_stage"])
        second_stage = str(reset_primitive_entry["second_stage"])
        output = str(reset_primitive_entry["output"])
        assignments = _assignments(source)
        first_stage_values = [
            " ".join(rhs.split())
            for lhs, rhs in assignments
            if lhs == first_stage
        ]
        second_stage_values = [
            " ".join(rhs.split())
            for lhs, rhs in assignments
            if lhs == second_stage
        ]
        first_stage_users = [
            lhs for lhs, rhs in assignments if _token_present(rhs, first_stage)
        ]
        second_stage_users = [
            lhs for lhs, rhs in assignments if _token_present(rhs, second_stage)
        ]
        marked = (
            _attribute_marks(original_source, first_stage)
            and _attribute_marks(original_source, second_stage)
        )
        sensitivity_verified = any(
            positive == ["CLK"] and negative == [async_source]
            for match in ALWAYS_FF_RE.finditer(source)
            for edges in (EDGE_RE.findall(match.group("sensitivity")),)
            for positive in (
                [signal for edge, signal in edges if edge == "posedge"],
            )
            for negative in (
                [signal for edge, signal in edges if edge == "negedge"],
            )
        )
        valid = (
            first_stage_values == ["1'b0", "1'b1"]
            and second_stage_values == ["1'b0", first_stage]
            and first_stage_users == [second_stage]
            and second_stage_users == [output]
            and sensitivity_verified
            and (
                not reset_primitive_entry.get("require_attribute")
                or marked
            )
        )
        reset_primitive_result = {
            "file": path,
            "async_source": async_source,
            "first_stage": first_stage,
            "second_stage": second_stage,
            "output": output,
            "first_stage_values": first_stage_values,
            "second_stage_values": second_stage_values,
            "first_stage_users": first_stage_users,
            "second_stage_users": second_stage_users,
            "marked": marked,
            "sensitivity_verified": sensitivity_verified,
            "status": "verified" if valid else "invalid",
        }
        if not valid:
            _violation(
                violations,
                rule="invalid-reset-synchronizer-primitive",
                path=path,
                detail="async-assert/sync-release topology or attributes changed",
            )

    reset_release_results: list[dict[str, str]] = []
    for entry in manifest.get("reset_release_instances", []):
        path = str(entry["file"])
        source = _strip_comments(sources.get(path, ""))
        instance = str(entry["instance"])
        reset_source = str(entry["source"])
        released_reset = str(entry["released_reset"])
        instance_match = re.search(
            rf"\barm7tdmis_reset_sync\s+{re.escape(instance)}\s*\("
            rf"(?P<ports>.*?)\)\s*;",
            source,
            flags=re.DOTALL,
        )
        valid = False
        if instance_match:
            ports = instance_match.group("ports")
            valid = bool(
                re.search(
                    rf"\.nRESET\s*\(\s*{re.escape(reset_source)}\s*\)",
                    ports,
                )
                and re.search(
                    rf"\.core_nreset\s*\(\s*{re.escape(released_reset)}\s*\)",
                    ports,
                )
            )
        reset_release_results.append(
            {
                "file": path,
                "instance": instance,
                "source": reset_source,
                "released_reset": released_reset,
                "status": "verified" if valid else "invalid",
            }
        )
        if not valid:
            _violation(
                violations,
                rule="invalid-reset-release-instance",
                path=path,
                detail=f"{instance} does not map {reset_source} to {released_reset}",
            )

    async_reset_count = sum(
        bool(block["async_resets"]) for block in sequential_blocks
    )
    expected_sequential = manifest.get("expected_sequential_block_count")
    expected_async_reset = manifest.get("expected_async_reset_block_count")
    if (
        expected_sequential is not None
        and len(sequential_blocks) != expected_sequential
    ):
        _violation(
            violations,
            rule="sequential-inventory-change",
            path="rtl/",
            detail=(
                f"found {len(sequential_blocks)} always_ff blocks, "
                f"expected {expected_sequential}"
            ),
        )
    if (
        expected_async_reset is not None
        and async_reset_count != expected_async_reset
    ):
        _violation(
            violations,
            rule="async-reset-inventory-change",
            path="rtl/",
            detail=(
                f"found {async_reset_count} async-reset blocks, "
                f"expected {expected_async_reset}"
            ),
        )

    return {
        "clock_domains": sorted(clocks),
        "sequential_block_count": len(sequential_blocks),
        "async_reset_block_count": async_reset_count,
        "sequential_blocks": sequential_blocks,
        "synchronizer_count": len(synchronizer_results),
        "synchronizers": synchronizer_results,
        "reset_synchronizer_primitive": reset_primitive_result,
        "reset_release_count": len(reset_release_results),
        "reset_release_instances": reset_release_results,
        "violations": violations,
    }


def _git(command: tuple[str, ...], repo_root: pathlib.Path) -> str:
    return subprocess.run(
        ("git", *command),
        cwd=repo_root,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    ).stdout.strip()


def build_report(
    *,
    repo_root: pathlib.Path = REPO_ROOT,
    manifest_path: pathlib.Path = DEFAULT_MANIFEST,
) -> dict[str, Any]:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("schema") != MANIFEST_SCHEMA:
        raise ValueError("CDC/RDC manifest has wrong schema")
    rtl_root = repo_root / "rtl"
    sources = {
        path.relative_to(repo_root).as_posix(): path.read_text(encoding="utf-8")
        for path in sorted(rtl_root.rglob("*.sv"))
    }
    analysis = analyze_sources(sources, manifest)
    status_text = _git(
        ("status", "--porcelain=v1", "--untracked-files=all"),
        repo_root,
    )
    report = {
        "schema": REPORT_SCHEMA,
        "created_utc": _utc_now(),
        "status": "passed" if not analysis["violations"] else "failed",
        "git": {
            "commit": _git(("rev-parse", "HEAD"), repo_root),
            "dirty": bool(status_text),
            "status": status_text.splitlines(),
        },
        "manifest": {
            "path": manifest_path.relative_to(repo_root).as_posix(),
            "sha256": _sha256_bytes(manifest_path.read_bytes()),
            "reviewed_reset_contracts": manifest.get(
                "reviewed_reset_contracts", []
            ),
        },
        "checker": {
            "path": pathlib.Path(__file__).resolve().relative_to(
                repo_root
            ).as_posix(),
            "bytes": pathlib.Path(__file__).stat().st_size,
            "sha256": _sha256_bytes(pathlib.Path(__file__).read_bytes()),
        },
        "inputs": {
            path: {
                "bytes": len(contents.encode()),
                "sha256": _sha256_bytes(contents.encode()),
            }
            for path, contents in sorted(sources.items())
        },
        **analysis,
    }
    return report


def validate_report(report: dict[str, Any]) -> None:
    if report.get("schema") != REPORT_SCHEMA:
        raise ValueError("CDC/RDC report has wrong schema")
    if report.get("status") != "passed" or report.get("violations"):
        raise ValueError("CDC/RDC report contains structural violations")
    if report.get("clock_domains") != ["CLK"]:
        raise ValueError("CDC/RDC report does not prove the single-clock design")
    if report.get("synchronizer_count", 0) < 6:
        raise ValueError("CDC/RDC report lost an event synchronizer")
    if report.get("reset_release_count", 0) < 2:
        raise ValueError("CDC/RDC report lost a reset-release synchronizer")
    if report.get("reset_synchronizer_primitive", {}).get(
        "status"
    ) != "verified":
        raise ValueError("CDC/RDC report lost reset synchronizer topology")


def _atomic_write(path: pathlib.Path, report: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, path)


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=pathlib.Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--output", type=pathlib.Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--check", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    report = build_report(manifest_path=args.manifest)
    _atomic_write(args.output, report)
    if args.check:
        validate_report(report)
    print(
        f"[cdc-rdc] {report['status'].upper()} "
        f"({report['sequential_block_count']} sequential blocks, "
        f"{report['synchronizer_count']} event synchronizers, "
        f"{len(report['violations'])} violations)"
    )
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
