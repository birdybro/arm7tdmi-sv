# Changelog

This project follows Semantic Versioning. It has not reached the v1.0
sign-off gate in `TASKS.md` §31.13.

## [Unreleased]

- Add an opt-in schema-1.0 architectural save-state handshake to the MiSTer
  wrapper, with exact quiescence, all physical register banks, deterministic
  replay, and Thumb BL-boundary restore evidence.
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
