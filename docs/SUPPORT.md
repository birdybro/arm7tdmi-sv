# Support matrix

The project version is recorded in [`VERSION`](../VERSION). Version
`0.9.0-dev` is a verification prerelease, not a signed drop-in CPU-IP
release. [`TASKS.md`](../TASKS.md) §31 is the authoritative readiness ledger.

| Surface or tool | Status | Checked scope |
|---|---|---|
| `arm7tdmi_mister` valid/ready API v1 | Supported for directed integration | Verilator execution, randomized waits and CPU enables, errors, CDC/reset, all option profiles, DMA arbitration, and Quartus characterization |
| `arm7tdmis_top` raw API v1 | Supported for directed integration | ARM DDI 0234B pin semantics, reusable protocol checker, Chapter 7 directed phase matrices, and Quartus conformance profile |
| Verilator 5.x | Supported simulator and linter | Local release characterization used Verilator 5.048; CI installs its distribution version and records the exact result |
| Slang 11.0 | Supported independent SystemVerilog frontend | CI verifies the official Linux archive SHA-256 before compiling the generic SoC and records the phase log |
| QEMU system ARM | Supported independent shared-subset reference | The differential runner records the exact installed version and compares 77 ARMv4T retirements; it does not treat ARM926 extensions or platform behavior as ARM7 evidence |
| Quartus Lite 17.0.2 | Supported characterization tool | Analysis, synthesis, fit, assembly, and four-corner TimeQuest for Cyclone V `5CSEBA6U23I7` |
| GNU Make and Python 3 | Supported orchestration | Exact versions are recorded by every regression and release manifest |
| Icarus Verilog 13.0 | Not supported | Its SystemVerilog frontend rejects package/type syntax used by this RTL |
| Yosys/SymbiYosys and other synthesis/formal tools | Not yet verified | Independent synthesis, CDC/RDC, and formal closure remain FPGA-004 and VAL-007/008 |
| MiSTer framework project | Not yet supported as a released target | A real framework build, clock constraints, bitstream, and board evidence remain MIST-007 and FPGA-002/007 |
| PocketStation system or software images | Not included | System integration, legal user-supplied images, reference comparison, and soak evidence remain MIST-008/009 |

Only the two documented API version-1 surfaces are public compatibility
contracts. Internal module hierarchy, verification-only ports, and package
implementation details are not stable integration APIs.
