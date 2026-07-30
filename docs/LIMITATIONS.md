# Known limitations

This file is a readable snapshot for version `0.9.0-dev`. The checkbox state
and full acceptance criteria in [`TASKS.md`](../TASKS.md) are authoritative
and may be stricter than this summary.

- No real MiSTer framework, PocketStation subsystem, copyrighted BIOS or
  software image, hardware run, or long system soak is included
  (MIST-007, MIST-008, MIST-009, FPGA-002, and FPGA-007).
- The debugger-issued system-speed Data Abort path and the §5.25 Debug Status
  write disposition still require directed public-interface evidence
  (DBG-008 and DBG-009).
- The complete 242-page TRM inventory is a checked mandatory evidence phase
  (DOC-008), but Chapter 8/Table 8-1 still needs an explicit target-specific
  FPGA timing disposition (FPGA-009).
- Independent evidence review remains open (VAL-011). Formal proof and
  reachability close VAL-007/VAL-008 at 14 proofs and 77 covers. The 32-seed
  all-class randomized external-event campaign closes VAL-005, exhaustive
  234-bin ARMv4T functional coverage closes VAL-006, and exact deterministic
  Chapter 7 legal-equivalence cycle crosses close VAL-004. The checked public
  ARM/Thumb exercisers close VAL-003, but the proprietary Arm Validation Suite
  has not been run. The QEMU differential, 32-seed constrained-random
  campaign, pinned compiler-program test, and 256-seed sanitizing wrapper soak
  close VAL-001, VAL-002, VAL-009, and VAL-010 respectively.
- A fully pinned clean-checkout release toolchain remains open (FPGA-008).
  Independent Slang lint, structural CDC/RDC closure, and two-endian
  functional post-fit simulation are checked under FPGA-004/006; these are
  not a claim of commercial CDC sign-off or SDF timing simulation for a future
  containing MiSTer framework.
The core has no MMU, MPU, cache, Thumb-2, ARMv5 instruction extensions, or
ETM trace macrocell. Those are architectural or profile exclusions, not
unfinished ARM7TDMI-S features. See the public API documents for deterministic
policies on ARMv4T UNPREDICTABLE cases and legacy unaligned transfers.
