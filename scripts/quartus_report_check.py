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
ALLOWED_POWER_CRITICAL_WARNING_CODES = {"215050"}


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


def _table_integer_field(text: str, label: str) -> int | None:
    match = re.search(
        rf"^\s*;\s*{re.escape(label)}\s*;\s*([\d,]+)\s*;",
        text,
        re.MULTILINE,
    )
    if match is None:
        return None
    return int(match.group(1).replace(",", ""))


def _float_field(text: str, label: str, unit: str) -> float | None:
    match = re.search(
        rf"^{re.escape(label)}\s*:\s*(-?\d+(?:\.\d+)?)\s*{re.escape(unit)}",
        text,
        re.MULTILINE,
    )
    if match is None:
        return None
    return float(match.group(1))


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
    map_report = _read(prefix.with_suffix(".map.rpt"), errors)
    fit_summary = _read(prefix.with_suffix(".fit.summary"), errors)
    fit_report = _read(prefix.with_suffix(".fit.rpt"), errors)
    asm_report = _read(prefix.with_suffix(".asm.rpt"), errors)
    sta_summary = _read(prefix.with_suffix(".sta.summary"), errors)
    sta_report = _read(prefix.with_suffix(".sta.rpt"), errors)
    power_summary = _read(prefix.with_suffix(".pow.summary"), errors)
    power_report = _read(prefix.with_suffix(".pow.rpt"), errors)

    required_markers = (
        (flow, "Flow Status", "Successful", "full flow"),
        (map_summary, "Analysis & Synthesis Status", "Successful", "synthesis"),
        (fit_summary, "Fitter Status", "Successful", "fit"),
        (asm_report, "Assembler was successful", "", "assembly"),
        (sta_report, "TimeQuest Timing Analyzer was successful", "", "TimeQuest"),
        (
            power_summary,
            "PowerPlay Power Analyzer Status",
            "Successful",
            "PowerPlay",
        ),
        (
            power_report,
            "PowerPlay Power Analyzer was successful",
            "",
            "PowerPlay report",
        ),
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

    power_warning_waivers: list[str] = []
    for report_name, text in (
        ("fit", fit_report),
        ("sta", sta_report),
        ("power", power_report),
    ):
        for line in text.splitlines():
            if "Critical Warning" in line:
                code_match = re.search(r"Critical Warning \((\d+)\)", line)
                code = code_match.group(1) if code_match else ""
                if (
                    report_name == "power"
                    and code in ALLOWED_POWER_CRITICAL_WARNING_CODES
                ):
                    power_warning_waivers.append(line.strip())
                else:
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

    clock_enable_registers = _table_integer_field(
        map_report,
        "Number of registers using Clock Enable",
    )
    if clock_enable_registers is None:
        errors.append("missing clock-enable register inference field")
    elif clock_enable_registers == 0:
        errors.append("no registers inferred with clock enable")

    fmax_values = [
        float(value)
        for value in re.findall(
            r"^\s*;\s*(\d+(?:\.\d+)?)\s+MHz\s*;"
            r"\s*\d+(?:\.\d+)?\s+MHz\s*;\s*CLK\s*;",
            sta_report,
            re.MULTILINE,
        )
    ]
    if not fmax_values:
        errors.append("no CLK Fmax entries found")

    power_fields = {
        "total": "Total Thermal Power Dissipation",
        "core_dynamic": "Core Dynamic Thermal Power Dissipation",
        "core_static": "Core Static Thermal Power Dissipation",
        "io": "I/O Thermal Power Dissipation",
    }
    power_mw = {
        key: _float_field(power_summary, label, "mW")
        for key, label in power_fields.items()
    }
    for field, value in power_mw.items():
        if value is None:
            errors.append(f"missing power field: {field}")
    confidence_match = re.search(
        r"^Power Estimation Confidence\s*:\s*(.+)$",
        power_summary,
        re.MULTILINE,
    )
    power_confidence = (
        confidence_match.group(1).strip() if confidence_match else None
    )
    if power_confidence is None:
        errors.append("missing power estimation confidence")

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
        "clock_enable_registers": clock_enable_registers,
        "fmax_mhz": {
            "corners": fmax_values,
            "minimum": min(fmax_values) if fmax_values else None,
        },
        "power_mw": power_mw,
        "power_confidence": power_confidence,
        "power_warning_waivers": power_warning_waivers,
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
