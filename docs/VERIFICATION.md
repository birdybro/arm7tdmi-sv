# Verification and regression evidence

`make -C scripts regress` is the release-facing directed regression entry point.
It always removes the Verilator build directory first, then runs:

1. RTL lint and testbench lint.
2. The harness unit test and intentional-failure sentinel.
3. Every unit test in the `UNIT_TESTS` manifest.
4. Every directed test in the `INTEG_TESTS` manifest.
5. The mixed-instruction smoke test.

The runner stops at the first failing phase and returns nonzero. The intentional
failure sentinel contains a real SystemVerilog `$fatal`; the enclosing target
passes only when Verilator propagates that failure as a nonzero process status.
This catches accidental loss of simulator failures in shell or result handling.

## Machine-readable result

Each run atomically updates `reports/generated/regression.json` using schema
`arm7tdmis-regression-v1`. It records:

- the full Git commit, dirty status, and SHA-256 of local source/build inputs;
- Verilator, Python, GNU Make, Git, and host-platform versions;
- build variant and deterministic seed;
- the complete lint, harness, unit, integration, and smoke manifests;
- each phase's command, timestamps, duration, exit status, log path, and
  SHA-256; and
- the aggregate `running`, `passed`, `failed`, or `interrupted` status.

Per-phase logs live beside the report under `reports/generated/logs/`. Generated
reports are ignored because an ordinary developer run is not immutable release
evidence. A release workflow must copy the selected report and logs to its
versioned artifact archive together with the corresponding clean source commit.

`make -C scripts regress-quick` exercises the same metadata, clean-build, lint,
harness, and smoke path with one unit and one integration test. Its report is
explicitly marked `"mode": "quick"` and cannot be mistaken for the full run.

Functional/line/toggle coverage reporting, mutation testing of architectural
controls, differential testing, and formal evidence remain separate open
requirements in `TASKS.md` §31.
