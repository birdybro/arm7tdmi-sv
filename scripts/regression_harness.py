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
REQUIRED_QUICK_INTEGRATION = ("qemu_diff", "compiler")


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
    for directory in (
        "rtl",
        "tb",
        "verification",
        "scripts",
        "fpga",
        "examples",
    ):
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
                ".S",
                ".c",
                ".ld",
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
    include_fpga: bool = True,
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
            "clang": _run_text(("clang", "--version")).splitlines()[0],
            "qemu": _run_text(("qemu-system-arm", "--version")).splitlines()[0],
            "quartus": (
                _run_text(("quartus_map", "--version"))
                if include_fpga
                else "not requested (simulation-only profile)"
            ),
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
                "generic-soc-verilator",
                "generic-soc-slang",
                "all-public-tops-slang",
                "structural-cdc-rdc",
                "testbench",
            ],
            "harness": [
                "unit",
                "expected-failure",
                "raw-bus-checker",
                "traceability",
            ],
            "fpga": (
                [
                    "quartus-analysis",
                    "quartus-conformance-analysis",
                    "quartus-compile",
                    "quartus-conformance-compile",
                    "quartus-option-characterization",
                    "postfit-sim",
                ]
                if include_fpga
                else []
            ),
            "unit": list(unit_tests),
            "integration": list(integration_tests),
            "constrained_random": [],
            "soak": [],
            "examples": ["generic-soc"],
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
    include_fpga: bool = True,
) -> Iterable[tuple[str, tuple[str, ...]]]:
    yield _make_phase("clean", "clean")
    yield _make_phase("lint-rtl", "lint")
    yield _make_phase("lint-mister-wrapper", "lint-mister")
    yield _make_phase("lint-fpga-package-example", "lint-example")
    yield _make_phase("lint-generic-soc", "lint-generic-soc")
    yield _make_phase("lint-generic-soc-slang", "lint-generic-soc-slang")
    yield _make_phase("lint-independent", "lint-independent")
    yield _make_phase("cdc-rdc", "cdc-rdc")
    yield _make_phase("sim-generic-soc", "sim-generic-soc")
    if include_fpga:
        yield _make_phase("quartus-analysis", "quartus-analysis")
        yield _make_phase(
            "quartus-conformance-analysis", "quartus-conformance-analysis"
        )
        if not quick:
            yield _make_phase("quartus-compile", "quartus-compile")
            yield _make_phase(
                "quartus-conformance-compile", "quartus-conformance-compile"
            )
            yield _make_phase(
                "quartus-option-characterization",
                "quartus-option-characterization",
            )
            yield _make_phase("postfit-sim", "postfit-sim")
    yield _make_phase("lint-testbench", "lint-tb")
    yield _make_phase("harness-unit", "harness-unit")
    yield _make_phase("harness-expected-failure", "harness-self-test")
    yield _make_phase("raw-checker-expected-failure", "raw-checker-self-test")

    selected_units = unit_tests[:1] if quick else unit_tests
    if quick:
        selected_integration = tuple(
            test
            for test in integration_tests
            if test in REQUIRED_QUICK_INTEGRATION
        )
        if not selected_integration:
            selected_integration = integration_tests[:1]
    else:
        selected_integration = integration_tests
    for test in selected_units:
        yield _make_phase(f"unit-{test}", f"unit-{test}")
    for test in selected_integration:
        yield _make_phase(f"integration-{test}", f"integ-{test}")
    if quick:
        yield _make_phase(
            "random-validation-quick", "random-validation-quick"
        )
    else:
        yield _make_phase("random-validation", "random-validation")
    if not quick:
        yield _make_phase("soak", "soak")
    yield _make_phase("smoke", "run")
    yield _make_phase("traceability", "traceability")


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
        help=(
            "run one unit and the mandatory independent/compiler "
            "integrations plus lint/harness/smoke"
        ),
    )
    parser.add_argument(
        "--simulation-only",
        action="store_true",
        help="omit all Quartus phases and report an empty FPGA manifest",
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
        include_fpga=not args.simulation_only,
    )
    report["mode"] = "quick" if args.quick else "full"
    report["scope"] = "simulation-only" if args.simulation_only else "release"
    report["manifest"]["soak"] = (
        [] if args.quick else ["mister-wrapper-256-seed-sanitized"]
    )
    report["manifest"]["constrained_random"] = [
        "2-seed-quick" if args.quick else "32-seed-release"
    ]
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
            unit_tests,
            integration_tests,
            quick=args.quick,
            include_fpga=not args.simulation_only,
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
