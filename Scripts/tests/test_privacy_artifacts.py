from __future__ import annotations

import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts" / "validate-privacy-artifacts.py"


def load_script():
    spec = importlib.util.spec_from_file_location("validate_privacy_artifacts", SCRIPT)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class PrivacyArtifactTests(unittest.TestCase):
    def setUp(self) -> None:
        self.module = load_script()
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        (self.root / "nested").mkdir()

    def tearDown(self) -> None:
        self.temp.cleanup()

    def write(self, relative: str, content: str) -> pathlib.Path:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        return path

    def run_cli(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), *arguments], cwd=ROOT, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )

    def test_recursive_scan_accepts_safe_metadata_and_is_deterministic(self) -> None:
        self.write("nested/z.log", "state=idle\nrouteClass=bluetooth\n")
        self.write("a.json", json.dumps({"operationId": "op-1", "timingMs": 12, "state": "idle"}))
        first = self.module.scan([self.root])
        second = self.module.scan([self.root])
        self.assertEqual(first, second)
        self.assertEqual(first, [])

    def test_rejects_speech_credentials_private_paths_and_reports_sorted_lines(self) -> None:
        self.write("nested/z.log", "transcript: hello world\npassword=secret\n")
        self.write("a.md", "artifact from /Users/alice/Desktop/voice.log\n")
        findings = self.module.scan([self.root])
        rendered = [item.render() for item in findings]
        self.assertEqual(rendered, sorted(rendered))
        self.assertIn("a.md:1:PRIVATE_PATH", rendered[0])
        self.assertTrue(any(":CREDENTIAL:" in item for item in rendered))
        self.assertTrue(any(":SPEECH_CONTENT:" in item for item in rendered))

    def test_json_rejects_sensitive_fields_even_when_value_is_placeholder(self) -> None:
        path = self.write("report.json", '{"transcript":"<redacted>","apiKey":"<redacted>"}\n')
        rendered = [item.render() for item in self.module.scan([path])]
        self.assertTrue(any("SPEECH_FIELD" in item for item in rendered))
        self.assertTrue(any("CREDENTIAL_FIELD" in item for item in rendered))

    def test_rejects_raw_device_udids_and_device_identity_fields(self) -> None:
        udid = "a" * 40
        text = self.write("report.md", f"- Device identifier: {udid}\n")
        self.assertEqual({item.code for item in self.module.scan([text])}, {"DEVICE_UDID"})

        document = self.write("report.json", json.dumps({"deviceIdentifier": udid}))
        codes = {item.code for item in self.module.scan([document])}
        self.assertEqual(codes, {"DEVICE_UDID_FIELD"})

    def test_framework_identifiers_and_tts_proxy_labels_are_not_speech(self) -> None:
        path = self.write(
            "frameworks.txt",
            "SpeechAnalyzer\nSpeechInput\nAVSpeechSynthesizer\nTTS proxy label\n",
        )
        self.assertEqual(self.module.scan([path]), [])

    def test_speech_and_tts_payload_labels_are_rejected(self) -> None:
        path = self.write(
            "payloads.txt",
            "speechText: hello\ntts_content: hello\nraw_audio: bytes\n",
        )
        codes = {item.code for item in self.module.scan([path])}
        self.assertEqual(codes, {"SPEECH_CONTENT"})

        json_path = self.write("payload-fields.json", '{"speechContent":"<redacted>","ttsContent":"<redacted>"}\n')
        field_codes = {item.code for item in self.module.scan([json_path])}
        self.assertEqual(field_codes, {"SPEECH_FIELD"})

    def test_malformed_json_and_unknown_allowlist_fail_closed(self) -> None:
        path = self.write("report.json", '{"state":\n')
        findings = self.module.scan([path])
        self.assertEqual(findings[0].code, "MALFORMED_JSON")
        allowlist = self.write("allowlist.json", '{"metadata":["transcript"]}\n')
        with self.assertRaisesRegex(self.module.PrivacyArtifactError, "unsupported field"):
            self.module.load_allowlist(allowlist)

    def test_allowlist_is_strictly_sorted_unique_and_only_supports_safe_fields(self) -> None:
        allowlist = self.write("allowlist.json", '{"metadata":["operationId"]}\n')
        self.assertEqual(self.module.load_allowlist(allowlist), frozenset({"operationId"}))
        duplicate = self.write("duplicate.json", '{"metadata":["operationId","operationId"]}\n')
        with self.assertRaisesRegex(self.module.PrivacyArtifactError, "sorted and unique"):
            self.module.load_allowlist(duplicate)

    def test_optional_metadata_requires_explicit_allowlist(self) -> None:
        path = self.write("event.json", '{"event":"speech_started"}\n')
        self.assertTrue(any(item.code == "SPEECH_CONTENT" for item in self.module.scan([path])))
        allowlist = self.write("allowlist.json", '{"metadata":["event"]}\n')
        self.assertEqual(self.module.scan([path], self.module.load_allowlist(allowlist)), [])

    def test_benchmark_metadata_is_allowlisted_by_path_not_by_keyword(self) -> None:
        safe = self.write(
            "benchmark.json",
            json.dumps({"measurements": [{"name": "TTS chunk transitions proxy", "notes": "pure chunking proxy"}]}),
        )
        allowlist = self.write(
            "allowlist.json",
            json.dumps({"metadata": ["measurements[].name", "measurements[].notes"]}),
        )
        self.assertEqual(self.module.scan([safe], self.module.load_allowlist(allowlist)), [])
        unsafe = self.write(
            "unsafe.json",
            json.dumps({"measurements": [{"notes": "user transcript: hello"}]}),
        )
        self.assertTrue(any(item.code == "SPEECH_CONTENT" for item in self.module.scan([unsafe])))

    def test_manifest_logical_paths_are_allowlisted_without_allowing_private_paths(self) -> None:
        safe = self.write(
            "manifest.json",
            json.dumps({"artifacts": [{"path": "external/transcript-result.json"}]}),
        )
        allowlist = self.write("allowlist.json", '{"metadata":["artifacts[].path"]}\n')
        self.assertEqual(self.module.scan([safe], self.module.load_allowlist(allowlist)), [])

        unsafe = self.write(
            "private-manifest.json",
            json.dumps({"artifacts": [{"path": "/Users/alice/transcript-result.json"}]}),
        )
        findings = self.module.scan([unsafe], self.module.load_allowlist(allowlist))
        self.assertEqual({item.code for item in findings}, {"PRIVATE_PATH"})

    def test_cli_returns_one_for_findings_and_two_for_invalid_input(self) -> None:
        artifact = self.write("report.txt", "tts text: private response\n")
        result = self.run_cli(str(artifact))
        self.assertEqual(result.returncode, 1)
        self.assertIn("SPEECH_CONTENT", result.stdout)
        invalid = self.run_cli(str(self.root / "missing"))
        self.assertEqual(invalid.returncode, 2)
        self.assertIn("privacy artifact validation failed", invalid.stderr)


if __name__ == "__main__":
    unittest.main()
