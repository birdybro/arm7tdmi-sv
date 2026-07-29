#!/usr/bin/env python3
"""Run and record the VAL-005 constrained-random external-event campaign."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import time
from collections.abc import Sequence
from typing import Any


SCHEMA = "arm7tdmis-random-events-v1"
REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_REPORT = REPO_ROOT / "reports/generated/random-events-report.json"
DEFAULT_LOG_DIRECTORY = REPO_ROOT / "reports/generated/random_events"
MINIMUM_RELEASE_SEEDS = 32
MINIMUM_DECISIONS_PER_SEED = 256

CLASS_BINS = (
    "undef",
    "dp",
    "msr",
    "mrs",
    "mul",
    "mull",
    "branch",
    "bx",
    "ldr_str",
    "ldrh_strh",
    "ldm_stm",
    "swp",
    "swi",
    "cdp",
    "mcr_mrc",
    "ldc_stc",
)
EVENT_BINS = (
    "abort_opcode_read",
    "abort_data_read",
    "abort_data_write",
    "irq",
    "fiq",
    "reset",
    "dbgrq",
    "cp_ready",
    "cp_busy",
    "cp_absent",
)
REQUIRED_CLASS_MASK = (1 << len(CLASS_BINS)) - 1
REQUIRED_EVENT_MASK = (1 << len(EVENT_BINS)) - 1

PASS_MARKER = re.compile(
    r"^\[random_events\] PASS "
    r"seed=(?P<seed>[0-9]+) "
    r"classes=(?P<classes>[0-9a-f]{4}) "
    r"stalls=(?P<stalls>[0-9a-f]{4}) "
    r"events=(?P<events>[0-9a-f]{4}) "
    r"decisions=(?P<decisions>[0-9]+)$",
    re.MULTILINE,
)


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


def _path_text(path: pathlib.Path) -> str:
    resolved = path.resolve()
    try:
        return resolved.relative_to(REPO_ROOT).as_posix()
    except ValueError:
        return str(resolved)


def _file_entry(path: pathlib.Path) -> dict[str, Any]:
    return {
        "path": _path_text(path),
        "bytes": path.stat().st_size,
        "sha256": _sha256(path),
    }


def _atomic_json(path: pathlib.Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, path)


def _seed_sequence(base_seed: int, count: int) -> list[int]:
    """Return a stable nonzero LCG prefix accepted by Verilator's seed API."""
    state = base_seed & 0x7FFF_FFFF
    if state == 0:
        state = 1
    seeds: list[int] = []
    while len(seeds) < count:
        if state != 0 and state not in seeds:
            seeds.append(state)
        state = (state * 1_664_525 + 1_013_904_223) & 0x7FFF_FFFF
    return seeds


def _bins_from_mask(mask: int, names: Sequence[str]) -> list[str]:
    return [name for index, name in enumerate(names) if mask & (1 << index)]


def parse_pass_marker(
    output: str,
    *,
    expected_seed: int,
) -> dict[str, int]:
    """Parse the one exact PASS marker and reject any incomplete bin mask."""
    matches = list(PASS_MARKER.finditer(output))
    if len(matches) != 1:
        raise ValueError("random-event output lacks one exact PASS marker")
    match = matches[0]
    parsed = {
        "seed": int(match.group("seed")),
        "class_mask": int(match.group("classes"), 16),
        "class_stall_mask": int(match.group("stalls"), 16),
        "event_mask": int(match.group("events"), 16),
        "decision_count": int(match.group("decisions")),
    }
    if parsed["seed"] != expected_seed:
        raise ValueError("random-event PASS marker has the wrong seed")
    if parsed["class_mask"] != REQUIRED_CLASS_MASK:
        raise ValueError("random-event PASS marker lacks an instruction class")
    if parsed["class_stall_mask"] != REQUIRED_CLASS_MASK:
        raise ValueError("random-event PASS marker lacks a class stall")
    if parsed["event_mask"] != REQUIRED_EVENT_MASK:
        raise ValueError("random-event PASS marker lacks an external event")
    if parsed["decision_count"] < MINIMUM_DECISIONS_PER_SEED:
        raise ValueError("random-event PASS marker is below the decision floor")
    return parsed


