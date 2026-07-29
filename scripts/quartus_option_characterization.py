#!/usr/bin/env python3
"""Validate four like-for-like Quartus option profiles and publish deltas."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
from typing import Any

import quartus_report_check


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
DEFAULT_OUTPUT = REPO_ROOT / "reports" / "generated" / "quartus-options.json"
PROFILES = ("none", "debug", "coprocessor", "both")


def summarize_profiles(
    profiles: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    if set(profiles) != set(PROFILES):
        raise ValueError(
            "option profiles must be exactly: " + ", ".join(PROFILES)
        )
    for name, report in profiles.items():
        if report.get("status") != "passed":
            raise ValueError(f"{name} option report did not pass")
        if report.get("top") != "arm7tdmi_mister":
            raise ValueError(f"{name} option report has wrong top")
        if report.get("device") != "5CSEBA6U23I7":
            raise ValueError(f"{name} option report has wrong device")

    baseline = profiles["none"]
    baseline_resources = baseline["resources"]
    deltas: dict[str, dict[str, float | int]] = {}
    for name in ("debug", "coprocessor", "both"):
        report = profiles[name]
        resources = report["resources"]
        deltas[name] = {
            "alm": resources["alm"] - baseline_resources["alm"],
            "register": (
                resources["register"] - baseline_resources["register"]
            ),
            "memory_bit": (
                resources["memory_bit"] - baseline_resources["memory_bit"]
            ),
            "dsp": resources["dsp"] - baseline_resources["dsp"],
            "fmax_mhz": round(
                report["fmax_mhz"]["minimum"]
                - baseline["fmax_mhz"]["minimum"],
                3,
            ),
            "core_dynamic_power_mw": round(
                report["power_mw"]["core_dynamic"]
                - baseline["power_mw"]["core_dynamic"],
                3,
            ),
        }

    return {
        "schema": "arm7tdmis-quartus-options-v1",
        "status": "passed",
        "device": "5CSEBA6U23I7",
        "top": "arm7tdmi_mister",
        "profiles": profiles,
        "deltas": deltas,
    }


def collect_profiles() -> dict[str, dict[str, Any]]:
    reports: dict[str, dict[str, Any]] = {}
    failures: list[str] = []
    for profile in PROFILES:
        project = f"arm7tdmi_option_{profile}"
        output_dir = REPO_ROOT / "fpga" / "option_output" / profile
        report, errors = quartus_report_check.validate_reports(
            output_dir,
            project=project,
            expected_top="arm7tdmi_mister",
            expected_device="5CSEBA6U23I7",
            resource_limits={
                "alm": 7_500,
                "register": 6_000,
                "dsp": 8,
                "memory_bit": 0,
            },
        )
        reports[profile] = report
        failures.extend(f"{profile}: {error}" for error in errors)
    if failures:
        raise ValueError("\n".join(failures))
    return reports


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=pathlib.Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()

    summary = summarize_profiles(collect_profiles())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_suffix(args.output.suffix + ".tmp")
    temporary.write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, args.output)
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
