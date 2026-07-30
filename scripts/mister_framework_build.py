#!/usr/bin/env python3
"""Build and validate the CPU inside a pinned official MiSTer framework."""

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
import sys
from collections.abc import Sequence
from typing import Any


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
FRAMEWORK_URL = "https://github.com/MiSTer-devel/Template_MiSTer.git"
FRAMEWORK_COMMIT = "69b8a2acc6d84dd313b5abcba6a17155287ed3d8"
FRAMEWORK_TREE = "b8b642eae80716da93754a3e778a5daa3313350b"
FRAMEWORK_PROJECT = "Template"
EXPECTED_TOP = "sys_top"
EXPECTED_DEVICE = "5CSEBA6U23I7"
EXPECTED_CLOCK_MHZ = 12.5
REPORT_SCHEMA = "arm7tdmis-mister-framework-v1"
SOURCE_MANIFEST = REPO_ROOT / "fpga" / "arm7tdmi_mister.f"
GENERIC_SOC = (
    REPO_ROOT / "examples" / "generic_soc" / "arm7tdmi_generic_soc.sv"
)
EMU_SOURCE = (
    REPO_ROOT
    / "examples"
    / "mister_framework"
    / "arm7tdmi_mister_emu.sv"
)
CORE_SDC = REPO_ROOT / "examples" / "mister_framework" / "Template.sdc"
DEFAULT_CACHE = REPO_ROOT / ".tools" / "mister-framework" / "upstream"
DEFAULT_WORK = REPO_ROOT / ".tools" / "mister-framework" / "work"
DEFAULT_REPORT = (
    REPO_ROOT / "reports" / "generated" / "mister-framework-report.json"
)
DEFAULT_ARTIFACT_DIR = (
    REPO_ROOT / "reports" / "generated" / "mister-framework"
)
UNCONSTRAINED_LABELS = (
    "Unconstrained Clocks",
    "Unconstrained Input Ports",
    "Unconstrained Input Port Paths",
    "Unconstrained Output Ports",
    "Unconstrained Output Port Paths",
)
REPORT_SUFFIXES = (
    ".flow.rpt",
    ".map.summary",
    ".map.rpt",
    ".fit.summary",
    ".fit.rpt",
    ".asm.rpt",
    ".sta.summary",
    ".sta.rpt",
    ".rbf",
)


def _sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _file_entry(path: pathlib.Path) -> dict[str, Any]:
    resolved = path.resolve()
    return {
        "path": resolved.relative_to(REPO_ROOT).as_posix(),
        "bytes": resolved.stat().st_size,
        "sha256": _sha256(resolved),
    }


def _run_text(command: Sequence[str], *, cwd: pathlib.Path) -> str:
    return subprocess.run(
        command,
        cwd=cwd,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    ).stdout.strip()


