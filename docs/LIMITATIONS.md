# Known limitations

This file is a readable snapshot for version `0.9.0-dev`. The checkbox state
and full acceptance criteria in [`TASKS.md`](../TASKS.md) are authoritative
and may be stricter than this summary.

- No real MiSTer framework, PocketStation subsystem, copyrighted BIOS or
  software image, hardware run, or long system soak is included
  (MIST-007 through MIST-009, FPGA-002, and FPGA-007).
- Encoding-level required-bin functional coverage, formal proof, and
  independent review remain open (VAL-006 through VAL-008 and VAL-011).
  The 32-seed all-class randomized external-event campaign closes VAL-005.
  Exact deterministic Chapter 7
  legal-equivalence cycle crosses close VAL-004; they do not substitute for
  those broader gates. The checked public ARM/Thumb exercisers close VAL-003,
  but the proprietary Arm Validation Suite has not been run. The QEMU
  differential, 32-seed constrained-random campaign, pinned compiler-program
  test, and 256-seed sanitizing wrapper soak close VAL-001, VAL-002, VAL-009,
  and VAL-010 respectively.
- A fully pinned clean-checkout release toolchain remains open (FPGA-008).
  Independent Slang lint, structural CDC/RDC closure, and two-endian
  functional post-fit simulation are checked under FPGA-004/006; these are
  not a claim of commercial CDC sign-off or SDF timing simulation for a future
  containing MiSTer framework.
The core has no MMU, MPU, cache, Thumb-2, ARMv5 instruction extensions, or
ETM trace macrocell. Those are architectural or profile exclusions, not
unfinished ARM7TDMI-S features. See the public API documents for deterministic
policies on ARMv4T UNPREDICTABLE cases and legacy unaligned transfers.
