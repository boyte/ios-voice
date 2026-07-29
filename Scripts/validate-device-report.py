#!/usr/bin/env python3
"""Validate a generated physical-device report before release acceptance.

The report is deliberately treated as a small, machine-checkable record.  A
human may add detail to the notes, but cannot make an incomplete or detached
evidence bundle look complete by editing a checkbox.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import plistlib
import re
import shutil
import subprocess
import sys


EXPECTED_SCENARIO_IDS = (
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

_METADATA_FIELDS = (
    "Device:",
    "Device model identifier:",
    "Device class:",
    "iOS:",
    "iOS build:",
    "Toolchain:",
    "SDK:",
    "Package test action exit code:",
    "Result bundle:",
    "Test log:",
)


def _field(text: str, name: str) -> str:
    match = re.search(rf"^- {re.escape(name)}\s+(\S.*)$", text, re.MULTILINE)
    if not match:
        raise ValueError(f"missing device report metadata: {name}")
    value = match.group(1).strip()
    if not value:
        raise ValueError(f"empty device report metadata: {name}")
    return value


def _resolve_report_path(report: pathlib.Path, value: str, label: str) -> pathlib.Path:
    candidate = pathlib.Path(value).expanduser()
    if candidate.is_absolute():
        candidates = [candidate]
    else:
        # run-device-validation.sh records paths relative to the caller's
        # working directory. Accept that form, while also accepting a path
        # relative to the report for hand-authored reports.
        candidates = [pathlib.Path.cwd() / candidate, report.parent / candidate]
    existing = next((path for path in candidates if path.exists()), None)
    candidate = existing or candidates[0]
    if candidate.is_symlink():
        raise ValueError(f"{label} must not be a symlink: {candidate}")
    candidate = candidate.resolve()
    if not candidate.exists():
        raise ValueError(f"{label} does not exist: {candidate}")
    if label == "result bundle" and not candidate.is_dir():
        raise ValueError(f"result bundle is not a directory: {candidate}")
    if label == "test log" and not candidate.is_file():
        raise ValueError(f"test log is not a regular file: {candidate}")
    if label == "result bundle" and not any(candidate.iterdir()):
        raise ValueError(f"result bundle is empty: {candidate}")
    if label == "test log" and candidate.stat().st_size == 0:
        raise ValueError(f"test log is empty: {candidate}")
    return candidate


def _verify_xcresult_if_native(candidate: pathlib.Path) -> None:
    """Ask Apple's result-tool to read native bundles when available.

    Small synthetic fixtures and hand-authored reports remain portable: they
    do not contain Apple's result-bundle root object and are checked by the
    structural rules above. A real Xcode bundle is verified through
    ``xcresulttool`` in release mode, where a successful directory copy alone
    must not be enough evidence.
    """
    info_path = candidate / "Info.plist"
    try:
        with info_path.open("rb") as handle:
            info = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException, ValueError):
        return
    if not isinstance(info, dict) or not info.get("rootObject"):
        return
    xcrun = shutil.which("xcrun")
    if xcrun is None:
        raise ValueError("native result bundle requires xcrun for release verification")
    completed = subprocess.run(
        [xcrun, "xcresulttool", "get", "test-results", "summary", "--path", str(candidate), "--format", "json"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        detail = completed.stderr.strip() or "unknown xcresulttool error"
        raise ValueError(f"xcresulttool could not verify result bundle: {detail}")
    try:
        summary = json.loads(completed.stdout)
    except ValueError as error:
        raise ValueError("xcresulttool returned invalid JSON for result bundle") from error
    if not isinstance(summary, dict):
        raise ValueError("xcresulttool returned an invalid result summary")


def _scenario_rows(text: str) -> list[tuple[str, str, str]]:
    rows: list[tuple[str, str, str]] = []
    in_table = False
    row_pattern = re.compile(r"^\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|\s*(.*?)\s*\|\s*$")
    for line in text.splitlines():
        if line.startswith("| Scenario ID"):
            in_table = True
            continue
        if not in_table:
            continue
        if line.startswith("## "):
            break
        if line.startswith("|---"):
            continue
        match = row_pattern.match(line)
        if match is None:
            if line.startswith("|"):
                raise ValueError(f"malformed scenario row: {line}")
            continue
        rows.append(tuple(part.strip() for part in match.groups()))
    if not rows:
        raise ValueError("device report has no scenario rows")
    return rows


def _validate_release_log(test_log: pathlib.Path) -> None:
    """Require the durable xcodebuild success marker for release evidence.

    The numeric exit code is necessary but not sufficient when a report is
    assembled by hand.  xcodebuild emits this marker after it has written the
    result bundle and completed the test action.
    """
    text = test_log.read_text(encoding="utf-8", errors="replace")
    upper = text.upper()
    if "TEST FAILED" in upper or "TEST FAILED" in upper.replace("**", ""):
        raise ValueError("test log contains an xcodebuild failure marker")
    if "TEST SUCCEEDED" not in upper:
        raise ValueError("test log does not contain the xcodebuild TEST SUCCEEDED marker")


def _validate_release_scenarios(
    rows: list[tuple[str, str, str]],
    text: str,
) -> None:
    failed = [(scenario_id, notes) for scenario_id, result, notes in rows if result != "pass"]
    if not failed:
        return

    # A failure may be accepted only by an explicit, reviewable waiver.  The
    # table is intentionally plain Markdown so it remains readable in GitHub
    # and easy to diff.  Each failed scenario needs exactly one non-empty row.
    waiver_rows: dict[str, tuple[str, str, str]] = {}
    in_table = False
    row_pattern = re.compile(
        r"^\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|\s*$"
    )
    for line in text.splitlines():
        if line.startswith("| Scenario ID") and "Waiver" in line:
            in_table = True
            continue
        if not in_table:
            continue
        if line.startswith("|---"):
            continue
        match = row_pattern.match(line)
        if match is None:
            if line.startswith("|"):
                raise ValueError(f"malformed release waiver row: {line}")
            continue
        scenario_id, issue, owner, approval = (part.strip() for part in match.groups())
        if scenario_id in waiver_rows:
            raise ValueError(f"duplicate release waiver: {scenario_id}")
        if not all((issue, owner, approval)):
            raise ValueError(f"release waiver is incomplete: {scenario_id}")
        waiver_rows[scenario_id] = (issue, owner, approval)

    failed_ids = {scenario_id for scenario_id, _ in failed}
    unknown = sorted(set(waiver_rows) - set(EXPECTED_SCENARIO_IDS))
    if unknown:
        raise ValueError("release waiver names unknown scenario IDs: " + ", ".join(unknown))
    missing = sorted(failed_ids - set(waiver_rows))
    if missing:
        raise ValueError("failed scenarios require explicit waivers: " + ", ".join(missing))


def _read_report_facts(report: pathlib.Path) -> tuple[dict[str, str], list[tuple[str, str, str]]]:
    """Read the fields needed for cross-report comparisons.

    Per-report validation remains the source of truth for the report schema;
    this helper only extracts already-validated values for manifest mode.
    """
    text = report.read_text(encoding="utf-8")
    fields = {name: _field(text, name) for name in _METADATA_FIELDS}
    return fields, _scenario_rows(text)


def validate(report: pathlib.Path, require_complete: bool, require_release: bool) -> int:
    if not report.is_file():
        raise ValueError(f"device report does not exist: {report}")
    text = report.read_text(encoding="utf-8")

    fields = {name: _field(text, name) for name in _METADATA_FIELDS}
    if fields["Device class:"] != "physical iPhone/iPad":
        raise ValueError("device report is not marked as a physical iPhone/iPad")
    for name in ("Device:", "Device model identifier:", "iOS:", "Toolchain:", "SDK:"):
        if fields[name].lower() == "unknown":
            raise ValueError(f"{name} cannot be unknown")
    try:
        exit_code = int(fields["Package test action exit code:"])
    except ValueError as error:
        raise ValueError("package test action exit code is not an integer") from error
    if exit_code != 0:
        raise ValueError(f"package test action did not pass (exit code {exit_code})")
    if "- [x] Physical-device package tests passed." not in text:
        raise ValueError("physical-device package tests are not marked passed")
    if "- [x] The `.xcresult` bundle above is retained" not in text:
        raise ValueError("result bundle is not marked retained")

    result_bundle = _resolve_report_path(report, fields["Result bundle:"], "result bundle")
    test_log = _resolve_report_path(report, fields["Test log:"], "test log")
    expected_bundle = report.with_suffix(".xcresult").resolve()
    expected_log = report.with_suffix(".log").resolve()
    if result_bundle != expected_bundle:
        raise ValueError(
            f"result bundle path is inconsistent with report path: expected {expected_bundle}, got {result_bundle}"
        )
    if test_log != expected_log:
        raise ValueError(
            f"test log path is inconsistent with report path: expected {expected_log}, got {test_log}"
        )

    rows = _scenario_rows(text)
    ids = [scenario_id for scenario_id, _, _ in rows]
    duplicates = sorted({scenario_id for scenario_id in ids if ids.count(scenario_id) > 1})
    if duplicates:
        raise ValueError("duplicate scenario IDs: " + ", ".join(duplicates))
    unknown = sorted(set(ids) - set(EXPECTED_SCENARIO_IDS))
    if unknown:
        raise ValueError("unknown scenario IDs: " + ", ".join(unknown))
    missing = [scenario_id for scenario_id in EXPECTED_SCENARIO_IDS if scenario_id not in ids]
    if missing:
        raise ValueError("missing scenario IDs: " + ", ".join(missing))
    for scenario_id, result, notes in rows:
        if not notes.strip():
            raise ValueError(f"scenario {scenario_id} has empty notes")
        if (require_complete or require_release) and result not in {"pass", "fail"}:
            raise ValueError(f"incomplete scenario result for {scenario_id}: {result}")

    if require_complete or require_release:
        if fields["iOS build:"] == "unknown" or fields["SDK:"] == "unknown":
            raise ValueError("release-complete report cannot use unknown iOS build or SDK")
        if "- [x] No raw audio, transcript text, TTS text, or credentials were included" not in text:
            raise ValueError("privacy review is not complete")
        if require_complete and not require_release:
            incomplete = [scenario_id for scenario_id, result, _ in rows if result != "pass"]
            if incomplete:
                raise ValueError(
                    "complete device report requires every scenario to pass: "
                    + ", ".join(incomplete)
                )
    if require_release:
        _verify_xcresult_if_native(result_bundle)
        _validate_release_log(test_log)
        _validate_release_scenarios(rows, text)

    print(f"device report OK: {report} ({len(rows)} scenario rows)")
    return 0


def _route_for_scenario(scenario_id: str) -> str:
    """Return the stable route dimension represented by a scenario row."""
    return scenario_id if scenario_id.startswith("route.") else "none"


def validate_manifest(manifest: pathlib.Path, require_complete: bool, require_release: bool) -> int:
    """Validate a JSON manifest and compare all of its reports.

    A manifest intentionally contains paths only. Device and OS identity are
    read from each report, so a stale manifest cannot override report data.
    """
    if not manifest.is_file():
        raise ValueError(f"device report manifest does not exist: {manifest}")
    try:
        document = json.loads(manifest.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise ValueError(f"device report manifest is not valid JSON: {error.msg}") from error
    if not isinstance(document, dict) or not isinstance(document.get("reports"), list):
        raise ValueError("device report manifest must contain a reports array")
    if not document["reports"]:
        raise ValueError("device report manifest reports array is empty")
    if any(not isinstance(path, str) or not path.strip() for path in document["reports"]):
        raise ValueError("device report manifest reports must be non-empty strings")

    reports: list[pathlib.Path] = []
    seen_paths: set[pathlib.Path] = set()
    for value in document["reports"]:
        report = pathlib.Path(value).expanduser()
        if not report.is_absolute():
            report = manifest.parent / report
        report = report.resolve()
        if report in seen_paths:
            raise ValueError(f"duplicate report path in manifest: {report}")
        seen_paths.add(report)
        reports.append(report)

    observations: dict[tuple[str, str, str, str], list[tuple[pathlib.Path, str]]] = {}
    identities: dict[tuple[str, str], list[tuple[pathlib.Path, dict[str, str]]]] = {}
    for report in reports:
        # validate() checks all existing single-report rules and evidence.
        validate(report, require_complete, require_release)
        fields, rows = _read_report_facts(report)
        identity = (fields["Device model identifier:"], fields["iOS build:"])
        identities.setdefault(identity, []).append((report, fields))
        for scenario_id, result, _ in rows:
            route = _route_for_scenario(scenario_id)
            key = (*identity, route, scenario_id)
            observations.setdefault(key, []).append((report, result))

    for identity in sorted(identities):
        entries = identities[identity]
        if len(entries) < 2:
            continue
        baseline = entries[0][1]
        conflicts = sorted(
            name
            for name in ("Device:", "iOS:", "Toolchain:", "SDK:")
            if any(fields[name] != baseline[name] for _, fields in entries[1:])
        )
        if conflicts:
            raise ValueError(
                "contradictory device/OS metadata for "
                f"{identity[0]} / {identity[1]}: {', '.join(conflicts)}"
            )

    duplicates: list[str] = []
    contradictions: list[str] = []
    for key in sorted(observations):
        entries = observations[key]
        if len(entries) < 2:
            continue
        label = "/".join(key)
        results = {result for _, result in entries}
        if len(results) > 1:
            contradictions.append(label)
        else:
            duplicates.append(label)
    if contradictions:
        raise ValueError("contradictory device/OS/route/scenario rows: " + ", ".join(contradictions))
    if duplicates:
        raise ValueError("duplicate device/OS/route/scenario rows: " + ", ".join(duplicates))

    print(f"device report manifest OK: {manifest} ({len(reports)} reports)")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("report", type=pathlib.Path, nargs="?")
    parser.add_argument(
        "--manifest",
        type=pathlib.Path,
        help="validate multiple reports listed in a JSON manifest",
    )
    parser.add_argument("--require-complete", action="store_true")
    parser.add_argument(
        "--require-release",
        action="store_true",
        help="require successful xcodebuild evidence and pass-or-waived scenarios",
    )
    args = parser.parse_args()
    if (args.report is None) == (args.manifest is None):
        parser.error("provide exactly one report path or --manifest")
    try:
        if args.manifest is not None:
            return validate_manifest(args.manifest, args.require_complete, args.require_release)
        return validate(args.report, args.require_complete, args.require_release)
    except (OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
