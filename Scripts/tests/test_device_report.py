#!/usr/bin/env python3
"""Standard-library tests for physical-device report and simulator helpers."""

from __future__ import annotations

import os
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
VALIDATOR = ROOT / "Scripts" / "validate-device-report.py"
BENCHMARK = ROOT / "Scripts" / "run-benchmarks.sh"
MEMORY = ROOT / "Scripts" / "run-memory-sweep.sh"
SCENARIOS = (
    "route.builtin",
    "route.bluetooth.hfp",
    "route.wired",
    "permission.first-run",
    "permission.denied-retry",
    "model.installed",
    "model.missing-install",
    "model.install-interrupted",
    "interruption.phone-call",
    "interruption.siri",
    "interruption.notification",
    "interruption.media-services-reset",
    "route.bluetooth-reconnect",
    "lifecycle.background-foreground",
    "lifecycle.screen-lock",
    "lifecycle.rapid-turns",
    "audio.music-playing",
    "model.low-storage",
    "voice.compact",
    "voice.enhanced",
    "voice.premium",
    "lifecycle.active-close",
    "lifecycle.process-relaunch",
    "capability.hardware-availability",
    "endurance.30-minutes",
)


class DeviceReportTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="applocalvoice-device-report-")
        self.directory = pathlib.Path(self.temp.name)
        self.report = self.directory / "device-report.md"
        self.bundle = self.report.with_suffix(".xcresult")
        self.bundle.mkdir()
        (self.bundle / "Info.plist").write_text("fixture\n", encoding="utf-8")
        self.log = self.report.with_suffix(".log")
        self.log.write_text("** TEST SUCCEEDED **\n", encoding="utf-8")
        self.write_report()

    def tearDown(self) -> None:
        self.temp.cleanup()

    def write_report(
        self,
        *,
        rows: list[tuple[str, str, str]] | None = None,
        exit_code: int = 0,
        privacy: bool = True,
        ios_build: str = "23A123",
        result_path: pathlib.Path | None = None,
        waivers: list[tuple[str, str, str, str]] | None = None,
    ) -> None:
        rows = rows or [(scenario, "pass", "synthetic device check") for scenario in SCENARIOS]
        result_path = result_path or self.bundle
        privacy_checkbox = "[x]" if privacy else "[ ]"
        table = "\n".join(f"| {scenario} | {result} | {notes} |" for scenario, result, notes in rows)
        waiver_table = ""
        if waivers:
            waiver_table = "\n## Release waivers\n\n| Scenario ID | Waiver / issue | Owner | Approval / expiry |\n|---|---|---|---|\n"
            waiver_table += "\n".join(
                f"| {scenario} | {issue} | {owner} | {approval} |"
                for scenario, issue, owner, approval in waivers
            )
        self.report.write_text(
            f"""# AppLocalVoice device validation report

- Date (UTC): 2026-07-11T00:00:00Z
- Device: iPhone 17 Pro
- Device model identifier: iPhone18,3
- Device class: physical iPhone/iPad
- iOS: 26.5
- iOS build: {ios_build}
- Toolchain: Xcode 26.5
- SDK: 26.5
- Package test action exit code: {exit_code}
- Result bundle: {result_path}
- Test log: {self.log}

## Automated evidence

- [x] Physical-device package tests passed.
- [x] The `.xcresult` bundle above is retained with the release artifacts.

## Manual scenarios

| Scenario ID | Result | Notes / issue |
|---|---|---|
{table}

## Privacy check

- {privacy_checkbox} No raw audio, transcript text, TTS text, or credentials were included
{waiver_table}
""",
            encoding="utf-8",
        )

    def run_validator(
        self,
        *extra: str,
        cwd: pathlib.Path = ROOT,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(VALIDATOR), str(self.report), *extra],
            cwd=cwd,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def make_report_copy(self, name: str, *, device_model_identifier: str = "iPhone18,3") -> pathlib.Path:
        """Create a second self-contained report fixture with rewritten paths."""
        report = self.directory / f"{name}.md"
        bundle = report.with_suffix(".xcresult")
        log = report.with_suffix(".log")
        shutil.copytree(self.bundle, bundle)
        shutil.copyfile(self.log, log)
        text = self.report.read_text(encoding="utf-8")
        text = text.replace(str(self.report), str(report)).replace(str(self.bundle), str(bundle))
        text = text.replace(str(self.log), str(log)).replace("iPhone18,3", device_model_identifier)
        report.write_text(text, encoding="utf-8")
        return report

    def write_manifest(self, reports: list[pathlib.Path], *, relative: bool = False) -> pathlib.Path:
        manifest = self.directory / "device-reports.json"
        values = [path.name if relative else str(path) for path in reports]
        manifest.write_text(json.dumps({"reports": values}, indent=2) + "\n", encoding="utf-8")
        return manifest

    def test_complete_report_requires_all_evidence_and_scenarios(self) -> None:
        result = self.run_validator("--require-complete")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("25 scenario rows", result.stdout)

    def test_release_report_requires_successful_log_and_all_scenarios_pass(self) -> None:
        result = self.run_validator("--require-release")
        self.assertEqual(result.returncode, 0, result.stderr)

        failed = [(scenario, "fail", "reproduced issue") for scenario in SCENARIOS]
        self.write_report(rows=failed)
        result = self.run_validator("--require-release")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("failed scenarios require explicit waivers", result.stderr)

    def test_release_report_accepts_only_explicit_failed_scenario_waivers(self) -> None:
        rows = [(scenario, "pass", "synthetic device check") for scenario in SCENARIOS]
        rows[0] = (SCENARIOS[0], "fail", "reproduced issue")
        self.write_report(
            rows=rows,
            waivers=[(SCENARIOS[0], "tracked issue #1", "maintainer", "approved 2026-07-11")],
        )
        result = self.run_validator("--require-release")
        self.assertEqual(result.returncode, 0, result.stderr)

        self.log.write_text("xcodebuild completed without a success marker\n", encoding="utf-8")
        result = self.run_validator("--require-release")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("TEST SUCCEEDED marker", result.stderr)

    def test_complete_release_allows_only_explicit_waivers(self) -> None:
        rows = [(scenario, "pass", "synthetic device check") for scenario in SCENARIOS]
        rows[0] = (SCENARIOS[0], "fail", "reproduced issue")
        self.write_report(
            rows=rows,
            waivers=[(SCENARIOS[0], "tracked issue #1", "maintainer", "approved 2026-07-11")],
        )
        result = self.run_validator("--require-complete", "--require-release")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_generated_relative_evidence_paths_are_resolved_from_caller(self) -> None:
        self.write_report(result_path=pathlib.Path("device-report.xcresult"))
        self.report.write_text(
            self.report.read_text(encoding="utf-8").replace(
                f"- Test log: {self.log}", "- Test log: device-report.log"
            ),
            encoding="utf-8",
        )
        result = self.run_validator("--require-complete", cwd=self.directory)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_duplicate_and_missing_scenarios_fail_closed(self) -> None:
        rows = [(scenario, "pass", "note") for scenario in SCENARIOS[:-1]]
        rows.append((SCENARIOS[0], "pass", "duplicate"))
        self.write_report(rows=rows)
        result = self.run_validator()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("duplicate scenario IDs", result.stderr)

    def test_unknown_scenario_fails(self) -> None:
        rows = [(scenario, "pass", "note") for scenario in SCENARIOS]
        rows[-1] = ("not-a-stable-id", "pass", "note")
        self.write_report(rows=rows)
        result = self.run_validator()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unknown scenario IDs", result.stderr)

    def test_empty_notes_fail(self) -> None:
        rows = [(scenario, "pass", "note") for scenario in SCENARIOS]
        rows[3] = (rows[3][0], "pass", "")
        self.write_report(rows=rows)
        result = self.run_validator()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("empty notes", result.stderr)

    def test_complete_report_rejects_pending_result_and_missing_privacy(self) -> None:
        self.write_report(
            rows=[(scenario, "_pending_", "manual note") for scenario in SCENARIOS],
            privacy=False,
        )
        result = self.run_validator("--require-complete")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("incomplete scenario result", result.stderr)

    def test_package_exit_code_and_evidence_paths_are_checked(self) -> None:
        self.write_report(exit_code=1)
        result = self.run_validator()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("did not pass", result.stderr)

        self.write_report(result_path=self.directory / "other.xcresult")
        (self.directory / "other.xcresult").mkdir()
        (self.directory / "other.xcresult" / "Info.plist").write_text("fixture\n", encoding="utf-8")
        result = self.run_validator()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("path is inconsistent", result.stderr)

    def test_missing_and_empty_result_evidence_fails(self) -> None:
        self.bundle.joinpath("Info.plist").unlink()
        result = self.run_validator()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("result bundle is empty", result.stderr)

    def test_manifest_validates_distinct_devices(self) -> None:
        second = self.make_report_copy("second-device", device_model_identifier="iPad16,8")
        manifest = self.write_manifest([self.report, second], relative=True)
        result = subprocess.run(
            [sys.executable, str(VALIDATOR), "--manifest", str(manifest)],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("2 reports", result.stdout)

    def test_manifest_rejects_duplicate_device_os_route_scenario_rows(self) -> None:
        second = self.make_report_copy("duplicate-device")
        manifest = self.write_manifest([self.report, second])
        result = subprocess.run(
            [sys.executable, str(VALIDATOR), "--manifest", str(manifest)],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("duplicate device/OS/route/scenario rows", result.stderr)
        self.assertIn("route.builtin", result.stderr)

    def test_manifest_rejects_contradictory_scenario_rows_deterministically(self) -> None:
        second = self.make_report_copy("contradictory-device")
        text = second.read_text(encoding="utf-8").replace(
            "| route.builtin | pass | synthetic device check |",
            "| route.builtin | fail | contradictory result |",
        )
        second.write_text(text, encoding="utf-8")
        manifest = self.write_manifest([self.report, second])
        result = subprocess.run(
            [sys.executable, str(VALIDATOR), "--manifest", str(manifest)],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("contradictory device/OS/route/scenario rows", result.stderr)
        self.assertIn("iPhone18,3/23A123/route.builtin/route.builtin", result.stderr)

    def test_manifest_rejects_same_identity_with_contradictory_os_metadata(self) -> None:
        second = self.make_report_copy("contradictory-os")
        text = second.read_text(encoding="utf-8").replace("- iOS: 26.5", "- iOS: 26.6")
        second.write_text(text, encoding="utf-8")
        manifest = self.write_manifest([self.report, second])
        result = subprocess.run(
            [sys.executable, str(VALIDATOR), "--manifest", str(manifest)],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("contradictory device/OS metadata", result.stderr)
        self.assertIn("iOS:", result.stderr)

    def test_measurement_scripts_require_exact_model_and_id_destination(self) -> None:
        benchmark = BENCHMARK.read_text(encoding="utf-8")
        memory = MEMORY.read_text(encoding="utf-8")
        for script in (benchmark, memory):
            self.assertIn('APPLOCALVOICE_SIMULATOR_NAME:-iPhone 17 Pro', script)
            self.assertIn('simctl list devices available --json', script)
            self.assertIn('simctl erase "$DEVICE_ID"', script)
            self.assertIn('simctl bootstatus "$DEVICE_ID" -b', script)
            self.assertIn('-destination "platform=iOS Simulator,id=$DEVICE_ID"', script)
            self.assertIn('RESULT_BUNDLE', script)
            self.assertIn('TEST SUCCEEDED', script)
            self.assertNotIn("| awk -F '[()]' '/iPhone/", script)
        self.assertIn("APPLOCALVOICE_SIMULATOR_RUNTIME", benchmark)
        self.assertIn("APPLOCALVOICE_SIMULATOR_RUNTIME", memory)
        self.assertIn('APPLOCALVOICE_SIMULATOR_RUNTIME:-iOS-26-0', benchmark)
        self.assertIn('APPLOCALVOICE_SIMULATOR_RUNTIME:-iOS-26-0', memory)


if __name__ == "__main__":
    unittest.main(verbosity=2)
