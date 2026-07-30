#!/usr/bin/env python3
"""Build the generic-SoC ARMv4T smoke ROM and prove RTL byte equivalence."""

from __future__ import annotations

import argparse
import hashlib
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
from collections.abc import Mapping, Sequence


REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
PROGRAM_SOURCE = REPO_ROOT / "examples" / "generic_soc" / "program.S"
LINKER_SCRIPT = REPO_ROOT / "examples" / "generic_soc" / "linker.ld"
RTL_SOURCE = (
    REPO_ROOT
    / "examples"
    / "generic_soc"
    / "arm7tdmi_generic_soc.sv"
)
DEFAULT_TOOLCHAIN = (
    REPO_ROOT
    / ".tools"
    / "arm-gnu-toolchain-14.3.rel1-x86_64-arm-none-eabi"
)
ROM_BYTES = 1024
EXPECTED_BYTES = 812
EXPECTED_WORDS = 203
EXPECTED_SHA256 = (
    "ee9c06bc1720ce9e4f9f57da3e162acdfc0e42df403766f6d98bbeb9249c4900"
)
REQUIRED_SYMBOLS = (
    "_start",
    "reset",
    "pass",
    "fail",
    "irq_handler",
    "thumb_test",
)
ROM_WORD_RE = re.compile(
    r"8'h(?P<index>[0-9a-fA-F]{2})\s*:\s*"
    r"return\s+32'h(?P<word>[0-9a-fA-F_]+)\s*;"
)


def run(command: Sequence[str]) -> str:
    return subprocess.run(
        command,
        cwd=REPO_ROOT,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    ).stdout


def parse_rtl_words(text: str) -> dict[int, int]:
    function_match = re.search(
        r"function automatic logic \[31:0\] rom_word.*?endfunction",
        text,
        re.DOTALL,
    )
    if function_match is None:
        raise ValueError("RTL rom_word function is missing")

    words: dict[int, int] = {}
    for match in ROM_WORD_RE.finditer(function_match.group(0)):
        index = int(match.group("index"), 16)
        word = int(match.group("word").replace("_", ""), 16)
        if index in words:
            raise ValueError(f"RTL ROM index 0x{index:02x} is duplicated")
        if word > 0xFFFF_FFFF:
            raise ValueError(f"RTL ROM index 0x{index:02x} exceeds 32 bits")
        words[index] = word
    if not words:
        raise ValueError("RTL rom_word function contains no words")
    if "default: return 32'h0000_0000;" not in function_match.group(0):
        raise ValueError("RTL ROM default is not an explicit zero word")
    return words


