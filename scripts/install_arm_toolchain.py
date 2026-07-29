#!/usr/bin/env python3
"""Install the release-pinned Arm GNU bare-metal toolchain."""

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
VERSION = "14.3.rel1"
ARCHIVE_NAME = (
    f"arm-gnu-toolchain-{VERSION}-x86_64-arm-none-eabi.tar.xz"
)
TOP_DIRECTORY = ARCHIVE_NAME.removesuffix(".tar.xz")
URL = (
    "https://developer.arm.com/-/media/Files/downloads/gnu/"
    f"{VERSION}/binrel/{ARCHIVE_NAME}"
)
SHA256 = "8f6903f8ceb084d9227b9ef991490413014d991874a1e34074443c2a72b14dbd"
DEFAULT_ROOT = REPO_ROOT / ".tools"


def file_sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def compiler_version(install: pathlib.Path) -> str:
    gcc = install / "bin/arm-none-eabi-gcc"
    result = subprocess.run(
        (str(gcc), "--version"),
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    return result.stdout.splitlines()[0]


def existing_install_is_valid(install: pathlib.Path) -> bool:
    metadata_path = install / "metadata.json"
    gcc = install / "bin/arm-none-eabi-gcc"
    if not metadata_path.is_file() or not gcc.is_file():
        return False
    try:
        metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        version = compiler_version(install)
    except (OSError, ValueError, subprocess.SubprocessError):
        return False
    return (
        metadata.get("schema") == "arm7tdmis-arm-toolchain-v1"
        and metadata.get("release") == VERSION
        and metadata.get("archive_sha256") == SHA256
        and "14.3.1" in version
    )


def safe_extract(archive: pathlib.Path, destination: pathlib.Path) -> None:
    destination_resolved = destination.resolve()
    with tarfile.open(archive, "r:xz") as tar:
        for member in tar.getmembers():
            target = (destination / member.name).resolve()
            if not target.is_relative_to(destination_resolved):
                raise ValueError(f"unsafe archive member: {member.name}")
        tar.extractall(destination, filter="data")


def install_toolchain(root: pathlib.Path) -> pathlib.Path:
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        raise RuntimeError(
            "the pinned binary toolchain supports Linux x86_64 only"
        )
    root = root.resolve()
    install = root / TOP_DIRECTORY
    if existing_install_is_valid(install):
        print(f"[arm-toolchain] PASS cached {compiler_version(install)}")
        return install

    root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".arm-toolchain-", dir=root) as raw:
        staging = pathlib.Path(raw)
        archive = staging / ARCHIVE_NAME
        print(f"[arm-toolchain] downloading {URL}")
        with urllib.request.urlopen(URL, timeout=300) as response:
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
        if not (extracted / "bin/arm-none-eabi-gcc").is_file():
            raise ValueError("toolchain archive has an unexpected layout")
        metadata = {
            "schema": "arm7tdmis-arm-toolchain-v1",
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

    print(f"[arm-toolchain] PASS installed {compiler_version(install)}")
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
