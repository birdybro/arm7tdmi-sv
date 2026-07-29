#!/usr/bin/env python3
"""Generate independent QEMU post-instruction state for the ARMv4T RTL test.

The runner compiles one repository-authored ARM/Thumb program, executes it on
QEMU's ARM926 model one instruction per translation block, and converts
QEMU's register log into a packed expected-state image. The compared program
uses only the ARMv4T subset shared by ARM7TDMI and ARM926.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import subprocess
from dataclasses import dataclass
from typing import Sequence


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
DEFAULT_SOURCE = REPO_ROOT / "verification/programs/qemu_diff.S"
LINK_ADDRESS = 0x0001_0000
DATA_ADDRESS = 0x0002_0000
PSR_COMPARE_MASK = 0xF000_00FF
SCHEMA = "arm7tdmis-qemu-differential-v1"

REGISTER_LINE = re.compile(
    r"R\d\d=([0-9a-fA-F]{8}) R\d\d=([0-9a-fA-F]{8}) "
    r"R\d\d=([0-9a-fA-F]{8}) R\d\d=([0-9a-fA-F]{8})"
)
PSR_LINE = re.compile(r"PSR=([0-9a-fA-F]{8})")
SYMBOL_LINE = re.compile(r"^([0-9a-fA-F]+)\s+\w\s+(\S+)$")


@dataclass(frozen=True)
class CpuState:
    registers: tuple[int, ...]
    psr: int

    @property
    def pc(self) -> int:
        return self.registers[15]


def run(
    command: Sequence[str],
    *,
    environment: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=REPO_ROOT,
        env=environment,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def parse_symbols(output: str) -> dict[str, int]:
    symbols: dict[str, int] = {}
    for line in output.splitlines():
        match = SYMBOL_LINE.match(line)
        if match:
            symbols[match.group(2)] = int(match.group(1), 16)
    for required in ("_start", "measure_begin", "measure_end"):
        if required not in symbols:
            raise ValueError(f"linked image has no {required} symbol")
    return symbols


def parse_qemu_states(text: str) -> list[CpuState]:
    lines = text.splitlines()
    states: list[CpuState] = []
    index = 0
    while index + 4 < len(lines):
        first = REGISTER_LINE.fullmatch(lines[index])
        if first is None:
            index += 1
            continue

        registers: list[int] = []
        for group in range(4):
            match = REGISTER_LINE.fullmatch(lines[index + group])
            if match is None:
                raise ValueError(
                    f"truncated QEMU register record at line {index + 1}"
                )
            registers.extend(int(value, 16) for value in match.groups())
        psr_match = PSR_LINE.match(lines[index + 4])
        if psr_match is None:
            raise ValueError(f"missing QEMU PSR at line {index + 5}")
        states.append(
            CpuState(tuple(registers), int(psr_match.group(1), 16))
        )
        index += 5
    if not states:
        raise ValueError("QEMU log contains no CPU states")
    return states


def differential_events(
    states: Sequence[CpuState],
    *,
    begin: int,
    end: int,
) -> list[tuple[CpuState, CpuState]]:
    try:
        start_index = next(
            index for index, state in enumerate(states) if state.pc == begin
        )
    except StopIteration as error:
        raise ValueError(f"QEMU never reached measure_begin {begin:#x}") from error

    events: list[tuple[CpuState, CpuState]] = []
    for index in range(start_index, len(states) - 1):
        before = states[index]
        if before.pc == end:
            break
        after = states[index + 1]
        events.append((before, after))
    else:
        raise ValueError(f"QEMU never reached measure_end {end:#x}")

    if len(events) < 50:
        raise ValueError(f"differential trace is unexpectedly short: {len(events)}")
    return events


def normalize_thumb_bl(
    events: Sequence[tuple[CpuState, CpuState]],
    binary: bytes,
) -> list[tuple[CpuState, CpuState]]:
    """Split QEMU's atomic Thumb BL into ARMv4T prefix/suffix dispositions.

    QEMU's later CPU model logs a Format-19 pair as one translated guest
    instruction. ARM7TDMI architecturally executes the prefix (writing LR)
    and suffix (branch/link) as two halfword dispositions. Split only the
    allocated F000/F800 pair; all state after the suffix remains QEMU's.
    """
    normalized: list[tuple[CpuState, CpuState]] = []
    for before, after in events:
        offset = before.pc - LINK_ADDRESS
        if (
            before.psr & (1 << 5)
            and 0 <= offset
            and offset + 4 <= len(binary)
        ):
            prefix = int.from_bytes(binary[offset:offset + 2], "little")
            suffix = int.from_bytes(binary[offset + 2:offset + 4], "little")
            if prefix >> 11 == 0b11110 and suffix >> 11 == 0b11111:
                high = prefix & 0x7FF
                signed_high = high if high < 0x400 else high - 0x800
                registers = list(before.registers)
                registers[14] = (
                    before.pc + 4 + (signed_high << 12)
                ) & 0xFFFF_FFFF
                registers[15] = before.pc + 2
                intermediate = CpuState(tuple(registers), before.psr)
                normalized.append((before, intermediate))
                normalized.append((intermediate, after))
                continue
        normalized.append((before, after))
    return normalized


def packed_expected_line(before: CpuState, after: CpuState) -> str:
    words = [
        before.pc,
        1 if (before.psr & (1 << 5)) else 0,
        after.psr & PSR_COMPARE_MASK,
        *after.registers[:15],
    ]
    if len(words) != 18:
        raise AssertionError("expected state record is not 18 words")
    return "".join(f"{word & 0xFFFF_FFFF:08x}" for word in words)


def write_program_hex(binary: bytes, path: pathlib.Path) -> None:
    padded = binary + bytes((-len(binary)) % 4)
    # From address zero, branch to the QEMU kernel load address.
    reset_branch = 0xEA00_0000 | (((LINK_ADDRESS - 8) >> 2) & 0x00FF_FFFF)
    lines = ["@00000000", f"{reset_branch:08x}", f"@{LINK_ADDRESS // 4:08x}"]
    for offset in range(0, len(padded), 4):
        lines.append(f"{int.from_bytes(padded[offset:offset + 4], 'little'):08x}")
    path.write_text("\n".join(lines) + "\n", encoding="ascii")


def build_reference(args: argparse.Namespace) -> dict[str, object]:
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    elf = output / "program.elf"
    binary = output / "program.bin"
    trace = output / "qemu.log"
    expected = output / "expected.hex"
    program = output / "program.hex"
    generated = output / "qemu_diff_generated.svh"
    metadata_path = output / "metadata.json"

    clang_version = run((args.clang, "--version")).stdout.splitlines()[0]
    qemu_version = run((args.qemu, "--version")).stdout.splitlines()[0]
    if not qemu_version.startswith("QEMU emulator version"):
        raise ValueError(f"unexpected qemu-system-arm identity: {qemu_version}")

    compile_command = (
        args.clang,
        "--target=arm-none-eabi",
        "-march=armv4t",
        "-marm",
        "-nostdlib",
        "-fuse-ld=lld",
        f"-Wl,-Ttext={LINK_ADDRESS:#x}",
        "-Wl,--entry=_start",
        "-Wl,--build-id=none",
        str(args.source.resolve()),
        "-o",
        str(elf),
    )
    run(compile_command)
    run((args.objcopy, "-O", "binary", str(elf), str(binary)))
    symbol_result = run((args.nm, "--defined-only", str(elf)))
    symbols = parse_symbols(symbol_result.stdout)

    qemu_command = (
        args.qemu,
        "-M",
        "versatilepb",
        "-cpu",
        "arm926",
        "-accel",
        "tcg,one-insn-per-tb=on",
        "-m",
        "128M",
        "-nographic",
        "-monitor",
        "none",
        "-serial",
        "none",
        "-kernel",
        str(binary),
        "-semihosting-config",
        "enable=on,target=native",
        "-d",
        "cpu,nochain",
        "-D",
        str(trace),
    )
    environment = os.environ.copy()
    environment["QEMU_AUDIO_DRV"] = "none"
    run(qemu_command, environment=environment)

    states = parse_qemu_states(trace.read_text(encoding="ascii"))
    binary_contents = binary.read_bytes()
    events = differential_events(
        states,
        begin=symbols["measure_begin"] & ~1,
        end=symbols["measure_end"] & ~1,
    )
    events = normalize_thumb_bl(events, binary_contents)
    expected.write_text(
        "\n".join(packed_expected_line(before, after)
                  for before, after in events)
        + "\n",
        encoding="ascii",
    )
    write_program_hex(binary_contents, program)
    generated.write_text(
        "// Generated by qemu_armv4t_reference.py; do not edit.\n"
        f"localparam int EXPECTED_EVENTS = {len(events)};\n",
        encoding="ascii",
    )

    metadata: dict[str, object] = {
        "schema": SCHEMA,
        "reference": "QEMU ARM926, restricted to shared ARMv4T behavior",
        "normalization": {
            "psr_mask": f"0x{PSR_COMPARE_MASK:08x}",
            "excluded": [
                "ARMv5 instructions",
                "reserved and architecturally UNPREDICTABLE inputs",
                "implementation-defined reset register contents",
                "QEMU CPSR A bit and other non-ARM7 PSR extensions",
                "QEMU atomic Thumb BL log split into ARMv4T prefix/suffix",
            ],
        },
        "tools": {
            "clang": clang_version,
            "qemu": qemu_version,
            "objcopy": args.objcopy,
            "nm": args.nm,
        },
        "symbols": {
            name: f"0x{address & ~1:08x}" for name, address in symbols.items()
            if name in {"_start", "measure_begin", "measure_end"}
        },
        "events": len(events),
        "data_address": f"0x{DATA_ADDRESS:08x}",
        "sha256": {
            "source": sha256(args.source),
            "elf": sha256(elf),
            "binary": sha256(binary),
            "program_hex": sha256(program),
            "expected_hex": sha256(expected),
            "qemu_log": sha256(trace),
        },
        "commands": {
            "compile": list(compile_command),
            "qemu": list(qemu_command),
        },
    }
    metadata_path.write_text(
        json.dumps(metadata, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return metadata


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=pathlib.Path, default=DEFAULT_SOURCE)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--clang", default="clang")
    parser.add_argument("--objcopy", default="llvm-objcopy")
    parser.add_argument("--nm", default="llvm-nm")
    parser.add_argument("--qemu", default="qemu-system-arm")
    return parser.parse_args()


def main() -> int:
    metadata = build_reference(parse_args())
    print(
        "[qemu-reference] "
        f"PASS ({metadata['events']} events, "
        f"{metadata['tools']['qemu']})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
