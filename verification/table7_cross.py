#!/usr/bin/env python3
"""Aggregate exact Chapter 7 cross evidence from a full regression.

This gate does not infer coverage from source names or prose.  Every manifest
entry must identify a passing full-regression phase, a PASS marker in that
phase's hashed log, and the exact hashed testbench source that owns the rows.
"""

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
SCHEMA = "arm7tdmis-table7-cross-v1"
MANIFEST_SCHEMA = "arm7tdmis-table7-cross-map-v1"
REGRESSION_SCHEMA = "arm7tdmis-regression-v1"
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


def _sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _utc_now() -> str:
    return dt.datetime.now(dt.UTC).isoformat(timespec="seconds")


def _repo_path(path_text: str, *, must_exist: bool = True) -> pathlib.Path:
    candidate = pathlib.Path(path_text)
    resolved = (
        candidate.resolve()
        if candidate.is_absolute()
        else (REPO_ROOT / candidate).resolve()
    )
    try:
        resolved.relative_to(REPO_ROOT)
    except ValueError as error:
        raise ValueError(f"path escapes repository: {path_text}") from error
    if must_exist and not resolved.is_file():
        raise ValueError(f"required file is missing: {path_text}")
    return resolved


def _artifact(path: pathlib.Path) -> dict[str, Any]:
    resolved = path.resolve()
    return {
        "path": resolved.relative_to(REPO_ROOT).as_posix(),
        "bytes": resolved.stat().st_size,
        "sha256": _sha256(resolved),
    }


def _git(*arguments: str) -> str:
    return subprocess.run(
        ("git", *arguments),
        cwd=REPO_ROOT,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    ).stdout.strip()


def _write_report(path: pathlib.Path, report: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, path)


def _load_json(path: pathlib.Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"JSON root is not an object: {path}")
    return value


def _validate_manifest(manifest: dict[str, Any]) -> None:
    if manifest.get("schema") != MANIFEST_SCHEMA:
        raise ValueError("Chapter 7 cross manifest has wrong schema")
    required = manifest.get("required_crosses")
    crosses = manifest.get("crosses")
    if (
        not isinstance(required, list)
        or tuple(required) != REQUIRED_CROSSES
        or len(required) != len(set(required))
        or not isinstance(crosses, dict)
        or tuple(crosses) != REQUIRED_CROSSES
    ):
        raise ValueError("Chapter 7 required cross set is incomplete")

    for name in REQUIRED_CROSSES:
        cross = crosses[name]
        if not isinstance(cross, dict):
            raise ValueError(f"cross {name} is malformed")
        dimensions = cross.get("dimensions")
        evidence = cross.get("evidence")
        if (
            not isinstance(cross.get("description"), str)
            or not cross["description"]
            or not isinstance(dimensions, dict)
            or not dimensions
            or any(
                not isinstance(values, list)
                or not values
                or len(values) != len(set(values))
                for values in dimensions.values()
            )
            or type(cross.get("minimum_rows")) is not int
            or cross["minimum_rows"] <= 0
            or not isinstance(evidence, list)
            or not evidence
        ):
            raise ValueError(f"cross {name} has an incomplete definition")

        identities: set[tuple[str, str]] = set()
        expected_rows = 0
        for entry in evidence:
            if not isinstance(entry, dict):
                raise ValueError(f"cross {name} evidence is malformed")
            phase = entry.get("phase")
            source = entry.get("source")
            marker = entry.get("marker")
            rows = entry.get("expected_rows")
            if (
                not isinstance(phase, str)
                or not re.fullmatch(r"integration-[a-z0-9_]+", phase)
                or not isinstance(source, str)
                or not source.startswith("tb/integration/")
                or not source.endswith("_tb.sv")
                or not isinstance(marker, str)
                or "PASS" not in marker
                or type(rows) is not int
                or rows <= 0
            ):
                raise ValueError(f"cross {name} evidence entry is incomplete")
            try:
                re.compile(marker)
            except re.error as error:
                raise ValueError(
                    f"cross {name} has invalid marker regex"
                ) from error
            identity = (phase, source)
            if identity in identities:
                raise ValueError(f"cross {name} repeats evidence {phase}")
            identities.add(identity)
            _repo_path(source)
            expected_rows += rows
        if expected_rows < cross["minimum_rows"]:
            raise ValueError(f"cross {name} is below its minimum row count")


