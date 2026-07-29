#!/usr/bin/env python3
"""Reproducible, fail-hard ARM7TDMI-S regression runner.

The runner deliberately invokes each Make target separately so the JSON report
contains a durable result and log digest for every lint/test phase. A clean
build is always the first phase; no cached binary can be reported as a fresh
release regression.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import pathlib
import platform
import shlex
import subprocess
import sys
import time
from collections.abc import Iterable, Sequence
from typing import Any


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
REPORT_SCHEMA = "arm7tdmis-regression-v1"


def _run_text(command: Sequence[str]) -> str:
    result = subprocess.run(
        command,
        cwd=REPO_ROOT,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    return result.stdout.strip()


def _utc_now() -> str:
    return dt.datetime.now(dt.UTC).isoformat(timespec="seconds")


def _source_digest() -> str:
    """Hash every local source/build input, including untracked test files."""
    candidates: list[pathlib.Path] = []
    for directory in ("rtl", "tb", "scripts", "fpga"):
        root = REPO_ROOT / directory
        for path in root.rglob("*"):
            if not path.is_file():
                continue
            relative = path.relative_to(REPO_ROOT)
            if "obj_dir" in relative.parts or "__pycache__" in relative.parts:
                continue
            if path.suffix in {
                ".sv",
                ".svh",
                ".f",
                ".py",
                ".sdc",
                ".qsf",
                ".qip",
                ".tcl",
                ".json",
            } or path.name == "Makefile":
                candidates.append(path)

    digest = hashlib.sha256()
    for path in sorted(candidates):
        relative = path.relative_to(REPO_ROOT).as_posix().encode()
        digest.update(len(relative).to_bytes(4, "big"))
        digest.update(relative)
        contents = path.read_bytes()
        digest.update(len(contents).to_bytes(8, "big"))
        digest.update(contents)
    return digest.hexdigest()


def collect_metadata(
    *,
    unit_tests: Sequence[str],
    integration_tests: Sequence[str],
    variant: str,
    seed: int,
) -> dict[str, Any]:
    status = _run_text(("git", "status", "--porcelain=v1", "--untracked-files=all"))
    return {
        "schema": REPORT_SCHEMA,
        "started_utc": _utc_now(),
        "git": {
            "commit": _run_text(("git", "rev-parse", "HEAD")),
            "describe": _run_text(
                ("git", "describe", "--always", "--dirty", "--broken")
            ),
            "dirty": bool(status),
            "status": status.splitlines(),
            "source_sha256": _source_digest(),
        },
        "tools": {
            "verilator": _run_text(("verilator", "--version")),
            "quartus": _run_text(("quartus_map", "--version")),
            "python": f"Python {sys.version.replace('\n', ' ')}",
            "make": _run_text(("make", "--version")).splitlines()[0],
            "git": _run_text(("git", "--version")),
            "platform": platform.platform(),
        },
        "variant": variant,
        "seed": seed,
        "manifest": {
            "lint": [
                "raw-core",
                "mister-wrapper",
                "fpga-package-example",
                "testbench",
            ],
            "harness": ["unit", "expected-failure"],
            "fpga": ["quartus-analysis"],
            "unit": list(unit_tests),
            "integration": list(integration_tests),
            "smoke": ["arm7tdmis_tb_top"],
        },
    }


def write_report(path: pathlib.Path, report: dict[str, Any]) -> None:
    """Atomically replace a JSON report so interruption cannot leave torn JSON."""
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, path)


def expected_failure(command: Sequence[str]) -> bool:
    """Return true only when *command* exits nonzero."""
    result = subprocess.run(
        command,
        cwd=REPO_ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    return result.returncode != 0


def _safe_name(name: str) -> str:
    return "".join(character if character.isalnum() else "_" for character in name)


def _run_phase(
    *,
    name: str,
    command: Sequence[str],
    log_directory: pathlib.Path,
) -> dict[str, Any]:
    started_utc = _utc_now()
    started_monotonic = time.monotonic()
    log_directory.mkdir(parents=True, exist_ok=True)
    log_path = log_directory / f"{_safe_name(name)}.log"

    print(f"\n[regression] START {name}: {shlex.join(command)}", flush=True)
    with log_path.open("w", encoding="utf-8") as log:
        process = subprocess.Popen(
            command,
            cwd=REPO_ROOT,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        assert process.stdout is not None
        for line in process.stdout:
            sys.stdout.write(line)
            log.write(line)
        returncode = process.wait()

    duration = time.monotonic() - started_monotonic
    log_digest = hashlib.sha256(log_path.read_bytes()).hexdigest()
    status = "passed" if returncode == 0 else "failed"
    print(
        f"[regression] {status.upper()} {name} "
        f"({duration:.3f}s, exit={returncode})",
        flush=True,
    )
    return {
        "name": name,
        "command": list(command),
        "started_utc": started_utc,
        "finished_utc": _utc_now(),
        "duration_seconds": round(duration, 6),
        "exit_code": returncode,
        "status": status,
        "log": str(log_path.relative_to(REPO_ROOT)),
        "log_sha256": log_digest,
    }


def _make_phase(name: str, target: str) -> tuple[str, tuple[str, ...]]:
    return name, ("make", "-C", str(SCRIPT_DIR), target)


def _phases(
    unit_tests: Sequence[str],
    integration_tests: Sequence[str],
    *,
    quick: bool,
) -> Iterable[tuple[str, tuple[str, ...]]]:
    yield _make_phase("clean", "clean")
    yield _make_phase("lint-rtl", "lint")
    yield _make_phase("lint-mister-wrapper", "lint-mister")
    yield _make_phase("lint-fpga-package-example", "lint-example")
    yield _make_phase("quartus-analysis", "quartus-analysis")
    yield _make_phase("lint-testbench", "lint-tb")
    yield _make_phase("harness-unit", "harness-unit")
    yield _make_phase("harness-expected-failure", "harness-self-test")

    selected_units = unit_tests[:1] if quick else unit_tests
    selected_integration = integration_tests[:1] if quick else integration_tests
    for test in selected_units:
        yield _make_phase(f"unit-{test}", f"unit-{test}")
    for test in selected_integration:
        yield _make_phase(f"integration-{test}", f"integ-{test}")
    yield _make_phase("smoke", "run")


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--unit-tests", required=True)
    parser.add_argument("--integration-tests", required=True)
    parser.add_argument(
        "--variant",
        default=os.environ.get("REGRESSION_VARIANT", "default"),
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=int(os.environ.get("REGRESSION_SEED", "1")),
    )
    parser.add_argument(
        "--report",
        type=pathlib.Path,
        default=REPO_ROOT / "reports/generated/regression.json",
    )
    parser.add_argument(
        "--quick",
        action="store_true",
        help="run one unit and one integration test plus lint/harness/smoke",
    )
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    unit_tests = tuple(args.unit_tests.split())
    integration_tests = tuple(args.integration_tests.split())
    report_path = args.report
    if not report_path.is_absolute():
        report_path = REPO_ROOT / report_path
    log_directory = report_path.parent / "logs"

    report = collect_metadata(
        unit_tests=unit_tests,
        integration_tests=integration_tests,
        variant=args.variant,
        seed=args.seed,
    )
    report["mode"] = "quick" if args.quick else "full"
    report["status"] = "running"
    report["results"] = []
    write_report(report_path, report)

    print(
        "[regression] "
        f"commit={report['git']['commit']} "
        f"source_sha256={report['git']['source_sha256']} "
        f"dirty={report['git']['dirty']} "
        f"variant={args.variant} seed={args.seed}",
        flush=True,
    )
    print(f"[regression] report={report_path}", flush=True)

    try:
        for name, command in _phases(
            unit_tests, integration_tests, quick=args.quick
        ):
            result = _run_phase(
                name=name,
                command=command,
                log_directory=log_directory,
            )
            report["results"].append(result)
            if result["status"] == "failed":
                report["status"] = "failed"
                report["finished_utc"] = _utc_now()
                write_report(report_path, report)
                return 1
            write_report(report_path, report)
    except KeyboardInterrupt:
        report["status"] = "interrupted"
        report["finished_utc"] = _utc_now()
        write_report(report_path, report)
        return 130

    report["status"] = "passed"
    report["finished_utc"] = _utc_now()
    report["result_count"] = len(report["results"])
    write_report(report_path, report)
    print(f"[regression] PASS ({len(report['results'])} phases)", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
