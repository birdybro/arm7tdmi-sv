#!/usr/bin/env python3
"""Install the release-pinned open-source synthesis/formal tool suite."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import platform
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request


REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
VERSION = "2026-07-29"
ARCHIVE_NAME = f"oss-cad-suite-linux-x64-{VERSION.replace('-', '')}.tgz"
URL = (
    "https://github.com/YosysHQ/oss-cad-suite-build/releases/download/"
    f"{VERSION}/{ARCHIVE_NAME}"
)
SHA256 = "89ea1152ea84bc600f18cc685f721d534d1f018e09831662787865a3d79ce4aa"
TOP_DIRECTORY = "oss-cad-suite"
INSTALL_DIRECTORY = f"oss-cad-suite-{VERSION.replace('-', '')}"
DEFAULT_ROOT = REPO_ROOT / ".tools"


def file_sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def tool_versions(install: pathlib.Path) -> dict[str, str]:
    commands = {
        "sby": (install / "bin/sby", "--version"),
        "yosys": (install / "bin/yosys", "--version"),
        "boolector": (install / "bin/boolector", "--version"),
    }
    versions: dict[str, str] = {}
    for name, command in commands.items():
        result = subprocess.run(
            tuple(str(value) for value in command),
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        versions[name] = result.stdout.splitlines()[0]
    return versions


def existing_install_is_valid(install: pathlib.Path) -> bool:
    metadata_path = install / "metadata.json"
    if not metadata_path.is_file():
        return False
    try:
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        versions = tool_versions(install)
    except (OSError, ValueError, subprocess.SubprocessError):
        return False
    return (
        metadata.get("schema") == "arm7tdmis-oss-cad-suite-v1"
        and metadata.get("release") == VERSION
        and metadata.get("archive_sha256") == SHA256
        and "SBY v0.67" in versions["sby"]
        and "Yosys 0.67" in versions["yosys"]
        and versions["boolector"] == "3.2.4"
    )


def safe_extract(archive: pathlib.Path, destination: pathlib.Path) -> None:
    destination_resolved = destination.resolve()
    with tarfile.open(archive, "r:gz") as tar:
        for member in tar.getmembers():
            target = (destination / member.name).resolve()
            if not target.is_relative_to(destination_resolved):
                raise ValueError(f"unsafe archive member: {member.name}")
        tar.extractall(destination, filter="data")


def install_toolchain(root: pathlib.Path) -> pathlib.Path:
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        raise RuntimeError(
            "the pinned OSS CAD Suite binary supports Linux x86_64 only"
        )
    root = root.resolve()
    install = root / INSTALL_DIRECTORY
    if existing_install_is_valid(install):
        versions = tool_versions(install)
        print(
            "[oss-cad-suite] PASS cached "
            f"{versions['sby']}; {versions['yosys']}; "
            f"Boolector {versions['boolector']}"
        )
        return install

    root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".oss-cad-", dir=root) as raw:
        staging = pathlib.Path(raw)
        cached_archive = root / ARCHIVE_NAME
        if cached_archive.is_file():
            archive = cached_archive
            print(f"[oss-cad-suite] using cached archive {cached_archive}")
        else:
            archive = staging / ARCHIVE_NAME
            print(f"[oss-cad-suite] downloading {URL}")
            with urllib.request.urlopen(URL, timeout=600) as response:
                with archive.open("wb") as output:
                    shutil.copyfileobj(response, output)
        observed = file_sha256(archive)
        if observed != SHA256:
            raise ValueError(
                f"toolchain SHA-256 expected {SHA256}, got {observed}"
            )

        extract_root = staging / "extract"
        extract_root.mkdir()
        safe_extract(archive, extract_root)
        extracted = extract_root / TOP_DIRECTORY
        if not (extracted / "bin/sby").is_file():
            raise ValueError("OSS CAD Suite archive has an unexpected layout")
        metadata = {
            "schema": "arm7tdmis-oss-cad-suite-v1",
            "release": VERSION,
            "url": URL,
            "archive": ARCHIVE_NAME,
            "archive_sha256": SHA256,
        }
        (extracted / "metadata.json").write_text(
            json.dumps(metadata, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        if install.exists():
            shutil.rmtree(install)
        extracted.rename(install)

    print(
        "[oss-cad-suite] PASS installed "
        + "; ".join(tool_versions(install).values())
    )
    return install


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=pathlib.Path, default=DEFAULT_ROOT)
    return parser.parse_args()


def main() -> int:
    install_toolchain(parse_args().root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
