#!/usr/bin/env python3
"""Fail-hard checks for the public FPGA/MiSTer source package."""

from __future__ import annotations

import pathlib
import re
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
FPGA_DIR = REPO_ROOT / "fpga"
FILELIST = FPGA_DIR / "arm7tdmi_mister.f"
QIP = FPGA_DIR / "arm7tdmi_mister.qip"
QSF = FPGA_DIR / "arm7tdmi_mister.qsf"
SDC = FPGA_DIR / "arm7tdmi_mister.sdc"
CONFORMANCE_QSF = FPGA_DIR / "arm7tdmis_conformance.qsf"
CONFORMANCE_SDC = FPGA_DIR / "arm7tdmis_conformance.sdc"
EXAMPLE = FPGA_DIR / "example" / "arm7tdmi_mister_example_top.sv"
NO_DFT_WRAPPER = REPO_ROOT / "rtl" / "top" / "arm7tdmis_no_dft.sv"
MISLEADING_DFT_WRAPPER = REPO_ROOT / "rtl" / "top" / "arm7tdmis_chip.sv"


def _required_rtl() -> set[pathlib.Path]:
    """Use the simulation manifest as the dependency oracle, minus ASIC DFT."""
    required: set[pathlib.Path] = set()
    sim_file = REPO_ROOT / "scripts" / "sim.f"
    for raw_line in sim_file.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line.startswith("../rtl/"):
            continue
        resolved = (sim_file.parent / line).resolve()
        relative = resolved.relative_to(REPO_ROOT)
        if relative.as_posix() != "rtl/top/arm7tdmis_no_dft.sv":
            required.add(relative)
    return required


def _resolved_filelist_sources() -> set[pathlib.Path]:
    sources: set[pathlib.Path] = set()
    for raw_line in FILELIST.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or line.startswith("+incdir+"):
            continue
        source = (FILELIST.parent / line).resolve()
        sources.add(source.relative_to(REPO_ROOT))
    return sources


def _qip_sources() -> set[pathlib.Path]:
    text = QIP.read_text(encoding="utf-8")
    matches = re.findall(r"\.\./(rtl/[A-Za-z0-9_./-]+\.sv)", text)
    return {pathlib.Path(match) for match in matches}


class FpgaPackageTest(unittest.TestCase):
    def test_required_public_files_exist(self) -> None:
        for path in (
            FILELIST,
            QIP,
            QSF,
            SDC,
            CONFORMANCE_QSF,
            CONFORMANCE_SDC,
            EXAMPLE,
        ):
            with self.subTest(path=path.relative_to(REPO_ROOT)):
                self.assertTrue(path.is_file(), f"missing public package file: {path}")

    def test_filelist_is_complete_and_portable(self) -> None:
        text = FILELIST.read_text(encoding="utf-8")
        self.assertNotRegex(text, r"(^|[\s\"'])/(home|Users|tmp)/")
        self.assertEqual(_resolved_filelist_sources(), _required_rtl())
        for relative in _resolved_filelist_sources():
            self.assertTrue((REPO_ROOT / relative).is_file(), relative)

    def test_qip_matches_the_plain_filelist(self) -> None:
        text = QIP.read_text(encoding="utf-8")
        self.assertIn("$::quartus(qip_path)", text)
        self.assertNotRegex(text, r"(^|[\s\"'])/(home|Users|tmp)/")
        self.assertEqual(_qip_sources(), _required_rtl())

    def test_qsf_references_only_public_fragments(self) -> None:
        text = QSF.read_text(encoding="utf-8")
        self.assertIn("arm7tdmi_mister.qip", text)
        self.assertIn("arm7tdmi_mister.sdc", text)
        self.assertIn("example/arm7tdmi_mister_example_top.sv", text)
        self.assertIn("TOP_LEVEL_ENTITY arm7tdmi_mister_example_top", text)
        self.assertNotRegex(text, r"(^|[\s\"'])/(home|Users|tmp)/")

    def test_conformance_qsf_keeps_the_raw_feature_complete_top(self) -> None:
        text = CONFORMANCE_QSF.read_text(encoding="utf-8")
        self.assertIn("arm7tdmi_mister.qip", text)
        self.assertIn("arm7tdmis_conformance.sdc", text)
        self.assertIn("TOP_LEVEL_ENTITY arm7tdmis_top", text)
        self.assertNotIn("arm7tdmi_mister_example_top", text)
        self.assertNotRegex(text, r"(^|[\s\"'])/(home|Users|tmp)/")

    def test_example_uses_only_the_public_wrapper(self) -> None:
        text = EXAMPLE.read_text(encoding="utf-8")
        self.assertRegex(text, r"\bmodule\s+arm7tdmi_mister_example_top\b")
        self.assertRegex(text, r"\barm7tdmi_mister\b")
        for forbidden in (
            ".u_core.",
            ".u_dut.",
            "request_valid_q",
            "response_valid_q",
            "de_q",
            "fetch_pc_q",
        ):
            self.assertNotIn(forbidden, text)

    def test_non_dft_compatibility_wrapper_is_honest_and_excluded(self) -> None:
        self.assertFalse(
            MISLEADING_DFT_WRAPPER.exists(),
            "a tied-off scan facade must not be named as a chip/DFT wrapper",
        )
        self.assertTrue(NO_DFT_WRAPPER.is_file(), "missing named no-DFT wrapper")
        text = NO_DFT_WRAPPER.read_text(encoding="utf-8")
        self.assertRegex(text, r"\bmodule\s+arm7tdmis_no_dft\b")
        self.assertNotRegex(text, r"\bmodule\s+arm7tdmis_chip\b")
        self.assertIn("assign SO = 1'b0;", text)
        self.assertNotIn("scan-flop stitching happens", text)
        self.assertNotIn(NO_DFT_WRAPPER.relative_to(REPO_ROOT), _required_rtl())
        self.assertNotIn(
            NO_DFT_WRAPPER.relative_to(REPO_ROOT),
            _resolved_filelist_sources(),
        )
        self.assertNotIn(NO_DFT_WRAPPER.relative_to(REPO_ROOT), _qip_sources())


if __name__ == "__main__":
    unittest.main()
