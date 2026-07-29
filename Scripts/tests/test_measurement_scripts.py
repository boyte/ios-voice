#!/usr/bin/env python3
"""Contract tests for benchmark and memory evidence publication."""

from __future__ import annotations

import json
import pathlib
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
VALIDATOR = ROOT / "Scripts" / "validate-test-result.py"
SCRIPTS = (
    ROOT / "Scripts" / "run-benchmarks.sh",
    ROOT / "Scripts" / "run-memory-sweep.sh",
)


class MeasurementScriptTests(unittest.TestCase):
    def test_scripts_reconcile_and_retain_native_summary(self) -> None:
        for path in SCRIPTS:
            text = path.read_text(encoding="utf-8")
            self.assertIn("xcresulttool get test-results summary", text)
            self.assertIn("--format json", text)
            self.assertIn("--max-skipped 0", text)
            expected_methods = 2 if path.name == "run-benchmarks.sh" else 1
            self.assertIn(f'printf \'{{"testMethods":{expected_methods}}}\\n\'', text)
            self.assertIn("test-summary.json", text)
            self.assertIn("TEST SUCCEEDED", text)

    def test_native_summary_contract_rejects_partial_or_failed_results(self) -> None:
        with tempfile.TemporaryDirectory(prefix="applocalvoice-native-summary-") as temporary:
            directory = pathlib.Path(temporary)
            inventory = directory / "inventory.json"
            inventory.write_text('{"testMethods": 1}\n', encoding="utf-8")
            summary = directory / "summary.json"

            valid = {
                "result": "Passed",
                "totalTestCount": 1,
                "failedTests": 0,
                "skippedTests": 0,
                "expectedFailures": 0,
            }
            summary.write_text(json.dumps(valid), encoding="utf-8")
            result = subprocess.run(
                [
                    sys.executable,
                    str(VALIDATOR),
                    "--inventory",
                    str(inventory),
                    "--summary",
                    str(summary),
                    "--max-skipped",
                    "0",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

            for key, value in (("result", "Failed"), ("failedTests", 1), ("skippedTests", 1)):
                candidate = dict(valid)
                candidate[key] = value
                summary.write_text(json.dumps(candidate), encoding="utf-8")
                result = subprocess.run(
                    [
                        sys.executable,
                        str(VALIDATOR),
                        "--inventory",
                        str(inventory),
                        "--summary",
                        str(summary),
                        "--max-skipped",
                        "0",
                    ],
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    check=False,
                )
                self.assertNotEqual(result.returncode, 0, key)


if __name__ == "__main__":
    unittest.main(verbosity=2)
