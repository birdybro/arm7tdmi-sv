# Source and license provenance

This inventory applies to version `0.9.0-dev`. It records SPDX identifiers
where the license is known and uses `NOASSERTION` where this project cannot
make a broader licensing claim. It is not legal advice.

| Material | Origin and handling | SPDX license status |
|---|---|---|
| `rtl/`, `tb/`, `verification/`, `scripts/`, `fpga/`, project documentation, and checked text metadata | Authored for this repository; individual files do not currently carry SPDX headers | `GPL-3.0-only`, under the root `LICENSE` |
| `ARM_DDI_0234B_ARM7TDMI-S_r4p3_TRM.pdf` | Arm specification retained with its original notices; used as the behavioral reference and not relicensed by this project | `LicenseRef-Arm-DDI-0234B`; overall SPDX conclusion `NOASSERTION` |
| Published r4p3 errata notice | Not vendored; `ERRATA.md` records the official URL, size, SHA-256, review date, and derived dispositions | `NOASSERTION` |
| Test-program `.hex` files | Repository-authored hand encodings used only by the local verification benches | `GPL-3.0-only` |
| QEMU differential reference | No QEMU code is vendored. The installed `qemu-system-arm` executable is invoked as an independent tool; each generated metadata file records its exact version, command, and output hashes | Governed by QEMU's upstream license terms; generated register facts are not committed to the repository |
| Arm GNU Toolchain compiler-program evidence | No toolchain binary is vendored. `install_arm_toolchain.py` downloads Arm GNU Toolchain 14.3.Rel1 from Arm's official release endpoint, verifies the recorded archive SHA-256, and installs it only in ignored local storage. Generated objects, ELF, disassembly, and signatures are not committed; release evidence records their tool/source/output metadata | Governed by the upstream Arm GNU Toolchain notices and component licenses |
| Third-party ARM validation suites or other reference emulator code | None vendored or claimed as evidence | `NOASSERTION` until a separately reviewed dependency is added |
| Firmware, BIOS, ROMs, games, and PocketStation software | None included. Users and downstream projects must supply only material they may lawfully use; it must not be committed to this repository | `NOASSERTION` |
| GitHub Actions | Workflow references `actions/checkout@v4` and `actions/upload-artifact@v4`; action source is fetched by GitHub and is not vendored here | Governed by each upstream action |

The release manifest records exact SHA-256 values for the included TRM and
root license, the Git tree and regression source digest, tool version and
executable manifests, and every archived evidence file. A new third-party
suite, emulator, firmware fragment, ROM, generated IP block, font, image, or
MiSTer component requires an entry here with origin, exact revision, license,
local modifications, and redistribution decision before it can become
release evidence.

Copyright authorship for repository-authored material follows Git history;
this document makes no additional ownership assignment. The root GPL license
does not alter the copyright or terms of the Arm manual or any future
user-supplied software.
