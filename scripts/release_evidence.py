#!/usr/bin/env python3
"""Validate and archive immutable regression/coverage release evidence."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import pathlib
import re
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
TABLE7_REQUIRED_CROSSES = (
    "class_waveform_endian_stall",
    "class_condition_mode",
    "register_pc_state",
    "multiply_class_m",
    "block_class_n",
    "coprocessor_class_b_n",
    "memory_class_endian_alignment",
    "memory_class_abort",
    "class_interrupt_exception",
)
RANDOM_EVENT_CLASS_BINS = (
    "undef",
    "dp",
    "msr",
    "mrs",
    "mul",
    "mull",
    "branch",
    "bx",
    "ldr_str",
    "ldrh_strh",
    "ldm_stm",
    "swp",
    "swi",
    "cdp",
    "mcr_mrc",
    "ldc_stc",
)
RANDOM_EVENT_BINS = (
    "abort_opcode_read",
    "abort_data_read",
    "abort_data_write",
    "irq",
    "fiq",
    "reset",
    "dbgrq",
    "cp_ready",
    "cp_busy",
    "cp_absent",
)
FUNCTIONAL_COVERAGE_GROUPS = {
    "arm.class",
    "arm.condition",
    "arm.dp_opcode",
    "arm.shifter",
    "arm.multiply",
    "arm.psr",
    "arm.branch",
    "arm.single_transfer",
    "arm.extra_transfer",
    "arm.block_transfer",
    "arm.block_operands",
    "arm.swap",
    "arm.coprocessor",
    "thumb.format",
    "thumb.alu",
    "thumb.condition",
    "thumb.subfamily",
    "exception.reserved",
    "exception.policy",
}
FUNCTIONAL_COVERAGE_DOMAINS = {
    "arm_decode_rows": 4096,
    "arm_nv_rows": 4096,
    "thumb_words": 65536,
    "arm_static_policy_rows": 1066,
    "thumb_static_policy_rows": 448,
}


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


def _formal_required_covers(manifest: dict[str, Any]) -> set[str]:
    if manifest.get("schema") != "arm7tdmis-formal-map-v1":
        raise ValueError("formal requirements manifest has wrong schema")
    covers = manifest.get("covers", {})
    result = {
        f"fsm.state.{value}" for value in covers.get("fsm_states", [])
    }
    result.update(
        f"fsm.transition.{value}"
        for value in covers.get("fsm_transitions", [])
    )
    result.update(
        f"exception.{value}" for value in covers.get("exceptions", [])
    )
    result.update(f"debug.{value}" for value in covers.get("debug", []))
    return result


def validate_formal_evidence(
    report: dict[str, Any],
    manifest: dict[str, Any],
    *,
    expected_commit: str,
) -> None:
    """Reject incomplete, stale, weakened, or unhashed formal evidence."""
    if report.get("schema") != "arm7tdmis-formal-v1":
        raise ValueError("formal report has wrong schema")
    if report.get("status") != "passed" or report.get("failure") is not None:
        raise ValueError("formal report is not passed")
    git = report.get("git", {})
    if git.get("dirty"):
        raise ValueError("formal report describes a dirty source tree")
    if git.get("commit") != expected_commit:
        raise ValueError("formal report commit does not match regression")
    if report.get("toolchain") != manifest.get("toolchain"):
        raise ValueError("formal report does not use the pinned toolchain")

    proof_entries = manifest.get("proofs")
    if (
        not isinstance(proof_entries, list)
        or any(not isinstance(entry, dict) for entry in proof_entries)
    ):
        raise ValueError("formal proof manifest is malformed")
    required_proofs = {entry.get("id") for entry in proof_entries}
    if None in required_proofs or len(required_proofs) != len(proof_entries):
        raise ValueError("formal proof IDs are missing or duplicated")
    required_covers = _formal_required_covers(manifest)
    if (
        set(report.get("required_proofs", [])) != required_proofs
        or set(report.get("proven_proofs", [])) != required_proofs
        or set(report.get("required_covers", [])) != required_covers
        or set(report.get("covered_covers", [])) != required_covers
        or report.get("uncovered_covers") != []
    ):
        raise ValueError("formal proof or cover closure is incomplete")

    results = report.get("results")
    required_results = required_proofs | required_covers
    if not isinstance(results, dict) or set(results) != required_results:
        raise ValueError("formal result map is incomplete")
    digest_pattern = re.compile(r"^[0-9a-f]{64}$")
    for obligation, entry in results.items():
        if (
            not isinstance(entry, dict)
            or entry.get("status") != "passed"
            or not isinstance(entry.get("engine"), str)
            or not entry["engine"]
            or not isinstance(entry.get("depth"), int)
            or entry["depth"] <= 0
        ):
            raise ValueError(f"formal result is not passing: {obligation}")
        for artifact_name in ("log", "source"):
            artifact = entry.get(artifact_name)
            if (
                not isinstance(artifact, dict)
                or not isinstance(artifact.get("path"), str)
                or not artifact["path"]
                or not isinstance(artifact.get("bytes"), int)
                or artifact["bytes"] <= 0
                or digest_pattern.fullmatch(str(artifact.get("sha256", "")))
                is None
            ):
                raise ValueError(
                    f"formal {obligation} lacks hashed {artifact_name}"
                )
        if obligation in required_covers:
            witnesses = entry.get("witnesses")
            if (
                not isinstance(witnesses, list)
                or len(witnesses) != 2
                or {
                    pathlib.PurePosixPath(str(witness.get("path", ""))).suffix
                    for witness in witnesses
                    if isinstance(witness, dict)
                }
                != {".vcd", ".yw"}
            ):
                raise ValueError(
                    f"formal cover {obligation} lacks its witness pair"
                )
            for witness in witnesses:
                if (
                    not isinstance(witness, dict)
                    or not isinstance(witness.get("path"), str)
                    or not witness["path"]
                    or not isinstance(witness.get("bytes"), int)
                    or witness["bytes"] <= 0
                    or digest_pattern.fullmatch(
                        str(witness.get("sha256", ""))
                    )
                    is None
                ):
                    raise ValueError(
                        f"formal cover {obligation} has an unhashed witness"
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


def validate_random_event_evidence(
    report: dict[str, Any],
    *,
    expected_commit: str,
) -> None:
    """Reject incomplete, stale, or weakened VAL-005 campaign evidence."""
    if report.get("schema") != "arm7tdmis-random-events-v1":
        raise ValueError("random-event report has wrong schema")
    if report.get("status") != "passed" or report.get("failures"):
        raise ValueError("random-event report is not passed")
    if report.get("git", {}).get("dirty"):
        raise ValueError("random-event report describes a dirty source tree")
    if report.get("git", {}).get("commit") != expected_commit:
        raise ValueError("random-event report commit does not match regression")

    required_classes = report.get("required_class_bins")
    required_events = report.get("required_event_bins")
    if (
        not isinstance(required_classes, list)
        or len(required_classes) != len(set(required_classes))
        or set(required_classes) != set(RANDOM_EVENT_CLASS_BINS)
        or not isinstance(required_events, list)
        or len(required_events) != len(set(required_events))
        or set(required_events) != set(RANDOM_EVENT_BINS)
    ):
        raise ValueError("random-event required-bin manifest was weakened")
    if (
        set(report.get("covered_class_bins", []))
        != set(RANDOM_EVENT_CLASS_BINS)
        or set(report.get("covered_class_stall_bins", []))
        != set(RANDOM_EVENT_CLASS_BINS)
        or set(report.get("covered_event_bins", []))
        != set(RANDOM_EVENT_BINS)
    ):
        raise ValueError("random-event aggregate coverage is incomplete")

    configuration = report.get("configuration", {})
    seeds = report.get("seeds")
    if (
        not isinstance(seeds, list)
        or any(not isinstance(entry, dict) for entry in seeds)
        or not isinstance(configuration.get("seed_count"), int)
        or configuration["seed_count"] < 32
        or configuration["seed_count"] != len(seeds)
        or report.get("completed_seed_count") != len(seeds)
        or len({entry.get("seed") for entry in seeds}) != len(seeds)
        or configuration.get("minimum_decisions_per_seed", 0) < 256
    ):
        raise ValueError("random-event report lacks 32 unique strong seeds")

    minimum_decisions = configuration["minimum_decisions_per_seed"]
    for entry in seeds:
        if (
            entry.get("status") != "passed"
            or entry.get("exit_code") != 0
            or not entry.get("pass_marker_found")
            or int(entry.get("decision_count", 0)) < minimum_decisions
            or set(entry.get("class_bins", []))
            != set(RANDOM_EVENT_CLASS_BINS)
            or set(entry.get("class_stall_bins", []))
            != set(RANDOM_EVENT_CLASS_BINS)
            or set(entry.get("event_bins", [])) != set(RANDOM_EVENT_BINS)
            or not isinstance(entry.get("reproducer"), list)
            or not entry["reproducer"]
        ):
            raise ValueError("random-event seed evidence is incomplete")

    total_decisions = sum(
        int(entry.get("decision_count", 0)) for entry in seeds
    )
    if report.get("total_decision_count") != total_decisions:
        raise ValueError("random-event decision total is inconsistent")


def _functional_required_bins(
    manifest: dict[str, Any],
) -> tuple[list[str], set[str]]:
    if manifest.get("schema") != "arm7tdmis-functional-coverage-map-v1":
        raise ValueError("functional-coverage manifest has wrong schema")
    if manifest.get("domains") != FUNCTIONAL_COVERAGE_DOMAINS:
        raise ValueError("functional-coverage domains were weakened")
    groups = manifest.get("required_bin_groups")
    if (
        not isinstance(groups, list)
        or any(not isinstance(group, dict) for group in groups)
        or {group.get("id") for group in groups}
        != FUNCTIONAL_COVERAGE_GROUPS
    ):
        raise ValueError("functional-coverage groups are incomplete")
    evidence_entries = manifest.get("evidence")
    if (
        not isinstance(evidence_entries, list)
        or any(not isinstance(entry, dict) for entry in evidence_entries)
    ):
        raise ValueError("functional-coverage evidence map is malformed")
    evidence_phases = {entry.get("phase") for entry in evidence_entries}
    if None in evidence_phases or len(evidence_phases) != len(
        evidence_entries
    ):
        raise ValueError("functional-coverage evidence phases are ambiguous")

    required: list[str] = []
    for group in groups:
        members = group.get("members")
        if (
            group.get("kind")
            not in {"encoding-family", "exceptional-reserved"}
            or group.get("coverage") not in {"enumerated", "evidence"}
            or not isinstance(members, list)
            or not members
            or len(members) != len(set(members))
            or not re.search(
                r"(ARM DDI 0100|ARM DDI 0234|ARMv4T)",
                str(group.get("citation", "")),
            )
            or not isinstance(group.get("evidence"), list)
            or not group["evidence"]
            or not set(group["evidence"]) <= evidence_phases
        ):
            raise ValueError(
                f"functional-coverage group is malformed: {group.get('id')}"
            )
        required.extend(
            f"{group['id']}.{member}" for member in members
        )
    if len(required) != 234 or len(required) != len(set(required)):
        raise ValueError("functional-coverage required-bin count changed")

    by_group = {
        group["id"]: set(group["members"]) for group in groups
    }
    foundations = {
        "arm.class": {
            "undef",
            "dp",
            "msr",
            "mrs",
            "mul",
            "mull",
            "branch",
            "bx",
            "ldr_str",
            "ldrh_strh",
            "ldm_stm",
            "swp",
            "swi",
            "cdp",
            "mcr_mrc",
            "ldc_stc",
        },
        "arm.dp_opcode": {
            "and",
            "eor",
            "sub",
            "rsb",
            "add",
            "adc",
            "sbc",
            "rsc",
            "tst",
            "teq",
            "cmp",
            "cmn",
            "orr",
            "mov",
            "bic",
            "mvn",
        },
        "thumb.format": {f"{number:02d}" for number in range(1, 20)},
    }
    if any(by_group.get(group) != values for group, values in foundations.items()):
        raise ValueError("functional-coverage foundational bins changed")

    exclusions = manifest.get("exclusions")
    if not isinstance(exclusions, list) or not exclusions:
        raise ValueError("functional-coverage exclusions are missing")
    for exclusion in exclusions:
        if (
            not isinstance(exclusion, dict)
            or not exclusion.get("id")
            or not exclusion.get("pattern")
            or not exclusion.get("rationale")
            or not re.search(
                r"(ARM DDI 0100|ARM DDI 0234|ARMv4T)",
                str(exclusion.get("citation", "")),
            )
        ):
            raise ValueError("functional-coverage exclusion is uncited")
    return sorted(required), evidence_phases


def validate_functional_coverage_evidence(
    report: dict[str, Any],
    manifest: dict[str, Any],
    *,
    expected_commit: str,
) -> None:
    """Reject stale or weakened VAL-006 required-bin closure."""
    required, evidence_phases = _functional_required_bins(manifest)
    if report.get("schema") != "arm7tdmis-functional-coverage-v1":
        raise ValueError("functional-coverage report has wrong schema")
    if report.get("status") != "passed":
        raise ValueError("functional-coverage report is not passed")
    if report.get("git", {}).get("dirty"):
        raise ValueError(
            "functional-coverage report describes a dirty source tree"
        )
    if report.get("git", {}).get("commit") != expected_commit:
        raise ValueError(
            "functional-coverage report commit does not match regression"
        )

    domains = report.get("domains")
    expected_domains = {
        name: {"expected": count, "observed": count}
        for name, count in FUNCTIONAL_COVERAGE_DOMAINS.items()
    }
    if domains != expected_domains:
        raise ValueError("functional-coverage exhaustive domains are incomplete")
    if (
        report.get("required_bin_count") != len(required)
        or report.get("required_bins") != required
        or report.get("covered_bin_count") != len(required)
        or report.get("covered_bins") != required
        or report.get("uncovered_bins") != []
    ):
        raise ValueError("functional-coverage required bins are incomplete")
    if report.get("exclusions") != manifest.get("exclusions"):
        raise ValueError("functional-coverage exclusions do not match")
    evidence = report.get("evidence")
    if (
        not isinstance(evidence, dict)
        or set(evidence) != evidence_phases
        or any(
            not isinstance(entry, dict) or entry.get("status") != "passed"
            for entry in evidence.values()
        )
    ):
        raise ValueError("functional-coverage evidence is incomplete")


def validate_constrained_random_evidence(
    report: dict[str, Any],
    *,
    expected_commit: str,
    release_grade: bool,
) -> None:
    """Reject stale, weakened, incomplete, or non-passing VAL-002 evidence."""
    if report.get("schema") != "arm7tdmis-constrained-random-v1":
        raise ValueError("constrained-random report has wrong schema")
    if report.get("status") != "passed" or report.get("failure"):
        raise ValueError("constrained-random report is not passed")
    if report.get("git", {}).get("dirty"):
        raise ValueError(
            "constrained-random report describes a dirty source tree"
        )
    if report.get("git", {}).get("commit") != expected_commit:
        raise ValueError(
            "constrained-random report commit does not match regression"
        )

    configuration = report.get("configuration", {})
    seeds = report.get("seeds", [])
    if (
        not isinstance(seeds, list)
        or any(not isinstance(entry, dict) for entry in seeds)
        or report.get("completed_seed_count") != len(seeds)
        or configuration.get("seed_count") != len(seeds)
        or len({entry.get("seed") for entry in seeds}) != len(seeds)
        or any(entry.get("status") != "passed" for entry in seeds)
    ):
        raise ValueError("constrained-random seed manifest is incomplete")
    minimum_seeds = 32 if release_grade else 2
    minimum_instructions = 256 if release_grade else 64
    if (
        len(seeds) < minimum_seeds
        or configuration.get("instructions_per_seed", 0)
        < minimum_instructions
        or configuration.get("release_grade") is not release_grade
    ):
        raise ValueError("constrained-random campaign strength is too low")
    total_events = sum(int(entry.get("qemu_events", 0)) for entry in seeds)
    if report.get("total_qemu_events") != total_events:
        raise ValueError("constrained-random event total is inconsistent")
    if release_grade and total_events < 8_192:
        raise ValueError("constrained-random release trace is too short")

    required = set(report.get("required_coverage", []))
    covered = set(report.get("covered", []))
    required_dimensions = {
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
    if required != required_dimensions or not required <= covered:
        raise ValueError("constrained-random required coverage is incomplete")
    for seed in seeds:
        if (
            int(seed.get("qemu_events", 0))
            < configuration.get("instructions_per_seed", 0)
            or set(seed.get("policy_profiles", {})) != {"little", "big"}
            or not isinstance(seed.get("reproducer"), list)
            or not seed["reproducer"]
        ):
            raise ValueError("constrained-random seed evidence is incomplete")
        for name, expected_endian in (
            ("little", "little"),
            ("big", "big"),
        ):
            profile = seed["policy_profiles"][name]
            if (
                profile.get("status") != "passed"
                or profile.get("endian") != expected_endian
                or profile.get("result_words", 0) < 20
            ):
                raise ValueError(
                    f"constrained-random {name} profile is incomplete"
                )


def validate_public_suite_evidence(
    report: dict[str, Any],
    manifest: dict[str, Any],
    *,
    expected_commit: str,
) -> None:
    """Reject stale, altered, weakened, or non-passing VAL-003 evidence."""
    if manifest.get("schema") != "arm7tdmis-public-suites-v1":
        raise ValueError("public-suite manifest has wrong schema")
    manifest_upstream = manifest.get("upstream")
    manifest_suites = manifest.get("suites")
    manifest_patches = manifest.get("patches")
    if (
        not isinstance(manifest_upstream, dict)
        or manifest_upstream.get("url")
        != "https://github.com/jsmolka/gba-suite.git"
        or manifest_upstream.get("license_spdx") != "MIT"
        or not re.fullmatch(
            r"[0-9a-f]{40}", str(manifest_upstream.get("commit", ""))
        )
        or not re.fullmatch(
            r"[0-9a-f]{40}", str(manifest_upstream.get("tree", ""))
        )
        or not re.fullmatch(
            r"[0-9a-f]{64}",
            str(manifest_upstream.get("license_sha256", "")),
        )
        or not isinstance(manifest_patches, list)
        or not isinstance(manifest_suites, dict)
        or set(manifest_suites) != {"arm", "thumb"}
    ):
        raise ValueError("public-suite manifest is not trusted")

    if report.get("schema") != "arm7tdmis-public-suite-v1":
        raise ValueError("public-suite report has wrong schema")
    if report.get("status") != "passed" or report.get("failure"):
        raise ValueError("public-suite report is not passed")
    if report.get("git", {}).get("dirty"):
        raise ValueError("public-suite report describes a dirty source tree")
    if report.get("git", {}).get("commit") != expected_commit:
        raise ValueError("public-suite report commit does not match regression")

    upstream = report.get("upstream")
    if not isinstance(upstream, dict) or any(
        upstream.get(key) != value
        for key, value in manifest_upstream.items()
    ):
        raise ValueError("public-suite upstream provenance does not match")
    license_artifact = upstream.get("license_artifact")
    if (
        not isinstance(upstream.get("acquisition_commands"), list)
        or not isinstance(license_artifact, dict)
        or license_artifact.get("sha256")
        != manifest_upstream["license_sha256"]
        or type(license_artifact.get("bytes")) is not int
        or license_artifact["bytes"] <= 0
    ):
        raise ValueError("public-suite license evidence is incomplete")
    if report.get("patches") != manifest_patches:
        raise ValueError("public-suite policy patch manifest was altered")

    suites = report.get("suites")
    if (
        not isinstance(suites, dict)
        or set(suites) != {"arm", "thumb"}
        or report.get("suite_count") != 2
    ):
        raise ValueError("public-suite report does not contain both suites")

    total_retirements = 0
    minimum_isa_retirements = {
        "arm": {"arm_retirements": 8_000, "thumb_retirements": 1},
        "thumb": {"arm_retirements": 6_000, "thumb_retirements": 500},
    }
    for name in ("arm", "thumb"):
        suite_manifest = manifest_suites[name]
        suite = suites[name]
        if not isinstance(suite_manifest, dict) or not isinstance(suite, dict):
            raise ValueError(f"public-suite {name} entry is malformed")
        expected_fields = {
            "upstream_path": suite_manifest.get("path"),
            "upstream_sha256": suite_manifest.get("upstream_sha256"),
            "patched_sha256": suite_manifest.get("patched_sha256"),
            "idle_pc": suite_manifest.get("idle_pc"),
            "result_register": suite_manifest.get("result_register"),
            "expected_vram_signature": suite_manifest.get(
                "expected_vram_signature"
            ),
            "word_patches": suite_manifest.get("word_patches"),
        }
        if suite.get("status") != "passed" or any(
            suite.get(key) != value for key, value in expected_fields.items()
        ):
            raise ValueError(
                f"public-suite {name} result does not match its manifest"
            )
        if (
            not re.fullmatch(
                r"0x[0-9a-f]{8}",
                str(suite.get("expected_vram_signature", "")),
            )
            or suite.get("expected_vram_signature") == "0x00000000"
        ):
            raise ValueError(f"public-suite {name} signature is invalid")

        metrics = suite.get("metrics")
        metric_names = {
            "retirements",
            "arm_retirements",
            "thumb_retirements",
            "rom_words",
        }
        if (
            not isinstance(metrics, dict)
            or any(type(metrics.get(key)) is not int for key in metric_names)
            or metrics["retirements"]
            != metrics["arm_retirements"] + metrics["thumb_retirements"]
            or metrics["retirements"]
            < int(suite_manifest.get("minimum_retirements", 0))
            or metrics["rom_words"] <= 0
            or any(
                metrics[key] < minimum
                for key, minimum in minimum_isa_retirements[name].items()
            )
        ):
            raise ValueError(
                f"public-suite {name} retirement evidence is too weak"
            )
        total_retirements += metrics["retirements"]

        reproducer = suite.get("reproducer")
        artifacts = suite.get("artifacts")
        if (
            not isinstance(reproducer, list)
            or not reproducer
            or any(not isinstance(value, str) or not value for value in reproducer)
            or not isinstance(artifacts, dict)
            or not artifacts
        ):
            raise ValueError(
                f"public-suite {name} reproduction evidence is incomplete"
            )
        for artifact in artifacts.values():
            if (
                not isinstance(artifact, dict)
                or not isinstance(artifact.get("path"), str)
                or type(artifact.get("bytes")) is not int
                or artifact["bytes"] <= 0
                or not re.fullmatch(
                    r"[0-9a-f]{64}", str(artifact.get("sha256", ""))
                )
            ):
                raise ValueError(
                    f"public-suite {name} artifact manifest is malformed"
                )

    if (
        report.get("total_retirements") != total_retirements
        or total_retirements < 14_000
    ):
        raise ValueError("public-suite total retirement evidence is inconsistent")


def validate_table7_cross_evidence(
    report: dict[str, Any],
    manifest: dict[str, Any],
    *,
    expected_commit: str,
) -> None:
    """Reject stale, altered, weakened, or non-passing VAL-004 evidence."""
    required = manifest.get("required_crosses")
    definitions = manifest.get("crosses")
    if (
        manifest.get("schema") != "arm7tdmis-table7-cross-map-v1"
        or not isinstance(required, list)
        or tuple(required) != TABLE7_REQUIRED_CROSSES
        or len(required) != len(set(required))
        or not isinstance(definitions, dict)
        or set(definitions) != set(TABLE7_REQUIRED_CROSSES)
    ):
        raise ValueError("Chapter 7 cross manifest is not trusted")

    for name in TABLE7_REQUIRED_CROSSES:
        definition = definitions[name]
        if (
            not isinstance(definition, dict)
            or not isinstance(definition.get("description"), str)
            or not definition["description"]
            or not isinstance(definition.get("dimensions"), dict)
            or not definition["dimensions"]
            or type(definition.get("minimum_rows")) is not int
            or definition["minimum_rows"] <= 0
            or not isinstance(definition.get("evidence"), list)
            or not definition["evidence"]
        ):
            raise ValueError(f"Chapter 7 cross definition is weak: {name}")
        for evidence in definition["evidence"]:
            if (
                not isinstance(evidence, dict)
                or not re.fullmatch(
                    r"integration-[a-z0-9_]+",
                    str(evidence.get("phase", "")),
                )
                or not str(evidence.get("source", "")).startswith(
                    "tb/integration/"
                )
                or "PASS" not in str(evidence.get("marker", ""))
                or type(evidence.get("expected_rows")) is not int
                or evidence["expected_rows"] <= 0
            ):
                raise ValueError(
                    f"Chapter 7 cross evidence is weak: {name}"
                )

    if report.get("schema") != "arm7tdmis-table7-cross-v1":
        raise ValueError("Chapter 7 cross report has wrong schema")
    if report.get("status") != "passed" or report.get("failure"):
        raise ValueError("Chapter 7 cross report is not passed")
    if report.get("git", {}).get("dirty"):
        raise ValueError("Chapter 7 cross report describes a dirty tree")
    if report.get("git", {}).get("commit") != expected_commit:
        raise ValueError("Chapter 7 cross report commit does not match")
    if (
        report.get("required_crosses") != required
        or report.get("covered_crosses") != required
        or report.get("missing_crosses") != []
        or report.get("cross_count") != len(required)
    ):
        raise ValueError("Chapter 7 required cross coverage is incomplete")

    report_crosses = report.get("crosses")
    if not isinstance(report_crosses, dict) or set(report_crosses) != set(
        TABLE7_REQUIRED_CROSSES
    ):
        raise ValueError("Chapter 7 report cross set is incomplete")

    total_minimum_rows = 0
    total_observed_rows = 0
    for name in TABLE7_REQUIRED_CROSSES:
        definition = definitions[name]
        cross = report_crosses[name]
        expected_evidence = definition["evidence"]
        actual_evidence = cross.get("evidence")
        if (
            cross.get("description") != definition["description"]
            or cross.get("dimensions") != definition["dimensions"]
            or cross.get("minimum_rows") != definition["minimum_rows"]
            or not isinstance(actual_evidence, list)
            or len(actual_evidence) != len(expected_evidence)
        ):
            raise ValueError(f"Chapter 7 cross was altered: {name}")

        observed_rows = 0
        for expected, actual in zip(expected_evidence, actual_evidence):
            if not isinstance(actual, dict) or any(
                actual.get(key) != expected.get(key)
                for key in ("phase", "source", "marker", "expected_rows")
            ):
                raise ValueError(
                    f"Chapter 7 evidence identity was altered: {name}"
                )
            log = actual.get("log")
            source = actual.get("source_artifact")
            if (
                actual.get("status") != "passed"
                or not isinstance(log, dict)
                or not str(log.get("path", "")).startswith(
                    "reports/generated/logs/"
                )
                or type(log.get("bytes")) is not int
                or log["bytes"] <= 0
                or not re.fullmatch(
                    r"[0-9a-f]{64}", str(log.get("sha256", ""))
                )
                or not isinstance(source, dict)
                or source.get("path") != expected["source"]
                or type(source.get("bytes")) is not int
                or source["bytes"] <= 0
                or not re.fullmatch(
                    r"[0-9a-f]{64}", str(source.get("sha256", ""))
                )
            ):
                raise ValueError(
                    f"Chapter 7 hashed evidence is incomplete: {name}"
                )
            observed_rows += expected["expected_rows"]

        if (
            cross.get("observed_rows") != observed_rows
            or observed_rows < definition["minimum_rows"]
        ):
            raise ValueError(f"Chapter 7 cross is under-covered: {name}")
        total_minimum_rows += definition["minimum_rows"]
        total_observed_rows += observed_rows

    if (
        report.get("total_minimum_rows") != total_minimum_rows
        or report.get("total_observed_rows") != total_observed_rows
    ):
        raise ValueError("Chapter 7 aggregate row counts are inconsistent")


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
    if (
        regression.get("mode") == "full"
        and "table7-cross" not in phase_names
    ):
        raise ValueError(
            "full regression is missing mandatory Chapter 7 cross evidence"
        )
    if (
        regression.get("mode") == "full"
        and "random-events" not in phase_names
    ):
        raise ValueError(
            "full regression is missing mandatory randomized-event evidence"
        )
    if (
        regression.get("mode") == "full"
        and "functional-coverage" not in phase_names
    ):
        raise ValueError(
            "full regression is missing mandatory functional coverage"
        )
    if regression.get("mode") == "full" and "formal" not in phase_names:
        raise ValueError("full regression is missing mandatory formal evidence")
    if "formal" in phase_names:
        formal_report_path = REPORT_ROOT / "formal-report.json"
        formal_manifest_path = (
            REPO_ROOT / "verification/formal_requirements.json"
        )
        if not formal_report_path.is_file():
            raise ValueError("formal-report.json is missing")
        if not formal_manifest_path.is_file():
            raise ValueError("formal requirements manifest is missing")
        formal_report = json.loads(
            formal_report_path.read_text(encoding="utf-8")
        )
        formal_manifest = json.loads(
            formal_manifest_path.read_text(encoding="utf-8")
        )
        validate_formal_evidence(
            formal_report,
            formal_manifest,
            expected_commit=str(
                regression.get("git", {}).get("commit", "")
            ),
        )
        for result in formal_report["results"].values():
            for artifact_name in ("log", "source"):
                artifact = result[artifact_name]
                artifact_path = _repo_path(str(artifact["path"]))
                if (
                    artifact_path.stat().st_size != artifact["bytes"]
                    or _sha256(artifact_path) != artifact["sha256"]
                ):
                    raise ValueError(
                        f"formal {artifact_name} artifact hash mismatch"
                    )
                candidates.append(artifact_path)
            for witness in result.get("witnesses", []):
                witness_path = _repo_path(str(witness["path"]))
                if (
                    witness_path.stat().st_size != witness["bytes"]
                    or _sha256(witness_path) != witness["sha256"]
                ):
                    raise ValueError("formal cover witness hash mismatch")
                candidates.append(witness_path)
        for artifact_name in ("manifest", "sby_file", "runner_log"):
            artifact = formal_report.get(artifact_name, {})
            artifact_path = _repo_path(str(artifact.get("path", "")))
            if (
                artifact_path.stat().st_size != artifact.get("bytes")
                or _sha256(artifact_path) != artifact.get("sha256")
            ):
                raise ValueError(
                    f"formal {artifact_name} artifact hash mismatch"
                )
            candidates.append(artifact_path)
        candidates.extend(
            (formal_report_path.resolve(), formal_manifest_path.resolve())
        )
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
    if "random-events" in phase_names:
        event_report_path = REPORT_ROOT / "random-events-report.json"
        if not event_report_path.is_file():
            raise ValueError("random-event report is missing")
        event_report = json.loads(
            event_report_path.read_text(encoding="utf-8")
        )
        validate_random_event_evidence(
            event_report,
            expected_commit=str(
                regression.get("git", {}).get("commit", "")
            ),
        )
        expected_inputs = {"runner", "testbench", "binary"}
        inputs = event_report.get("inputs")
        if not isinstance(inputs, dict) or set(inputs) != expected_inputs:
            raise ValueError("random-event input manifest is incomplete")
        for input_entry in inputs.values():
            if not isinstance(input_entry, dict):
                raise ValueError("random-event input entry is malformed")
            input_path = _repo_path(str(input_entry.get("path", "")))
            if (
                input_path.stat().st_size != input_entry.get("bytes")
                or _sha256(input_path) != input_entry.get("sha256")
            ):
                raise ValueError("random-event input hash mismatch")
            candidates.append(input_path)
        for seed in event_report["seeds"]:
            log_entry = seed.get("log")
            if not isinstance(log_entry, dict):
                raise ValueError("random-event seed log is malformed")
            log_path = _repo_path(str(log_entry.get("path", "")))
            if (
                log_path.stat().st_size != log_entry.get("bytes")
                or _sha256(log_path) != log_entry.get("sha256")
                or _sha256(log_path) != seed.get("output_sha256")
            ):
                raise ValueError("random-event seed log hash mismatch")
            candidates.append(log_path)
        candidates.append(event_report_path.resolve())
    random_phase_names = {
        "random-validation",
        "random-validation-quick",
    } & phase_names
    if random_phase_names:
        if len(random_phase_names) != 1:
            raise ValueError("regression contains ambiguous random phases")
        random_report_path = REPORT_ROOT / "constrained-random-report.json"
        if not random_report_path.is_file():
            raise ValueError("constrained-random report is missing")
        random_report = json.loads(
            random_report_path.read_text(encoding="utf-8")
        )
        release_grade = "random-validation" in random_phase_names
        validate_constrained_random_evidence(
            random_report,
            expected_commit=str(
                regression.get("git", {}).get("commit", "")
            ),
            release_grade=release_grade,
        )
        for input_entry in random_report.get("inputs", {}).values():
            if not isinstance(input_entry, dict):
                raise ValueError(
                    "constrained-random report has a malformed input"
                )
            input_path = _repo_path(str(input_entry.get("path", "")))
            if (
                input_path.stat().st_size != input_entry.get("bytes")
                or _sha256(input_path) != input_entry.get("sha256")
            ):
                raise ValueError(
                    "constrained-random input hash mismatch"
                )
            candidates.append(input_path)

        artifact_root = REPORT_ROOT / "constrained_random"
        for seed in random_report.get("seeds", []):
            seed_value = int(seed["seed"])
            seed_root = artifact_root / f"seed-{seed_value:08x}"
            artifact_groups = [
                (
                    seed_root / "differential",
                    seed.get("differential", {}).get("artifacts", {}),
                ),
                *[
                    (
                        seed_root / f"policy_{name}",
                        seed.get("policy_profiles", {})
                        .get(name, {})
                        .get("artifacts", {}),
                    )
                    for name in ("little", "big")
                ],
            ]
            for group_root, artifacts in artifact_groups:
                if not isinstance(artifacts, dict) or not artifacts:
                    raise ValueError(
                        "constrained-random artifact group is empty"
                    )
                for artifact in artifacts.values():
                    if not isinstance(artifact, dict):
                        raise ValueError(
                            "constrained-random artifact is malformed"
                        )
                    artifact_path = (
                        group_root / str(artifact.get("path", ""))
                    ).resolve()
                    try:
                        artifact_path.relative_to(group_root.resolve())
                    except ValueError as error:
                        raise ValueError(
                            "constrained-random artifact escapes its seed"
                        ) from error
                    if (
                        not artifact_path.is_file()
                        or artifact_path.stat().st_size
                        != artifact.get("bytes")
                        or _sha256(artifact_path)
                        != artifact.get("sha256")
                    ):
                        raise ValueError(
                            "constrained-random artifact hash mismatch"
                        )
                    candidates.append(artifact_path)
        candidates.append(random_report_path.resolve())
    if "public-suite" in phase_names:
        public_report_path = REPORT_ROOT / "public-suite-report.json"
        public_manifest_path = REPO_ROOT / "verification" / "public_suites.json"
        if not public_report_path.is_file():
            raise ValueError("public-suite report is missing")
        if not public_manifest_path.is_file():
            raise ValueError("public-suite manifest is missing")
        public_report = json.loads(
            public_report_path.read_text(encoding="utf-8")
        )
        public_manifest = json.loads(
            public_manifest_path.read_text(encoding="utf-8")
        )
        validate_public_suite_evidence(
            public_report,
            public_manifest,
            expected_commit=str(
                regression.get("git", {}).get("commit", "")
            ),
        )

        expected_inputs = {
            "tb/integration/arm7tdmis_public_suite_tb.sv",
            "verification/public_suite.py",
            "verification/public_suites.json",
        }
        inputs = public_report.get("inputs")
        if not isinstance(inputs, dict) or set(inputs) != expected_inputs:
            raise ValueError("public-suite input manifest is incomplete")
        for input_entry in inputs.values():
            if not isinstance(input_entry, dict):
                raise ValueError("public-suite input entry is malformed")
            input_path = _repo_path(str(input_entry.get("path", "")))
            if (
                input_path.stat().st_size != input_entry.get("bytes")
                or _sha256(input_path) != input_entry.get("sha256")
            ):
                raise ValueError("public-suite input hash mismatch")
            candidates.append(input_path)

        artifact_root = (REPORT_ROOT / "public_suite").resolve()
        artifact_entries = [
            public_report.get("upstream", {}).get("license_artifact"),
            *[
                artifact
                for suite in public_report.get("suites", {}).values()
                for artifact in suite.get("artifacts", {}).values()
            ],
        ]
        for artifact in artifact_entries:
            if not isinstance(artifact, dict):
                raise ValueError("public-suite artifact is malformed")
            artifact_path = (
                artifact_root / str(artifact.get("path", ""))
            ).resolve()
            try:
                artifact_path.relative_to(artifact_root)
            except ValueError as error:
                raise ValueError(
                    "public-suite artifact escapes its report directory"
                ) from error
            if (
                not artifact_path.is_file()
                or artifact_path.stat().st_size != artifact.get("bytes")
                or _sha256(artifact_path) != artifact.get("sha256")
            ):
                raise ValueError("public-suite artifact hash mismatch")
            candidates.append(artifact_path)
        candidates.extend(
            (public_report_path.resolve(), public_manifest_path.resolve())
        )
    if "table7-cross" in phase_names:
        cross_report_path = REPORT_ROOT / "table7-cross-report.json"
        cross_manifest_path = REPO_ROOT / "verification/table7_cross.json"
        if not cross_report_path.is_file():
            raise ValueError("Chapter 7 cross report is missing")
        if not cross_manifest_path.is_file():
            raise ValueError("Chapter 7 cross manifest is missing")
        cross_report = json.loads(
            cross_report_path.read_text(encoding="utf-8")
        )
        cross_manifest = json.loads(
            cross_manifest_path.read_text(encoding="utf-8")
        )
        validate_table7_cross_evidence(
            cross_report,
            cross_manifest,
            expected_commit=str(
                regression.get("git", {}).get("commit", "")
            ),
        )

        expected_inputs = {
            "verification/table7_cross.json",
            "verification/table7_cross.py",
        }
        inputs = cross_report.get("inputs")
        if not isinstance(inputs, dict) or set(inputs) != expected_inputs:
            raise ValueError("Chapter 7 cross input manifest is incomplete")
        for path_text, entry in inputs.items():
            if not isinstance(entry, dict) or entry.get("path") != path_text:
                raise ValueError("Chapter 7 cross input entry is malformed")
            input_path = _repo_path(path_text)
            if (
                input_path.stat().st_size != entry.get("bytes")
                or _sha256(input_path) != entry.get("sha256")
            ):
                raise ValueError("Chapter 7 cross input hash mismatch")
            candidates.append(input_path)

        result_by_name = {
            str(result.get("name")): result for result in results
        }
        for cross in cross_report["crosses"].values():
            for evidence in cross["evidence"]:
                phase = evidence["phase"]
                result = result_by_name.get(phase)
                log_entry = evidence["log"]
                source_entry = evidence["source_artifact"]
                if (
                    result is None
                    or result.get("status") != "passed"
                    or result.get("exit_code") != 0
                    or result.get("log") != log_entry.get("path")
                    or result.get("log_sha256") != log_entry.get("sha256")
                ):
                    raise ValueError(
                        f"Chapter 7 phase evidence mismatch: {phase}"
                    )
                log_path = _repo_path(str(log_entry.get("path", "")))
                source_path = _repo_path(str(source_entry.get("path", "")))
                if (
                    log_path.stat().st_size != log_entry.get("bytes")
                    or _sha256(log_path) != log_entry.get("sha256")
                    or source_path.stat().st_size
                    != source_entry.get("bytes")
                    or _sha256(source_path)
                    != source_entry.get("sha256")
                ):
                    raise ValueError(
                        f"Chapter 7 evidence hash mismatch: {phase}"
                    )
                if re.search(
                    str(evidence["marker"]),
                    log_path.read_text(encoding="utf-8", errors="replace"),
                ) is None:
                    raise ValueError(
                        f"Chapter 7 PASS marker missing: {phase}"
                    )
                candidates.extend((log_path, source_path))
        candidates.extend(
            (cross_report_path.resolve(), cross_manifest_path.resolve())
        )
    if "functional-coverage" in phase_names:
        functional_report_path = (
            REPORT_ROOT / "functional-coverage-report.json"
        )
        functional_manifest_path = (
            REPO_ROOT / "verification/functional_coverage.json"
        )
        if not functional_report_path.is_file():
            raise ValueError("functional-coverage report is missing")
        if not functional_manifest_path.is_file():
            raise ValueError("functional-coverage manifest is missing")
        functional_report = json.loads(
            functional_report_path.read_text(encoding="utf-8")
        )
        functional_manifest = json.loads(
            functional_manifest_path.read_text(encoding="utf-8")
        )
        validate_functional_coverage_evidence(
            functional_report,
            functional_manifest,
            expected_commit=str(
                regression.get("git", {}).get("commit", "")
            ),
        )
        expected_inputs = {
            "verification/functional_coverage.json",
            "verification/functional_coverage.py",
        }
        inputs = functional_report.get("inputs")
        if not isinstance(inputs, dict) or set(inputs) != expected_inputs:
            raise ValueError(
                "functional-coverage input manifest is incomplete"
            )
        for path_text, entry in inputs.items():
            if not isinstance(entry, dict) or entry.get("path") != path_text:
                raise ValueError(
                    "functional-coverage input entry is malformed"
                )
            input_path = _repo_path(path_text)
            if (
                input_path.stat().st_size != entry.get("bytes")
                or _sha256(input_path) != entry.get("sha256")
            ):
                raise ValueError("functional-coverage input hash mismatch")
            candidates.append(input_path)

        result_by_name = {
            str(result.get("name")): result for result in results
        }
        for phase, evidence in functional_report["evidence"].items():
            result = result_by_name.get(phase)
            log_entry = evidence.get("log", {})
            source_entry = evidence.get("source", {})
            if (
                result is None
                or result.get("status") != "passed"
                or result.get("exit_code") != 0
                or result.get("log") != log_entry.get("path")
                or result.get("log_sha256") != log_entry.get("sha256")
            ):
                raise ValueError(
                    f"functional-coverage phase mismatch: {phase}"
                )
            log_path = _repo_path(str(log_entry.get("path", "")))
            source_path = _repo_path(str(source_entry.get("path", "")))
            if (
                log_path.stat().st_size != log_entry.get("bytes")
                or _sha256(log_path) != log_entry.get("sha256")
                or source_path.stat().st_size != source_entry.get("bytes")
                or _sha256(source_path) != source_entry.get("sha256")
                or re.search(
                    str(evidence.get("marker", "")),
                    log_path.read_text(
                        encoding="utf-8", errors="replace"
                    ),
                )
                is None
            ):
                raise ValueError(
                    f"functional-coverage evidence mismatch: {phase}"
                )
            candidates.extend((log_path, source_path))
        candidates.extend(
            (
                functional_report_path.resolve(),
                functional_manifest_path.resolve(),
            )
        )
    quality_phases = {"lint-independent", "cdc-rdc"}
    present_quality_phases = quality_phases & phase_names
    if present_quality_phases and present_quality_phases != quality_phases:
        raise ValueError("regression contains incomplete FPGA-quality phases")
    if present_quality_phases:
        independent_path = REPORT_ROOT / "independent-lint.json"
        cdc_path = REPORT_ROOT / "cdc-rdc.json"
        if not independent_path.is_file() or not cdc_path.is_file():
            raise ValueError("FPGA-quality report is missing")
        independent = json.loads(
            independent_path.read_text(encoding="utf-8")
        )
        cdc = json.loads(cdc_path.read_text(encoding="utf-8"))
        for label, report, schema in (
            (
                "independent lint",
                independent,
                "arm7tdmis-independent-lint-v1",
            ),
            ("CDC/RDC", cdc, "arm7tdmis-cdc-rdc-v1"),
        ):
            if report.get("schema") != schema or report.get("status") != "passed":
                raise ValueError(f"{label} report is not passed")
            if report.get("git", {}).get("dirty"):
                raise ValueError(f"{label} report describes a dirty source tree")
            if report.get("git", {}).get("commit") != regression.get(
                "git", {}
            ).get("commit"):
                raise ValueError(f"{label} report commit does not match regression")

        lint_results = independent.get("results", [])
        expected_tops = {
            "arm7tdmis_top",
            "arm7tdmi_mister",
            "arm7tdmis_no_dft",
            "arm7tdmi_mister_example_top",
            "arm7tdmi_generic_soc",
        }
        if (
            independent.get("result_count") != len(lint_results)
            or {entry.get("top") for entry in lint_results} != expected_tops
            or any(
                entry.get("status") != "passed"
                or entry.get("exit_code") != 0
                or entry.get("error_count") != 0
                or entry.get("warning_count") != 0
                for entry in lint_results
            )
        ):
            raise ValueError("independent lint did not pass every public top")
        if independent.get("tool", {}).get("version") != (
            "slang version 11.0.0+7ddf4059f"
        ):
            raise ValueError("independent lint used the wrong Slang version")
        for entry in lint_results:
            diagnostic = entry.get("diagnostics", {})
            diagnostic_path = _repo_path(str(diagnostic.get("path", "")))
            if (
                diagnostic_path.stat().st_size != diagnostic.get("bytes")
                or _sha256(diagnostic_path) != diagnostic.get("sha256")
            ):
                raise ValueError("independent lint diagnostic hash mismatch")
            candidates.append(diagnostic_path)
        for path_text, entry in independent.get("inputs", {}).items():
            input_path = _repo_path(str(path_text))
            if (
                input_path.stat().st_size != entry.get("bytes")
                or _sha256(input_path) != entry.get("sha256")
            ):
                raise ValueError("independent lint input hash mismatch")

        if (
            cdc.get("clock_domains") != ["CLK"]
            or cdc.get("violations")
            or cdc.get("synchronizer_count", 0) < 6
            or cdc.get("reset_release_count", 0) < 2
            or cdc.get("reset_synchronizer_primitive", {}).get("status")
            != "verified"
        ):
            raise ValueError("CDC/RDC report does not prove reviewed closure")
        manifest_entry = cdc.get("manifest", {})
        manifest_path = _repo_path(str(manifest_entry.get("path", "")))
        if _sha256(manifest_path) != manifest_entry.get("sha256"):
            raise ValueError("CDC/RDC manifest hash mismatch")
        checker_entry = cdc.get("checker", {})
        checker_path = _repo_path(str(checker_entry.get("path", "")))
        if (
            checker_path.stat().st_size != checker_entry.get("bytes")
            or _sha256(checker_path) != checker_entry.get("sha256")
        ):
            raise ValueError("CDC/RDC checker hash mismatch")
        for path_text, entry in cdc.get("inputs", {}).items():
            input_path = _repo_path(str(path_text))
            if (
                input_path.stat().st_size != entry.get("bytes")
                or _sha256(input_path) != entry.get("sha256")
            ):
                raise ValueError("CDC/RDC input hash mismatch")
        candidates.extend(
            (
                independent_path.resolve(),
                cdc_path.resolve(),
                manifest_path,
                checker_path,
            )
        )
    if "postfit-sim" in phase_names:
        postfit_path = REPORT_ROOT / "postfit-report.json"
        if not postfit_path.is_file():
            raise ValueError("post-fit simulation report is missing")
        postfit = json.loads(postfit_path.read_text(encoding="utf-8"))
        if (
            postfit.get("schema") != "arm7tdmis-postfit-v1"
            or postfit.get("status") != "passed"
        ):
            raise ValueError("post-fit simulation report is not passed")
        if postfit.get("git", {}).get("dirty"):
            raise ValueError("post-fit report describes a dirty source tree")
        if postfit.get("git", {}).get("commit") != regression.get(
            "git", {}
        ).get("commit"):
            raise ValueError("post-fit report commit does not match regression")
        if postfit.get("device") != "5CSEBA6U23I7":
            raise ValueError("post-fit report targets the wrong device")
        for tool_name in ("quartus_map", "quartus_fit", "quartus_eda"):
            if (
                "Version 17.0.2 Build 602 07/19/2017 SJ Lite Edition"
                not in postfit.get("tools", {})
                .get(tool_name, {})
                .get("version", "")
            ):
                raise ValueError(
                    f"post-fit report used the wrong {tool_name} version"
                )

        expected_primitives = {
            "dffeas",
            "cyclonev_lcell_comb",
            "cyclonev_io_ibuf",
            "cyclonev_io_obuf",
            "cyclonev_clkena",
        }
        profiles = postfit.get("profiles", {})
        if set(profiles) != {"little", "big"}:
            raise ValueError("post-fit report lacks both endian profiles")
        for name, expected_big_endian in (("little", False), ("big", True)):
            profile = profiles[name]
            metrics = profile.get("metrics", {})
            netlist = profile.get("netlist", {})
            if (
                profile.get("status") != "passed"
                or profile.get("big_endian") is not expected_big_endian
                or profile.get("device") != "5CSEBA6U23I7"
                or profile.get("synthesis_policy", {}).get(
                    "auto_dsp_recognition"
                )
                != "off"
                or set(profile.get("critical_warning_ids", []))
                != {"169085", "332012"}
                or set(netlist.get("primitives", [])) != expected_primitives
                or not isinstance(netlist.get("bytes"), int)
                or netlist["bytes"] <= 0
                or not re.fullmatch(r"[0-9a-f]{64}", str(netlist.get("sha256")))
                or metrics.get("accepted_transactions", 0) < 30
                or metrics.get("accepted_while_cpu_ce_low", 0) < 1
                or metrics.get("longest_wait_cycles", 0) < 2
            ):
                raise ValueError(f"post-fit {name} profile is incomplete")
            for phase in ("map", "fit", "eda", "verilator", "simulation"):
                log_entry = profile.get("logs", {}).get(phase, {})
                log_path = _repo_path(str(log_entry.get("path", "")))
                if (
                    log_path.stat().st_size != log_entry.get("bytes")
                    or _sha256(log_path) != log_entry.get("sha256")
                ):
                    raise ValueError(
                        f"post-fit {name}/{phase} log hash mismatch"
                    )
                candidates.append(log_path)
        for path_text, entry in postfit.get("inputs", {}).items():
            input_path = _repo_path(str(path_text))
            if (
                input_path.stat().st_size != entry.get("bytes")
                or _sha256(input_path) != entry.get("sha256")
            ):
                raise ValueError("post-fit input hash mismatch")
        candidates.append(postfit_path.resolve())
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
