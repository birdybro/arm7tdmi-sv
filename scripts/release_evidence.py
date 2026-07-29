#!/usr/bin/env python3
"""Validate and archive immutable regression/coverage release evidence."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import pathlib
import subprocess
import tarfile
from typing import Any


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent
REPORT_ROOT = REPO_ROOT / "reports" / "generated"
MANIFEST_SCHEMA = "arm7tdmis-release-evidence-v1"


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


def _sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _git_commit() -> str:
    return subprocess.run(
        ("git", "rev-parse", "HEAD"),
        cwd=REPO_ROOT,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    ).stdout.strip()


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
    return sorted(set(candidates))


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

    manifest = {
        "schema": MANIFEST_SCHEMA,
        "created_utc": dt.datetime.now(dt.UTC).isoformat(timespec="seconds"),
        "git_commit": commit,
        "files": [
            {
                "path": str(path.relative_to(REPO_ROOT)),
                "bytes": path.stat().st_size,
                "sha256": _sha256(path),
            }
            for path in candidates
        ],
    }
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
