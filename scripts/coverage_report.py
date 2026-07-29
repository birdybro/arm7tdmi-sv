#!/usr/bin/env python3
"""Convert Verilator raw/LCOV coverage into an auditable JSON summary."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import pathlib
import re
import subprocess
from collections import defaultdict
from typing import Any


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
REPORT_SCHEMA = "arm7tdmis-coverage-v1"
RAW_POINT_RE = re.compile(r"^C '(.*)' ([0-9]+)$")


def _field(body: str, name: str) -> str:
    match = re.search(rf"\x01{re.escape(name)}\x02([^\x01]*)", body)
    return match.group(1) if match else ""


def _is_rtl_source(source: str) -> bool:
    parts = pathlib.PurePosixPath(source.replace("\\", "/")).parts
    return "rtl" in parts


def _point_totals(raw_text: str) -> dict[str, dict[str, dict[str, int]]]:
    counters: dict[str, dict[str, list[int]]] = {
        "all": defaultdict(lambda: [0, 0]),
        "rtl": defaultdict(lambda: [0, 0]),
    }
    parsed = 0
    for line in raw_text.splitlines():
        match = RAW_POINT_RE.match(line)
        if not match:
            continue
        body, count_text = match.groups()
        point_type = _field(body, "t") or "unknown"
        source = _field(body, "f")
        count = int(count_text)
        parsed += 1
        scopes = ("all", "rtl") if _is_rtl_source(source) else ("all",)
        for scope in scopes:
            counters[scope][point_type][1] += 1
            if count > 0:
                counters[scope][point_type][0] += 1
    if parsed == 0:
        raise ValueError("raw coverage contains no Verilator points")
    return {
        scope: {
            point_type: {"covered": values[0], "total": values[1]}
            for point_type, values in sorted(types.items())
        }
        for scope, types in counters.items()
    }


def _lcov_totals(lcov_text: str) -> dict[str, dict[str, dict[str, int]]]:
    records: dict[str, dict[str, dict[str, int]]] = {}
    current_source = ""
    line_total = line_hit = branch_total = branch_hit = 0

    def finish_record() -> None:
        nonlocal current_source, line_total, line_hit, branch_total, branch_hit
        if current_source:
            records[current_source] = {
                "lines": {"covered": line_hit, "total": line_total},
                "branches": {
                    "covered": branch_hit,
                    "total": branch_total,
                },
            }
        current_source = ""
        line_total = line_hit = branch_total = branch_hit = 0

    for line in lcov_text.splitlines():
        if line.startswith("SF:"):
            finish_record()
            current_source = line[3:]
        elif line.startswith("LF:"):
            line_total = int(line[3:])
        elif line.startswith("LH:"):
            line_hit = int(line[3:])
        elif line.startswith("BRF:"):
            branch_total = int(line[4:])
        elif line.startswith("BRH:"):
            branch_hit = int(line[4:])
        elif line == "end_of_record":
            finish_record()
    finish_record()
    if not records:
        raise ValueError("LCOV input contains no source records")
    return dict(sorted(records.items()))


def _sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _report_path(path: pathlib.Path) -> str:
    resolved = path.resolve()
    try:
        return str(resolved.relative_to(REPO_ROOT))
    except ValueError:
        return str(resolved)


def build_report(
    *,
    raw_path: pathlib.Path,
    lcov_path: pathlib.Path,
    tests: tuple[str, ...],
    git_commit: str,
    source_sha256: str,
    tool_version: str,
    git_dirty: bool = False,
) -> dict[str, Any]:
    raw_text = raw_path.read_text(encoding="utf-8")
    lcov_text = lcov_path.read_text(encoding="utf-8")
    points = _point_totals(raw_text)
    return {
        "schema": REPORT_SCHEMA,
        "generated_utc": dt.datetime.now(dt.UTC).isoformat(timespec="seconds"),
        "git": {
            "commit": git_commit,
            "dirty": git_dirty,
            "source_sha256": source_sha256,
        },
        "tool": tool_version,
        "instrumentation": ["--coverage"],
        "point_types": sorted(points["all"]),
        "tests": list(tests),
        "points": points,
        "lcov": _lcov_totals(lcov_text),
        "artifacts": {
            "raw": {
                "path": _report_path(raw_path),
                "bytes": raw_path.stat().st_size,
                "sha256": _sha256(raw_path),
            },
            "lcov": {
                "path": _report_path(lcov_path),
                "bytes": lcov_path.stat().st_size,
                "sha256": _sha256(lcov_path),
            },
        },
        "claim": (
            "Measured coverage for the listed tests only; this is not "
            "architectural or functional coverage closure."
        ),
    }


def _git_text(*arguments: str) -> str:
    return subprocess.run(
        ("git", *arguments),
        cwd=REPO_ROOT,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    ).stdout.strip()


def _source_digest() -> str:
    # Keep identical source selection and framing to regression_harness.py.
    import regression_harness

    return regression_harness._source_digest()


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--raw", type=pathlib.Path, required=True)
    parser.add_argument("--lcov", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--tests", required=True)
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    status = _git_text("status", "--porcelain=v1", "--untracked-files=all")
    report = build_report(
        raw_path=args.raw,
        lcov_path=args.lcov,
        tests=tuple(args.tests.split()),
        git_commit=_git_text("rev-parse", "HEAD"),
        git_dirty=bool(status),
        source_sha256=_source_digest(),
        tool_version=subprocess.run(
            ("verilator_coverage", "--version"),
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        ).stdout.strip(),
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_suffix(args.output.suffix + ".tmp")
    temporary.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, args.output)
    print(
        f"[coverage] wrote {args.output} "
        f"({report['points']['rtl'].get('line', {}).get('covered', 0)}/"
        f"{report['points']['rtl'].get('line', {}).get('total', 0)} "
        "RTL line points for listed tests)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
