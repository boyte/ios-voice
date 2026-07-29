"""Tests for the offline repository documentation validator."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
VALIDATE = ROOT / "Scripts" / "validate-documentation.py"


class DocumentationValidatorTests(unittest.TestCase):
    def run_tool(self, root: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(VALIDATE), "--root", str(root)],
            text=True,
            capture_output=True,
            check=False,
        )

    def test_repository_documentation_passes_without_network_access(self) -> None:
        result = self.run_tool(ROOT)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_local_target_is_rejected_but_external_url_is_preserved(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "README.md").write_text(
                "[missing](missing.md) [external](https://example.com/docs)\n",
                encoding="utf-8",
            )
            result = self.run_tool(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("missing local target", result.stderr)
            self.assertNotIn("https://example.com", result.stderr)

    def test_malformed_local_link_and_missing_fragment_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "README.md").write_text(
                "[bad](<broken) [anchor](other.md#gone)\n", encoding="utf-8"
            )
            (root / "other.md").write_text("# Present\n", encoding="utf-8")
            result = self.run_tool(root)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("malformed local link", result.stderr)
            self.assertIn("missing fragment", result.stderr)

    def test_fenced_code_is_not_treated_as_a_repository_link(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "README.md").write_text("```md\n[example](not-a-real-file.md)\n```\n", encoding="utf-8")
            result = self.run_tool(root)
            self.assertNotIn("missing local target", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
