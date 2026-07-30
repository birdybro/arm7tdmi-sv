#!/usr/bin/env python3
"""Validate the revision-locked Chapter 8/Table 8-1 FPGA disposition."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import pathlib
import re
import subprocess
from typing import Any


REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_MANIFEST = REPO_ROOT / "verification" / "ac_timing.json"
DEFAULT_OUTPUT = REPO_ROOT / "reports" / "generated" / "ac-timing-report.json"
SCHEMA = "arm7tdmis-ac-timing-map-v1"
REPORT_SCHEMA = "arm7tdmis-ac-timing-v1"
SOURCE_IDENTITY = {
    "document": "ARM DDI 0234B",
    "revision": "ARM7TDMI-S r4p3",
    "path": "ARM_DDI_0234B_ARM7TDMI-S_r4p3_TRM.pdf",
    "pages": 242,
    "bytes": 1477711,
    "sha256": "bb9cd0e3f2b7e2fdca4ff961cdfc5c9c85c063842e491f8997a504d3241baa14",
    "section": "8.2",
    "table": "8-1",
    "printed_pages": ["8-8", "8-9"],
    "title": "Provisional AC parameters",
}
TARGET_IDENTITY = {
    "profile": "raw-feature-complete",
    "top": "arm7tdmis_top",
    "device": "5CSEBA6U23I7",
    "tool": "Quartus Lite 17.0.2",
    "sdc": "fpga/arm7tdmis_conformance.sdc",
    "clock_port": "CLK",
    "clock_period_ns": 40.0,
    "clock_mhz": 25.0,
    "input_translation": (
        "max input delay = period - source setup fraction; min input delay "
        "= 0 ns for a source 0% maximum hold"
    ),
    "output_translation": (
        "max output delay = period - source clock-to-valid fraction; min "
        "output delay = 0 ns and routed hold slack must remain positive for "
        "source >0% holds"
    ),
}

# symbol, parameter, source min, source max, figure, source signals,
# SDC kind, target delay/period, SDC port collection.
EXPECTED_ROWS = (
    ("tcyc", "CLK cycle time", "100%", "-", "8-1", ("CLK",),
     "clock", 40.0, ("CLK",)),
    ("tisclken", "CLKEN input setup to rising CLK", "40%", "-", "8-1",
     ("CLKEN",), "input-max", 24.0, ("CLKEN",)),
    ("tihclken", "CLKEN input hold from rising CLK", "-", "0%", "8-1",
     ("CLKEN",), "input-min", 0.0, ("CLKEN",)),
    ("tisabort", "ABORT input setup to rising CLK", "15%", "-", "8-1",
     ("ABORT",), "input-max", 34.0, ("ABORT",)),
    ("tihabort", "ABORT input hold from rising CLK", "-", "0%", "8-1",
     ("ABORT",), "input-min", 0.0, ("ABORT",)),
    ("tisrdata", "RDATA input setup to rising CLK", "10%", "-", "8-1",
     ("RDATA[31:0]",), "input-max", 36.0, ("RDATA[*]",)),
    ("tihrdata", "RDATA input hold from rising CLK", "-", "0%", "8-1",
     ("RDATA[31:0]",), "input-min", 0.0, ("RDATA[*]",)),
    ("tovaddr", "Rising CLK to ADDR valid", "-", "90%", "8-1",
     ("ADDR[31:0]",), "output-max", 4.0, ("ADDR[*]",)),
    ("tohaddr", "ADDR hold time from rising CLK", ">0%", "-", "8-1",
     ("ADDR[31:0]",), "output-min", 0.0, ("ADDR[*]",)),
    ("tovctl", "Rising CLK to control valid", "-", "90%", "8-1",
     ("WRITE", "SIZE[1:0]", "PROT[1:0]", "LOCK"), "output-max", 4.0,
     ("WRITE", "SIZE[*]", "PROT[*]", "LOCK")),
    ("tohctl", "Control hold time from rising CLK", ">0%", "-", "8-1",
     ("WRITE", "SIZE[1:0]", "PROT[1:0]", "LOCK"), "output-min", 0.0,
     ("WRITE", "SIZE[*]", "PROT[*]", "LOCK")),
    ("tovtrans", "Rising CLK to transaction type valid", "-", "50%", "8-1",
     ("TRANS[1:0]",), "output-max", 20.0, ("TRANS[*]",)),
    ("tohtrans", "Transaction type hold time from rising CLK", ">0%", "-",
     "8-1", ("TRANS[1:0]",), "output-min", 0.0, ("TRANS[*]",)),
    ("tovwdata", "Rising CLK to WDATA valid", "-", "40%", "8-1",
     ("WDATA[31:0]",), "output-max", 24.0, ("WDATA[*]",)),
    ("tohwdata", "WDATA hold time from rising CLK", ">0%", "-", "8-1",
     ("WDATA[31:0]",), "output-min", 0.0, ("WDATA[*]",)),
    ("tiscpstat", "CPA, CPB input setup to rising CLK", "20%", "-", "8-2",
     ("CPA", "CPB"), "input-max", 32.0, ("CPA", "CPB")),
    ("tihcpstat", "CPA, CPB input hold from rising CLK", "-", "0%", "8-2",
     ("CPA", "CPB"), "input-min", 0.0, ("CPA", "CPB")),
    ("tovcpctl", "Rising CLK to coprocessor control valid", "-", "80%",
     "8-2", ("CPnMREQ", "CPSEQ", "CPnOPC", "CPnTRANS", "CPTBIT"),
     "output-max", 8.0,
     ("CPnMREQ", "CPSEQ", "CPnOPC", "CPnTRANS", "CPTBIT")),
    ("tohcpctl", "Coprocessor control hold time from rising CLK", ">0%", "-",
     "8-2", ("CPnMREQ", "CPSEQ", "CPnOPC", "CPnTRANS", "CPTBIT"),
     "output-min", 0.0,
     ("CPnMREQ", "CPSEQ", "CPnOPC", "CPnTRANS", "CPTBIT")),
    ("tovcpni", "Rising CLK to coprocessor CPnI valid", "-", "40%", "8-2",
     ("CPnI",), "output-max", 24.0, ("CPnI",)),
    ("tohcpni", "Coprocessor CPnI hold time from rising CLK", ">0%", "-",
     "8-2", ("CPnI",), "output-min", 0.0, ("CPnI",)),
    ("tisexc", "nFIQ, nIRQ, nRESET setup to rising CLK", "10%", "-", "8-3",
     ("nFIQ", "nIRQ", "nRESET"), "input-max", 36.0, ("nFIQ", "nIRQ")),
    ("tihexc", "nFIQ, nIRQ, nRESET hold from rising CLK", "-", "0%", "8-3",
     ("nFIQ", "nIRQ", "nRESET"), "input-min", 0.0, ("nFIQ", "nIRQ")),
    ("tiscfg", "CFGBIGEND setup to rising CLK", "10%", "-", "8-3",
     ("CFGBIGEND",), "input-max", 36.0, ("CFGBIGEND",)),
    ("tihcfg", "CFGBIGEND hold from rising CLK", "-", "0%", "8-3",
     ("CFGBIGEND",), "input-min", 0.0, ("CFGBIGEND",)),
    ("tisdbgstat", "Debug status inputs setup to rising CLK", "10%", "-",
     "8-4", ("DBGRQ", "DBGBREAK", "DBGEXT[1:0]"), "input-max", 36.0,
     ("DBGRQ", "DBGBREAK", "DBGEXT[*]")),
    ("tihdbgstat", "Debug status inputs hold from rising CLK", "-", "0%",
     "8-4", ("DBGRQ", "DBGBREAK", "DBGEXT[1:0]"), "input-min", 0.0,
     ("DBGRQ", "DBGBREAK", "DBGEXT[*]")),
    ("tovdbgctl", "Rising CLK to debug control valid", "-", "40%", "8-4",
     ("DBGACK", "DBGCOMMTX", "DBGCOMMRX"), "output-max", 24.0,
     ("DBGACK", "DBGCOMMTX", "DBGCOMMRX")),
    ("tohdbctl", "Debug control hold time from rising CLK", ">0%", "-", "8-4",
     ("DBGACK", "DBGCOMMTX", "DBGCOMMRX"), "output-min", 0.0,
     ("DBGACK", "DBGCOMMTX", "DBGCOMMRX")),
    ("tistcken", "DBGTCKEN input setup to rising CLK", "40%", "-", "8-5",
     ("DBGTCKEN",), "input-max", 24.0, ("DBGTCKEN",)),
    ("tihtcken", "DBGTCKEN input hold from rising CLK", "-", "0%", "8-5",
     ("DBGTCKEN",), "input-min", 0.0, ("DBGTCKEN",)),
    ("tistctl", "DBGTDI, DBGTMS input setup to rising CLK", "35%", "-", "8-5",
     ("DBGTDI", "DBGTMS"), "input-max", 26.0, ("DBGTDI", "DBGTMS")),
    ("tihtctl", "DBGTDI, DBGTMS input hold from rising CLK", "-", "0%",
     "8-5", ("DBGTDI", "DBGTMS"), "input-min", 0.0,
     ("DBGTDI", "DBGTMS")),
    ("tovtdo", "Rising CLK to DBGTDO valid", "-", "20%", "8-5",
     ("DBGTDO",), "output-max", 32.0, ("DBGTDO",)),
    ("tohtdo", "DBGTDO hold time from rising CLK", ">0%", "-", "8-5",
     ("DBGTDO",), "output-min", 0.0, ("DBGTDO",)),
    ("tovdbgstat", "Rising CLK to debug status valid", "-", "40%", "8-4",
     ("DBGRNG[1:0]",), "output-max", 24.0, ("DBGRNG[*]",)),
    ("tohdbgstat", "Debug status hold time", ">0%", "-", "8-4",
     ("DBGRNG[1:0]",), "output-min", 0.0, ("DBGRNG[*]",)),
)

EXPECTED_FIGURE_ROWS = {
    "8-1": tuple(row[0] for row in EXPECTED_ROWS if row[4] == "8-1" and row[0] != "tcyc"),
    "8-2": tuple(row[0] for row in EXPECTED_ROWS if row[4] == "8-2"),
    "8-3": tuple(row[0] for row in EXPECTED_ROWS if row[4] == "8-3"),
    "8-4": tuple(row[0] for row in EXPECTED_ROWS if row[4] == "8-4"),
    "8-5": tuple(row[0] for row in EXPECTED_ROWS if row[4] == "8-5"),
}
EXPECTED_FIGURE_TITLES = {
    "8-1": "Timing parameters for data accesses",
    "8-2": "Coprocessor timing",
    "8-3": "Exception and configuration input timing",
    "8-4": "Debug timing",
    "8-5": "Scan timing",
}
EXPECTED_FIGURE_SYMBOLS = {
    "tisdbgstat": "tisdbgctl",
    "tihdbgstat": "tihdbgctl",
    "tovdbgctl": "tovdbgstat",
    "tohdbctl": "tohdbgstat",
    "tovdbgstat": "tovdbgstat",
    "tohdbgstat": "tohdbgstat",
}
EXPECTED_INTEGRATION_OWNERS = {
    "clock": ("CLK",),
    "reset": ("nRESET", "DBGnTRST"),
    "debug-synchronization": (
        "DBGRQ", "DBGBREAK", "DBGEXT[1:0]", "DBGTCKEN", "DBGTDI", "DBGTMS"
    ),
    "atpg-test": ("SCANENABLE", "SCANIN", "SCANOUT"),
    "power": ("VDD", "VSS"),
}
EXPECTED_NON_TABLE_PORTS = {
    "inputs": ("DBGEN",),
    "outputs": ("DBGnEXEC", "DBGINSTRVALID", "DBGnTDOEN", "DMORE"),
    "asynchronous": ("DBGnTRST",),
}


def _sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _commands(text: str) -> list[str]:
    commands: list[str] = []
    current = ""
    brace_depth = 0
    bracket_depth = 0
    for raw_line in text.splitlines():
        line = raw_line.split("#", maxsplit=1)[0].strip()
        if not line:
            continue
        current = f"{current} {line}".strip()
        brace_depth += line.count("{") - line.count("}")
        bracket_depth += line.count("[") - line.count("]")
        if brace_depth == 0 and bracket_depth == 0:
            commands.append(current)
            current = ""
    if current:
        raise ValueError("SDC ends with an incomplete Tcl command")
    return commands


def _delay_constraints(text: str) -> dict[tuple[str, str, tuple[str, ...]], float]:
    result: dict[tuple[str, str, tuple[str, ...]], float] = {}
    pattern = re.compile(
        r"^set_(input|output)_delay -clock CLK -(min|max) "
        r"([0-9]+(?:\.[0-9]+)?) \[get_ports \{([^}]*)\}\]$"
    )
    for command in _commands(text):
        match = pattern.match(command)
        if not match:
            continue
        key = (
            match.group(1),
            match.group(2),
            tuple(match.group(4).split()),
        )
        if key in result:
            raise ValueError(f"duplicate SDC delay constraint: {key}")
        result[key] = float(match.group(3))
    return result


def _validate_scope(contract: dict[str, Any]) -> None:
    scope = contract.get("scope")
    if not isinstance(scope, dict) or set(scope) != {
        "source_units", "supplier_dependency", "implementation_scope", "fpga_claim"
    }:
        raise ValueError("AC timing physical scope is incomplete")
    joined = " ".join(str(value).lower() for value in scope.values())
    for term in ("percent", "supplier", "provisional", "synthesized", "not a portable"):
        if term not in joined:
            raise ValueError(f"AC timing physical scope lost required caveat: {term}")


def _validate_figures(contract: dict[str, Any]) -> None:
    figures = contract.get("figure_groups")
    if not isinstance(figures, list) or len(figures) != 5:
        raise ValueError("Chapter 8 figure disposition is incomplete")
    actual: dict[str, tuple[str, tuple[str, ...]]] = {}
    for item in figures:
        if not isinstance(item, dict):
            raise ValueError("Chapter 8 figure disposition is malformed")
        figure = item.get("figure")
        if figure in actual:
            raise ValueError(f"duplicate Chapter 8 figure disposition: {figure}")
        actual[str(figure)] = (
            str(item.get("title")),
            tuple(item.get("rows", [])),
        )
    expected = {
        figure: (EXPECTED_FIGURE_TITLES[figure], rows)
        for figure, rows in EXPECTED_FIGURE_ROWS.items()
    }
    if actual != expected:
        raise ValueError("Chapter 8 figure-to-row mapping changed")


def _validate_ownership(contract: dict[str, Any]) -> None:
    entries = contract.get("integration_owned")
    if not isinstance(entries, list):
        raise ValueError("integration-owned timing categories are missing")
    actual: dict[str, tuple[str, ...]] = {}
    for entry in entries:
        if not isinstance(entry, dict) or not str(entry.get("disposition", "")).strip():
            raise ValueError("integration-owned timing category is malformed")
        entry_id = str(entry.get("id"))
        if entry_id in actual:
            raise ValueError(f"duplicate integration-owned category: {entry_id}")
        actual[entry_id] = tuple(entry.get("signals", []))
    if actual != EXPECTED_INTEGRATION_OWNERS:
        raise ValueError("clock/reset/debug/test/power ownership changed")

    non_table = contract.get("non_table_raw_ports")
    if not isinstance(non_table, dict) or set(non_table) != set(EXPECTED_NON_TABLE_PORTS):
        raise ValueError("non-Table-8 raw-port disposition is incomplete")
    for category, ports in EXPECTED_NON_TABLE_PORTS.items():
        entry = non_table[category]
        if (
            not isinstance(entry, dict)
            or tuple(entry.get("ports", [])) != ports
            or not str(entry.get("disposition", "")).strip()
        ):
            raise ValueError(f"non-Table-8 {category} disposition changed")


def validate_contract(
    contract: dict[str, Any],
    *,
    sdc_text: str | None = None,
    verify_source: bool = True,
) -> dict[str, Any]:
    if contract.get("schema") != SCHEMA:
        raise ValueError("AC timing manifest has wrong schema")
    if contract.get("source") != SOURCE_IDENTITY:
        raise ValueError("AC timing source identity changed")
    if contract.get("target") != TARGET_IDENTITY:
        raise ValueError("AC timing FPGA target/translation changed")
    _validate_scope(contract)
    _validate_figures(contract)
    _validate_ownership(contract)

    if verify_source:
        source = REPO_ROOT / SOURCE_IDENTITY["path"]
        if (
            not source.is_file()
            or source.stat().st_size != SOURCE_IDENTITY["bytes"]
            or _sha256(source) != SOURCE_IDENTITY["sha256"]
        ):
            raise ValueError("TRM PDF identity does not match the audited revision")

    rows = contract.get("rows")
    if not isinstance(rows, list) or len(rows) != len(EXPECTED_ROWS):
        raise ValueError(f"Table 8-1 must contain exactly {len(EXPECTED_ROWS)} rows")
    symbols = [row.get("symbol") for row in rows if isinstance(row, dict)]
    expected_symbols = [row[0] for row in EXPECTED_ROWS]
    if symbols != expected_symbols or len(symbols) != len(set(symbols)):
        raise ValueError("Table 8-1 row order/set changed")

    positive_hold_rows = 0
    replacement_count = 0
    for actual, expected in zip(rows, EXPECTED_ROWS, strict=True):
        (
            symbol, parameter, source_min, source_max, figure, signals,
            kind, delay, ports,
        ) = expected
        for field, value in (
            ("symbol", symbol),
            ("parameter", parameter),
            ("source_min", source_min),
            ("source_max", source_max),
            ("figure", figure),
        ):
            if actual.get(field) != value:
                raise ValueError(f"Table 8-1 {symbol} {field} changed")
        if tuple(actual.get("signals", [])) != signals:
            raise ValueError(f"Table 8-1 {symbol} signal mapping changed")

        target_sdc = actual.get("target_sdc")
        if not isinstance(target_sdc, dict):
            raise ValueError(f"Table 8-1 {symbol} has no target SDC mapping")
        expected_target: dict[str, Any] = {"kind": kind, "ports": list(ports)}
        if kind == "clock":
            expected_target["period_ns"] = delay
        else:
            expected_target["delay_ns"] = delay
        if kind == "output-min":
            expected_target["requires_positive_routed_hold_slack"] = True
            positive_hold_rows += 1
        if target_sdc != expected_target:
            raise ValueError(f"Table 8-1 {symbol} target SDC mapping changed")

        figure_symbol = actual.get("figure_symbol")
        if symbol in EXPECTED_FIGURE_SYMBOLS:
            if figure_symbol != EXPECTED_FIGURE_SYMBOLS[symbol]:
                raise ValueError(f"Figure 8-4 symbol conflict mapping changed: {symbol}")
        elif figure_symbol is not None:
            raise ValueError(f"unexpected alternate figure symbol on {symbol}")

        replacements = actual.get("replaced_signals", [])
        if symbol in {"tisexc", "tihexc"}:
            expected_replacement = [{
                "signal": "nRESET",
                "owner": (
                    "architectural asynchronous-assert/synchronous-release "
                    "reset contract"
                ),
                "sdc_marker": "AC-OWN:reset",
            }]
            if replacements != expected_replacement:
                raise ValueError(f"Table 8-1 {symbol} reset replacement changed")
            replacement_count += len(replacements)
        elif replacements:
            raise ValueError(f"unexpected replacement on Table 8-1 {symbol}")

    notes = contract.get("source_notes")
    if not isinstance(notes, dict) or set(notes) != {
        "zero_hold", "control_group", "debug_label_conflict"
    }:
        raise ValueError("Table 8-1 source notes are incomplete")
    if "tohdbctl" not in notes["debug_label_conflict"]:
        raise ValueError("Table/Figure 8-4 symbol conflict caveat disappeared")

    if sdc_text is None:
        sdc_path = REPO_ROOT / TARGET_IDENTITY["sdc"]
        if not sdc_path.is_file():
            raise ValueError("target SDC is missing")
        sdc_text = sdc_path.read_text(encoding="utf-8")
    constraints = _delay_constraints(sdc_text)
    for expected in EXPECTED_ROWS:
        symbol, *_, kind, delay, ports = expected
        marker = f"AC-T8:{symbol}"
        if sdc_text.count(marker) != 1:
            raise ValueError(f"SDC must contain exactly one {marker} marker")
        if kind == "clock":
            clock_pattern = re.compile(
                r"create_clock -name CLK -period 40\.000 "
                r"\[get_ports \{CLK\}\]"
            )
            if not clock_pattern.search(sdc_text):
                raise ValueError("tcyc target clock constraint changed")
            continue
        direction, delay_kind = kind.split("-", maxsplit=1)
        key = (direction, delay_kind, ports)
        if constraints.get(key) != delay:
            raise ValueError(
                f"SDC constraint for {symbol} changed: "
                f"expected {key}={delay}, got {constraints.get(key)}"
            )
    if sdc_text.count("AC-OWN:reset") < 1:
        raise ValueError("reset replacement SDC marker is missing")
    false_paths = " ".join(
        command for command in _commands(sdc_text)
        if command.startswith("set_false_path")
    )
    for reset in ("nRESET", "DBGnTRST"):
        if reset not in false_paths:
            raise ValueError(f"asynchronous reset is not false-pathed: {reset}")
    for marker in ("AC-NONTABLE:input", "AC-NONTABLE:output"):
        if sdc_text.count(marker) != 1:
            raise ValueError(f"non-Table-8 target marker changed: {marker}")

    return {
        "table_row_count": len(rows),
        "figure_count": len(EXPECTED_FIGURE_ROWS),
        "sdc_mapped_row_count": len(rows),
        "positive_hold_row_count": positive_hold_rows,
        "replacement_signal_count": replacement_count,
        "integration_owner_count": len(EXPECTED_INTEGRATION_OWNERS),
        "symbols": expected_symbols,
    }


def _git(*arguments: str) -> str:
    return subprocess.run(
        ("git", *arguments),
        cwd=REPO_ROOT,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    ).stdout.strip()


def _git_metadata() -> dict[str, Any]:
    return {
        "commit": _git("rev-parse", "HEAD"),
        "dirty": bool(_git("status", "--porcelain", "--untracked-files=all")),
    }


def build_report(manifest_path: pathlib.Path = DEFAULT_MANIFEST) -> dict[str, Any]:
    contract = json.loads(manifest_path.read_text(encoding="utf-8"))
    summary = validate_contract(contract)
    sdc_path = REPO_ROOT / TARGET_IDENTITY["sdc"]
    return {
        "schema": REPORT_SCHEMA,
        "generated_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
        "git": _git_metadata(),
        "source": SOURCE_IDENTITY,
        "target": TARGET_IDENTITY,
        "manifest": {
            "path": str(manifest_path.resolve().relative_to(REPO_ROOT)),
            "sha256": _sha256(manifest_path),
        },
        "sdc": {
            "path": TARGET_IDENTITY["sdc"],
            "sha256": _sha256(sdc_path),
        },
        **summary,
    }


def validate_report(
    report: dict[str, Any],
    *,
    expected_commit: str | None = None,
    require_clean: bool = False,
) -> None:
    if report.get("schema") != REPORT_SCHEMA:
        raise ValueError("AC timing report has wrong schema")
    if report.get("source") != SOURCE_IDENTITY:
        raise ValueError("AC timing report source identity changed")
    if report.get("target") != TARGET_IDENTITY:
        raise ValueError("AC timing report target identity changed")
    if report.get("table_row_count") != len(EXPECTED_ROWS):
        raise ValueError("AC timing report row count changed")
    git = report.get("git", {})
    if expected_commit is not None and git.get("commit") != expected_commit:
        raise ValueError("AC timing report commit does not match regression")
    if require_clean and git.get("dirty"):
        raise ValueError("AC timing report describes a dirty source tree")


def _write_json(path: pathlib.Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, path)


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--manifest", type=pathlib.Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--output", type=pathlib.Path, default=DEFAULT_OUTPUT)
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    try:
        report = build_report(args.manifest.resolve())
        validate_report(report)
        _write_json(args.output.resolve(), report)
    except (OSError, ValueError, json.JSONDecodeError, subprocess.CalledProcessError) as exc:
        print(f"[ac-timing] FAIL: {exc}")
        return 1
    print(
        "[ac-timing] PASS "
        f"({report['table_row_count']} Table 8-1 rows, "
        f"{report['figure_count']} figures, "
        f"{report['integration_owner_count']} integration-owner categories)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
