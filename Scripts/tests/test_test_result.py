import json
import pathlib
import tempfile
import unittest
import importlib.util


ROOT = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Scripts" / "validate-test-result.py"


def load_script():
    spec = importlib.util.spec_from_file_location("validate_test_result", SCRIPT)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class TestResultValidationTests(unittest.TestCase):
    def write(self, directory: pathlib.Path, name: str, value: object) -> pathlib.Path:
        path = directory / name
        path.write_text(json.dumps(value), encoding="utf-8")
        return path

    def test_reconciles_total_count_and_approved_skip(self) -> None:
        module = load_script()
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            inventory = self.write(directory, "inventory.json", {"testMethods": 125})
            summary = self.write(
                directory,
                "summary.json",
                {
                    "result": "Passed",
                    "totalTestCount": 125,
                    "failedTests": 0,
                    "skippedTests": 1,
                    "expectedFailures": 0,
                },
            )
            tests = self.write(
                directory,
                "tests.json",
                {
                    "testNodes": [
                        {
                            "nodeType": "Test Case",
                            "name": "AudioEngineSafetyTests.testMalformedHardwareFormatsFailClosed()",
                            "result": "Skipped",
                            "details": [
                                {
                                    "title": "Skip reason",
                                    "value": "This simulator SDK cannot construct a nine-channel standard format.",
                                }
                            ],
                        }
                    ]
                },
            )
            record = module.validate(inventory, summary, 1, tests)
            self.assertEqual(record["executedTests"], 125)

    def test_rejects_allowed_skip_without_named_details(self) -> None:
        module = load_script()
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            inventory = self.write(directory, "inventory.json", {"testMethods": 125})
            summary = self.write(directory, "summary.json", {
                "result": "Passed", "totalTestCount": 125, "failedTests": 0,
                "skippedTests": 1, "expectedFailures": 0,
            })
            with self.assertRaisesRegex(module.ResultValidationError, "named test details"):
                module.validate(inventory, summary, 1)

    def test_rejects_wrong_skip_identity_and_reason(self) -> None:
        module = load_script()
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            inventory = self.write(directory, "inventory.json", {"testMethods": 125})
            summary = self.write(directory, "summary.json", {
                "result": "Passed", "totalTestCount": 125, "failedTests": 0,
                "skippedTests": 1, "expectedFailures": 0,
            })
            tests = self.write(directory, "tests.json", {
                "testNodes": [{"name": "AudioEngineSafetyTests.testOther", "result": "Skipped",
                                "details": [{"value": "not an SDK reason"}]}]
            })
            with self.assertRaisesRegex(module.ResultValidationError, "identity"):
                module.validate(inventory, summary, 1, tests)

            tests = self.write(directory, "tests.json", {
                "testNodes": [{
                    "name": "AudioEngineSafetyTests.testMalformedHardwareFormatsFailClosed()",
                    "result": "Skipped",
                    "details": [{"value": "not an SDK reason"}],
                }]
            })
            with self.assertRaisesRegex(module.ResultValidationError, "reason"):
                module.validate(inventory, summary, 1, tests)

    def test_accepts_zero_skips_without_test_details_for_compatibility(self) -> None:
        module = load_script()
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            inventory = self.write(directory, "inventory.json", {"testMethods": 125})
            summary = self.write(directory, "summary.json", {
                "result": "Passed", "totalTestCount": 125, "failedTests": 0,
                "skippedTests": 0, "expectedFailures": 0,
            })
            self.assertEqual(module.validate(inventory, summary, 0)["skippedTests"], 0)

    def test_accepts_native_xcresult_node_identifier_with_method_only_name(self) -> None:
        module = load_script()
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            inventory = self.write(directory, "inventory.json", {"testMethods": 125})
            summary = self.write(directory, "summary.json", {
                "result": "Passed", "totalTestCount": 125, "failedTests": 0,
                "skippedTests": 1, "expectedFailures": 0,
            })
            tests = self.write(directory, "tests.json", {
                "testNodes": [{
                    "nodeIdentifier": "AudioEngineSafetyTests/testMalformedHardwareFormatsFailClosed()",
                    "name": "testMalformedHardwareFormatsFailClosed()",
                    "result": "Skipped",
                    "details": [{
                        "value": "This simulator SDK cannot construct a three-channel standard format."
                    }],
                }]
            })
            self.assertEqual(module.validate(inventory, summary, 1, tests)["skippedTests"], 1)

    def test_rejects_inventory_drift_and_failures(self) -> None:
        module = load_script()
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            inventory = self.write(directory, "inventory.json", {"testMethods": 125})
            summary = self.write(
                directory,
                "summary.json",
                {
                    "result": "Failed",
                    "totalTestCount": 124,
                    "failedTests": 1,
                    "skippedTests": 0,
                    "expectedFailures": 0,
                },
            )
            with self.assertRaises(module.ResultValidationError):
                module.validate(inventory, summary, 1)

    def test_exact_identity_reconciliation_rejects_same_count_substitution(self) -> None:
        module = load_script()
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            inventory = self.write(directory, "inventory.json", {
                "testMethods": 2,
                "testIdentities": ["FirstTests.testOne", "SecondTests.testTwo"],
            })
            summary = self.write(directory, "summary.json", {
                "result": "Passed", "totalTestCount": 2, "failedTests": 0,
                "skippedTests": 0, "expectedFailures": 0,
            })
            tests = self.write(directory, "tests.json", {
                "testNodes": [
                    {"nodeType": "Test Case", "nodeIdentifier": "FirstTests/testOne()"},
                    {"nodeType": "Test Case", "nodeIdentifier": "ThirdTests/testThree()"},
                ]
            })
            with self.assertRaisesRegex(module.ResultValidationError, "identities"):
                module.validate(inventory, summary, 0, tests)

    def test_exact_identity_reconciliation_rejects_duplicate_details(self) -> None:
        module = load_script()
        with tempfile.TemporaryDirectory() as temporary:
            directory = pathlib.Path(temporary)
            inventory = self.write(directory, "inventory.json", {
                "testMethods": 2,
                "testIdentities": ["FirstTests.testOne", "SecondTests.testTwo"],
            })
            summary = self.write(directory, "summary.json", {
                "result": "Passed", "totalTestCount": 2, "failedTests": 0,
                "skippedTests": 0, "expectedFailures": 0,
            })
            tests = self.write(directory, "tests.json", {
                "testNodes": [
                    {"nodeType": "Test Case", "nodeIdentifier": "FirstTests/testOne()"},
                    {"nodeType": "Test Case", "nodeIdentifier": "FirstTests/testOne()"},
                ]
            })
            with self.assertRaisesRegex(module.ResultValidationError, "duplicate"):
                module.validate(inventory, summary, 0, tests)


if __name__ == "__main__":
    unittest.main()
