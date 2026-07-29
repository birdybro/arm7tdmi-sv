#!/usr/bin/env python3
"""Deterministic constrained-random ARMv4T differential validation.

Each seed has two deliberately separate oracle lanes:

* QEMU ARM926 executes a legal shared-ARMv4T ARM/Thumb program from the
  exception vector table.  The RTL compares every retirement, including
  banked privileged modes plus SVC and undefined exception entry/return.
* A small architecture-derived memory model predicts the permitted effects
  of ARM7TDMI legacy unaligned word loads and both endian configurations.

The generator imports no project decoder or expected-value package.  A failed
case is left in the evidence directory with exact commands for reproduction.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import pathlib
import random
import re
import shlex
import shutil
import subprocess
import sys
from collections.abc import Sequence
from dataclasses import dataclass
from typing import Any

import qemu_armv4t_reference as qemu_reference


SCHEMA = "arm7tdmis-constrained-random-v1"
REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
DATA_ADDRESS = 0x0001_0000
POLICY_DATA_ADDRESS = 0x0001_8000
POLICY_OUTPUT_ADDRESS = 0x0001_A000
PSR_COMPARE_MASK = 0xF000_00FF
EXPECTED_EXCEPTION_NONE = 0xFFFF_FFFF
MIN_RELEASE_SEEDS = 32
MIN_RELEASE_INSTRUCTIONS = 256
MIN_RELEASE_EVENTS = 8_192

# ARMv4T mode encodings used by the generated privileged-bank walk.
MODE_USER = 0x10
MODE_FIQ = 0x11
MODE_IRQ = 0x12
MODE_SUPERVISOR = 0x13
MODE_ABORT = 0x17
MODE_UNDEFINED = 0x1B
MODE_SYSTEM = 0x1F


@dataclass(frozen=True)
class CommandFailure(RuntimeError):
    command: tuple[str, ...]
    returncode: int
    output: str

    def __str__(self) -> str:
        return (
            f"command exited {self.returncode}: {shlex.join(self.command)}\n"
            f"{self.output}"
        )


def utc_now() -> str:
    return dt.datetime.now(dt.UTC).isoformat(timespec="seconds")


def sha256(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git_text(*arguments: str) -> str:
    return subprocess.run(
        ("git", *arguments),
        cwd=REPO_ROOT,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    ).stdout.strip()


def run_command(
    command: Sequence[str],
    *,
    environment: dict[str, str] | None = None,
    timeout: float = 120.0,
) -> str:
    command_tuple = tuple(str(part) for part in command)
    try:
        result = subprocess.run(
            command_tuple,
            cwd=REPO_ROOT,
            env=environment,
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


def file_entry(path: pathlib.Path) -> dict[str, Any]:
    resolved = path.resolve()
    return {
        "path": resolved.relative_to(REPO_ROOT).as_posix(),
        "bytes": resolved.stat().st_size,
        "sha256": sha256(resolved),
    }


def artifact_entry(path: pathlib.Path, root: pathlib.Path) -> dict[str, Any]:
    return {
        "path": path.resolve().relative_to(root.resolve()).as_posix(),
        "bytes": path.stat().st_size,
        "sha256": sha256(path),
    }


def write_json(path: pathlib.Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    os.replace(temporary, path)


def arm_immediate(rng: random.Random) -> int:
    return rng.randrange(0, 256)


def random_arm_instruction(
    rng: random.Random,
    index: int,
    previous_destination: int,
) -> tuple[list[str], int, set[str]]:
    registers = (0, 1, 2, 3, 4, 5, 8, 9, 11, 12)
    destination = rng.choice(registers)
    source = previous_destination if index % 3 == 0 else rng.choice(registers)
    other = rng.choice(registers)
    immediate = arm_immediate(rng)
    operation = rng.randrange(8)
    coverage = {"arm", "dependency" if source == previous_destination else "register"}

    if operation == 0:
        return [f"    adds r{destination}, r{source}, #{immediate}"], destination, coverage | {"data_processing", "flags"}
    if operation == 1:
        return [f"    subs r{destination}, r{source}, #{immediate}"], destination, coverage | {"data_processing", "flags"}
    if operation == 2:
        return [f"    eor r{destination}, r{source}, r{other}"], destination, coverage | {"data_processing"}
    if operation == 3:
        return [f"    orr r{destination}, r{source}, r{other}"], destination, coverage | {"data_processing"}
    if operation == 4:
        shift = rng.randrange(1, 32)
        return [f"    movs r{destination}, r{source}, lsl #{shift}"], destination, coverage | {"shift", "flags"}
    if operation == 5:
        # ARM7TDMI documents Rd==Rm as UNPREDICTABLE for MUL.
        multiplier = rng.choice(tuple(reg for reg in registers if reg != destination))
        return [f"    mul r{destination}, r{multiplier}, r{other}"], destination, coverage | {"multiply"}
    if operation == 6:
        offset = 4 * rng.randrange(0, 5)
        if rng.randrange(2):
            return [f"    str r{source}, [r10, #{offset}]"], source, coverage | {"memory", "store", "aligned"}
        return [f"    ldr r{destination}, [r10, #{offset}]"], destination, coverage | {"memory", "load", "aligned"}

    label = f"arm_condition_{index}"
    condition = "eq" if rng.randrange(2) else "ne"
    return [
        f"    cmp r{source}, r{other}",
        f"    add{condition} r{destination}, r{source}, #{immediate}",
        f"{label}:",
    ], destination, coverage | {"condition", "flags"}


def random_thumb_instruction(
    rng: random.Random,
    index: int,
    previous_destination: int,
) -> tuple[list[str], int, set[str]]:
    registers = (0, 1, 2, 3, 4, 5)
    destination = rng.choice(registers)
    source = (
        previous_destination
        if previous_destination in registers and index % 3 == 0
        else rng.choice(registers)
    )
    other = rng.choice(registers)
    immediate = rng.randrange(0, 8)
    operation = rng.randrange(9)
    coverage = {
        "thumb",
        "dependency" if source == previous_destination else "register",
    }

    if operation == 0:
        return [f"    adds r{destination}, r{source}, #{immediate}"], destination, coverage | {"data_processing", "flags"}
    if operation == 1:
        return [f"    subs r{destination}, r{source}, #{immediate}"], destination, coverage | {"data_processing", "flags"}
    if operation == 2:
        return [f"    eors r{destination}, r{other}"], destination, coverage | {"data_processing", "flags"}
    if operation == 3:
        return [f"    orrs r{destination}, r{other}"], destination, coverage | {"data_processing", "flags"}
    if operation == 4:
        shift = rng.randrange(1, 32)
        return [f"    lsls r{destination}, r{source}, #{shift}"], destination, coverage | {"shift", "flags"}
    if operation == 5:
        return [f"    muls r{destination}, r{other}"], destination, coverage | {"multiply", "flags"}
    if operation == 6:
        offset = 4 * rng.randrange(0, 5)
        if rng.randrange(2):
            return [f"    str r{source}, [r6, #{offset}]"], source, coverage | {"memory", "store", "aligned"}
        return [f"    ldr r{destination}, [r6, #{offset}]"], destination, coverage | {"memory", "load", "aligned"}
    if operation == 7:
        offset = rng.randrange(0, 20)
        if rng.randrange(2):
            return [f"    strb r{source}, [r6, #{offset}]"], source, coverage | {"memory", "store", "byte"}
        return [f"    ldrb r{destination}, [r6, #{offset}]"], destination, coverage | {"memory", "load", "byte"}

    label = f"thumb_condition_{index}"
    return [
        f"    cmp r{source}, r{other}",
        f"    bne {label}",
        f"    adds r{destination}, #{immediate}",
        f"{label}:",
    ], destination, coverage | {"condition", "flags"}


def mode_walk(rng: random.Random) -> tuple[list[str], set[str]]:
    modes = [
        ("fiq", MODE_FIQ),
        ("irq", MODE_IRQ),
        ("abort", MODE_ABORT),
        ("undefined", MODE_UNDEFINED),
        ("system", MODE_SYSTEM),
    ]
    rng.shuffle(modes)
    lines: list[str] = []
    coverage: set[str] = {"mode", "banked_register"}
    for sequence, (name, mode) in enumerate(modes):
        lines.extend(
            (
                f"    /* enter MODE_{name.upper()} */",
                # Do not copy ARM926's post-ARM7 A bit through an MRS.
                f"    mov r7, #0x{mode:02x}",
                "    msr cpsr_c, r7",
            )
        )
        if mode == MODE_FIQ:
            for register in range(8, 13):
                lines.append(
                    f"    mov r{register}, #{(sequence + register) & 0xff}"
                )
        lines.extend(
            (
                f"    mov r13, #{0x40 + sequence}",
                f"    mov r14, #{0x80 + sequence}",
            )
        )
    lines.extend(
        (
            "    /* return to MODE_SUPERVISOR */",
            f"    mov r7, #0x{MODE_SUPERVISOR:02x}",
            "    msr cpsr_c, r7",
        )
    )
    return lines, coverage


def generate_differential_source(
    seed: int,
    instruction_count: int,
) -> tuple[str, set[str]]:
    rng = random.Random(seed)
    coverage: set[str] = {
        "instruction",
        "register",
        "flags",
        "memory",
        "exception",
        "alignment",
        "little",
    }
    arm_count = instruction_count // 2
    thumb_count = instruction_count - arm_count
    arm_lines: list[str] = []
    thumb_lines: list[str] = []
    previous = 0
    for index in range(arm_count):
        lines, previous, bins = random_arm_instruction(
            rng, index, previous
        )
        arm_lines.extend(lines)
        coverage.update(bins)
    previous = 0
    for index in range(thumb_count):
        lines, previous, bins = random_thumb_instruction(
            rng, index, previous
        )
        thumb_lines.extend(lines)
        coverage.update(bins)

    modes, mode_bins = mode_walk(rng)
    coverage.update(mode_bins)
    exception_order = ["svc #0x41", ".word 0xe7f000f0"]
    rng.shuffle(exception_order)
    exception_lines = [
        "    /* synchronous exception coverage: svc and undefined */",
        *(f"    {instruction}" for instruction in exception_order),
    ]
    coverage.update({"svc", "undefined"})

    initial_words = [rng.getrandbits(32) for _ in range(5)]
    initialize_memory: list[str] = ["    ldr r10, =0x00010000"]
    for index, value in enumerate(initial_words):
        initialize_memory.extend(
            (
                f"    ldr r0, =0x{value:08x}",
                f"    str r0, [r10, #{4 * index}]",
            )
        )

    source_lines = [
        "/* Generated constrained-random shared ARMv4T program. */",
        "    .syntax unified",
        "    .cpu arm7tdmi",
        "    .section .text",
        "    .global _start",
        "    .global measure_begin",
        "    .global measure_end",
        "    .arm",
        "_start:",
        "    b initialize",
        "    b undefined_handler",
        "    b svc_handler",
        "    b prefetch_abort_handler",
        "    b data_abort_handler",
        "    b reserved_handler",
        "    b irq_handler",
        "    b fiq_handler",
        "initialize:",
        "    mov r0, #0",
        "    mov r1, #0",
        "    mov r2, #0",
        "    mov r3, #0",
        "    mov r4, #0",
        "    mov r5, #0",
        "    mov r6, #0",
        "    mov r7, #0",
        "    mov r8, #0",
        "    mov r9, #0",
        "    mov r10, #0",
        "    mov r11, #0",
        "    mov r12, #0",
        "    ldr r13, =0x0001f000",
        "    mov r14, #0",
        *initialize_memory,
        "    cmp r0, r0",
        "    b measure_begin",
        "measure_begin:",
        *modes,
        *exception_lines,
        "    /* enter MODE_USER after every privileged bank is covered */",
        f"    mov r7, #0x{MODE_USER:02x}",
        "    msr cpsr_c, r7",
        *arm_lines,
        "    ldr r5, =thumb_random_entry",
        "    bx r5",
        "    .thumb",
        "    .thumb_func",
        "thumb_random_entry:",
        "    ldr r6, =0x00010000",
        *thumb_lines,
        "    svc #0x42",
        "    .hword 0xde00 /* allocated Thumb undefined instruction */",
        "    ldr r5, =arm_random_return",
        "    bx r5",
        "    .align 2",
        "    .arm",
        "arm_random_return:",
        "    ldr r10, =0x00010000",
        "    ldmia r10, {r8-r12}",
        "    b measure_end",
        "measure_end:",
        "    ldr r0, =0x51a7e11a",
        "    ldr r1, =0xae581ee5",
        "    svc #0x7f",
        "    b .",
        "semihost_call:",
        "    mov r0, #0x20",
        "    adr r1, semihost_exit",
        "    svc #0x123456",
        "undefined_handler:",
        "    add r6, r6, #1",
        "    movs pc, lr",
        "svc_handler:",
        "    ldr r12, =0x51a7e11a",
        "    cmp r0, r12",
        "    bne ordinary_svc",
        "    mvn r12, r12",
        "    cmp r1, r12",
        "    beq semihost_call",
        "ordinary_svc:",
        "    add r6, r6, #2",
        "    movs pc, lr",
        "prefetch_abort_handler:",
        "data_abort_handler:",
        "reserved_handler:",
        "irq_handler:",
        "fiq_handler:",
        "    b .",
        "    .align 2",
        "semihost_exit:",
        "    .word 0x00020026",
        "    .word 0",
        "    .ltorg",
        "",
    ]
    return "\n".join(source_lines), coverage


def write_word_hex(binary: bytes, path: pathlib.Path) -> None:
    padded = binary + bytes((-len(binary)) % 4)
    lines = ["@00000000"]
    for offset in range(0, len(padded), 4):
        lines.append(
            f"{int.from_bytes(padded[offset:offset + 4], 'little'):08x}"
        )
    path.write_text("\n".join(lines) + "\n", encoding="ascii")


def expected_exception(before_pc: int, after_pc: int) -> int:
    if after_pc == 0x0000_0004 and before_pc >= 0x20:
        return 1
    if after_pc == 0x0000_0008 and before_pc >= 0x20:
        return 2
    return EXPECTED_EXCEPTION_NONE


def packed_expected_line(
    before: qemu_reference.CpuState,
    after: qemu_reference.CpuState,
) -> str:
    words = [
        before.pc,
        1 if (before.psr & (1 << 5)) else 0,
        after.psr & PSR_COMPARE_MASK,
        expected_exception(before.pc, after.pc),
        *after.registers[:15],
    ]
    if len(words) != 19:
        raise AssertionError("random expected state record is not 19 words")
    return "".join(f"{word & 0xffff_ffff:08x}" for word in words)


def compile_program(
    source: pathlib.Path,
    directory: pathlib.Path,
    args: argparse.Namespace,
) -> tuple[pathlib.Path, pathlib.Path, dict[str, int], tuple[str, ...]]:
    elf = directory / "program.elf"
    binary = directory / "program.bin"
    command = (
        args.clang,
        "--target=arm-none-eabi",
        "-march=armv4t",
        "-marm",
        "-nostdlib",
        "-fuse-ld=lld",
        "-Wl,--image-base=0",
        "-Wl,-Ttext=0",
        "-Wl,--entry=_start",
        "-Wl,--build-id=none",
        str(source),
        "-o",
        str(elf),
    )
    run_command(command)
    run_command((args.objcopy, "-O", "binary", str(elf), str(binary)))
    symbols = qemu_reference.parse_symbols(
        run_command((args.nm, "--defined-only", str(elf)))
    )
    return elf, binary, symbols, command


def qemu_expected(
    source: pathlib.Path,
    directory: pathlib.Path,
    args: argparse.Namespace,
) -> tuple[int, dict[str, Any]]:
    elf, binary, symbols, compile_command = compile_program(
        source, directory, args
    )
    trace = directory / "qemu.log"
    expected = directory / "expected.hex"
    program = directory / "program.hex"
    permitted_memory = directory / "permitted_memory.hex"
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
        "-device",
        f"loader,file={binary},addr=0,force-raw=on,cpu-num=0",
        "-semihosting-config",
        "enable=on,target=native",
        "-d",
        "cpu,nochain",
        "-D",
        str(trace),
    )
    environment = os.environ.copy()
    environment["QEMU_AUDIO_DRV"] = "none"
    run_command(qemu_command, environment=environment)
    states = qemu_reference.parse_qemu_states(
        trace.read_text(encoding="ascii")
    )
    events = qemu_reference.differential_events(
        states,
        begin=symbols["measure_begin"] & ~1,
        end=symbols["measure_end"] & ~1,
    )
    expected.write_text(
        "\n".join(
            packed_expected_line(before, after)
            for before, after in events
        )
        + "\n",
        encoding="ascii",
    )
    write_word_hex(binary.read_bytes(), program)
    final_state = events[-1][1]
    permitted_memory.write_text(
        "\n".join(f"{value:08x}" for value in final_state.registers[8:13])
        + "\n",
        encoding="ascii",
    )
    artifacts = {
        path.name: artifact_entry(path, directory)
        for path in (
            source,
            elf,
            binary,
            trace,
            expected,
            program,
            permitted_memory,
        )
    }
    return len(events), {
        "compile_command": list(compile_command),
        "qemu_command": list(qemu_command),
        "artifacts": artifacts,
    }


def rotate_right(value: int, amount: int) -> int:
    amount %= 32
    if amount == 0:
        return value & 0xffff_ffff
    return (
        (value >> amount) | ((value << (32 - amount)) & 0xffff_ffff)
    ) & 0xffff_ffff


def sign_extend(value: int, width: int) -> int:
    sign = 1 << (width - 1)
    return ((value ^ sign) - sign) & 0xffff_ffff


def load_memory(
    words: list[int],
    byte_address: int,
    kind: str,
    big_endian: bool,
) -> int:
    word = words[byte_address // 4]
    low = byte_address & 3
    if kind == "word":
        return rotate_right(word, 8 * low)
    if kind in {"byte", "signed_byte"}:
        lane = (3 - low) if big_endian else low
        value = (word >> (8 * lane)) & 0xff
        return sign_extend(value, 8) if kind == "signed_byte" else value
    if low not in (0, 2):
        raise ValueError("generated halfword access is not aligned")
    high = (not bool(low & 2)) if big_endian else bool(low & 2)
    value = (word >> (16 if high else 0)) & 0xffff
    return sign_extend(value, 16) if kind == "signed_half" else value


def store_memory(
    words: list[int],
    byte_address: int,
    kind: str,
    value: int,
    big_endian: bool,
) -> None:
    index = byte_address // 4
    low = byte_address & 3
    if kind == "word":
        if low:
            raise ValueError("random word stores are constrained aligned")
        words[index] = value & 0xffff_ffff
        return
    if kind == "byte":
        lane = (3 - low) if big_endian else low
        mask = 0xff << (8 * lane)
        words[index] = (
            (words[index] & ~mask) | ((value & 0xff) << (8 * lane))
        ) & 0xffff_ffff
        return
    if low not in (0, 2):
        raise ValueError("generated halfword store is not aligned")
    high = (not bool(low & 2)) if big_endian else bool(low & 2)
    shift = 16 if high else 0
    mask = 0xffff << shift
    words[index] = (
        (words[index] & ~mask) | ((value & 0xffff) << shift)
    ) & 0xffff_ffff


def generate_policy_source(
    seed: int,
    instruction_count: int,
    *,
    big_endian: bool,
) -> tuple[str, list[int], int, set[str]]:
    rng = random.Random(seed ^ (0xB16E_0001 if big_endian else 0x1177_E001))
    data_words = [rng.getrandbits(32) for _ in range(8)]
    lines = [
        "/* Generated ARM7TDMI endian/unaligned permitted-memory program. */",
        "    .syntax unified",
        "    .cpu arm7tdmi",
        "    .section .text",
        "    .global _start",
        "    .global measure_begin",
        "    .global measure_end",
        "    .arm",
        "_start:",
        "    b initialize",
        "initialize:",
        "    ldr r10, =0x00018000",
        "    ldr r11, =0x0001a000",
        "measure_begin:",
    ]
    for index, value in enumerate(data_words):
        lines.extend(
            (
                f"    ldr r0, =0x{value:08x}",
                f"    str r0, [r10, #{4 * index}]",
            )
        )

    expected_results: list[int] = []
    coverage = {
        "alignment",
        "aligned",
        "unaligned",
        "memory",
        "permitted_memory",
        "big" if big_endian else "little",
        "byte",
        "halfword",
        "word",
        "signed",
    }

    def emit_load(kind: str, address: int) -> None:
        mnemonic = {
            "word": "ldr",
            "byte": "ldrb",
            "signed_byte": "ldrsb",
            "half": "ldrh",
            "signed_half": "ldrsh",
        }[kind]
        result = load_memory(data_words, address, kind, big_endian)
        output_offset = 4 * len(expected_results)
        lines.append(f"    {mnemonic} r0, [r10, #{address}]")
        lines.append(f"    str r0, [r11, #{output_offset}]")
        expected_results.append(result)

    def emit_store(kind: str, address: int, value: int) -> None:
        mnemonic = {"word": "str", "byte": "strb", "half": "strh"}[kind]
        lines.append(f"    ldr r0, =0x{value:08x}")
        lines.append(f"    {mnemonic} r0, [r10, #{address}]")
        store_memory(data_words, address, kind, value, big_endian)

    # Deterministically hit every legacy word alignment and endian byte lane.
    for offset in range(4):
        emit_load("word", offset)
        emit_load("byte", offset)
    for offset in (0, 2):
        emit_load("half", offset)
        emit_load("signed_half", offset)
    emit_load("signed_byte", 1)

    operation_count = max(32, instruction_count // 4)
    load_kinds = ("word", "byte", "signed_byte", "half", "signed_half")
    for _ in range(operation_count):
        if rng.randrange(100) < 65:
            kind = rng.choice(load_kinds)
            if kind == "word":
                address = rng.randrange(0, len(data_words) * 4)
            elif kind in {"half", "signed_half"}:
                address = 2 * rng.randrange(0, len(data_words) * 2)
            else:
                address = rng.randrange(0, len(data_words) * 4)
            emit_load(kind, address)
        else:
            kind = rng.choice(("word", "byte", "half"))
            if kind == "word":
                address = 4 * rng.randrange(0, len(data_words))
            elif kind == "half":
                address = 2 * rng.randrange(0, len(data_words) * 2)
            else:
                address = rng.randrange(0, len(data_words) * 4)
            emit_store(kind, address, rng.getrandbits(32))

    for index in range(len(data_words)):
        emit_load("word", 4 * index)

    completion = 0xC0DE_CAFE
    completion_offset = 4 * len(expected_results)
    lines.extend(
        (
            f"    ldr r0, =0x{completion:08x}",
            f"    str r0, [r11, #{completion_offset}]",
            "measure_end:",
            "    b .",
            "    .ltorg",
            "",
        )
    )
    expected_results.append(completion)
    expected = [*expected_results, *data_words]
    return "\n".join(lines), expected, len(expected_results), coverage


def build_policy_case(
    seed: int,
    instruction_count: int,
    *,
    big_endian: bool,
    directory: pathlib.Path,
    args: argparse.Namespace,
) -> dict[str, Any]:
    directory.mkdir(parents=True, exist_ok=True)
    source = directory / "policy.S"
    expected_path = directory / "expected_memory.hex"
    program_path = directory / "program.hex"
    source_text, expected, result_words, coverage = generate_policy_source(
        seed, instruction_count, big_endian=big_endian
    )
    source.write_text(source_text, encoding="utf-8")
    expected_path.write_text(
        "\n".join(f"{word:08x}" for word in expected) + "\n",
        encoding="ascii",
    )
    elf, binary, _symbols, compile_command = compile_program(
        source, directory, args
    )
    write_word_hex(binary.read_bytes(), program_path)
    simulation_command = (
        str(args.policy_binary.resolve()),
        f"+PROGRAM_HEX={program_path.resolve()}",
        f"+EXPECTED_MEMORY_HEX={expected_path.resolve()}",
        f"+EXPECTED_WORDS={result_words}",
        "+DATA_WORDS=8",
        f"+BIG_ENDIAN={1 if big_endian else 0}",
        f"+SEED={seed}",
    )
    output = run_command(simulation_command)
    if "[random_policy] PASS" not in output:
        raise ValueError("policy simulator omitted its PASS marker")
    simulation_log = directory / "simulation.log"
    simulation_log.write_text(output, encoding="utf-8")
    return {
        "status": "passed",
        "endian": "big" if big_endian else "little",
        "coverage": sorted(coverage),
        "result_words": result_words,
        "compile_command": list(compile_command),
        "simulation_command": list(simulation_command),
        "artifacts": {
            path.name: artifact_entry(path, directory)
            for path in (
                source,
                elf,
                binary,
                program_path,
                expected_path,
                simulation_log,
            )
        },
    }


def build_seed_case(
    seed: int,
    instruction_count: int,
    directory: pathlib.Path,
    args: argparse.Namespace,
) -> dict[str, Any]:
    directory.mkdir(parents=True, exist_ok=True)
    differential_directory = directory / "differential"
    differential_directory.mkdir()
    source = differential_directory / "random.S"
    source_text, qemu_coverage = generate_differential_source(
        seed, instruction_count
    )
    source.write_text(source_text, encoding="utf-8")
    event_count, qemu_metadata = qemu_expected(
        source, differential_directory, args
    )
    simulation_command = (
        str(args.differential_binary.resolve()),
        f"+PROGRAM_HEX={(differential_directory / 'program.hex').resolve()}",
        f"+EXPECTED_HEX={(differential_directory / 'expected.hex').resolve()}",
        f"+EXPECTED_EVENTS={event_count}",
        f"+PERMITTED_MEMORY_HEX={(differential_directory / 'permitted_memory.hex').resolve()}",
        f"+SEED={seed}",
    )
    output = run_command(simulation_command)
    if "[random_diff] PASS" not in output:
        raise ValueError("differential simulator omitted its PASS marker")
    simulation_log = differential_directory / "simulation.log"
    simulation_log.write_text(output, encoding="utf-8")
    qemu_metadata["simulation_command"] = list(simulation_command)
    qemu_metadata["artifacts"]["simulation.log"] = artifact_entry(
        simulation_log, differential_directory
    )

    profiles: dict[str, Any] = {}
    combined_coverage = set(qemu_coverage)
    for name, big_endian in (("little", False), ("big", True)):
        profile = build_policy_case(
            seed,
            instruction_count,
            big_endian=big_endian,
            directory=directory / f"policy_{name}",
            args=args,
        )
        profiles[name] = profile
        combined_coverage.update(profile["coverage"])

    return {
        "seed": seed,
        "status": "passed",
        "qemu_events": event_count,
        "coverage": sorted(combined_coverage),
        "differential": qemu_metadata,
        "policy_profiles": profiles,
        "reproducer": [
            sys.executable,
            str(pathlib.Path(__file__).resolve()),
            "--differential-binary",
            str(args.differential_binary.resolve()),
            "--policy-binary",
            str(args.policy_binary.resolve()),
            "--output",
            str(args.output.resolve()),
            "--seeds",
            "1",
            "--seed-base",
            str(seed),
            "--instructions",
            str(instruction_count),
        ],
    }


def required_coverage() -> set[str]:
    return {
        "instruction",
        "arm",
        "thumb",
        "register",
        "flags",
        "mode",
        "banked_register",
        "memory",
        "load",
        "store",
        "exception",
        "svc",
        "undefined",
        "alignment",
        "aligned",
        "unaligned",
        "little",
        "big",
        "dependency",
        "permitted_memory",
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--differential-binary", type=pathlib.Path, required=True
    )
    parser.add_argument("--policy-binary", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--seeds", type=int, default=32)
    parser.add_argument("--seed-base", type=int, default=1)
    parser.add_argument("--instructions", type=int, default=256)
    parser.add_argument("--clang", default="clang")
    parser.add_argument("--objcopy", default="llvm-objcopy")
    parser.add_argument("--nm", default="llvm-nm")
    parser.add_argument("--qemu", default="qemu-system-arm")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.seeds <= 0 or args.instructions < 32:
        raise ValueError("seeds must be positive and instructions at least 32")
    if not args.differential_binary.is_file():
        raise ValueError("differential simulator binary is missing")
    if not args.policy_binary.is_file():
        raise ValueError("policy simulator binary is missing")

    output = args.output.resolve()
    artifact_root = output.parent / "constrained_random"
    if artifact_root.is_dir():
        shutil.rmtree(artifact_root)
    artifact_root.mkdir(parents=True, exist_ok=True)
    git_status = git_text("status", "--porcelain=v1", "--untracked-files=all")
    release_grade = (
        args.seeds >= MIN_RELEASE_SEEDS
        and args.instructions >= MIN_RELEASE_INSTRUCTIONS
    )
    report: dict[str, Any] = {
        "schema": SCHEMA,
        "status": "running",
        "started_utc": utc_now(),
        "git": {
            "commit": git_text("rev-parse", "HEAD"),
            "dirty": bool(git_status),
            "status": git_status.splitlines(),
        },
        "configuration": {
            "seed_count": args.seeds,
            "seed_base": args.seed_base,
            "instructions_per_seed": args.instructions,
            "minimum_release_qemu_events": MIN_RELEASE_EVENTS,
            "release_grade": release_grade,
            "profiles": ["qemu-shared-armv4t", "little", "big"],
        },
        "tools": {
            "python": f"Python {sys.version.replace(chr(10), ' ')}",
            "clang": run_command((args.clang, "--version")).splitlines()[0],
            "qemu": run_command((args.qemu, "--version")).splitlines()[0],
            "differential_binary_sha256": sha256(args.differential_binary),
            "policy_binary_sha256": sha256(args.policy_binary),
        },
        "inputs": {
            entry["path"]: entry
            for entry in (
                file_entry(pathlib.Path(__file__)),
                file_entry(
                    REPO_ROOT
                    / "verification"
                    / "qemu_armv4t_reference.py"
                ),
                file_entry(
                    REPO_ROOT
                    / "tb"
                    / "integration"
                    / "arm7tdmis_random_diff_tb.sv"
                ),
                file_entry(
                    REPO_ROOT
                    / "tb"
                    / "integration"
                    / "arm7tdmis_random_policy_tb.sv"
                ),
            )
        },
        "required_coverage": sorted(required_coverage()),
        "seeds": [],
    }
    write_json(output, report)

    try:
        for offset in range(args.seeds):
            seed = args.seed_base + offset
            print(
                f"[constrained-random] seed={seed} "
                f"instructions={args.instructions}",
                flush=True,
            )
            seed_result = build_seed_case(
                seed,
                args.instructions,
                artifact_root / f"seed-{seed:08x}",
                args,
            )
            report["seeds"].append(seed_result)
            write_json(output, report)
    except (CommandFailure, ValueError) as error:
        report["status"] = "failed"
        report["finished_utc"] = utc_now()
        report["failure"] = str(error)
        if isinstance(error, CommandFailure):
            report["failure_command"] = list(error.command)
            report["failure_output"] = error.output[-20_000:]
        write_json(output, report)
        print(f"[constrained-random] FAIL: {error}", file=sys.stderr)
        return 1

    covered = {
        bin_name
        for seed in report["seeds"]
        for bin_name in seed["coverage"]
    }
    missing = required_coverage() - covered
    total_events = sum(seed["qemu_events"] for seed in report["seeds"])
    if missing:
        report["status"] = "failed"
        report["failure"] = f"missing required coverage: {sorted(missing)}"
    elif release_grade and total_events < MIN_RELEASE_EVENTS:
        report["status"] = "failed"
        report["failure"] = (
            f"release campaign has only {total_events} QEMU events; "
            f"requires {MIN_RELEASE_EVENTS}"
        )
    else:
        report["status"] = "passed"
    report["finished_utc"] = utc_now()
    report["completed_seed_count"] = len(report["seeds"])
    report["total_qemu_events"] = total_events
    report["covered"] = sorted(covered)
    write_json(output, report)
    if report["status"] != "passed":
        print(f"[constrained-random] FAIL: {report['failure']}", file=sys.stderr)
        return 1
    print(
        "[constrained-random] PASS "
        f"({len(report['seeds'])} seeds, {total_events} QEMU retirements)",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
