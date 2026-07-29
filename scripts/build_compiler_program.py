#!/usr/bin/env python3
"""Build the ARM/Thumb/interworking regression with pinned arm-none-eabi GCC."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import subprocess
from typing import Sequence


REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE_ROOT = REPO_ROOT / "verification/compiler"
DEFAULT_TOOLCHAIN = (
    REPO_ROOT
    / ".tools/arm-gnu-toolchain-14.3.rel1-x86_64-arm-none-eabi"
)
SCHEMA = "arm7tdmis-compiler-program-v1"


def run(command: Sequence[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=REPO_ROOT,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )


def sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_program_hex(binary: pathlib.Path, output: pathlib.Path) -> None:
    contents = binary.read_bytes()
    padded = contents + bytes((-len(contents)) % 4)
    output.write_text(
        "\n".join(
            f"{int.from_bytes(padded[offset:offset + 4], 'little'):08x}"
            for offset in range(0, len(padded), 4)
        )
        + "\n",
        encoding="ascii",
    )


def build(args: argparse.Namespace) -> dict[str, object]:
    toolchain = args.toolchain.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    prefix = toolchain / "bin/arm-none-eabi-"
    gcc = str(prefix) + "gcc"
    objcopy = str(prefix) + "objcopy"
    objdump = str(prefix) + "objdump"
    readelf = str(prefix) + "readelf"

    startup_object = output / "startup.o"
    arm_object = output / "arm_program.o"
    thumb_object = output / "thumb_program.o"
    elf = output / "compiler_program.elf"
    binary = output / "compiler_program.bin"
    program_hex = output / "program.hex"
    disassembly = output / "disassembly.txt"
    attributes = output / "attributes.txt"
    map_path = output / "compiler_program.map"

    common = (
        "-march=armv4t",
        "-mthumb-interwork",
        "-ffreestanding",
        "-fno-builtin",
        "-fno-pic",
        "-fno-pie",
        "-fno-stack-protector",
        "-fno-unwind-tables",
        "-fno-asynchronous-unwind-tables",
        "-O2",
        "-Wall",
        "-Wextra",
        "-Werror",
    )
    commands: list[tuple[str, ...]] = [
        (
            gcc,
            *common,
            "-marm",
            "-x",
            "assembler-with-cpp",
            "-c",
            str(SOURCE_ROOT / "startup.S"),
            "-o",
            str(startup_object),
        ),
        (
            gcc,
            *common,
            "-marm",
            "-std=c11",
            "-c",
            str(SOURCE_ROOT / "arm_program.c"),
            "-o",
            str(arm_object),
        ),
        (
            gcc,
            *common,
            "-mthumb",
            "-std=c11",
            "-c",
            str(SOURCE_ROOT / "thumb_program.c"),
            "-o",
            str(thumb_object),
        ),
        (
            gcc,
            "-march=armv4t",
            "-marm",
            "-mthumb-interwork",
            "-nostdlib",
            "-no-pie",
            f"-Wl,-T,{SOURCE_ROOT / 'linker.ld'}",
            f"-Wl,-Map,{map_path}",
            "-Wl,--build-id=none",
            str(startup_object),
            str(arm_object),
            str(thumb_object),
            "-o",
            str(elf),
        ),
        (objcopy, "-O", "binary", str(elf), str(binary)),
    ]
    for command in commands:
        run(command)

    disassembly_text = run((objdump, "-d", str(elf))).stdout
    attribute_text = run((readelf, "-A", str(elf))).stdout
    for symbol in ("arm_main", "arm_mix", "thumb_accumulate", "thumb_store"):
        if f"<{symbol}>" not in disassembly_text:
            raise ValueError(f"linked program is missing {symbol}")
    if "blx" in disassembly_text.lower():
        raise ValueError("ARMv5 BLX leaked into the ARMv4T program")
    if "Tag_CPU_arch: v4T" not in attribute_text:
        raise ValueError("ELF attributes do not identify ARMv4T")
    disassembly.write_text(disassembly_text, encoding="utf-8")
    attributes.write_text(attribute_text, encoding="utf-8")
    write_program_hex(binary, program_hex)

    version = run((gcc, "--version")).stdout.splitlines()[0]
    sources = [
        SOURCE_ROOT / "startup.S",
        SOURCE_ROOT / "arm_program.c",
        SOURCE_ROOT / "thumb_program.c",
        SOURCE_ROOT / "linker.ld",
    ]
    metadata: dict[str, object] = {
        "schema": SCHEMA,
        "toolchain": {
            "version": version,
            "release": "14.3.Rel1",
            "install_metadata_sha256": sha256(toolchain / "metadata.json"),
        },
        "flags": {
            "architecture": "-march=armv4t",
            "arm": "-marm",
            "thumb": "-mthumb",
            "interworking": "-mthumb-interwork",
            "environment": "-ffreestanding -nostdlib",
        },
        "commands": [list(command) for command in commands],
        "sha256": {
            "sources": {path.name: sha256(path) for path in sources},
            "elf": sha256(elf),
            "binary": sha256(binary),
            "program_hex": sha256(program_hex),
            "disassembly": sha256(disassembly),
            "attributes": sha256(attributes),
            "map": sha256(map_path),
        },
    }
    (output / "metadata.json").write_text(
        json.dumps(metadata, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(f"[compiler-build] PASS ({version}, {binary.stat().st_size} bytes)")
    return metadata


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--toolchain", type=pathlib.Path, default=DEFAULT_TOOLCHAIN
    )
    parser.add_argument("--output", type=pathlib.Path, required=True)
    return parser.parse_args()


def main() -> int:
    build(parse_args())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
