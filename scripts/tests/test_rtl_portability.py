"""Static portability checks that permissive HDL frontends may not enforce."""

from __future__ import annotations

import collections
import pathlib
import re
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
RTL_ROOT = REPO_ROOT / "rtl"


def _without_comments(text: str) -> str:
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.DOTALL)
    return re.sub(r"//[^\n]*", "", text)


class RtlPortabilityTest(unittest.TestCase):
    def test_named_port_is_not_connected_twice_in_one_instance(self) -> None:
        failures: list[str] = []
        for path in sorted(RTL_ROOT.rglob("*.sv")):
            text = _without_comments(path.read_text(encoding="utf-8"))
            line_offset = 0
            for statement in text.split(";"):
                ports = re.findall(r"\.\s*([A-Za-z_]\w*)\s*\(", statement)
                counts = collections.Counter(ports)
                duplicates = sorted(name for name, count in counts.items() if count > 1)
                if duplicates:
                    line = text.count("\n", 0, line_offset) + 1
                    failures.append(
                        f"{path.relative_to(REPO_ROOT)}:{line}: "
                        f"duplicate named connection(s): {', '.join(duplicates)}"
                    )
                line_offset += len(statement) + 1

        self.assertEqual([], failures, "\n".join(failures))


if __name__ == "__main__":
    unittest.main()
