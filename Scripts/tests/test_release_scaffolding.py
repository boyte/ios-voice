from __future__ import annotations

import importlib.util
import pathlib
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts/audit-release-scaffolding.py"


def load_module():
    spec = importlib.util.spec_from_file_location("audit_release_scaffolding", SCRIPT)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ReleaseScaffoldingTests(unittest.TestCase):
    def test_current_public_checkout_passes_host_audit(self) -> None:
        errors, open_items = load_module().audit(ROOT, require_host=True)
        self.assertEqual(errors, [])
        self.assertEqual(open_items, [])

    def test_missing_required_file_fails_closed(self) -> None:
        module = load_module()
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            for relative in module.REQUIRED_FILES:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("* @owner\n" if relative == ".github/CODEOWNERS" else "Git-host requirements physical-device previous release\n", encoding="utf-8")
            archive = root / "Scripts/create-source-archive.sh"
            archive.chmod(0o755)
            (root / ".github/workflows/test.yml").write_text("- uses: owner/action@" + "a" * 40 + "\n", encoding="utf-8")
            (root / ".github/workflows/release-validation.yml").write_text("- uses: owner/action@" + "b" * 40 + "\n", encoding="utf-8")
            (root / "CHANGELOG.md").unlink()
            errors, _ = module.audit(root)
            self.assertIn("missing required release file: CHANGELOG.md", errors)

            test_source = root / "Tests/AppLocalVoiceTests/NewTest.swift"
            test_source.parent.mkdir(parents=True, exist_ok=True)
            test_source.write_text("import XCTest\n", encoding="utf-8")
            project = root / "Testing/AppLocalVoice.xcodeproj/project.pbxproj"
            project.parent.mkdir(parents=True, exist_ok=True)
            project.write_text(
                "/* Begin PBXSourcesBuildPhase section */\n"
                "/* End PBXSourcesBuildPhase section */\n",
                encoding="utf-8",
            )
            errors, _ = module.audit(root)
            self.assertIn(
                "Testing/AppLocalVoice.xcodeproj omits test source: Tests/AppLocalVoiceTests/NewTest.swift",
                errors,
            )

    def test_require_host_rejects_an_offline_fixture(self) -> None:
        module = load_module()
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            for relative in module.REQUIRED_FILES:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(
                    "* @owner\n" if relative == ".github/CODEOWNERS"
                    else "Git-host requirements physical-device previous release\n",
                    encoding="utf-8",
                )
            (root / "Scripts/create-source-archive.sh").chmod(0o755)
            (root / ".github/workflows/test.yml").write_text("- uses: owner/action@" + "a" * 40 + "\n", encoding="utf-8")
            (root / ".github/workflows/release-validation.yml").write_text("- uses: owner/action@" + "b" * 40 + "\n", encoding="utf-8")
            errors, _ = module.audit(root, require_host=True)
            self.assertTrue(any("real Git repository" in item for item in errors))


if __name__ == "__main__":
    unittest.main(verbosity=2)
