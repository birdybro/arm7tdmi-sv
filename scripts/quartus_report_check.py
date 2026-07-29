#!/usr/bin/env python3
"""Fail-hard validation and extraction of Quartus release reports."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys
from typing import Any


DEFAULT_PROJECT = "arm7tdmi_mister"
DEFAULT_TOP = "arm7tdmi_mister_example_top"
DEFAULT_DEVICE = "5CSEBA6U23I7"
DEFAULT_RESOURCE_LIMITS = {
    "alm": 5_000,
    "register": 4_096,
    "dsp": 8,
    "memory_bit": 0,
}


def _read(path: pathlib.Path, errors: list[str]) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except FileNotFoundError:
        errors.append(f"missing report: {path.name}")
        return ""


def _integer_field(text: str, label: str) -> int | None:
    match = re.search(rf"^{re.escape(label)}\s*:\s*([\d,]+)", text, re.MULTILINE)
    if match is None:
        return None
    return int(match.group(1).replace(",", ""))


def validate_reports(
    output_dir: pathlib.Path,
    *,
    project: str = DEFAULT_PROJECT,
    expected_top: str = DEFAULT_TOP,
    expected_device: str = DEFAULT_DEVICE,
    resource_limits: dict[str, int] | None = None,
) -> tuple[dict[str, Any], list[str]]:
    errors: list[str] = []
    limits = dict(
        DEFAULT_RESOURCE_LIMITS if resource_limits is None else resource_limits
    )
    prefix = output_dir / project
    flow = _read(prefix.with_suffix(".flow.rpt"), errors)
    map_summary = _read(prefix.with_suffix(".map.summary"), errors)
    fit_summary = _read(prefix.with_suffix(".fit.summary"), errors)
    fit_report = _read(prefix.with_suffix(".fit.rpt"), errors)
    asm_report = _read(prefix.with_suffix(".asm.rpt"), errors)
    sta_summary = _read(prefix.with_suffix(".sta.summary"), errors)
    sta_report = _read(prefix.with_suffix(".sta.rpt"), errors)

    required_markers = (
        (flow, "Flow Status", "Successful", "full flow"),
        (map_summary, "Analysis & Synthesis Status", "Successful", "synthesis"),
        (fit_summary, "Fitter Status", "Successful", "fit"),
        (asm_report, "Assembler was successful", "", "assembly"),
        (sta_report, "TimeQuest Timing Analyzer was successful", "", "TimeQuest"),
    )
    for text, marker, value, phase in required_markers:
        if marker not in text or (value and value not in text):
            errors.append(f"{phase} success marker missing")

    top_match = re.search(r"^Top-level Entity Name\s*:\s*(\S+)", fit_summary,
                          re.MULTILINE)
    device_match = re.search(r"^Device\s*:\s*(\S+)", fit_summary, re.MULTILINE)
    top = top_match.group(1) if top_match else None
    device = device_match.group(1) if device_match else None
    if top != expected_top:
        errors.append(f"unexpected top: {top!r}")
    if device != expected_device:
        errors.append(f"unexpected device: {device!r}")

    if "fully constrained for setup requirements" not in sta_report:
        errors.append("setup paths are not fully constrained")
    if "fully constrained for hold requirements" not in sta_report:
        errors.append("hold paths are not fully constrained")

    for report_name, text in (("fit", fit_report), ("sta", sta_report)):
        for line in text.splitlines():
            if "Critical Warning" in line:
                errors.append(f"{report_name}: {line.strip()}")
            if "Warning (332174): Ignored filter" in line:
                errors.append(f"{report_name}: {line.strip()}")

    slack_entries: list[dict[str, Any]] = []
    blocks = re.findall(
        r"Type\s*:\s*(.+?)\nSlack\s*:\s*(-?\d+(?:\.\d+)?)",
        sta_summary,
    )
    if not blocks:
        errors.append("no timing slack entries found")
    for path_type, raw_slack in blocks:
        slack = float(raw_slack)
        slack_entries.append({"type": path_type.strip(), "slack_ns": slack})
        if slack < 0.0:
            errors.append(f"negative slack {slack:.3f} ns: {path_type.strip()}")

    resources = {
        "alm": _integer_field(fit_summary, "Logic utilization (in ALMs)"),
        "register": _integer_field(fit_summary, "Total registers"),
        "memory_bit": _integer_field(fit_summary, "Total block memory bits"),
        "dsp": _integer_field(fit_summary, "Total DSP Blocks"),
    }
    for resource, limit in limits.items():
        value = resources[resource]
        if value is None:
            errors.append(f"missing resource field: {resource}")
        elif value > limit:
            errors.append(f"{resource} budget exceeded: {value} > {limit}")

    sof = prefix.with_suffix(".sof")
    if not sof.is_file() or sof.stat().st_size == 0:
        errors.append(f"missing or empty programming image: {project}.sof")

    result = {
        "schema": "arm7tdmi-quartus-report-v1",
        "project": project,
        "top": top,
        "device": device,
        "resources": resources,
        "resource_limits": limits,
        "timing": slack_entries,
        "status": "passed" if not errors else "failed",
    }
    return result, errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("output_dir", type=pathlib.Path)
    parser.add_argument("--project", default=DEFAULT_PROJECT)
    parser.add_argument("--top", default=DEFAULT_TOP)
    parser.add_argument("--device", default=DEFAULT_DEVICE)
    parser.add_argument("--max-alm", type=int, default=DEFAULT_RESOURCE_LIMITS["alm"])
    parser.add_argument(
        "--max-register",
        type=int,
        default=DEFAULT_RESOURCE_LIMITS["register"],
    )
    parser.add_argument("--max-dsp", type=int, default=DEFAULT_RESOURCE_LIMITS["dsp"])
    parser.add_argument(
        "--max-memory-bit",
        type=int,
        default=DEFAULT_RESOURCE_LIMITS["memory_bit"],
    )
    args = parser.parse_args()

    result, errors = validate_reports(
        args.output_dir,
        project=args.project,
        expected_top=args.top,
        expected_device=args.device,
        resource_limits={
            "alm": args.max_alm,
            "register": args.max_register,
            "dsp": args.max_dsp,
            "memory_bit": args.max_memory_bit,
        },
    )
    print(json.dumps(result, indent=2, sort_keys=True))
    for error in errors:
        print(f"[quartus-report] FAIL: {error}", file=sys.stderr)
    return 0 if not errors else 1


if __name__ == "__main__":
    raise SystemExit(main())