def compare_rom(binary: bytes, rtl_words: Mapping[int, int]) -> None:
    if len(binary) > ROM_BYTES:
        raise ValueError(
            f"compiled ROM is {len(binary)} bytes; limit is {ROM_BYTES}"
        )
    if len(binary) % 4:
        raise ValueError("compiled ROM length is not word-aligned")

    padded = binary + bytes(ROM_BYTES - len(binary))
    mismatches: list[str] = []
    for index in range(ROM_BYTES // 4):
        offset = index * 4
        expected = int.from_bytes(padded[offset : offset + 4], "little")
        actual = rtl_words.get(index, 0)
        if actual != expected:
            mismatches.append(
                f"word 0x{index:02x}: compiled=0x{expected:08x}, "
                f"rtl=0x{actual:08x}"
            )
    out_of_range = sorted(index for index in rtl_words if index >= ROM_BYTES // 4)
    if out_of_range:
        mismatches.append(
            "RTL contains out-of-range word indices: "
            + ", ".join(f"0x{index:02x}" for index in out_of_range)
        )
    if mismatches:
        detail = "\n  ".join(mismatches[:16])
        suffix = (
            f"\n  ... {len(mismatches) - 16} more"
            if len(mismatches) > 16
            else ""
        )
        raise ValueError(f"compiled/RTL ROM mismatch:\n  {detail}{suffix}")


def build_and_check(
    toolchain: pathlib.Path,
    *,
    output: pathlib.Path | None = None,
) -> dict[str, object]:
    prefix = toolchain.resolve() / "bin" / "arm-none-eabi-"
    gcc = pathlib.Path(f"{prefix}gcc")
    objcopy = pathlib.Path(f"{prefix}objcopy")
    objdump = pathlib.Path(f"{prefix}objdump")
    readelf = pathlib.Path(f"{prefix}readelf")
    nm = pathlib.Path(f"{prefix}nm")
    for executable in (gcc, objcopy, objdump, readelf, nm):
        if not executable.is_file():
            raise ValueError(f"required tool is missing: {executable}")

    source_text = PROGRAM_SOURCE.read_text(encoding="utf-8")
    if ".arch armv4t" not in source_text:
        raise ValueError("program.S does not declare ARMv4T")
    if re.search(r"\bblx\b", source_text, re.IGNORECASE):
        raise ValueError("ARMv5 BLX is forbidden in the ARMv4T ROM")

    with tempfile.TemporaryDirectory(prefix="arm7tdmis-rom-") as directory:
        work = pathlib.Path(directory)
        object_path = work / "program.o"
        elf_path = work / "program.elf"
        binary_path = work / "program.bin"
        map_path = work / "program.map"
        disassembly_path = work / "disassembly.txt"
        attributes_path = work / "attributes.txt"

        compile_command = (
            str(gcc),
            "-march=armv4t",
            "-marm",
            "-mthumb-interwork",
            "-x",
            "assembler-with-cpp",
            "-ffreestanding",
            "-fno-pic",
            "-fno-pie",
            "-Wall",
            "-Werror",
            "-c",
            str(PROGRAM_SOURCE),
            "-o",
            str(object_path),
        )
        link_command = (
            str(gcc),
            "-march=armv4t",
            "-marm",
            "-mthumb-interwork",
            "-nostdlib",
            "-no-pie",
            f"-Wl,-T,{LINKER_SCRIPT}",
            f"-Wl,-Map,{map_path}",
            "-Wl,--build-id=none",
            str(object_path),
            "-o",
            str(elf_path),
        )
        run(compile_command)
        run(link_command)
        run((str(objcopy), "-O", "binary", str(elf_path), str(binary_path)))

        attributes = run((str(readelf), "-A", str(object_path)))
        if "Tag_CPU_arch: v4T" not in attributes:
            raise ValueError("object attributes do not identify ARMv4T")
        if "Tag_THUMB_ISA_use: Thumb-1" not in attributes:
            raise ValueError("object attributes do not identify Thumb-1")
        attributes_path.write_text(attributes, encoding="utf-8")

        symbols = run((str(nm), "-n", str(elf_path)))
        for symbol in REQUIRED_SYMBOLS:
            if re.search(rf"\b{re.escape(symbol)}$", symbols, re.MULTILINE) is None:
                raise ValueError(f"linked ROM is missing symbol {symbol}")

        disassembly = run((str(objdump), "-d", str(elf_path)))
        for instruction in ("umull", "swp", "subs"):
            if re.search(rf"\b{instruction}\b", disassembly) is None:
                raise ValueError(
                    f"linked ROM is missing required instruction {instruction}"
                )
        # Binutils 2.44 mislabels the ARM-state BX word as an ARMv8
        # system-register instruction, so check the architected encoding too.
        if bytes.fromhex("11ff2fe1") not in binary_path.read_bytes():
            raise ValueError("linked ROM is missing ARM-state BX r1")
        if bytes.fromhex("7047") not in binary_path.read_bytes():
            raise ValueError("linked ROM is missing Thumb-state BX lr")
        disassembly_path.write_text(disassembly, encoding="utf-8")

        binary = binary_path.read_bytes()
        digest = hashlib.sha256(binary).hexdigest()
        if len(binary) != EXPECTED_BYTES:
            raise ValueError(
                f"compiled ROM is {len(binary)} bytes; expected {EXPECTED_BYTES}"
            )
        if len(binary) // 4 != EXPECTED_WORDS:
            raise ValueError(
                f"compiled ROM is {len(binary) // 4} words; "
                f"expected {EXPECTED_WORDS}"
            )
        if digest != EXPECTED_SHA256:
            raise ValueError(
                f"compiled ROM SHA-256 is {digest}; expected {EXPECTED_SHA256}"
            )

        rtl_words = parse_rtl_words(RTL_SOURCE.read_text(encoding="utf-8"))
        compare_rom(binary, rtl_words)

        if output is not None:
            output.mkdir(parents=True, exist_ok=True)
            for artifact in (
                elf_path,
                binary_path,
                map_path,
                disassembly_path,
                attributes_path,
            ):
                shutil.copy2(artifact, output / artifact.name)

        version = run((str(gcc), "--version")).splitlines()[0]

    return {
        "bytes": EXPECTED_BYTES,
        "words": EXPECTED_WORDS,
        "sha256": EXPECTED_SHA256,
        "toolchain": version,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--toolchain",
        type=pathlib.Path,
        default=DEFAULT_TOOLCHAIN,
    )
    parser.add_argument(
        "--output",
        type=pathlib.Path,
        help="optionally retain ELF, binary, map, disassembly, and attributes",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        result = build_and_check(args.toolchain, output=args.output)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"[generic-soc-rom] FAIL: {error}", file=sys.stderr)
        return 1
    print(
        "[generic-soc-rom] PASS "
        f"({result['bytes']} bytes, {result['words']} words, "
        f"sha256={result['sha256']})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
