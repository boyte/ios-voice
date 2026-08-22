from __future__ import annotations

import importlib.util
import pathlib
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/lint-repository.py"


def load_module():
    spec = importlib.util.spec_from_file_location("lint_repository", SCRIPT)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class LintRepositoryTests(unittest.TestCase):
    def test_current_checkout_passes(self) -> None:
        self.assertEqual(load_module().audit(ROOT), [])

    def test_test_source_missing_from_xcode_host_is_reported(self) -> None:
        module = load_module()
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / ".github/workflows").mkdir(parents=True)
            test_source = root / "Tests/AppLocalVoiceTests/NewTest.swift"
            test_source.parent.mkdir(parents=True)
            test_source.write_text("import XCTest\n", encoding="utf-8")
            project = root / "Testing/AppLocalVoice.xcodeproj/project.pbxproj"
            project.parent.mkdir(parents=True)
            project.write_text(
                "/* Begin PBXSourcesBuildPhase section */\n"
                "A1 /* GoneTest.swift in Sources */,\n"
                "/* End PBXSourcesBuildPhase section */\n",
                encoding="utf-8",
            )
            errors = module.audit(root)
            self.assertIn(
                "Testing/AppLocalVoice.xcodeproj omits test source: Tests/AppLocalVoiceTests/NewTest.swift",
                errors,
            )
            self.assertIn(
                "Testing/AppLocalVoice.xcodeproj references a missing source: GoneTest.swift",
                errors,
            )

    def test_unpinned_action_is_reported(self) -> None:
        module = load_module()
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / ".github/workflows").mkdir(parents=True)
            (root / ".github/workflows/test.yml").write_text(
                "- uses: owner/action@v4\n- uses: owner/other@" + "a" * 40 + "\n",
                encoding="utf-8",
            )
            errors = module.audit(root)
            self.assertEqual(
                errors,
                [".github/workflows/test.yml:1: action is not pinned to a full commit SHA"],
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)
