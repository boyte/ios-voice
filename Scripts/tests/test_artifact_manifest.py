#!/usr/bin/env python3
"""Standard-library tests for create-artifact-manifest.py."""

from __future__ import annotations

import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts" / "create-artifact-manifest.py"


class ArtifactManifestTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.work = pathlib.Path(self.temp.name)
        self.artifacts = self.work / "artifacts"
        self.artifacts.mkdir()
        (self.artifacts / "z.log").write_text("z\n", encoding="utf-8")
        (self.artifacts / "a.log").write_text("a\n", encoding="utf-8")
        self.inventory = self.work / "TestInventory.json"
        self.inventory.write_text('{"tests": 1}\n', encoding="utf-8")
        self.graph = self.work / "symbols.json"
        self.graph.write_text('{"symbols": []}\n', encoding="utf-8")
        self.output = self.work / "manifest.json"

    def tearDown(self) -> None:
        self.temp.cleanup()

    def run_manifest(
        self,
        *extra: str,
        env: dict[str, str] | None = None,
        cwd: pathlib.Path = ROOT,
    ) -> subprocess.CompletedProcess[str]:
        command = [
            sys.executable,
            str(SCRIPT),
            "--output",
            str(self.output),
            "--artifact",
            str(self.artifacts),
            "--test-inventory",
            str(self.inventory),
            "--api-symbol-graph",
            str(self.graph),
            *extra,
        ]
        child_env = os.environ.copy()
        child_env["SOURCE_DATE_EPOCH"] = "1704067200"
        if env:
            child_env.update(env)
        return subprocess.run(command, cwd=cwd, env=child_env, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)

    def read_manifest(self) -> dict[str, object]:
        return json.loads(self.output.read_text(encoding="utf-8"))

    def test_manifest_is_deterministic_and_records_sorted_hashes(self) -> None:
        first = self.run_manifest()
        self.assertEqual(first.returncode, 0, first.stderr)
        first_bytes = self.output.read_bytes()
        first_manifest = self.read_manifest()
        second = self.run_manifest()
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(first_bytes, self.output.read_bytes())
        self.assertEqual(first_manifest["generatedAt"], "2024-01-01T00:00:00Z")
        records = first_manifest["artifacts"]
        self.assertEqual([record["path"] for record in records], sorted(record["path"] for record in records))
        self.assertEqual(len(first_manifest["testInventorySha256"]), 64)
        self.assertEqual(len(first_manifest["apiSymbolGraphSha256"]), 64)
        self.assertIn("architecture", first_manifest["provenance"])
        self.assertIn("swift", first_manifest["provenance"])
        self.assertTrue(first_manifest["sourceRevision"])
        self.assertEqual(first_manifest["sdk"], first_manifest["provenance"]["sdk"])
        self.assertEqual(first_manifest["runtime"], first_manifest["provenance"]["simulatorRuntime"])
        self.assertEqual(first_manifest["osBuild"], first_manifest["provenance"]["simulatorOSBuild"])
        self.assertEqual(first_manifest["evidenceKind"], "unknown")

    def test_explicit_provenance_is_recorded_exactly_and_deterministically(self) -> None:
        options = (
            "--source-revision", "abc123",
            "--toolchain", "Xcode 26.0; Build version 17A123",
            "--sdk", "26.0",
            "--runtime", "iOS-26-0",
            "--os-build", "23A123",
            "--evidence-kind", "simulator-tests",
        )
        first = self.run_manifest(*options)
        self.assertEqual(first.returncode, 0, first.stderr)
        first_bytes = self.output.read_bytes()
        manifest = self.read_manifest()
        second = self.run_manifest(*options)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(first_bytes, self.output.read_bytes())
        self.assertEqual(manifest["sourceRevision"], "abc123")
        self.assertEqual(manifest["toolchain"], "Xcode 26.0; Build version 17A123")
        self.assertEqual(manifest["sdk"], "26.0")
        self.assertEqual(manifest["runtime"], "iOS-26-0")
        self.assertEqual(manifest["osBuild"], "23A123")
        self.assertEqual(manifest["evidenceKind"], "simulator-tests")
        self.assertEqual(manifest["provenance"]["xcode"], manifest["toolchain"])

    def test_explicit_empty_provenance_fails(self) -> None:
        result = self.run_manifest("--evidence-kind", " ")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("evidence-kind must not be empty", result.stderr)

    def test_explicit_generated_at_overrides_environment(self) -> None:
        result = self.run_manifest("--generated-at", "2025-02-03T04:05:06-05:00")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read_manifest()["generatedAt"], "2025-02-03T09:05:06Z")

    def test_missing_inputs_fail(self) -> None:
        missing = self.work / "missing"
        result = self.run_manifest("--artifact", str(missing))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not exist", result.stderr)

    def test_no_artifact_inputs_fail(self) -> None:
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--output", str(self.output)],
            cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("at least one --artifact", result.stderr)

    def test_empty_directory_fails(self) -> None:
        empty = self.work / "empty"
        empty.mkdir()
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--output", str(self.output), "--artifact", str(empty)],
            cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("is empty", result.stderr)

    def test_empty_file_fails(self) -> None:
        empty = self.work / "empty.log"
        empty.touch()
        result = self.run_manifest("--artifact", str(empty))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("is empty", result.stderr)

    def test_duplicate_artifact_inputs_fail(self) -> None:
        result = self.run_manifest("--artifact", str(self.artifacts))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("duplicate artifact input", result.stderr)

    def test_non_regular_and_symlink_inputs_fail(self) -> None:
        fifo = self.work / "fifo"
        if hasattr(os, "mkfifo"):
            os.mkfifo(fifo)
            result = self.run_manifest("--artifact", str(fifo))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("not a regular", result.stderr)
        symlink = self.work / "linked"
        symlink.symlink_to(self.artifacts, target_is_directory=True)
        result = self.run_manifest("--artifact", str(symlink))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("symlink", result.stderr)

    def test_nested_symlink_and_duplicate_manifest_path_fail(self) -> None:
        linked = self.artifacts / "linked.log"
        linked.symlink_to(self.artifacts / "a.log")
        result = self.run_manifest()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("contains a symlink", result.stderr)

    def test_referenced_files_must_be_single_regular_files(self) -> None:
        directory = self.work / "inventory-directory"
        directory.mkdir()
        (directory / "nested.json").write_text("{}\n", encoding="utf-8")
        result = self.run_manifest("--test-inventory", str(directory))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must be one non-empty regular file", result.stderr)

    def test_output_inside_artifact_directory_fails_closed(self) -> None:
        output = self.artifacts / "manifest.json"
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--output", str(output), "--artifact", str(self.artifacts)],
            cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("inside an artifact directory", result.stderr)

    def test_require_clean_git_fails_outside_clean_checkout(self) -> None:
        result = self.run_manifest("--require-clean-git", cwd=self.work)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("clean Git worktree", result.stderr)


if __name__ == "__main__":
    unittest.main()
