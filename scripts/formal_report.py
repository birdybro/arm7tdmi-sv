#!/usr/bin/env python3
"""Run the pinned formal matrix and emit immutable VAL-007/VAL-008 evidence."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import pathlib
import subprocess
from typing import Any


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
DEFAULT_MANIFEST = REPO_ROOT / "verification/formal_requirements.json"
DEFAULT_SBY = REPO_ROOT / "tb/formal/formal.sby"
DEFAULT_OUTPUT = REPO_ROOT / "reports/generated/formal-report.json"
DEFAULT_WORK = REPO_ROOT / "reports/generated/formal/work"
TOOL_RELEASE = "20260729"
REPORT_SCHEMA = "arm7tdmis-formal-v1"


def _sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _file_entry(path: pathlib.Path) -> dict[str, object]:
    return {
        "path": path.relative_to(REPO_ROOT).as_posix(),
        "bytes": path.stat().st_size,
        "sha256": _sha256(path),
    }


def _run_text(command: tuple[str, ...]) -> str:
    result = subprocess.run(
        command,
        cwd=REPO_ROOT,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    return result.stdout.strip()


def _git() -> dict[str, object]:
    status = _run_text(
        ("git", "status", "--porcelain=v1", "--untracked-files=all")
    )
    return {
        "commit": _run_text(("git", "rev-parse", "HEAD")),
        "dirty": bool(status),
        "status": status.splitlines(),
    }


def _cover_obligations(
    manifest: dict[str, Any],
) -> dict[str, tuple[str, str, dict[str, Any]]]:
    covers = manifest["covers"]
    tasks = manifest["cover_tasks"]
    result: dict[str, tuple[str, str, dict[str, Any]]] = {}
    for state in covers["fsm_states"]:
        result[f"fsm.state.{state}"] = (
            tasks["fsm"]["task"],
            f"cover_state_{state}",
            tasks["fsm"],
        )
    for transition in covers["fsm_transitions"]:
        start, finish = transition.split("->", 1)
        result[f"fsm.transition.{transition}"] = (
            tasks["fsm"]["task"],
            f"cover_transition_{start}_to_{finish}",
            tasks["fsm"],
        )
    for exception in covers["exceptions"]:
        result[f"exception.{exception}"] = (
            tasks["exception"]["task"],
            "cover_exception_" + exception.replace(".", "_"),
            tasks["exception"],
        )
    for debug in covers["debug"]:
        result[f"debug.{debug}"] = (
            tasks["debug"]["task"],
            "cover_debug_" + debug.replace(".", "_"),
            tasks["debug"],
        )
    return result


def _cover_witnesses(
    task_dir: pathlib.Path,
    summary: str,
) -> dict[str, list[dict[str, object]]]:
    """Map each reached cover property to its concrete VCD/Yosys witness."""
    current: list[pathlib.Path] = []
    result: dict[str, list[dict[str, object]]] = {}
    marker = "reached cover statement "
    for raw_line in summary.splitlines():
        line = raw_line.strip()
        if line.startswith("cover trace: "):
            relative = line.removeprefix("cover trace: ").strip()
            if relative.endswith(".vcd"):
                current = []
            witness = task_dir / relative
            if not witness.is_file():
                raise FileNotFoundError(
                    f"cover summary references missing witness: {witness}"
                )
            current.append(witness)
            continue
        if marker not in line:
            continue
        qualified = line.split(marker, 1)[1].split()[0]
        property_name = qualified.rsplit(".", 1)[-1]
        suffixes = {path.suffix for path in current}
        if suffixes != {".vcd", ".yw"}:
            raise ValueError(
                f"{property_name} lacks a VCD/Yosys witness pair"
            )
        result[property_name] = [_file_entry(path) for path in current]
    return result


def _write_report(path: pathlib.Path, report: dict[str, Any]) -> None:
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
    parser.add_argument("--sby-file", type=pathlib.Path, default=DEFAULT_SBY)
    parser.add_argument("--output", type=pathlib.Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--work-prefix", type=pathlib.Path, default=DEFAULT_WORK)
    parser.add_argument(
        "--tool-directory",
        type=pathlib.Path,
        default=REPO_ROOT / f".tools/oss-cad-suite-{TOOL_RELEASE}",
    )
    parser.add_argument("--jobs", type=int, default=2)
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    manifest_path = args.manifest.resolve()
    sby_file = args.sby_file.resolve()
    output = args.output.resolve()
    work_prefix = args.work_prefix.resolve()
    tool_directory = args.tool_directory.resolve()
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    cover_obligations = _cover_obligations(manifest)
    proofs = {
        entry["id"]: entry for entry in manifest.get("proofs", [])
    }
    tasks = sorted(
        {entry["task"] for entry in proofs.values()}
        | {entry[0] for entry in cover_obligations.values()}
    )
    sby = tool_directory / "bin/sby"
    if not sby.is_file():
        raise FileNotFoundError(
            f"pinned sby is missing: run {SCRIPT_DIR / 'install_oss_cad_suite.py'}"
        )

    runner_log = output.parent / "formal" / "runner.log"
    runner_log.parent.mkdir(parents=True, exist_ok=True)
    command = [
        str(sby),
        "-f",
        "-j",
        str(args.jobs),
        "--prefix",
        str(work_prefix),
        str(sby_file),
        *tasks,
    ]
    print("[formal] START " + " ".join(tasks), flush=True)
    with runner_log.open("w", encoding="utf-8") as log:
        result = subprocess.run(
            command,
            cwd=REPO_ROOT,
            stdout=log,
            stderr=subprocess.STDOUT,
            text=True,
        )

    task_evidence: dict[str, dict[str, object]] = {}
    failures: list[str] = []
    for task in tasks:
        task_dir = pathlib.Path(f"{work_prefix}_{task}")
        pass_path = task_dir / "PASS"
        log_path = task_dir / "logfile.txt"
        if not pass_path.is_file() or not log_path.is_file():
            failures.append(f"{task}: missing PASS or logfile.txt")
            continue
        summary = pass_path.read_text(
            encoding="utf-8", errors="replace"
        )
        task_evidence[task] = {
            "summary": summary,
            "log": _file_entry(log_path),
            "covers": _cover_witnesses(task_dir, summary),
        }

    for cover_id, (task, property_name, _settings) in cover_obligations.items():
        evidence = task_evidence.get(task)
        if (
            evidence is None
            or property_name not in str(evidence["summary"])
            or property_name not in evidence["covers"]
        ):
            failures.append(
                f"{cover_id}: {property_name} was not reached by {task}"
            )

    required_proofs = sorted(proofs)
    required_covers = sorted(cover_obligations)
    passed = result.returncode == 0 and not failures
    results: dict[str, dict[str, object]] = {}
    if passed:
        for proof_id, proof in proofs.items():
            evidence = task_evidence[proof["task"]]
            source = REPO_ROOT / proof["source"]
            results[proof_id] = {
                "status": "passed",
                "task": proof["task"],
                "property": proof["property"],
                "engine": proof["engine"],
                "depth": proof["depth"],
                "log": evidence["log"],
                "source": _file_entry(source),
            }
        for cover_id, (task, property_name, settings) in cover_obligations.items():
            evidence = task_evidence[task]
            source = REPO_ROOT / settings["source"]
            results[cover_id] = {
                "status": "passed",
                "task": task,
                "property": property_name,
                "engine": settings["engine"],
                "depth": settings["depth"],
                "log": evidence["log"],
                "source": _file_entry(source),
                "witnesses": evidence["covers"][property_name],
            }

    report = {
        "schema": REPORT_SCHEMA,
        "status": "passed" if passed else "failed",
        "failure": None if passed else {
            "runner_exit_code": result.returncode,
            "messages": failures,
            "runner_log": _file_entry(runner_log),
        },
        "created_utc": dt.datetime.now(dt.UTC).isoformat(timespec="seconds"),
        "git": _git(),
        "toolchain": manifest["toolchain"],
        "tools": {
            "sby": _run_text((str(sby), "--version")),
            "yosys": _run_text(
                (str(tool_directory / "bin/yosys"), "--version")
            ).splitlines()[0],
            "boolector": _run_text(
                (str(tool_directory / "bin/boolector"), "--version")
            ).splitlines()[0],
        },
        "manifest": _file_entry(manifest_path),
        "sby_file": _file_entry(sby_file),
        "runner_log": _file_entry(runner_log),
        "required_proofs": required_proofs,
        "proven_proofs": required_proofs if passed else [],
        "required_covers": required_covers,
        "covered_covers": required_covers if passed else [],
        "uncovered_covers": [] if passed else required_covers,
        "results": results,
    }
    _write_report(output, report)
    if not passed:
        print(
            f"[formal] FAIL; inspect {runner_log.relative_to(REPO_ROOT)}",
            flush=True,
        )
        return 1
    print(
        f"[formal] PASS {len(required_proofs)} proofs, "
        f"{len(required_covers)} covers",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