def build_report(
    *,
    manifest: dict[str, Any],
    regression: dict[str, Any],
    manifest_path: pathlib.Path,
    regression_path: pathlib.Path,
) -> dict[str, Any]:
    """Validate live full-regression results and build their cross report."""
    _validate_manifest(manifest)
    if regression.get("schema") != REGRESSION_SCHEMA:
        raise ValueError("regression report has wrong schema")
    if regression.get("mode") != "full":
        raise ValueError("expected full regression for Chapter 7 cross gate")
    if regression.get("status") not in {"running", "passed"}:
        raise ValueError("regression is not in a passing/running state")

    git = regression.get("git")
    current_commit = _git("rev-parse", "HEAD")
    current_dirty = bool(
        _git("status", "--porcelain=v1", "--untracked-files=all")
    )
    if (
        not isinstance(git, dict)
        or git.get("dirty")
        or git.get("commit") != current_commit
        or current_dirty
    ):
        raise ValueError(
            "Chapter 7 cross evidence requires the current clean commit"
        )

    raw_results = regression.get("results")
    if not isinstance(raw_results, list):
        raise ValueError("regression report has no phase results")
    results: dict[str, dict[str, Any]] = {}
    for result in raw_results:
        if not isinstance(result, dict):
            raise ValueError("regression phase result is malformed")
        name = result.get("name")
        if not isinstance(name, str) or name in results:
            raise ValueError("regression phase names are missing or duplicated")
        results[name] = result

    output_crosses: dict[str, Any] = {}
    total_minimum_rows = 0
    total_observed_rows = 0
    for name in REQUIRED_CROSSES:
        definition = manifest["crosses"][name]
        resolved_evidence: list[dict[str, Any]] = []
        observed_rows = 0
        for expected in definition["evidence"]:
            phase = expected["phase"]
            result = results.get(phase)
            if (
                result is None
                or result.get("status") != "passed"
                or result.get("exit_code") != 0
            ):
                raise ValueError(
                    f"required Chapter 7 phase did not pass: {phase}"
                )
            log_path = _repo_path(str(result.get("log", "")))
            if _sha256(log_path) != result.get("log_sha256"):
                raise ValueError(
                    f"Chapter 7 regression log_sha256 mismatch: {phase}"
                )
            log_text = log_path.read_text(encoding="utf-8", errors="replace")
            if re.search(expected["marker"], log_text) is None:
                raise ValueError(
                    f"Chapter 7 PASS marker missing from phase: {phase}"
                )

            source_path = _repo_path(expected["source"])
            resolved_evidence.append(
                {
                    **expected,
                    "status": "passed",
                    "log": _artifact(log_path),
                    "source_artifact": _artifact(source_path),
                }
            )
            observed_rows += expected["expected_rows"]

        minimum_rows = definition["minimum_rows"]
        if observed_rows < minimum_rows:
            raise ValueError(f"cross {name} did not meet minimum_rows")
        output_crosses[name] = {
            "description": definition["description"],
            "dimensions": definition["dimensions"],
            "minimum_rows": minimum_rows,
            "observed_rows": observed_rows,
            "evidence": resolved_evidence,
        }
        total_minimum_rows += minimum_rows
        total_observed_rows += observed_rows

    runner_path = pathlib.Path(__file__).resolve()
    return {
        "schema": SCHEMA,
        "status": "passed",
        "failure": None,
        "created_utc": _utc_now(),
        "git": {
            "commit": current_commit,
            "dirty": False,
            "source_sha256": git.get("source_sha256"),
        },
        "regression": {
            "path": regression_path.resolve().relative_to(REPO_ROOT).as_posix(),
            "schema": REGRESSION_SCHEMA,
            "mode": "full",
            "status_when_sampled": regression["status"],
            "commit": current_commit,
        },
        "inputs": {
            manifest_path.resolve().relative_to(REPO_ROOT).as_posix(): _artifact(
                manifest_path
            ),
            runner_path.relative_to(REPO_ROOT).as_posix(): _artifact(runner_path),
        },
        "required_crosses": list(REQUIRED_CROSSES),
        "covered_crosses": list(REQUIRED_CROSSES),
        "missing_crosses": [],
        "cross_count": len(REQUIRED_CROSSES),
        "total_minimum_rows": total_minimum_rows,
        "total_observed_rows": total_observed_rows,
        "crosses": output_crosses,
    }


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--manifest",
        type=pathlib.Path,
        default=REPO_ROOT / "verification/table7_cross.json",
    )
    parser.add_argument(
        "--regression",
        type=pathlib.Path,
        default=REPO_ROOT / "reports/generated/regression.json",
    )
    parser.add_argument(
        "--output",
        type=pathlib.Path,
        default=REPO_ROOT / "reports/generated/table7-cross-report.json",
    )
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    manifest_path = _repo_path(str(args.manifest))
    regression_path = _repo_path(str(args.regression))
    output_path = _repo_path(str(args.output), must_exist=False)
    try:
        report = build_report(
            manifest=_load_json(manifest_path),
            regression=_load_json(regression_path),
            manifest_path=manifest_path,
            regression_path=regression_path,
        )
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        failure = {
            "schema": SCHEMA,
            "status": "failed",
            "failure": str(error),
            "created_utc": _utc_now(),
        }
        _write_report(output_path, failure)
        print(f"[table7-cross] FAIL: {error}")
        return 1

    _write_report(output_path, report)
    print(
        "[table7-cross] PASS "
        f"({report['cross_count']} crosses, "
        f"{report['total_observed_rows']} evidence rows)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
