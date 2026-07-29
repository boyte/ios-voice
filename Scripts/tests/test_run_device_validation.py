#!/usr/bin/env python3
"""Focused contract tests for physical-device evidence collection."""

from __future__ import annotations

import json
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts" / "run-device-validation.sh"
EXTRACTOR = ROOT / "Scripts" / "device-validation-evidence.py"


class DeviceValidationContractTests(unittest.TestCase):
    def run_extractor(self, document: dict[str, object], identifier: str = "UDID-123") -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory(prefix="device-validation-facts-") as directory:
            path = pathlib.Path(directory) / "devices.json"
            path.write_text(json.dumps(document), encoding="utf-8")
            return subprocess.run(
                ["python3", str(EXTRACTOR), str(path), identifier],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )

    def test_extractor_requires_exact_model_and_os_facts(self) -> None:
        result = self.run_extractor(
            {
                "result": {
                    "devices": [
                        {
                            "identifier": "UDID-123",
                            "deviceProperties": {
                                "name": "Test iPhone",
                                "productType": "iPhone17,1",
                                "productVersion": "26.0",
                                "osBuildVersion": "23A123",
                            },
                        }
                    ]
                }
            }
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "Test iPhone\tiPhone17,1\t26.0\t23A123")

        incomplete = self.run_extractor({"devices": [{"identifier": "UDID-123", "name": "Test iPhone"}]})
        self.assertNotEqual(incomplete.returncode, 0)
        self.assertIn("incomplete", incomplete.stderr)

    def test_script_contract_is_fail_closed_and_manifest_aware(self) -> None:
        text = SCRIPT.read_text(encoding="utf-8")
        self.assertIn("--manifest manifest-path", text)
        self.assertIn("device-validation-evidence.py", text)
        self.assertIn("Device model identifier:", text)
        self.assertIn("TEST_EVIDENCE='[ ]'", text)
        self.assertIn("MANIFEST_STATUS=0", text)
        self.assertIn("Physical-device evidence was incomplete", text)
        self.assertNotIn("echo \"Physical-device test action passed\"", text)
        self.assertIn("physical-device package test passed", text.lower())
        for scenario in (
            "route.builtin",
            "route.bluetooth.hfp",
            "permission.first-run",
            "model.install-interrupted",
            "interruption.media-services-reset",
            "lifecycle.active-close",
            "capability.hardware-availability",
            "endurance.30-minutes",
        ):
            self.assertIn(f"| {scenario} |", text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
