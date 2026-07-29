#!/usr/bin/env python3
"""Build and simulate two fitted Cyclone V ARM7TDMI wrapper netlists."""

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
import tempfile
from collections.abc import Sequence
from typing import Any


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
FPGA_DIR = REPO_ROOT / "fpga"
FILELIST = FPGA_DIR / "arm7tdmi_mister.f"
QIP_PATH = FPGA_DIR / "arm7tdmi_mister.qip"
PRIMITIVES_PATH = (
    REPO_ROOT / "verification" / "intel_cyclonev_postfit_primitives.sv"
)
TESTBENCH_PATH = REPO_ROOT / "tb" / "postfit" / "arm7tdmi_postfit_tb.sv"
DEFAULT_REPORT = REPO_ROOT / "reports" / "generated" / "postfit-report.json"
SCHEMA = "arm7tdmis-postfit-v1"
DEVICE = "5CSEBA6U23I7"
EXPECTED_QUARTUS = "Version 17.0.2 Build 602 07/19/2017 SJ Lite Edition"
ALLOWED_CRITICAL_WARNING_IDS = {"169085", "332012"}
ALLOWED_PRIMITIVES = {
    "dffeas",
    "cyclonev_lcell_comb",
    "cyclonev_io_ibuf",
    "cyclonev_io_obuf",
    "cyclonev_clkena",
}
FORBIDDEN_PRIMITIVES = {"cyclonev_mac", "_encrypted", "altera_mf"}
PROFILES = {"little": 0, "big": 1}


def sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def file_entry(path: pathlib.Path) -> dict[str, Any]:
    resolved = path.resolve()
    return {
        "path": resolved.relative_to(REPO_ROOT).as_posix(),
        "bytes": resolved.stat().st_size,
        "sha256": sha256(resolved),
    }


def run_text(command: Sequence[str]) -> str:
    return subprocess.run(
        command,
        cwd=REPO_ROOT,
        check=True,
        timeout=30,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    ).stdout.strip()


