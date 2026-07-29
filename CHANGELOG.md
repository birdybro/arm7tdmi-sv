# Changelog

This project follows Semantic Versioning. It has not reached the v1.0
sign-off gate in `TASKS.md` §31.13.

## [Unreleased]

- Add an opt-in schema-1.0 architectural save-state handshake to the MiSTer
  wrapper, with exact quiescence, all physical register banks, deterministic
  replay, and Thumb BL-boundary restore evidence.
- Add an always-regenerated QEMU differential covering 77 consecutive
  ARM/Thumb retirements and final memory effects through the public
  architectural retirement interface.
- Add a 32-seed constrained-random ARM/Thumb campaign with at least 8,192
  QEMU-compared retirements, privileged-mode/exception coverage, and separate
  two-endian ARM7 legacy-unaligned permitted-memory scoreboards.
- Add pinned MIT `jsmolka/gba-suite` ARM and Thumb exercisers with exact
  source/license/patch provenance, 15,287 retirements, frozen signatures,
  fail-hard public-port scoreboarding, and release-evidence validation.
- Add a checksum-pinned Arm GNU 14.3.Rel1 compiler gate that executes separate
  ARM and Thumb C units, bidirectional ARMv4T interworking, and mixed-width
  memory signatures on the RTL.
- Add fail-hard bidirectional traceability for every §31 requirement and every
  tracked RTL/verification source, with latest results in release evidence.
- Close the JTAG interoperability requirement through its project-specific
  bridge alternative: the public synchronous debug-step transport is packaged,
  documented, and protocol-tested without claiming asynchronous pod/GDB use.
- Add a 256-seed deterministic MiSTer-wrapper soak with sanitizer-instrumented
  simulation, unique X initialization, fail-hard timeouts, machine-readable
  evidence, and automatically minimized failure reproducers.
- Add zero-warning independent Slang elaboration for every public synthesis
  top and a mutation-tested structural CDC/RDC gate; synchronize deassertion
  of every wrapper/debug reset domain.
- Close deterministic Chapter 7 cycle-cross coverage with exact endian/stall
  waveforms, nine manifest-defined legal-equivalence crosses, full-regression
  log/source hashing, and mutation-tested release validation.
- Add a 32-seed constrained-random external-event gate that stalls every
  normalized instruction class and closes legal ABORT, IRQ, FIQ, reset,
  DBGRQ, and coprocessor-response bins independently per seed.
- Complete the remaining independent validation, formal, toolchain,
  MiSTer-framework, PocketStation, and hardware requirements in `TASKS.md`.
- Freeze v1.0 only after every release-gate statement has durable evidence.

## [0.9.0-dev] - 2026-07-29

- Implement the ARMv4T ARM and Thumb instruction families, register banking,
  PSR rules, exceptions, aborts, endianness, and the r4p3 bus-cycle contract.
- Implement the external coprocessor interface, CP14 debug communications,
  EmbeddedICE-RT behavior, JTAG scan chains, and ARM-side ETM7 boundary.
- Add versioned raw and canonical FPGA integration APIs, public
  enable/done and Wishbone adapters, DMA-arbitration tests, portable Quartus
  fragments, and checked Cyclone V characterization projects.
- Add fail-hard directed regression, mutation tests, structural coverage,
  machine-readable results, and hashed release-evidence archives.
- Reconcile public documentation with the audited task ledger. This
  prerelease is not a declaration that the final v1.0 gates are closed.
