import hashlib
import importlib.util
import pathlib
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts" / "validate-crash-report.py"


def load_script():
    spec = importlib.util.spec_from_file_location("validate_crash_report", SCRIPT)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class CrashReportTests(unittest.TestCase):
    def setUp(self) -> None:
        self.module = load_script()
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        for name in ("crash.ips", "host.log", "device.log", "recovery.log"):
            (self.root / name).write_text(f"synthetic {name}\n", encoding="utf-8")

    def tearDown(self) -> None:
        self.temp.cleanup()

    def ref(self, name: str) -> dict[str, str]:
        data = (self.root / name).read_bytes()
        return {"path": name, "sha256": hashlib.sha256(data).hexdigest()}

    def report(self) -> dict[str, object]:
        return {
            "schemaVersion": "1.0",
            "device": {
                "model": "iPhone synthetic", "identifier": "fixture-device",
                "osName": "iOS", "osVersion": "26.0", "osBuild": "23A000",
            },
            "sourceRevision": "0123456789abcdef0123456789abcdef01234567",
            "activeOperation": {"id": "op-42", "kind": "listen", "phase": "listening"},
            "crashTimestamp": "2026-07-11T10:00:00Z",
            "relaunchTimestamp": "2026-07-11T10:00:05Z",
            "crashArtifact": self.ref("crash.ips"),
            "attachedLogs": {"host": self.ref("host.log"), "device": self.ref("device.log")},
            "postRelaunchState": {
                "state": "idle", "observedAt": "2026-07-11T10:00:10Z",
                "freshOperationCompleted": True,
            },
            "recoveryResult": {
                "status": "proven", "verifiedAt": "2026-07-11T10:00:11Z",
                "evidence": [self.ref("recovery.log")],
            },
            "redaction": {
                "rulesVersion": "H12.4-1", "applied": True,
                "removedFields": ["credentials", "raw audio", "speech text"],
                "reviewedBy": "tester",
            },
        }

    def test_accepts_complete_report_and_hashes(self) -> None:
        self.assertEqual(self.module.validate(self.report(), self.root)["recovery"], "proven")

    def test_rejects_missing_sensitive_and_unknown_schema_fields(self) -> None:
        report = self.report()
        del report["crashArtifact"]
        with self.assertRaises(self.module.CrashReportValidationError):
            self.module.validate(report, self.root)
        report = self.report()
        report["transcript"] = "secret"
        with self.assertRaisesRegex(self.module.CrashReportValidationError, "unknown"):
            self.module.validate(report, self.root)
        report = self.report()
        report["schemaVersion"] = "2.0"
        with self.assertRaises(self.module.CrashReportValidationError):
            self.module.validate(report, self.root)

    def test_rejects_inconsistent_timestamps_unsafe_paths_and_unproven_recovery(self) -> None:
        report = self.report()
        report["relaunchTimestamp"] = report["crashTimestamp"]
        with self.assertRaisesRegex(self.module.CrashReportValidationError, "after"):
            self.module.validate(report, self.root)
        report = self.report()
        report["crashArtifact"] = {**self.ref("crash.ips"), "path": "../crash.ips"}
        with self.assertRaisesRegex(self.module.CrashReportValidationError, "unsafe"):
            self.module.validate(report, self.root)
        report = self.report()
        report["recoveryResult"]["status"] = "claimed"
        with self.assertRaisesRegex(self.module.CrashReportValidationError, "proven"):
            self.module.validate(report, self.root)


if __name__ == "__main__":
    unittest.main()
