#!/usr/bin/env python3
"""Fetch, verify, adapt, and run pinned redistributable ARMv4T suites."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import pathlib
import re
import shlex
import shutil
import subprocess
import sys
from collections.abc import Sequence
from typing import Any


SCHEMA = "arm7tdmis-public-suite-v1"
REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_MANIFEST = pathlib.Path(__file__).with_name("public_suites.json")
PASS_PATTERN = re.compile(
    r"\[public_suite\] PASS retirements=(\d+) arm=(\d+) thumb=(\d+) "
    r"vram_signature=([0-9a-fA-F]{8}) idle_pc=([0-9a-fA-F]{8})"
)


class CommandFailure(RuntimeError):
    def __init__(
        self,
        command: Sequence[str],
        returncode: int,
        output: str,
    ) -> None:
        self.command = tuple(command)
        self.returncode = returncode
        self.output = output
        super().__init__(
            f"command exited {returncode}: {shlex.join(self.command)}\n"
            f"{output}"
        )


def utc_now() -> str:
    return dt.datetime.now(dt.UTC).isoformat(timespec="seconds")


def sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run_command(
    command: Sequence[str],
    *,
    cwd: pathlib.Path = REPO_ROOT,
    timeout: float = 180.0,
) -> str:
    command_tuple = tuple(str(part) for part in command)
    try:
        result = subprocess.run(
            command_tuple,
            cwd=cwd,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as error:
        output = error.stdout or ""
        if isinstance(output, bytes):
            output = output.decode(errors="replace")
        raise CommandFailure(command_tuple, 124, output) from error
    if result.returncode:
        raise CommandFailure(command_tuple, result.returncode, result.stdout)
    return result.stdout


def git_text(*arguments: str, cwd: pathlib.Path = REPO_ROOT) -> str:
    return run_command(("git", *arguments), cwd=cwd).strip()


def write_json(path: pathlib.Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, path)


def file_entry(path: pathlib.Path) -> dict[str, Any]:
    resolved = path.resolve()
    return {
        "path": resolved.relative_to(REPO_ROOT).as_posix(),
        "bytes": resolved.stat().st_size,
        "sha256": sha256(resolved),
    }


def artifact_entry(
    path: pathlib.Path,
    artifact_root: pathlib.Path,
) -> dict[str, Any]:
    return {
        "path": path.resolve().relative_to(
            artifact_root.resolve()
        ).as_posix(),
        "bytes": path.stat().st_size,
        "sha256": sha256(path),
    }


def verify_checkout(
    checkout: pathlib.Path,
    manifest: dict[str, Any],
) -> None:
    upstream = manifest["upstream"]
    if git_text("rev-parse", "HEAD", cwd=checkout) != upstream["commit"]:
        raise ValueError("public-suite checkout has the wrong commit")
    if (
        git_text("rev-parse", "HEAD^{tree}", cwd=checkout)
        != upstream["tree"]
    ):
        raise ValueError("public-suite checkout has the wrong tree")
    if git_text("status", "--porcelain=v1", cwd=checkout):
        raise ValueError("public-suite checkout is dirty")
    remote = git_text("remote", "get-url", "origin", cwd=checkout)
    if remote != upstream["url"]:
        raise ValueError("public-suite checkout has the wrong origin")
    license_path = checkout / upstream["license_path"]
    if sha256(license_path) != upstream["license_sha256"]:
        raise ValueError("public-suite license_sha256 mismatch")
    if "MIT License" not in license_path.read_text(encoding="utf-8"):
        raise ValueError("public-suite license is not the recorded MIT text")
    for suite in manifest["suites"].values():
        if sha256(checkout / suite["path"]) != suite["upstream_sha256"]:
            raise ValueError("public-suite upstream ROM hash mismatch")


def acquire_checkout(
    cache_root: pathlib.Path,
    manifest: dict[str, Any],
) -> tuple[pathlib.Path, list[list[str]]]:
    upstream = manifest["upstream"]
    checkout = cache_root / f"gba-suite-{upstream['commit']}"
    commands: list[list[str]] = []
    if checkout.is_dir():
        try:
            verify_checkout(checkout, manifest)
            return checkout, commands
        except (CommandFailure, ValueError):
            shutil.rmtree(checkout)
    checkout.parent.mkdir(parents=True, exist_ok=True)
    init_command = ["git", "init", str(checkout)]
    remote_command = [
        "git",
        "-C",
        str(checkout),
        "remote",
        "add",
        "origin",
        upstream["url"],
    ]
    fetch_command = [
        "git",
        "-C",
        str(checkout),
        "fetch",
        "--depth=1",
        "origin",
        upstream["commit"],
    ]
    checkout_command = [
        "git",
        "-C",
        str(checkout),
        "checkout",
        "--detach",
        "FETCH_HEAD",
    ]
    for command in (
        init_command,
        remote_command,
        fetch_command,
        checkout_command,
    ):
        run_command(command)
        commands.append(command)
    verify_checkout(checkout, manifest)
    return checkout, commands


def patched_rom(
    upstream_path: pathlib.Path,
    suite: dict[str, Any],
) -> bytes:
    contents = bytearray(upstream_path.read_bytes())
    if len(contents) < 0xC0:
        raise ValueError("public-suite ROM is smaller than its GBA header")
    original = bytes(contents)
    contents[0x04:0xC0] = bytes(0xBC)
    allowed_payload_offsets: set[int] = set()
    for patch in suite.get("word_patches", []):
        offset = int(patch["offset"], 16)
        if offset < 0xC0 or offset + 4 > len(contents) or offset % 4:
            raise ValueError("public-suite word patch has an invalid offset")
        expected_word = int(patch["expected_word"], 16)
        replacement_word = int(patch["replacement_word"], 16)
        if int.from_bytes(contents[offset:offset + 4], "little") != expected_word:
            raise ValueError("public-suite word patch source mismatch")
        contents[offset:offset + 4] = replacement_word.to_bytes(4, "little")
        allowed_payload_offsets.update(range(offset, offset + 4))
    for offset in range(0xC0, len(contents)):
        if offset not in allowed_payload_offsets and contents[offset] != original[offset]:
            raise AssertionError("unlisted public-suite payload byte changed")
    if hashlib.sha256(contents).hexdigest() != suite["patched_sha256"]:
        raise ValueError("public-suite patched_sha256 mismatch")
    return bytes(contents)


def write_word_hex(contents: bytes, path: pathlib.Path) -> int:
    padded = contents + bytes((-len(contents)) % 4)
    path.write_text(
        "\n".join(
            f"{int.from_bytes(padded[offset:offset + 4], 'little'):08x}"
            for offset in range(0, len(padded), 4)
        )
        + "\n",
        encoding="ascii",
    )
    return len(padded) // 4


def run_suite(
    name: str,
    suite: dict[str, Any],
    *,
    checkout: pathlib.Path,
    artifact_root: pathlib.Path,
    binary: pathlib.Path,
    discover_signatures: bool,
) -> dict[str, Any]:
    suite_root = artifact_root / name
    suite_root.mkdir(parents=True)
    rom_path = suite_root / f"{name}.patched.gba"
    hex_path = suite_root / f"{name}.hex"
    log_path = suite_root / "simulation.log"
    contents = patched_rom(checkout / suite["path"], suite)
    rom_path.write_bytes(contents)
    rom_words = write_word_hex(contents, hex_path)
    expected_signature = int(suite["expected_vram_signature"], 16)
    if expected_signature == 0 and not discover_signatures:
        raise ValueError(
            f"public-suite {name} has no frozen expected_vram_signature"
        )
    command = [
        str(binary.resolve()),
        f"+ROM_HEX={hex_path.resolve()}",
        f"+ROM_WORDS={rom_words}",
        f"+IDLE_PC={suite['idle_pc'][2:]}",
        f"+RESULT_REGISTER={suite['result_register']}",
        f"+EXPECTED_VRAM_SIGNATURE={expected_signature:08x}",
        f"+MINIMUM_RETIREMENTS={suite['minimum_retirements']}",
    ]
    output = run_command(command)
    log_path.write_text(output, encoding="utf-8")
    match = PASS_PATTERN.search(output)
    if match is None:
        raise ValueError(f"public-suite {name} omitted its PASS marker")
    retirements, arm, thumb, signature, idle_pc = match.groups()
    if int(idle_pc, 16) != int(suite["idle_pc"], 16):
        raise ValueError(f"public-suite {name} reached the wrong idle PC")
    if (
        expected_signature != 0
        and int(signature, 16) != expected_signature
    ):
        raise ValueError(f"public-suite {name} VRAM signature mismatch")
    if int(retirements) < int(suite["minimum_retirements"]):
        raise ValueError(f"public-suite {name} trace is too short")
    return {
        "status": "passed",
        "upstream_path": suite["path"],
        "upstream_sha256": suite["upstream_sha256"],
        "patched_sha256": suite["patched_sha256"],
        "idle_pc": suite["idle_pc"],
        "result_register": suite["result_register"],
        "expected_vram_signature": f"0x{int(signature, 16):08x}",
        "word_patches": suite.get("word_patches", []),
        "metrics": {
            "retirements": int(retirements),
            "arm_retirements": int(arm),
            "thumb_retirements": int(thumb),
            "rom_words": rom_words,
        },
        "command": command,
        "reproducer": command,
        "artifacts": {
            path.name: artifact_entry(path, artifact_root)
            for path in (rom_path, hex_path, log_path)
        },
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument(
        "--manifest", type=pathlib.Path, default=DEFAULT_MANIFEST
    )
    parser.add_argument(
        "--cache-root",
        type=pathlib.Path,
        default=REPO_ROOT / ".tools" / "public-suites",
    )
    parser.add_argument("--discover-signatures", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not args.binary.is_file():
        raise ValueError("public-suite simulator binary is missing")
    manifest_path = args.manifest.resolve()
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("schema") != "arm7tdmis-public-suites-v1":
        raise ValueError("public-suite manifest has the wrong schema")

    output = args.output.resolve()
    artifact_root = output.parent / "public_suite"
    if artifact_root.is_dir():
        shutil.rmtree(artifact_root)
    artifact_root.mkdir(parents=True)
    status = git_text("status", "--porcelain=v1", "--untracked-files=all")
    report: dict[str, Any] = {
        "schema": SCHEMA,
        "status": "running",
        "started_utc": utc_now(),
        "git": {
            "commit": git_text("rev-parse", "HEAD"),
            "dirty": bool(status),
            "status": status.splitlines(),
        },
        "tools": {
            "python": f"Python {sys.version.replace(chr(10), ' ')}",
            "git": git_text("--version"),
            "simulator_binary_sha256": sha256(args.binary),
        },
        "inputs": {
            entry["path"]: entry
            for entry in (
                file_entry(pathlib.Path(__file__)),
                file_entry(manifest_path),
                file_entry(
                    REPO_ROOT
                    / "tb"
                    / "integration"
                    / "arm7tdmis_public_suite_tb.sv"
                ),
            )
        },
        "upstream": dict(manifest["upstream"]),
        "patches": manifest["patches"],
        "suites": {},
    }
    write_json(output, report)
    try:
        checkout, acquisition_commands = acquire_checkout(
            args.cache_root.resolve(), manifest
        )
        license_copy = artifact_root / "upstream-LICENSE"
        shutil.copyfile(
            checkout / manifest["upstream"]["license_path"],
            license_copy,
        )
        report["upstream"]["acquisition_commands"] = acquisition_commands
        report["upstream"]["license_artifact"] = artifact_entry(
            license_copy, artifact_root
        )
        for name, suite in manifest["suites"].items():
            print(f"[public-suite] running {name}", flush=True)
            report["suites"][name] = run_suite(
                name,
                suite,
                checkout=checkout,
                artifact_root=artifact_root,
                binary=args.binary,
                discover_signatures=args.discover_signatures,
            )
            write_json(output, report)
    except (CommandFailure, ValueError) as error:
        report["status"] = "failed"
        report["finished_utc"] = utc_now()
        report["failure"] = str(error)
        if isinstance(error, CommandFailure):
            report["failure_command"] = list(error.command)
            report["failure_output"] = error.output[-20_000:]
        write_json(output, report)
        print(f"[public-suite] FAIL: {error}", file=sys.stderr)
        return 1

    report["status"] = "passed"
    report["finished_utc"] = utc_now()
    report["suite_count"] = len(report["suites"])
    report["total_retirements"] = sum(
        suite["metrics"]["retirements"]
        for suite in report["suites"].values()
    )
    write_json(output, report)
    print(
        f"[public-suite] PASS ({report['suite_count']} suites, "
        f"{report['total_retirements']} retirements)",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
