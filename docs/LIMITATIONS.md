# Known limitations

This file is a readable snapshot for version `0.9.0-dev`. The checkbox state
and full acceptance criteria in [`TASKS.md`](../TASKS.md) are authoritative
and may be stricter than this summary.

- Save-state export/import and restore determinism are not implemented
  (MIST-006).
- No real MiSTer framework, PocketStation subsystem, copyrighted BIOS or
  software image, hardware run, or long system soak is included
  (MIST-007 through MIST-009, FPGA-002, and FPGA-007).
- A second generic SoC integration and independently fitted debug/coprocessor
  option-cost characterization remain open (MIST-010/011).
- Real debugger interoperability has not been demonstrated (JTAG-006).
- Independent differential comparison, constrained-random generation,
  third-party ARMv4T suites, complete cross/functional coverage, formal
  proof, compiler-built programs, long sanitizing fuzz runs, and independent
  review remain open (VAL-001 through VAL-011).
- Independent synthesis plus CDC/RDC analysis, post-synthesis architectural
  simulation or equivalence, and a fully pinned clean-checkout release
  toolchain remain open (FPGA-004, FPGA-006, and FPGA-008).
- Bidirectional requirement-to-RTL/test/coverage/result traceability remains
  open (DOC-003).

The core has no MMU, MPU, cache, Thumb-2, ARMv5 instruction extensions, or
ETM trace macrocell. Those are architectural or profile exclusions, not
unfinished ARM7TDMI-S features. See the public API documents for deterministic
policies on ARMv4T UNPREDICTABLE cases and legacy unaligned transfers.