def _run_logged(
    command: Sequence[str],
    *,
    cwd: pathlib.Path,
    log_path: pathlib.Path,
) -> int:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("w", encoding="utf-8") as log:
        process = subprocess.Popen(
            command,
            cwd=cwd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        assert process.stdout is not None
        for line in process.stdout:
            sys.stdout.write(line)
            log.write(line)
        return process.wait()


def manifest_sources() -> list[pathlib.Path]:
    sources: list[pathlib.Path] = []
    for raw_line in SOURCE_MANIFEST.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith(("#", "+")):
            continue
        source = (SOURCE_MANIFEST.parent / line).resolve()
        source.relative_to(REPO_ROOT)
        if not source.is_file():
            raise ValueError(f"manifest source is missing: {source}")
        sources.append(source)
    if len(sources) != len(set(sources)):
        raise ValueError("FPGA source manifest contains duplicate files")
    return sources


def local_inputs() -> list[pathlib.Path]:
    return sorted(
        {
            *manifest_sources(),
            SOURCE_MANIFEST,
            GENERIC_SOC,
            EMU_SOURCE,
            CORE_SDC,
            pathlib.Path(__file__).resolve(),
        }
    )


def _qip_line(relative: pathlib.PurePath) -> str:
    return (
        "set_global_assignment -name SYSTEMVERILOG_FILE "
        f'"{relative.as_posix()}"'
    )


def install_overlay(framework_root: pathlib.Path) -> dict[str, str]:
    """Copy the repository-owned core into an otherwise pristine framework."""
    overlay_root = framework_root / "arm7tdmi"
    copied: dict[str, str] = {}
    ordered_sources = manifest_sources() + [GENERIC_SOC]
    for source in ordered_sources:
        relative = source.relative_to(REPO_ROOT)
        destination = overlay_root / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
        copied[relative.as_posix()] = _sha256(destination)

    shutil.copy2(EMU_SOURCE, framework_root / "Template.sv")
    shutil.copy2(CORE_SDC, framework_root / "Template.sdc")
    pll_source = framework_root / "rtl" / "pll" / "pll_0002.v"
    pll_text = pll_source.read_text(encoding="utf-8")
    old_frequency = 'output_clock_frequency0("20.000000 MHz")'
    new_frequency = (
        f'output_clock_frequency0("{EXPECTED_CLOCK_MHZ:.6f} MHz")'
    )
    if pll_text.count(old_frequency) != 1:
        raise ValueError("official template PLL frequency marker changed")
    pll_source.write_text(
        pll_text.replace(old_frequency, new_frequency),
        encoding="utf-8",
    )
    qip_lines = [
        "# Generated by arm7tdmi-sv/scripts/mister_framework_build.py.",
        "# The official framework sys/ directory is intentionally unmodified.",
        "set_global_assignment -name TIMEQUEST_MULTICORNER_ANALYSIS ON",
        "",
    ]
    qip_lines.extend(
        _qip_line(
            pathlib.PurePosixPath("arm7tdmi")
            / path.relative_to(REPO_ROOT)
        )
        for path in ordered_sources
    )
    qip_lines.extend(
        (
            _qip_line(pathlib.PurePosixPath("Template.sv")),
            'set_global_assignment -name SDC_FILE "Template.sdc"',
            "",
        )
    )
    (framework_root / "files.qip").write_text(
        "\n".join(qip_lines),
        encoding="utf-8",
    )
    return copied


def _integer_field(text: str, label: str) -> int | None:
    match = re.search(
        rf"^{re.escape(label)}\s*:\s*([\d,]+)",
        text,
        re.MULTILINE,
    )
    return int(match.group(1).replace(",", "")) if match else None


def _read_report(path: pathlib.Path, errors: list[str]) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except FileNotFoundError:
        errors.append(f"missing report: {path.name}")
        return ""


def parse_reports(output_dir: pathlib.Path) -> tuple[dict[str, Any], list[str]]:
    """Extract and fail-close the real framework fit/STA/bitstream contract."""
    errors: list[str] = []
    prefix = output_dir / FRAMEWORK_PROJECT
    flow = _read_report(prefix.with_suffix(".flow.rpt"), errors)
    map_summary = _read_report(prefix.with_suffix(".map.summary"), errors)
    map_report = _read_report(prefix.with_suffix(".map.rpt"), errors)
    fit_summary = _read_report(prefix.with_suffix(".fit.summary"), errors)
    fit_report = _read_report(prefix.with_suffix(".fit.rpt"), errors)
    asm_report = _read_report(prefix.with_suffix(".asm.rpt"), errors)
    sta_summary = _read_report(prefix.with_suffix(".sta.summary"), errors)
    sta_report = _read_report(prefix.with_suffix(".sta.rpt"), errors)

    markers = (
        (flow, "Flow Status", "Successful", "full flow"),
        (map_summary, "Analysis & Synthesis Status", "Successful", "synthesis"),
        (fit_summary, "Fitter Status", "Successful", "fit"),
        (asm_report, "Assembler was successful", "", "assembly"),
        (
            sta_report,
            "TimeQuest Timing Analyzer was successful",
            "",
            "TimeQuest",
        ),
    )
    for text, marker, value, phase in markers:
        if marker not in text or (value and value not in text):
            errors.append(f"{phase} success marker missing")

    top_match = re.search(
        r"^Top-level Entity Name\s*:\s*(\S+)",
        fit_summary,
        re.MULTILINE,
    )
    device_match = re.search(
        r"^Device\s*:\s*(\S+)",
        fit_summary,
        re.MULTILINE,
    )
    top = top_match.group(1) if top_match else None
    device = device_match.group(1) if device_match else None
    if top != EXPECTED_TOP:
        errors.append(f"unexpected top: {top!r}")
    if device != EXPECTED_DEVICE:
        errors.append(f"unexpected device: {device!r}")

    for required_entity in ("arm7tdmi_generic_soc", "arm7tdmi_mister"):
        if required_entity not in map_report:
            errors.append(f"mapped hierarchy lacks {required_entity}")

    for report_name, text in (
        ("flow", flow),
        ("map", map_report),
        ("fit", fit_report),
        ("assembly", asm_report),
        ("sta", sta_report),
    ):
        for line in text.splitlines():
            if "Critical Warning" in line:
                errors.append(f"{report_name}: {line.strip()}")
            if "Warning (332174): Ignored filter" in line:
                errors.append(f"{report_name}: {line.strip()}")

    timing: list[dict[str, Any]] = []
    for path_type, raw_slack in re.findall(
        r"Type\s*:\s*(.+?)\nSlack\s*:\s*(-?\d+(?:\.\d+)?)",
        sta_summary,
    ):
        slack = float(raw_slack)
        timing.append({"type": path_type.strip(), "slack_ns": slack})
        if slack < 0.0:
            errors.append(
                f"negative slack {slack:.3f} ns: {path_type.strip()}"
            )
    if not timing:
        errors.append("no timing slack entries found")

    unconstrained: dict[str, dict[str, int] | None] = {}
    for label in UNCONSTRAINED_LABELS:
        match = re.search(
            rf"^\s*;\s*{re.escape(label)}\s*;\s*(\d+)\s*;\s*(\d+)\s*;",
            sta_report,
            re.MULTILINE,
        )
        if match is None:
            unconstrained[label] = None
            errors.append(f"missing unconstrained-path row: {label}")
        else:
            counts = {
                "setup": int(match.group(1)),
                "hold": int(match.group(2)),
            }
            unconstrained[label] = counts
            if counts != {"setup": 0, "hold": 0}:
                errors.append(f"{label} is not zero: {counts}")

    clock_pattern = rf"{EXPECTED_CLOCK_MHZ:.3f}\s+MHz"
    if re.search(clock_pattern, sta_report) is None:
        errors.append(
            f"generated {EXPECTED_CLOCK_MHZ:.3f} MHz core clock is absent"
        )

    resources = {
        "alm": _integer_field(fit_summary, "Logic utilization (in ALMs)"),
        "register": _integer_field(fit_summary, "Total registers"),
        "memory_bit": _integer_field(
            fit_summary,
            "Total block memory bits",
        ),
        "dsp": _integer_field(fit_summary, "Total DSP Blocks"),
        "pll": _integer_field(fit_summary, "Total PLLs"),
    }
    for name, value in resources.items():
        if value is None:
            errors.append(f"missing resource field: {name}")

    bitstream = prefix.with_suffix(".rbf")
    if not bitstream.is_file() or bitstream.stat().st_size == 0:
        errors.append(f"missing or empty bitstream: {bitstream.name}")

    setup_slacks = [
        entry["slack_ns"]
        for entry in timing
        if "Setup" in entry["type"]
    ]
    hold_slacks = [
        entry["slack_ns"]
        for entry in timing
        if "Hold" in entry["type"]
    ]
    result = {
        "project": FRAMEWORK_PROJECT,
        "top": top,
        "device": device,
        "core_clock_mhz": EXPECTED_CLOCK_MHZ,
        "resources": resources,
        "timing": {
            "entries": timing,
            "minimum_setup_slack_ns": min(setup_slacks)
            if setup_slacks
            else None,
            "minimum_hold_slack_ns": min(hold_slacks)
            if hold_slacks
            else None,
        },
        "unconstrained": unconstrained,
        "status": "passed" if not errors else "failed",
    }
    return result, errors


def _git_metadata() -> dict[str, Any]:
    import regression_harness

    status = _run_text(
        ("git", "status", "--porcelain=v1", "--untracked-files=all"),
        cwd=REPO_ROOT,
    )
    return {
        "commit": _run_text(("git", "rev-parse", "HEAD"), cwd=REPO_ROOT),
        "dirty": bool(status),
        "status": status.splitlines(),
        "source_sha256": regression_harness._source_digest(),
    }


def _ensure_framework(cache: pathlib.Path) -> None:
    cache.parent.mkdir(parents=True, exist_ok=True)
    if not cache.exists():
        _run_text(
            ("git", "clone", "--no-checkout", FRAMEWORK_URL, str(cache)),
            cwd=cache.parent,
        )
    if not (cache / ".git").is_dir():
        raise ValueError(f"framework cache is not a Git checkout: {cache}")
    remote = _run_text(
        ("git", "config", "--get", "remote.origin.url"),
        cwd=cache,
    )
    if remote.rstrip("/") != FRAMEWORK_URL.rstrip("/"):
        raise ValueError(f"framework cache has unexpected origin: {remote}")
    available = subprocess.run(
        ("git", "cat-file", "-e", f"{FRAMEWORK_COMMIT}^{{commit}}"),
        cwd=cache,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    ).returncode == 0
    if not available:
        _run_text(
            ("git", "fetch", "origin", FRAMEWORK_COMMIT),
            cwd=cache,
        )
    tree = _run_text(
        ("git", "rev-parse", f"{FRAMEWORK_COMMIT}^{{tree}}"),
        cwd=cache,
    )
    if tree != FRAMEWORK_TREE:
        raise ValueError(f"framework tree mismatch: {tree}")


def _copy_artifacts(
    framework_output: pathlib.Path,
    artifact_dir: pathlib.Path,
    build_log: pathlib.Path,
) -> dict[str, dict[str, Any]]:
    artifact_dir.mkdir(parents=True, exist_ok=True)
    copied: dict[str, dict[str, Any]] = {}
    for suffix in REPORT_SUFFIXES:
        source = framework_output / f"{FRAMEWORK_PROJECT}{suffix}"
        destination = artifact_dir / source.name
        shutil.copy2(source, destination)
        copied[destination.name] = _file_entry(destination)
    copied[build_log.name] = _file_entry(build_log)
    return copied


def validate_evidence(
    report: dict[str, Any],
    *,
    expected_commit: str,
    require_clean: bool,
) -> list[pathlib.Path]:
    """Validate a generated framework report and return its archived files."""
    if report.get("schema") != REPORT_SCHEMA:
        raise ValueError("MiSTer framework report has wrong schema")
    if report.get("status") != "passed":
        raise ValueError("MiSTer framework report is not passed")
    if report.get("framework") != {
        "url": FRAMEWORK_URL,
        "commit": FRAMEWORK_COMMIT,
        "tree": FRAMEWORK_TREE,
    }:
        raise ValueError("MiSTer framework identity is not pinned")
    git = report.get("git", {})
    if git.get("commit") != expected_commit:
        raise ValueError("MiSTer framework report commit does not match")
    if require_clean and git.get("dirty"):
        raise ValueError("MiSTer framework report describes a dirty tree")
    result = report.get("result", {})
    if (
        result.get("status") != "passed"
        or result.get("top") != EXPECTED_TOP
        or result.get("device") != EXPECTED_DEVICE
        or result.get("core_clock_mhz") != EXPECTED_CLOCK_MHZ
    ):
        raise ValueError("MiSTer framework result has wrong target identity")
    timing = result.get("timing", {})
    if (
        timing.get("minimum_setup_slack_ns") is None
        or timing["minimum_setup_slack_ns"] < 0
        or timing.get("minimum_hold_slack_ns") is None
        or timing["minimum_hold_slack_ns"] < 0
    ):
        raise ValueError("MiSTer framework timing is not closed")
    if set(result.get("unconstrained", {})) != set(UNCONSTRAINED_LABELS):
        raise ValueError("MiSTer framework unconstrained summary is incomplete")
    if any(
        value != {"setup": 0, "hold": 0}
        for value in result["unconstrained"].values()
    ):
        raise ValueError("MiSTer framework has unconstrained paths")

    candidates: list[pathlib.Path] = []
    for path_text, entry in report.get("inputs", {}).items():
        path = (REPO_ROOT / path_text).resolve()
        path.relative_to(REPO_ROOT)
        if (
            not path.is_file()
            or path.stat().st_size != entry.get("bytes")
            or _sha256(path) != entry.get("sha256")
        ):
            raise ValueError(f"MiSTer framework input hash mismatch: {path_text}")
        candidates.append(path)
    artifacts = report.get("artifacts", {})
    if set(artifacts) != {
        f"{FRAMEWORK_PROJECT}{suffix}" for suffix in REPORT_SUFFIXES
    } | {"build.log"}:
        raise ValueError("MiSTer framework artifact inventory is incomplete")
    for entry in artifacts.values():
        path = (REPO_ROOT / str(entry.get("path", ""))).resolve()
        path.relative_to(REPO_ROOT)
        if (
            not path.is_file()
            or path.stat().st_size != entry.get("bytes")
            or _sha256(path) != entry.get("sha256")
        ):
            raise ValueError("MiSTer framework artifact hash mismatch")
        candidates.append(path)
    return candidates


def build(
    *,
    cache: pathlib.Path,
    work_dir: pathlib.Path,
    report_path: pathlib.Path,
    artifact_dir: pathlib.Path,
    quartus_sh: str,
) -> dict[str, Any]:
    metadata = _git_metadata()
    if metadata["dirty"]:
        raise ValueError(
            "MiSTer framework evidence requires a clean source tree"
        )
    _ensure_framework(cache)
    if artifact_dir.exists():
        shutil.rmtree(artifact_dir)
    artifact_dir.mkdir(parents=True)
    build_log = artifact_dir / "build.log"
    command = (quartus_sh, "--flow", "compile", FRAMEWORK_PROJECT)

    work_dir.parent.mkdir(parents=True, exist_ok=True)
    if work_dir.exists():
        shutil.rmtree(work_dir)
    _run_text(
        (
            "git",
            "clone",
            "--no-hardlinks",
            str(cache),
            str(work_dir),
        ),
        cwd=work_dir.parent,
    )
    _run_text(
        ("git", "checkout", "--detach", FRAMEWORK_COMMIT),
        cwd=work_dir,
    )
    _run_text(
        ("git", "remote", "set-url", "origin", FRAMEWORK_URL),
        cwd=work_dir,
    )
    if _run_text(
        ("git", "status", "--porcelain=v1"),
        cwd=work_dir,
    ):
        raise ValueError("fresh framework checkout is not clean")
    if _run_text(
        ("git", "rev-parse", "HEAD^{tree}"),
        cwd=work_dir,
    ) != FRAMEWORK_TREE:
        raise ValueError("fresh framework checkout tree mismatch")

    install_overlay(work_dir)
    returncode = _run_logged(
        command,
        cwd=work_dir,
        log_path=build_log,
    )
    if returncode != 0:
        raise ValueError(
            f"MiSTer framework build failed with exit {returncode}"
        )
    output_dir = work_dir / "output_files"
    result, errors = parse_reports(output_dir)
    artifacts = _copy_artifacts(
        output_dir,
        artifact_dir,
        build_log,
    )
    if errors:
        raise ValueError("; ".join(errors))

    tool_version = _run_text((quartus_sh, "--version"), cwd=REPO_ROOT)
    report = {
        "schema": REPORT_SCHEMA,
        "status": "passed",
        "created_utc": dt.datetime.now(dt.UTC).isoformat(timespec="seconds"),
        "git": metadata,
        "framework": {
            "url": FRAMEWORK_URL,
            "commit": FRAMEWORK_COMMIT,
            "tree": FRAMEWORK_TREE,
        },
        "command": list(command),
        "tools": {"quartus_sh": tool_version},
        "inputs": {
            entry["path"]: {
                "bytes": entry["bytes"],
                "sha256": entry["sha256"],
            }
            for entry in map(_file_entry, local_inputs())
        },
        "result": result,
        "artifacts": artifacts,
    }
    report_path.parent.mkdir(parents=True, exist_ok=True)
    temporary_report = report_path.with_suffix(report_path.suffix + ".tmp")
    temporary_report.write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary_report, report_path)
    validate_evidence(
        report,
        expected_commit=metadata["commit"],
        require_clean=True,
    )
    return report


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache", type=pathlib.Path, default=DEFAULT_CACHE)
    parser.add_argument("--work-dir", type=pathlib.Path, default=DEFAULT_WORK)
    parser.add_argument("--output", type=pathlib.Path, default=DEFAULT_REPORT)
    parser.add_argument(
        "--artifact-dir",
        type=pathlib.Path,
        default=DEFAULT_ARTIFACT_DIR,
    )
    parser.add_argument("--quartus-sh", default="quartus_sh")
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    try:
        report = build(
            cache=args.cache.resolve(),
            work_dir=args.work_dir.resolve(),
            report_path=args.output.resolve(),
            artifact_dir=args.artifact_dir.resolve(),
            quartus_sh=args.quartus_sh,
        )
    except (OSError, subprocess.CalledProcessError, ValueError) as error:
        print(f"[mister-framework] FAIL: {error}", file=sys.stderr)
        return 1
    result = report["result"]
    print(
        "[mister-framework] PASS "
        f"{result['device']} at {result['core_clock_mhz']:.3f} MHz; "
        f"{result['resources']['alm']:,} ALMs; "
        f"setup {result['timing']['minimum_setup_slack_ns']:+.3f} ns; "
        f"hold {result['timing']['minimum_hold_slack_ns']:+.3f} ns"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