def run_logged(
    command: Sequence[str],
    *,
    cwd: pathlib.Path,
    log_path: pathlib.Path,
    timeout_seconds: int,
) -> str:
    try:
        result = subprocess.run(
            command,
            cwd=cwd,
            check=True,
            timeout=timeout_seconds,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        output = result.stdout
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        output = error.stdout or ""
        if isinstance(output, bytes):
            output = output.decode("utf-8", errors="replace")
        log_path.parent.mkdir(parents=True, exist_ok=True)
        temporary = log_path.with_suffix(log_path.suffix + ".tmp")
        temporary.write_text(output, encoding="utf-8")
        os.replace(temporary, log_path)
        raise
    log_path.parent.mkdir(parents=True, exist_ok=True)
    temporary = log_path.with_suffix(log_path.suffix + ".tmp")
    temporary.write_text(output, encoding="utf-8")
    os.replace(temporary, log_path)
    return output


def command_identity(command: str, version_args: Sequence[str]) -> dict[str, Any]:
    found = shutil.which(command) if not pathlib.Path(command).is_absolute() else command
    if found is None:
        raise FileNotFoundError(f"required command is not installed: {command}")
    executable = pathlib.Path(found).resolve()
    if not executable.is_file():
        raise FileNotFoundError(f"required command is not a file: {executable}")
    version = run_text((str(executable), *version_args))
    return {
        "command": command,
        "path": str(executable),
        "bytes": executable.stat().st_size,
        "sha256": sha256(executable),
        "version": version,
    }


def source_paths() -> list[pathlib.Path]:
    paths = [
        pathlib.Path(__file__).resolve(),
        FILELIST,
        QIP_PATH,
        PRIMITIVES_PATH,
        TESTBENCH_PATH,
    ]
    for raw_line in FILELIST.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or line.startswith("+"):
            continue
        paths.append((FILELIST.parent / line).resolve())
    missing = [path for path in paths if not path.is_file()]
    if missing:
        raise FileNotFoundError(f"post-fit input is missing: {missing[0]}")
    return sorted(set(paths))


def qsf_text(*, big_endian: int) -> str:
    qip_path = str(QIP_PATH.resolve())
    for original, escaped in (
        ("\\", "\\\\"),
        ('"', '\\"'),
        ("$", "\\$"),
        ("[", "\\["),
        ("]", "\\]"),
    ):
        qip_path = qip_path.replace(original, escaped)
    return "\n".join(
        (
            'set_global_assignment -name FAMILY "Cyclone V"',
            f"set_global_assignment -name DEVICE {DEVICE}",
            "set_global_assignment -name TOP_LEVEL_ENTITY arm7tdmi_mister",
            f'set_global_assignment -name QIP_FILE "{qip_path}"',
            "set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output",
            "set_global_assignment -name NUM_PARALLEL_PROCESSORS ALL",
            "set_global_assignment -name AUTO_DSP_RECOGNITION OFF",
            f"set_parameter -name BIG_ENDIAN {big_endian}",
            "set_parameter -name ENABLE_DEBUG 0",
            "set_parameter -name ENABLE_COPROCESSOR 0",
            "",
        )
    )


def validate_quartus_log(text: str, *, phase: str) -> list[str]:
    if re.search(r"(?m)^Error \(", text):
        raise ValueError(f"{phase} log contains a Quartus error")
    critical = set(re.findall(r"Critical Warning \((\d+)\)", text))
    unexpected = critical - ALLOWED_CRITICAL_WARNING_IDS
    if unexpected:
        raise ValueError(
            f"{phase} has unexpected critical warning IDs: "
            f"{sorted(unexpected)}"
        )
    return sorted(critical)


def validate_netlist(path: pathlib.Path) -> list[str]:
    text = path.read_text(encoding="utf-8")
    for forbidden in FORBIDDEN_PRIMITIVES:
        if forbidden in text:
            raise ValueError(
                f"fitted netlist requires forbidden primitive {forbidden}"
            )
    primitives = set(
        re.findall(r"(?m)^\s*(cyclonev_[A-Za-z0-9_]+|dffeas)\s+\\", text)
    )
    unknown = primitives - ALLOWED_PRIMITIVES
    if unknown:
        raise ValueError(f"fitted netlist has unmodeled primitives: {sorted(unknown)}")
    if primitives != ALLOWED_PRIMITIVES:
        raise ValueError(
            "fitted netlist primitive inventory changed: "
            f"{sorted(primitives)}"
        )
    return sorted(primitives)


def profile_result(
    *,
    name: str,
    big_endian: int,
    work_root: pathlib.Path,
    report_root: pathlib.Path,
    quartus_map: str,
    quartus_fit: str,
    quartus_eda: str,
    verilator: str,
    timeout_seconds: int,
) -> dict[str, Any]:
    profile_root = work_root / name
    profile_root.mkdir(parents=True)
    project = f"arm7tdmi_postfit_{name}"
    qsf_path = profile_root / f"{project}.qsf"
    qsf_path.write_text(qsf_text(big_endian=big_endian), encoding="utf-8")
    netlist_root = profile_root / "netlist"
    obj_root = profile_root / "obj"
    log_root = report_root / name

    commands: dict[str, list[str]] = {
        "map": [
            quartus_map,
            project,
            "--read_settings_files=on",
            "--write_settings_files=off",
        ],
        "fit": [
            quartus_fit,
            project,
            "--read_settings_files=on",
            "--write_settings_files=off",
        ],
        "eda": [
            quartus_eda,
            project,
            "--simulation",
            "--tool=modelsim",
            "--format=verilog",
            "--functional",
            f"--output_directory={netlist_root}",
            "--write_settings_files=off",
        ],
    }
    critical_warning_ids: set[str] = set()
    logs: dict[str, dict[str, Any]] = {}
    for phase in ("map", "fit", "eda"):
        log_path = log_root / f"{phase}.log"
        text = run_logged(
            commands[phase],
            cwd=profile_root,
            log_path=log_path,
            timeout_seconds=timeout_seconds,
        )
        critical_warning_ids.update(
            validate_quartus_log(text, phase=f"{name}/{phase}")
        )
        logs[phase] = file_entry(log_path)

    netlist_path = netlist_root / f"{project}.vo"
    if not netlist_path.is_file() or netlist_path.stat().st_size == 0:
        raise ValueError(f"{name} EDA writer produced no functional netlist")
    primitives = validate_netlist(netlist_path)

    commands["verilator"] = [
        verilator,
        "--binary",
        "--timing",
        "-j",
        "0",
        "-Wno-fatal",
        "-Wno-SPECIFYIGN",
        "-Wno-TIMESCALEMOD",
        "-Wno-WIDTHEXPAND",
        "-Wno-WIDTHTRUNC",
        "--top-module",
        "arm7tdmi_postfit_tb",
        "--Mdir",
        str(obj_root),
        f"-DPOSTFIT_BIG_ENDIAN={big_endian}",
        str(PRIMITIVES_PATH),
        str(netlist_path),
        str(TESTBENCH_PATH),
    ]
    verilator_log = log_root / "verilator.log"
    run_logged(
        commands["verilator"],
        cwd=REPO_ROOT,
        log_path=verilator_log,
        timeout_seconds=timeout_seconds,
    )
    logs["verilator"] = file_entry(verilator_log)

    binary_path = obj_root / "Varm7tdmi_postfit_tb"
    if not binary_path.is_file():
        raise ValueError(f"{name} Verilator build produced no executable")
    commands["simulation"] = [str(binary_path)]
    simulation_log = log_root / "simulation.log"
    simulation_text = run_logged(
        commands["simulation"],
        cwd=REPO_ROOT,
        log_path=simulation_log,
        timeout_seconds=30,
    )
    pass_match = re.search(
        r"\[postfit\] PASS endian=(\d+) accepted=(\d+) "
        r"ce_low=(\d+) longest_wait=(\d+)",
        simulation_text,
    )
    if pass_match is None or int(pass_match.group(1)) != big_endian:
        raise ValueError(f"{name} simulation has no exact [postfit] PASS marker")
    logs["simulation"] = file_entry(simulation_log)

    return {
        "status": "passed",
        "big_endian": bool(big_endian),
        "project": project,
        "device": DEVICE,
        "synthesis_policy": {
            "auto_dsp_recognition": "off",
            "reason": (
                "portable structural simulation; production DSP inference "
                "is independently checked by FPGA-005"
            ),
        },
        "netlist": {
            "bytes": netlist_path.stat().st_size,
            "sha256": sha256(netlist_path),
            "primitives": primitives,
        },
        "metrics": {
            "accepted_transactions": int(pass_match.group(2)),
            "accepted_while_cpu_ce_low": int(pass_match.group(3)),
            "longest_wait_cycles": int(pass_match.group(4)),
        },
        "critical_warning_ids": sorted(critical_warning_ids),
        "commands": commands,
        "logs": logs,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=pathlib.Path, default=DEFAULT_REPORT)
    parser.add_argument("--quartus-map", default="quartus_map")
    parser.add_argument("--quartus-fit", default="quartus_fit")
    parser.add_argument("--quartus-eda", default="quartus_eda")
    parser.add_argument("--verilator", default="verilator")
    parser.add_argument("--timeout-seconds", type=int, default=300)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.timeout_seconds <= 0:
        raise ValueError("timeout must be positive")
    report_path = args.output.resolve()
    report_root = report_path.parent / "postfit"

    tools = {
        "quartus_map": command_identity(args.quartus_map, ("--version",)),
        "quartus_fit": command_identity(args.quartus_fit, ("--version",)),
        "quartus_eda": command_identity(args.quartus_eda, ("--version",)),
        "verilator": command_identity(args.verilator, ("--version",)),
    }
    for label in ("quartus_map", "quartus_fit", "quartus_eda"):
        if EXPECTED_QUARTUS not in tools[label]["version"]:
            raise ValueError(
                "post-fit validation requires checked Quartus "
                f"{EXPECTED_QUARTUS} for {label}"
            )

    git_status = run_text(
        ("git", "status", "--porcelain=v1", "--untracked-files=all")
    )
    report: dict[str, Any] = {
        "schema": SCHEMA,
        "status": "running",
        "created_utc": dt.datetime.now(dt.UTC).isoformat(timespec="seconds"),
        "git": {
            "commit": run_text(("git", "rev-parse", "HEAD")),
            "dirty": bool(git_status),
            "status": git_status.splitlines(),
        },
        "device": DEVICE,
        "profile_exceptions": {
            "critical_warning_ids": sorted(ALLOWED_CRITICAL_WARNING_IDS),
            "explanation": (
                "The temporary simulation-only projects intentionally have "
                "no board pinout or SDC; production fit/timing closure is "
                "separately mandatory under FPGA-003."
            ),
        },
        "tools": tools,
        "inputs": {
            path.relative_to(REPO_ROOT).as_posix(): file_entry(path)
            for path in source_paths()
        },
        "profiles": {},
    }
    report_path.parent.mkdir(parents=True, exist_ok=True)

    try:
        with tempfile.TemporaryDirectory(prefix="arm7tdmi-postfit-") as temporary:
            work_root = pathlib.Path(temporary)
            for name, big_endian in PROFILES.items():
                report["profiles"][name] = profile_result(
                    name=name,
                    big_endian=big_endian,
                    work_root=work_root,
                    report_root=report_root,
                    quartus_map=args.quartus_map,
                    quartus_fit=args.quartus_fit,
                    quartus_eda=args.quartus_eda,
                    verilator=args.verilator,
                    timeout_seconds=args.timeout_seconds,
                )
    except Exception:
        report["status"] = "failed"
        report_path.write_text(
            json.dumps(report, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        raise

    report["status"] = "passed"
    temporary_report = report_path.with_suffix(report_path.suffix + ".tmp")
    temporary_report.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary_report, report_path)
    print(
        "[postfit] PASS "
        f"(little={report['profiles']['little']['netlist']['sha256'][:12]}, "
        f"big={report['profiles']['big']['netlist']['sha256'][:12]})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
