#!/usr/bin/env python3
"""Fail-closed architectural-control mutation runner."""

from __future__ import annotations

import dataclasses
import pathlib
import subprocess
import sys
from collections.abc import Callable, Iterable


SCRIPT_DIR = pathlib.Path(__file__).resolve().parent


@dataclasses.dataclass(frozen=True)
class Mutation:
    name: str
    command: tuple[str, ...]
    expected_diagnostic: str


@dataclasses.dataclass(frozen=True)
class MutationResult:
    name: str
    status: str
    returncode: int
    expected_diagnostic: str


class MutationFailure(RuntimeError):
    """Raised when a mutant survives or dies for an unrelated reason."""


MUTATIONS = (
    Mutation(
        name="writeback",
        command=(
            "make",
            "integ-sequence_dependencies",
            "INTEG_EXTRA_FLAGS_sequence_dependencies="
            "-DARM7TDMIS_MUTATE_WRITEBACK",
        ),
        expected_diagnostic="[sequence_dependencies] FAIL",
    ),
    Mutation(
        name="flags",
        command=(
            "make",
            "integ-flags_preserve",
            "INTEG_EXTRA_FLAGS_flags_preserve=-DARM7TDMIS_MUTATE_FLAGS",
        ),
        expected_diagnostic="[flags_preserve] FAIL",
    ),
    Mutation(
        name="exception",
        command=(
            "make",
            "integ-arm_exception_lr",
            "INTEG_EXTRA_FLAGS_arm_exception_lr="
            "-DARM7TDMIS_MUTATE_EXCEPTION",
        ),
        expected_diagnostic="[arm_exception_lr/SWI] FAIL",
    ),
    Mutation(
        name="bus",
        command=(
            "make",
            "integ-fetch_sequence",
            "INTEG_EXTRA_FLAGS_fetch_sequence=-DARM7TDMIS_MUTATE_BUS",
        ),
        expected_diagnostic="CPnMREQ does not mirror TRANS active",
    ),
)


Runner = Callable[[tuple[str, ...]], subprocess.CompletedProcess[str]]


def _subprocess_runner(
    command: tuple[str, ...],
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=SCRIPT_DIR,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )


def run_mutations(
    mutations: Iterable[Mutation],
    *,
    runner: Runner = _subprocess_runner,
) -> list[MutationResult]:
    """Require every mutant to fail through its intended architectural check."""

    results: list[MutationResult] = []
    for mutation in mutations:
        completed = runner(mutation.command)
        output = completed.stdout or ""
        if completed.returncode == 0:
            raise MutationFailure(
                f"{mutation.name} mutant survived: {' '.join(mutation.command)}"
            )
        if mutation.expected_diagnostic not in output:
            tail = "\n".join(output.splitlines()[-20:])
            raise MutationFailure(
                f"{mutation.name} mutant reached wrong detector; expected "
                f"{mutation.expected_diagnostic!r}\n{tail}"
            )
        results.append(
            MutationResult(
                name=mutation.name,
                status="killed",
                returncode=completed.returncode,
                expected_diagnostic=mutation.expected_diagnostic,
            )
        )
    return results


def main() -> int:
    try:
        results = run_mutations(MUTATIONS)
    except MutationFailure as error:
        print(f"[mutation] FAIL: {error}", file=sys.stderr)
        return 1

    for result in results:
        print(
            f"[mutation/{result.name}] PASS: killed by "
            f"{result.expected_diagnostic}"
        )
    print(f"[mutation] PASS: killed {len(results)}/{len(MUTATIONS)} mutants")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
