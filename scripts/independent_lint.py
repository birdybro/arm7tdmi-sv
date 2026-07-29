#!/usr/bin/env python3
"""Elaborate every public synthesis top with pinned independent Slang."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
from collections.abc import Sequence
from typing import Any


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
DEFAULT_OUTPUT = REPO_ROOT / "reports/generated/independent-lint.json"
REPORT_SCHEMA = "arm7tdmis-independent-lint-v1"
EXPECTED_SLANG_VERSION = "slang version 11.0.0+7ddf4059f"
PUBLIC_TOPS: tuple[tuple[str, tuple[str, ...]], ...] = (
    ("arm7tdmis_top", ()),
    ("arm7tdmi_mister", ()),
    ("arm7tdmis_no_dft", ()),
    (
        "arm7tdmi_mister_example_top",
        ("../fpga/example/arm7tdmi_mister_example_top.sv",),
    ),
    (
        "arm7tdmi_generic_soc",
        ("../examples/generic_soc/arm7tdmi_generic_soc.sv",),
    ),
)


def _utc_now() -> str:
    return dt.datetime.now(dt.UTC).isoformat(timespec="seconds")


def _sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _run_text(command: Sequence[str]) -> str:
    return subprocess.run(
        command,
        cwd=SCRIPT_DIR,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    ).stdout.strip()


def build_commands(
    *,
    slang: pathlib.Path,
    output: pathlib.Path,
) -> list[list[str]]:
    commands: list[list[str]] = []
    for top, extra_sources in PUBLIC_TOPS:
        diagnostic_path = output.parent / f"slang-{top}-diagnostics.json"
        commands.append(
            [
                str(slang),
                "--allow-use-before-declare",
                "--diag-option",
                "--diag-json",
                str(diagnostic_path),
                "--top",
                top,
                "-f",
                "sim.f",
                *extra_sources,
            ]
        )
    return commands


def _source_inputs() -> list[pathlib.Path]:
    paths = sorted((REPO_ROOT / "rtl").rglob("*.sv"))
    paths.extend(
        (
            SCRIPT_DIR / "sim.f",
            SCRIPT_DIR / "independent_lint.py",
            REPO_ROOT / "fpga/example/arm7tdmi_mister_example_top.sv",
            REPO_ROOT / "examples/generic_soc/arm7tdmi_generic_soc.sv",
        )
    )
    return sorted(set(path.resolve() for path in paths))


def _git(command: tuple[str, ...]) -> str:
    return subprocess.run(
        ("git", *command),
        cwd=REPO_ROOT,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    ).stdout.strip()


def _atomic_write(path: pathlib.Path, report: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, path)


def run(*, slang: pathlib.Path, output: pathlib.Path) -> dict[str, Any]:
    version = _run_text((str(slang), "--version"))
    if version != EXPECTED_SLANG_VERSION:
        raise ValueError(
            f"expected {EXPECTED_SLANG_VERSION}, found {version}"
        )
    status_text = _git(("status", "--porcelain=v1", "--untracked-files=all"))
    results: list[dict[str, Any]] = []
    report: dict[str, Any] = {
        "schema": REPORT_SCHEMA,
        "created_utc": _utc_now(),
        "status": "running",
        "git": {
            "commit": _git(("rev-parse", "HEAD")),
            "dirty": bool(status_text),
            "status": status_text.splitlines(),
        },
        "tool": {
            "path": str(slang.resolve()),
            "version": version,
            "bytes": slang.stat().st_size,
            "sha256": _sha256(slang),
        },
        "inputs": {
            path.relative_to(REPO_ROOT).as_posix(): {
                "bytes": path.stat().st_size,
                "sha256": _sha256(path),
            }
            for path in _source_inputs()
        },
        "results": results,
    }
    _atomic_write(output, report)

    for command in build_commands(slang=slang, output=output):
        top = command[command.index("--top") + 1]
        print(f"[independent-lint] START {top}", flush=True)
        completed = subprocess.run(
            command,
            cwd=SCRIPT_DIR,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        summary = re.search(
            r"Build (?:succeeded|failed):\s*(\d+) errors?,\s*(\d+) warnings?",
            completed.stdout,
        )
        error_count = int(summary.group(1)) if summary else -1
        warning_count = int(summary.group(2)) if summary else -1
        diagnostic_path = pathlib.Path(
            command[command.index("--diag-json") + 1]
        )
        result = {
            "top": top,
            "command": command,
            "exit_code": completed.returncode,
            "error_count": error_count,
            "warning_count": warning_count,
            "output_sha256": hashlib.sha256(
                completed.stdout.encode()
            ).hexdigest(),
            "diagnostics": {
                "path": diagnostic_path.relative_to(REPO_ROOT).as_posix(),
                "bytes": (
                    diagnostic_path.stat().st_size
                    if diagnostic_path.is_file()
                    else 0
                ),
                "sha256": (
                    _sha256(diagnostic_path)
                    if diagnostic_path.is_file()
                    else None
                ),
            },
            "status": (
                "passed"
                if completed.returncode == 0
                and error_count == 0
                and warning_count == 0
                else "failed"
            ),
        }
        results.append(result)
        print(
            f"[independent-lint] {result['status'].upper()} {top} "
            f"(errors={error_count}, warnings={warning_count})",
            flush=True,
        )
        if result["status"] == "failed":
            print(completed.stdout, end="")
            report["status"] = "failed"
            _atomic_write(output, report)
            return report
        _atomic_write(output, report)

    report["status"] = "passed"
    report["finished_utc"] = _utc_now()
    report["result_count"] = len(results)
    _atomic_write(output, report)
    return report


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--slang", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, default=DEFAULT_OUTPUT)
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    slang = args.slang
    if not slang.is_file():
        located = shutil.which(str(slang))
        if located is None:
            raise ValueError(f"Slang executable is missing: {slang}")
        slang = pathlib.Path(located)
    report = run(slang=slang.resolve(), output=args.output.resolve())
    if report["status"] != "passed":
        return 1
    print(
        f"[independent-lint] PASS ({report['result_count']} public tops)",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
