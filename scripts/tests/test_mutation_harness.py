#!/usr/bin/env python3
"""Fail-closed tests for architectural-control mutation orchestration."""

from __future__ import annotations

import subprocess
import unittest

import mutation_harness


class MutationHarnessTest(unittest.TestCase):
    def test_manifest_covers_every_required_control_class(self) -> None:
        self.assertEqual(
            {mutation.name for mutation in mutation_harness.MUTATIONS},
            {"writeback", "flags", "exception", "bus"},
        )
        for mutation in mutation_harness.MUTATIONS:
            self.assertTrue(mutation.expected_diagnostic)
            self.assertIn("-DARM7TDMIS_MUTATE_", " ".join(mutation.command))

    def test_every_expected_failure_is_reported_killed(self) -> None:
        def killed_runner(
            command: tuple[str, ...],
        ) -> subprocess.CompletedProcess[str]:
            mutation = next(
                item for item in mutation_harness.MUTATIONS
                if item.command == command
            )
            return subprocess.CompletedProcess(
                command, 1, stdout=mutation.expected_diagnostic
            )

        results = mutation_harness.run_mutations(
            mutation_harness.MUTATIONS, runner=killed_runner
        )

        self.assertEqual(len(results), len(mutation_harness.MUTATIONS))
        self.assertTrue(all(result.status == "killed" for result in results))

    def test_a_surviving_mutant_fails_the_suite(self) -> None:
        def survivor(
            command: tuple[str, ...],
        ) -> subprocess.CompletedProcess[str]:
            return subprocess.CompletedProcess(command, 0, stdout="PASS")

        with self.assertRaisesRegex(
            mutation_harness.MutationFailure, "survived"
        ):
            mutation_harness.run_mutations(
                (mutation_harness.MUTATIONS[0],), runner=survivor
            )

    def test_unrelated_build_failure_does_not_kill_a_mutant(self) -> None:
        def compiler_failure(
            command: tuple[str, ...],
        ) -> subprocess.CompletedProcess[str]:
            return subprocess.CompletedProcess(
                command, 2, stdout="syntax error"
            )

        with self.assertRaisesRegex(
            mutation_harness.MutationFailure, "wrong detector"
        ):
            mutation_harness.run_mutations(
                (mutation_harness.MUTATIONS[0],), runner=compiler_failure
            )


if __name__ == "__main__":
    unittest.main()
