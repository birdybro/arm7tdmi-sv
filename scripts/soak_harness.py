#!/usr/bin/env python3
"""Run a deterministic multi-seed Verilator soak and preserve reproducers."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import pathlib
import platform
import re
import shlex
import subprocess
import sys
import time
from collections.abc import Sequence
from typing import Any


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
REPORT_SCHEMA = "arm7tdmis-soak-v1"
DEFAULT_REPORT = REPO_ROOT / "reports/generated/soak-report.json"
DEFAULT_FAILURE_DIRECTORY = REPO_ROOT / "reports/generated/soak-failures"
ASAN_OPTIONS = "detect_leaks=1:halt_on_error=1:strict_string_checks=1"
UBSAN_OPTIONS = "halt_on_error=1:print_stacktrace=1"


def _utc_now() -> str:
    return dt.datetime.now(dt.UTC).isoformat(timespec="seconds")


def _sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _run_text(command: Sequence[str]) -> str:
    return subprocess.run(
        command,
        cwd=REPO_ROOT,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    ).stdout.strip()


def _atomic_json(path: pathlib.Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, path)


def _seeds(base_seed: int, count: int) -> list[int]:
    """Return a stable, nonzero, nonrepeating prefix of a 16-bit LCG."""
    state = base_seed & 0xFFFF
    if state == 0:
        state = 1
    seeds: list[int] = []
    while len(seeds) < count:
        if state != 0:
            seeds.append(state)
        state = (state * 25173 + 13849) & 0xFFFF
    return seeds


def _environment() -> dict[str, str]:
    environment = os.environ.copy()
    environment["ASAN_OPTIONS"] = ASAN_OPTIONS
    environment["UBSAN_OPTIONS"] = UBSAN_OPTIONS
    return environment


def _command(binary: pathlib.Path, seed: int) -> list[str]:
    return [
        str(binary),
        f"+SEED={seed}",
        f"+verilator+seed+{seed}",
    ]


def _path_text(path: pathlib.Path) -> str:
    resolved = path.resolve()
    try:
        return resolved.relative_to(REPO_ROOT).as_posix()
    except ValueError:
        return str(resolved)


def _failure_signature(
    *,
    timed_out: bool,
    exit_code: int | None,
    output: str,
) -> str:
    """Classify a failure so minimization cannot substitute another defect."""
    if timed_out:
        return "timeout"
    address = re.search(r"ERROR: AddressSanitizer: ([^\s]+)", output)
    if address:
        return f"sanitizer:address:{address.group(1)}"
    undefined = next(
        (
            line.strip()
            for line in output.splitlines()
            if "runtime error:" in line
        ),
        None,
    )
    if undefined:
        normalized = re.sub(r"0x[0-9a-fA-F]+|\b\d+\b", "#", undefined)
        return f"sanitizer:undefined:{normalized}"
    diagnostic = next(
        (
            line.split("[mister_wrapper] FAIL:", 1)[1].strip()
            for line in output.splitlines()
            if "[mister_wrapper] FAIL:" in line
        ),
        None,
    )
    if diagnostic:
        normalized = re.sub(r"0x[0-9a-fA-F]+|\b\d+\b", "#", diagnostic)
        return f"testbench:{normalized}"
    if exit_code is not None and exit_code < 0:
        return f"signal:{-exit_code}"
    return f"exit-code:{exit_code}"


def _execute(
    binary: pathlib.Path,
    seed: int,
    timeout_seconds: float,
) -> tuple[bool, dict[str, Any], str]:
    command = _command(binary, seed)
    started = time.monotonic()
    timed_out = False
    try:
        result = subprocess.run(
            command,
            cwd=REPO_ROOT,
            env=_environment(),
            timeout=timeout_seconds,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            errors="replace",
        )
        exit_code: int | None = result.returncode
        output = result.stdout
    except subprocess.TimeoutExpired as error:
        timed_out = True
        exit_code = None
        stdout = error.stdout or ""
        output = (
            stdout.decode(errors="replace")
            if isinstance(stdout, bytes)
            else stdout
        )
        output += (
            f"\n[soak] TIMEOUT after {timeout_seconds:.3f} seconds"
        )

    duration = time.monotonic() - started
    marker = f"[mister_wrapper] PASS seed={seed}"
    passed = not timed_out and exit_code == 0 and marker in output
    signature = (
        None
        if passed
        else _failure_signature(
            timed_out=timed_out,
            exit_code=exit_code,
            output=output,
        )
    )
    result_record = {
        "seed": seed,
        "command": command,
        "duration_seconds": round(duration, 6),
        "exit_code": exit_code,
        "timed_out": timed_out,
        "pass_marker_found": marker in output,
        "output_sha256": hashlib.sha256(output.encode()).hexdigest(),
        "failure_signature": signature,
        "status": "passed" if passed else "failed",
    }
    return passed, result_record, output


def _still_fails(
    binary: pathlib.Path,
    seed: int,
    timeout_seconds: float,
    failure_signature: str | None = None,
) -> bool:
    passed, result, _ = _execute(binary, seed, timeout_seconds)
    return not passed and (
        failure_signature is None
        or result.get("failure_signature") == failure_signature
    )


def minimize(
    binary: pathlib.Path,
    failing_seed: int,
    timeout_seconds: float,
    failure_signature: str | None = None,
) -> int:
    """Greedily clear seed bits while preserving the observed failure."""
    minimized = failing_seed
    for bit in reversed(range(16)):
        candidate = minimized & ~(1 << bit)
        if candidate != 0 and _still_fails(
            binary,
            candidate,
            timeout_seconds,
            failure_signature,
        ):
            minimized = candidate
    return minimized


def _failure_artifacts(
    *,
    binary: pathlib.Path,
    failing_seed: int,
    minimized_seed: int,
    timeout_seconds: float,
    output: str,
    directory: pathlib.Path,
    failure_signature: str | None = None,
) -> dict[str, str]:
    directory.mkdir(parents=True, exist_ok=True)
    stem = f"seed-{failing_seed}"
    log_path = directory / f"{stem}.log"
    reproducer_path = directory / f"{stem}-reproducer.json"
    log_path.write_text(output, encoding="utf-8")
    reproducer = {
        "schema": "arm7tdmis-soak-reproducer-v1",
        "failing_seed": failing_seed,
        "minimized_seed": minimized_seed,
        "failure_signature": failure_signature,
        "binary": str(binary),
        "binary_sha256": _sha256(binary),
        "command": _command(binary, minimized_seed),
        "command_shell": shlex.join(_command(binary, minimized_seed)),
        "timeout_seconds": timeout_seconds,
        "environment": {
            "ASAN_OPTIONS": ASAN_OPTIONS,
            "UBSAN_OPTIONS": UBSAN_OPTIONS,
        },
        "failure_log": _path_text(log_path),
        "failure_log_sha256": _sha256(log_path),
    }
    _atomic_json(reproducer_path, reproducer)
    return {
        "log": _path_text(log_path),
        "reproducer": _path_text(reproducer_path),
    }


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=pathlib.Path, required=True)
    parser.add_argument("--seeds", type=int, default=256)
    parser.add_argument("--base-seed", type=int, default=1)
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--output", type=pathlib.Path, default=DEFAULT_REPORT)
    parser.add_argument(
        "--failure-directory",
        type=pathlib.Path,
        default=DEFAULT_FAILURE_DIRECTORY,
    )
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    if args.seeds < 1:
        raise ValueError("--seeds must be positive")
    if args.timeout <= 0:
        raise ValueError("--timeout must be positive")
    binary = args.binary.resolve()
    if not binary.is_file():
        raise ValueError(f"simulator binary is missing: {binary}")
    binary_dependencies = _run_text(("ldd", str(binary)))
    for sanitizer_library in ("libasan", "libubsan"):
        if sanitizer_library not in binary_dependencies:
            raise ValueError(
                f"simulator binary is not linked to {sanitizer_library}"
            )

    testbench = REPO_ROOT / "tb/integration/arm7tdmis_mister_wrapper_tb.sv"
    status = _run_text(
        ("git", "status", "--porcelain=v1", "--untracked-files=all")
    )
    seed_sequence = _seeds(args.base_seed, args.seeds)
    report: dict[str, Any] = {
        "schema": REPORT_SCHEMA,
        "started_utc": _utc_now(),
        "status": "running",
        "git": {
            "commit": _run_text(("git", "rev-parse", "HEAD")),
            "dirty": bool(status),
            "status": status.splitlines(),
        },
        "tools": {
            "verilator": _run_text(("verilator", "--version")),
            "python": f"Python {sys.version.replace(chr(10), ' ')}",
            "platform": platform.platform(),
            "binary_dependencies": binary_dependencies.splitlines(),
        },
        "configuration": {
            "base_seed": args.base_seed,
            "seed_count": args.seeds,
            "timeout_seconds": args.timeout,
            "x_assignment": "unique",
            "x_initialization": "unique",
            "sanitizers": ["address", "undefined"],
            "environment": {
                "ASAN_OPTIONS": ASAN_OPTIONS,
                "UBSAN_OPTIONS": UBSAN_OPTIONS,
            },
        },
        "inputs": {
            "binary": {
                "path": str(binary),
                "bytes": binary.stat().st_size,
                "sha256": _sha256(binary),
            },
            "testbench": {
                "path": testbench.relative_to(REPO_ROOT).as_posix(),
                "bytes": testbench.stat().st_size,
                "sha256": _sha256(testbench),
            },
        },
        "seeds": [],
        "failures": [],
    }
    _atomic_json(args.output, report)

    for index, seed in enumerate(seed_sequence, start=1):
        print(
            f"[soak] seed {index}/{len(seed_sequence)}: {seed}",
            flush=True,
        )
        passed, result, output = _execute(binary, seed, args.timeout)
        report["seeds"].append(result)
        if not passed:
            failing_seed = seed
            print(
                f"[soak] minimizing failing seed {failing_seed}",
                flush=True,
            )
            failure_signature = str(result["failure_signature"])
            minimized_seed = minimize(
                binary,
                failing_seed,
                args.timeout,
                failure_signature,
            )
            artifacts = _failure_artifacts(
                binary=binary,
                failing_seed=failing_seed,
                minimized_seed=minimized_seed,
                timeout_seconds=args.timeout,
                output=output,
                directory=args.failure_directory,
                failure_signature=failure_signature,
            )
            report["failures"].append(
                {
                    "failing_seed": failing_seed,
                    "minimized_seed": minimized_seed,
                    "failure_signature": failure_signature,
                    **artifacts,
                }
            )
            report["status"] = "failed"
            report["finished_utc"] = _utc_now()
            report["completed_seed_count"] = len(report["seeds"])
            _atomic_json(args.output, report)
            print(
                "[soak] FAIL "
                f"seed={failing_seed} minimized={minimized_seed} "
                f"reproducer={artifacts['reproducer']}",
                flush=True,
            )
            return 1
        _atomic_json(args.output, report)

    report["status"] = "passed"
    report["finished_utc"] = _utc_now()
    report["completed_seed_count"] = len(report["seeds"])
    _atomic_json(args.output, report)
    print(
        f"[soak] PASS ({len(report['seeds'])} deterministic seeds)",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
