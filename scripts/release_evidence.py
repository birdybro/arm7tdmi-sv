#!/usr/bin/env python3
"""Validate and archive immutable regression/coverage release evidence."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tarfile
from typing import Any


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
REPORT_ROOT = REPO_ROOT / "reports" / "generated"
MANIFEST_SCHEMA = "arm7tdmis-release-evidence-v1"
VERSION_PATH = REPO_ROOT / "VERSION"
TRM_PATH = REPO_ROOT / "ARM_DDI_0234B_ARM7TDMI-S_r4p3_TRM.pdf"
LICENSE_PATH = REPO_ROOT / "LICENSE"


def validate_evidence(
    regression: dict[str, Any],
    coverage: dict[str, Any],
    *,
    expected_commit: str,
) -> None:
    if regression.get("schema") != "arm7tdmis-regression-v1":
        raise ValueError("regression report has wrong schema")
    if regression.get("status") != "passed":
        raise ValueError("regression report is not passed")
    if coverage.get("schema") != "arm7tdmis-coverage-v1":
        raise ValueError("coverage report has wrong schema")
    for label, report in (("regression", regression), ("coverage", coverage)):
        git = report.get("git", {})
        if git.get("dirty"):
            raise ValueError(f"{label} evidence describes a dirty source tree")
        if git.get("commit") != expected_commit:
            raise ValueError(
                f"{label} evidence commit does not match {expected_commit}"
            )


def validate_soak_evidence(
    soak: dict[str, Any],
    *,
    expected_commit: str,
) -> None:
    """Reject incomplete, stale, weakened, or non-passing soak evidence."""
    if soak.get("schema") != "arm7tdmis-soak-v1":
        raise ValueError("soak report has wrong schema")
    if soak.get("status") != "passed" or soak.get("failures"):
        raise ValueError("soak report is not passed")
    if soak.get("git", {}).get("dirty"):
        raise ValueError("soak report describes a dirty source tree")
    if soak.get("git", {}).get("commit") != expected_commit:
        raise ValueError("soak report commit does not match regression")

    configuration = soak.get("configuration", {})
    sanitizer_environment = configuration.get("environment", {})
    sanitizers = configuration.get("sanitizers", [])
    dependencies = "\n".join(
        str(value)
        for value in soak.get("tools", {}).get("binary_dependencies", [])
    )
    if (
        configuration.get("x_assignment") != "unique"
        or configuration.get("x_initialization") != "unique"
        or not isinstance(sanitizers, list)
        or set(sanitizers) != {"address", "undefined"}
        or not isinstance(sanitizer_environment, dict)
        or "halt_on_error=1"
        not in str(sanitizer_environment.get("ASAN_OPTIONS", ""))
        or "halt_on_error=1"
        not in str(sanitizer_environment.get("UBSAN_OPTIONS", ""))
        or not isinstance(configuration.get("timeout_seconds"), (int, float))
        or configuration["timeout_seconds"] <= 0
        or "libasan" not in dependencies
        or "libubsan" not in dependencies
    ):
        raise ValueError("soak report lacks sanitizer/X-state evidence")

    seeds = soak.get("seeds", [])
    if not isinstance(seeds, list) or any(
        not isinstance(entry, dict) for entry in seeds
    ):
        raise ValueError("soak report has a malformed seed list")
    if (
        not isinstance(configuration.get("seed_count"), int)
        or configuration["seed_count"] < 256
        or soak.get("completed_seed_count") != len(seeds)
        or len(seeds) != configuration["seed_count"]
        or len({entry.get("seed") for entry in seeds}) != len(seeds)
    ):
        raise ValueError("soak report does not contain 256 unique seeds")
    if any(
        entry.get("status") != "passed"
        or entry.get("exit_code") != 0
        or not entry.get("pass_marker_found")
        for entry in seeds
    ):
        raise ValueError("soak report contains a non-passing seed")


def _sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _json_sha256(value: Any) -> str:
    """Hash a JSON value using a stable, whitespace-free representation."""
    payload = json.dumps(
        value,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def _git_commit() -> str:
    return subprocess.run(
        ("git", "rev-parse", "HEAD"),
        cwd=REPO_ROOT,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    ).stdout.strip()


def _git_tree_sha256() -> str:
    tree = subprocess.run(
        ("git", "ls-tree", "-r", "--full-tree", "HEAD"),
        cwd=REPO_ROOT,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    ).stdout
    return hashlib.sha256(tree).hexdigest()


def _git_status() -> str:
    return subprocess.run(
        ("git", "status", "--porcelain=v1", "--untracked-files=all"),
        cwd=REPO_ROOT,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    ).stdout.strip()


def _repo_path(path_text: str) -> pathlib.Path:
    path = pathlib.Path(path_text)
    resolved = path.resolve() if path.is_absolute() else (REPO_ROOT / path).resolve()
    try:
        resolved.relative_to(REPO_ROOT)
    except ValueError as error:
        raise ValueError(f"evidence path escapes repository: {path_text}") from error
    if not resolved.is_file():
        raise ValueError(f"evidence file is missing: {path_text}")
    return resolved


def _validated_files(
    regression: dict[str, Any],
    coverage: dict[str, Any],
    *,
    regression_path: pathlib.Path,
    coverage_path: pathlib.Path,
) -> list[pathlib.Path]:
    results = regression.get("results")
    if not isinstance(results, list) or not results:
        raise ValueError("regression report has no phase results")
    if regression.get("result_count") != len(results):
        raise ValueError("regression result_count does not match phase results")

    candidates = [regression_path.resolve(), coverage_path.resolve()]
    for result in results:
        if result.get("status") != "passed" or result.get("exit_code") != 0:
            raise ValueError("regression contains a non-passing phase")
        log_path = _repo_path(str(result.get("log", "")))
        if _sha256(log_path) != result.get("log_sha256"):
            raise ValueError(f"regression log hash mismatch: {result.get('log')}")
        candidates.append(log_path)

    artifacts = coverage.get("artifacts")
    if not isinstance(artifacts, dict) or not artifacts:
        raise ValueError("coverage report has no artifacts")
    for label, artifact in artifacts.items():
        artifact_path = _repo_path(str(artifact.get("path", "")))
        if artifact_path.stat().st_size != artifact.get("bytes"):
            raise ValueError(f"coverage {label} size mismatch")
        if _sha256(artifact_path) != artifact.get("sha256"):
            raise ValueError(f"coverage {label} hash mismatch")
        candidates.append(artifact_path)

    if not coverage.get("tests"):
        raise ValueError("coverage report lists no measured tests")
    candidates.extend(
        path.resolve()
        for path in coverage_path.parent.rglob("*")
        if path.is_file()
    )
    phase_names = {str(result.get("name")) for result in results}
    traceability_report = REPORT_ROOT / "traceability-report.json"
    if "traceability" not in phase_names:
        raise ValueError("regression did not run mandatory traceability")
    if not traceability_report.is_file():
        raise ValueError("traceability report is missing")
    traceability = json.loads(
        traceability_report.read_text(encoding="utf-8")
    )
    if traceability.get("schema") != "arm7tdmis-traceability-v1":
        raise ValueError("traceability report has wrong schema")
    if traceability.get("git", {}).get("dirty"):
        raise ValueError("traceability report describes a dirty source tree")
    if traceability.get("git", {}).get("commit") != regression.get(
        "git", {}
    ).get("commit"):
        raise ValueError("traceability report commit does not match regression")
    if (
        traceability.get("unmapped_rtl")
        or traceability.get("unmapped_verification")
        or traceability.get("unknown_requirement_references")
    ):
        raise ValueError("traceability report contains unmapped evidence")
    for input_entry in traceability.get("inputs", {}).values():
        if not isinstance(input_entry, dict):
            continue
        input_path = _repo_path(str(input_entry.get("path", "")))
        if _sha256(input_path) != input_entry.get("sha256"):
            raise ValueError(
                f"traceability input hash mismatch: {input_entry.get('path')}"
            )
    candidates.append(traceability_report.resolve())
    option_report = REPORT_ROOT / "quartus-options.json"
    if "quartus-option-characterization" in phase_names:
        if not option_report.is_file():
            raise ValueError("option characterization report is missing")
        candidates.append(option_report.resolve())
    if "integration-qemu_diff" in phase_names:
        qemu_directory = REPORT_ROOT / "qemu_diff"
        if not (qemu_directory / "metadata.json").is_file():
            raise ValueError("QEMU differential metadata is missing")
        candidates.extend(
            path.resolve()
            for path in qemu_directory.rglob("*")
            if path.is_file()
        )
    if "integration-compiler" in phase_names:
        compiler_directory = REPORT_ROOT / "compiler"
        if not (compiler_directory / "metadata.json").is_file():
            raise ValueError("compiler-program metadata is missing")
        candidates.extend(
            path.resolve()
            for path in compiler_directory.rglob("*")
            if path.is_file()
        )
    if "soak" in phase_names:
        soak_path = REPORT_ROOT / "soak-report.json"
        if not soak_path.is_file():
            raise ValueError("soak report is missing")
        soak = json.loads(soak_path.read_text(encoding="utf-8"))
        validate_soak_evidence(
            soak,
            expected_commit=str(regression.get("git", {}).get("commit", "")),
        )
        for input_entry in soak.get("inputs", {}).values():
            if not isinstance(input_entry, dict):
                raise ValueError("soak report has a malformed input")
            input_path = _repo_path(str(input_entry.get("path", "")))
            if input_path.stat().st_size != input_entry.get("bytes"):
                raise ValueError(
                    f"soak input size mismatch: {input_entry.get('path')}"
                )
            if _sha256(input_path) != input_entry.get("sha256"):
                raise ValueError(
                    f"soak input hash mismatch: {input_entry.get('path')}"
                )
            candidates.append(input_path)
        candidates.append(soak_path.resolve())
    return sorted(set(candidates))


def _file_entry(path: pathlib.Path) -> dict[str, Any]:
    resolved = path.resolve()
    return {
        "path": resolved.relative_to(REPO_ROOT).as_posix(),
        "bytes": resolved.stat().st_size,
        "sha256": _sha256(resolved),
    }


def _tool_executable_manifest(tools: dict[str, str]) -> dict[str, Any]:
    commands = {
        "clang": "clang",
        "git": "git",
        "make": "make",
        "python": sys.executable,
        "qemu": "qemu-system-arm",
        "quartus": "quartus_map",
        "verilator": "verilator",
    }
    executables: dict[str, Any] = {}
    for label in sorted(tools):
        command = commands.get(label)
        if command is None:
            continue
        located = (
            pathlib.Path(command)
            if pathlib.Path(command).is_absolute()
            else pathlib.Path(found)
            if (found := shutil.which(command))
            else None
        )
        if located is None or not located.is_file():
            executables[label] = {
                "command": command,
                "status": "not-found",
            }
            continue
        resolved = located.resolve()
        executables[label] = {
            "command": command,
            "path": str(resolved),
            "bytes": resolved.stat().st_size,
            "sha256": _sha256(resolved),
        }
    return executables


def build_manifest(
    *,
    candidates: list[pathlib.Path],
    git_commit: str,
    source_sha256: str,
    tools: dict[str, str],
    created_utc: str,
) -> dict[str, Any]:
    """Build the canonical release manifest without writing any artifacts."""
    version = VERSION_PATH.read_text(encoding="utf-8").strip()
    executable_manifest = _tool_executable_manifest(tools)
    specifications = [_file_entry(TRM_PATH), _file_entry(LICENSE_PATH)]
    return {
        "schema": MANIFEST_SCHEMA,
        "version": version,
        "created_utc": created_utc,
        # Retained for v1 manifest-reader compatibility.
        "git_commit": git_commit,
        "source": {
            "git_commit": git_commit,
            "git_tree_sha256": _git_tree_sha256(),
            "source_sha256": source_sha256,
        },
        "tools": {
            "versions": tools,
            "versions_sha256": _json_sha256(tools),
            "executables": executable_manifest,
            "executables_sha256": _json_sha256(executable_manifest),
        },
        "specifications": specifications,
        "files": [_file_entry(path) for path in sorted(set(candidates))],
    }


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--regression",
        type=pathlib.Path,
        default=REPORT_ROOT / "regression.json",
    )
    parser.add_argument(
        "--coverage",
        type=pathlib.Path,
        default=REPORT_ROOT / "coverage" / "coverage.json",
    )
    parser.add_argument(
        "--output",
        type=pathlib.Path,
        default=None,
    )
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    commit = _git_commit()
    if _git_status():
        raise ValueError("current source tree is dirty")
    regression = json.loads(args.regression.read_text(encoding="utf-8"))
    coverage = json.loads(args.coverage.read_text(encoding="utf-8"))
    validate_evidence(regression, coverage, expected_commit=commit)
    if regression["git"].get("source_sha256") != coverage["git"].get(
        "source_sha256"
    ):
        raise ValueError("regression and coverage source digests do not match")

    import regression_harness

    if regression["git"].get("source_sha256") != regression_harness._source_digest():
        raise ValueError("current source digest does not match evidence")

    candidates = _validated_files(
        regression,
        coverage,
        regression_path=args.regression,
        coverage_path=args.coverage,
    )

    manifest = build_manifest(
        candidates=candidates,
        git_commit=commit,
        source_sha256=regression["git"]["source_sha256"],
        tools=regression["tools"],
        created_utc=dt.datetime.now(dt.UTC).isoformat(timespec="seconds"),
    )
    manifest_path = REPORT_ROOT / "release-manifest.json"
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_temporary = manifest_path.with_suffix(".json.tmp")
    manifest_temporary.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.replace(manifest_temporary, manifest_path)
    candidates.append(manifest_path.resolve())

    output = args.output or (
        REPORT_ROOT / f"arm7tdmis-release-evidence-{commit[:12]}.tar.gz"
    )
    output.parent.mkdir(parents=True, exist_ok=True)
    output_temporary = output.with_suffix(output.suffix + ".tmp")
    with tarfile.open(output_temporary, "w:gz") as archive:
        for path in candidates:
            archive.add(path, arcname=str(path.relative_to(REPO_ROOT)))
    os.replace(output_temporary, output)
    digest_path = output.with_suffix(output.suffix + ".sha256")
    digest_temporary = digest_path.with_suffix(digest_path.suffix + ".tmp")
    digest_temporary.write_text(
        f"{_sha256(output)}  {output.name}\n", encoding="utf-8"
    )
    os.replace(digest_temporary, digest_path)
    print(
        f"[release-evidence] wrote {output} "
        f"with {len(candidates)} hashed files"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
