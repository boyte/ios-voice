#!/usr/bin/env python3
"""Tests for the strict, deterministic source-archive helper."""

from __future__ import annotations

import hashlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from tarfile import open as open_tar


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts" / "create-source-archive.sh"


def run(command: list[str], cwd: Path, *, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=check,
    )


@unittest.skipUnless(shutil.which("git") and shutil.which("gzip") and shutil.which("shasum"), "Git archive tools unavailable")
class SourceArchiveTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="applocalvoice-archive-test-")
        self.repo = Path(self.temp.name) / "repo"
        self.repo.mkdir()
        run(["git", "init", "-q"], self.repo)
        run(["git", "config", "user.name", "Archive Test"], self.repo)
        run(["git", "config", "user.email", "archive-test@example.invalid"], self.repo)
        (self.repo / "README.md").write_text("source archive fixture\n", encoding="utf-8")
        run(["git", "add", "README.md"], self.repo)
        run(["git", "commit", "-qm", "fixture"], self.repo)
        self.run_script = lambda tag, output, check=True: run(
            [str(SCRIPT), tag, str(output)], self.repo, check=check
        )

    def tearDown(self) -> None:
        self.temp.cleanup()

    def tag(self, name: str = "v1.2.3") -> None:
        run(["git", "tag", "-a", "-m", "release", name], self.repo)

    def test_archive_and_checksum_are_reproducible_and_relocatable(self) -> None:
        self.tag()
        first_dir = Path(self.temp.name) / "first"
        second_dir = Path(self.temp.name) / "second"

        self.run_script("v1.2.3", first_dir)
        self.run_script("v1.2.3", second_dir)

        first = first_dir / "AppLocalVoice-v1.2.3.tar.gz"
        second = second_dir / "AppLocalVoice-v1.2.3.tar.gz"
        self.assertEqual(first.read_bytes(), second.read_bytes())

        checksum = first_dir / "AppLocalVoice-v1.2.3.tar.gz.sha256"
        self.assertEqual(checksum.read_text(encoding="utf-8"), f"{hashlib.sha256(first.read_bytes()).hexdigest()}  {first.name}\n")
        self.assertEqual(checksum.read_text(encoding="utf-8").split()[-1], first.name)

        moved = Path(self.temp.name) / "moved"
        moved.mkdir()
        moved_archive = moved / first.name
        moved_checksum = moved / checksum.name
        shutil.copy2(first, moved_archive)
        shutil.copy2(checksum, moved_checksum)
        verified = run(["shasum", "-a", "256", "-c", moved_checksum.name], moved, check=True)
        self.assertIn("OK", verified.stdout)

        with open_tar(first, "r:gz") as archive:
            self.assertEqual(
                archive.getnames(),
                ["AppLocalVoice-v1.2.3", "AppLocalVoice-v1.2.3/README.md"],
            )

    def test_rejects_non_semantic_version_tag_argument(self) -> None:
        self.tag("v1.2")
        result = self.run_script("v1.2", Path(self.temp.name) / "out", check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("vMAJOR.MINOR.PATCH", result.stderr)

    def test_rejects_missing_tag(self) -> None:
        result = self.run_script("v9.9.9", Path(self.temp.name) / "out", check=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn("does not resolve", result.stderr)

    def test_rejects_tag_not_at_head(self) -> None:
        self.tag()
        (self.repo / "README.md").write_text("new commit\n", encoding="utf-8")
        run(["git", "add", "README.md"], self.repo)
        run(["git", "commit", "-qm", "after tag"], self.repo)
        result = self.run_script("v1.2.3", Path(self.temp.name) / "out", check=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn("HEAD is not the tagged commit", result.stderr)

    def test_rejects_dirty_worktree(self) -> None:
        self.tag()
        (self.repo / "README.md").write_text("modified\n", encoding="utf-8")
        result = self.run_script("v1.2.3", Path(self.temp.name) / "out", check=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn("dirty worktree", result.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