def _execute(
    binary: pathlib.Path,
    seed: int,
    timeout_seconds: float,
) -> tuple[dict[str, Any], str]:
    command = [
        str(binary),
        f"+SEED={seed}",
        f"+verilator+seed+{seed}",
    ]
    started = time.monotonic()
    timed_out = False
    try:
        completed = subprocess.run(
            command,
            cwd=REPO_ROOT,
            check=False,
            timeout=timeout_seconds,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            errors="replace",
        )
        exit_code: int | None = completed.returncode
        output = completed.stdout
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
            f"\n[random_events] TIMEOUT after {timeout_seconds:.3f} seconds"
        )

    parsed: dict[str, int] | None = None
    marker_error: str | None = None
    if not timed_out and exit_code == 0:
        try:
            parsed = parse_pass_marker(output, expected_seed=seed)
        except ValueError as error:
            marker_error = str(error)
    passed = not timed_out and exit_code == 0 and parsed is not None
    result: dict[str, Any] = {
        "seed": seed,
        "status": "passed" if passed else "failed",
        "command": command,
        "reproducer": command,
        "duration_seconds": round(time.monotonic() - started, 6),
        "exit_code": exit_code,
        "timed_out": timed_out,
        "pass_marker_found": parsed is not None,
        "marker_error": marker_error,
        "output_sha256": hashlib.sha256(output.encode()).hexdigest(),
    }
    if parsed is not None:
        result.update(
            {
                "decision_count": parsed["decision_count"],
                "class_bins": _bins_from_mask(
                    parsed["class_mask"], CLASS_BINS
                ),
                "class_stall_bins": _bins_from_mask(
                    parsed["class_stall_mask"], CLASS_BINS
                ),
                "event_bins": _bins_from_mask(
                    parsed["event_mask"], EVENT_BINS
                ),
            }
        )
    return result, output


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=pathlib.Path, required=True)
    parser.add_argument("--seeds", type=int, default=MINIMUM_RELEASE_SEEDS)
    parser.add_argument("--base-seed", type=int, default=1)
    parser.add_argument("--timeout", type=float, default=15.0)
    parser.add_argument("--output", type=pathlib.Path, default=DEFAULT_REPORT)
    parser.add_argument(
        "--log-directory",
        type=pathlib.Path,
        default=DEFAULT_LOG_DIRECTORY,
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
    output_path = args.output.resolve()
    log_directory = args.log_directory.resolve()
    log_directory.mkdir(parents=True, exist_ok=True)

    testbench = (
        REPO_ROOT
        / "tb/integration/arm7tdmis_random_event_matrix_tb.sv"
    )
    runner = pathlib.Path(__file__).resolve()
    commit = _run_text(("git", "rev-parse", "HEAD"))
    dirty = bool(_run_text(("git", "status", "--porcelain")))
    seeds = _seed_sequence(args.base_seed, args.seeds)
    results: list[dict[str, Any]] = []
    failures: list[int] = []

    for index, seed in enumerate(seeds, start=1):
        print(f"[random-events] seed {index}/{len(seeds)}: {seed}")
        result, output = _execute(binary, seed, args.timeout)
        log_path = log_directory / f"seed-{seed}.log"
        log_path.write_text(output, encoding="utf-8")
        result["log"] = _file_entry(log_path)
        results.append(result)
        if result["status"] != "passed":
            failures.append(seed)
            print(output, file=sys.stderr)
            break

    passed_results = [
        result for result in results if result["status"] == "passed"
    ]
    class_bins = sorted(
        {
            value
            for result in passed_results
            for value in result.get("class_bins", [])
        }
    )
    class_stall_bins = sorted(
        {
            value
            for result in passed_results
            for value in result.get("class_stall_bins", [])
        }
    )
    event_bins = sorted(
        {
            value
            for result in passed_results
            for value in result.get("event_bins", [])
        }
    )
    total_decisions = sum(
        int(result.get("decision_count", 0)) for result in passed_results
    )
    status = (
        "passed"
        if not failures
        and len(results) == len(seeds)
        and set(class_bins) == set(CLASS_BINS)
        and set(class_stall_bins) == set(CLASS_BINS)
        and set(event_bins) == set(EVENT_BINS)
        else "failed"
    )
    report = {
        "schema": SCHEMA,
        "created_utc": _utc_now(),
        "status": status,
        "git": {"commit": commit, "dirty": dirty},
        "configuration": {
            "seed_count": args.seeds,
            "base_seed": args.base_seed,
            "timeout_seconds": args.timeout,
            "minimum_decisions_per_seed": MINIMUM_DECISIONS_PER_SEED,
            "event_constraint": (
                "ABORT only on active responses; CPA/CPB only 00, 01, or 11"
            ),
        },
        "required_class_bins": list(CLASS_BINS),
        "required_event_bins": list(EVENT_BINS),
        "covered_class_bins": class_bins,
        "covered_class_stall_bins": class_stall_bins,
        "covered_event_bins": event_bins,
        "completed_seed_count": len(passed_results),
        "total_decision_count": total_decisions,
        "inputs": {
            "runner": _file_entry(runner),
            "testbench": _file_entry(testbench),
            "binary": _file_entry(binary),
        },
        "seeds": results,
        "failures": failures,
    }
    _atomic_json(output_path, report)
    if status != "passed":
        print(
            f"[random-events] FAIL ({len(passed_results)}/{len(seeds)} seeds)",
            file=sys.stderr,
        )
        return 1
    print(
        "[random-events] PASS "
        f"({len(results)} seeds, {total_decisions} random decisions)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
