import importlib.util
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts" / "sanitize-evidence-log.py"


def load_script():
    spec = importlib.util.spec_from_file_location("sanitize_evidence_log", SCRIPT)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class SanitizeEvidenceLogTests(unittest.TestCase):
    def setUp(self) -> None:
        self.module = load_script()
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_sanitizes_paths_usernames_and_sensitive_lines_deterministically(self) -> None:
        source = (
            "INFO start operation=op-7\n"
            "DEBUG path=/Users/alice/Build/AppLocalVoice.log username=alice\n"
            "INFO transcript: the private words must not survive\n"
            "WARN password=hunter2\n"
            "INFO finished\n"
        )
        sanitized, summary = self.module.sanitize_text(source)
        self.assertEqual(
            sanitized,
            "INFO start operation=op-7\n"
            "DEBUG path=<PRIVATE_PATH> username=<USERNAME>\n"
            "[REDACTED: SPEECH_CONTENT]\n"
            "[REDACTED: CREDENTIAL]\n"
            "INFO finished\n",
        )
        self.assertEqual(summary, self.module.Summary(5, 1, 1, 1, 1, 0))
        self.assertEqual(self.module.sanitize_text(source), (sanitized, summary))

    def test_preserves_order_and_newline_style(self) -> None:
        sanitized, summary = self.module.sanitize_text("first\r\ntranscription=result\r\nlast")
        self.assertEqual(sanitized, "first\r\n[REDACTED: SPEECH_CONTENT]\r\nlast")
        self.assertEqual(summary.lines, 3)

    def test_rejects_binary_invalid_utf8_and_oversized_input_without_output(self) -> None:
        input_path = self.root / "input.log"
        output_path = self.root / "output.log"
        for data, limit in ((b"ok\x00bad", 100), (b"bad\xff", 100), (b"12345", 4)):
            input_path.write_bytes(data)
            with self.assertRaises(self.module.SanitizationError):
                self.module.sanitize_file(input_path, output_path, limit)
            self.assertFalse(output_path.exists())

    def test_cli_writes_summary_and_supports_positional_output(self) -> None:
        input_path = self.root / "input.log"
        output_path = self.root / "output.log"
        input_path.write_text("path=/private/tmp/alice/result.log\nutterance=secret\n", encoding="utf-8")
        result = subprocess.run(
            [sys.executable, str(SCRIPT), str(input_path), str(output_path)],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output_path.read_text(encoding="utf-8"), "path=<PRIVATE_PATH>\n[REDACTED: SPEECH_CONTENT]\n")
        self.assertIn("lines=2 paths=1 usernames=0 speech_redactions=1", result.stderr)

    def test_rejects_symlink_and_does_not_partially_redact_sensitive_lines(self) -> None:
        input_path = self.root / "input.log"
        input_path.write_text("token=sk_test_123456789012345\n", encoding="utf-8")
        output_path = self.root / "output.log"
        summary = self.module.sanitize_file(input_path, output_path, 1000)
        self.assertEqual(summary.credential_redactions, 1)
        self.assertEqual(output_path.read_text(encoding="utf-8"), "[REDACTED: CREDENTIAL]\n")
        link = self.root / "link.log"
        link.symlink_to(input_path)
        with self.assertRaises(self.module.SanitizationError):
            self.module.sanitize_file(link, output_path, 1000)

    def test_redacts_udids_from_device_destination_lines(self) -> None:
        udid = "a" * 40
        sanitized, summary = self.module.sanitize_text(f"Destination: iPhone, id={udid}\n")
        self.assertEqual(sanitized, "[REDACTED: DEVICE_IDENTIFIER]\n")
        self.assertEqual(summary.device_identifier_redactions, 1)


if __name__ == "__main__":
    unittest.main()
