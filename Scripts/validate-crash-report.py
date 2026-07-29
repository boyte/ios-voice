#!/usr/bin/env python3
"""Validate the privacy-safe H12.4 crash/relaunch evidence record.

This is intentionally a host/device-report tool. It does not import the
package or define a runtime diagnostics API.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
from datetime import datetime, timezone
from typing import Any


class CrashReportValidationError(ValueError):
    """The report is missing evidence or contains unsafe/private data."""


SCHEMA_VERSION = "1.0"
_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_REVISION = re.compile(r"^(?:[0-9a-f]{7,64}|unpublished-worktree)$")
_SAFE_PATH = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]*$")
_SENSITIVE_KEY = re.compile(
    r"(?:audio|recording|transcript|utterance|speech.?text|tts.?text|credential|password|token|cookie|email|phone|address|location|user.?id|raw.?log|dump)",
    re.IGNORECASE,
)
_SENSITIVE_VALUE = re.compile(
    r"(?:<redacted>|redacted|unknown|unavailable|not.?provided|/Users/|/private/|/var/|file://)",
    re.IGNORECASE,
)
_ALLOWED_TOP_LEVEL = {
    "schemaVersion", "device", "sourceRevision", "activeOperation",
    "crashTimestamp", "relaunchTimestamp", "crashArtifact",
    "attachedLogs", "postRelaunchState", "recoveryResult", "redaction",
}


def _object(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise CrashReportValidationError(f"{label} must be an object")
    return value


def _text(value: Any, label: str, *, pattern: re.Pattern[str] | None = None) -> str:
    if not isinstance(value, str) or not value.strip():
        raise CrashReportValidationError(f"{label} must be a non-empty string")
    value = value.strip()
    if _SENSITIVE_VALUE.search(value):
        raise CrashReportValidationError(f"{label} contains unknown or redacted data")
    if pattern and not pattern.fullmatch(value):
        raise CrashReportValidationError(f"{label} has an invalid value")
    return value


def _timestamp(value: Any, label: str) -> datetime:
    text = _text(value, label)
    if not text.endswith("Z"):
        raise CrashReportValidationError(f"{label} must be an explicit UTC timestamp ending in Z")
    try:
        parsed = datetime.fromisoformat(text[:-1] + "+00:00")
    except ValueError as error:
        raise CrashReportValidationError(f"{label} is not ISO-8601") from error
    if parsed.tzinfo != timezone.utc:
        raise CrashReportValidationError(f"{label} must be UTC")
    return parsed


def _reject_unknown(value: Any, path: str = "report") -> None:
    """Reject extension fields, including fields that could carry secrets."""
    if isinstance(value, dict):
        for key, child in value.items():
            if not isinstance(key, str) or _SENSITIVE_KEY.search(key):
                raise CrashReportValidationError(f"unknown sensitive field: {path}.{key}")
            _reject_unknown(child, f"{path}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            _reject_unknown(child, f"{path}[{index}]")


def _artifact(value: Any, label: str, root: pathlib.Path) -> dict[str, str]:
    item = _object(value, label)
    if set(item) != {"path", "sha256"}:
        raise CrashReportValidationError(f"{label} must contain only path and sha256")
    path_text = _text(item.get("path"), f"{label}.path")
    path = pathlib.PurePosixPath(path_text)
    if path.is_absolute() or ".." in path.parts or not _SAFE_PATH.fullmatch(path_text):
        raise CrashReportValidationError(f"{label}.path is unsafe")
    digest = _text(item.get("sha256"), f"{label}.sha256", pattern=_SHA256)
    candidate = root / pathlib.Path(*path.parts)
    if candidate.is_symlink() or not candidate.is_file():
        raise CrashReportValidationError(f"{label}.path must reference a regular retained file")
    if hashlib.sha256(candidate.read_bytes()).hexdigest() != digest:
        raise CrashReportValidationError(f"{label}.sha256 does not match the retained file")
    return {"path": path_text, "sha256": digest}


def validate(document: dict[str, Any], artifact_root: pathlib.Path | None = None) -> dict[str, str]:
    """Validate a decoded report and return a compact acceptance summary."""
    document = _object(document, "report")
    unknown = set(document) - _ALLOWED_TOP_LEVEL
    if unknown:
        raise CrashReportValidationError("unknown report field(s): " + ", ".join(sorted(unknown)))
    missing = _ALLOWED_TOP_LEVEL - set(document)
    if missing:
        raise CrashReportValidationError("missing required field(s): " + ", ".join(sorted(missing)))
    _reject_unknown(document)
    if document["schemaVersion"] != SCHEMA_VERSION:
        raise CrashReportValidationError("unsupported schemaVersion")

    device = _object(document["device"], "device")
    if set(device) != {"model", "identifier", "osName", "osVersion", "osBuild"}:
        raise CrashReportValidationError("device fields are incomplete or unknown")
    for key in device:
        _text(device[key], f"device.{key}")

    _text(document["sourceRevision"], "sourceRevision", pattern=_REVISION)
    operation = _object(document["activeOperation"], "activeOperation")
    if set(operation) != {"id", "kind", "phase"}:
        raise CrashReportValidationError("activeOperation fields are incomplete or unknown")
    _text(operation["id"], "activeOperation.id", pattern=re.compile(r"^[A-Za-z0-9._-]{1,80}$"))
    _text(operation["kind"], "activeOperation.kind", pattern=re.compile(r"^[a-z][a-z0-9._-]{1,63}$"))
    if operation["phase"] not in {"starting", "listening", "speaking", "stopping", "recovering"}:
        raise CrashReportValidationError("activeOperation.phase is unsupported")

    crash = _timestamp(document["crashTimestamp"], "crashTimestamp")
    relaunch = _timestamp(document["relaunchTimestamp"], "relaunchTimestamp")
    if crash >= relaunch:
        raise CrashReportValidationError("relaunchTimestamp must be after crashTimestamp")
    root = artifact_root or pathlib.Path.cwd()
    _artifact(document["crashArtifact"], "crashArtifact", root)
    logs = _object(document["attachedLogs"], "attachedLogs")
    if set(logs) != {"host", "device"}:
        raise CrashReportValidationError("attachedLogs must contain host and device references")
    _artifact(logs["host"], "attachedLogs.host", root)
    _artifact(logs["device"], "attachedLogs.device", root)

    state = _object(document["postRelaunchState"], "postRelaunchState")
    if set(state) != {"state", "observedAt", "freshOperationCompleted"}:
        raise CrashReportValidationError("postRelaunchState fields are incomplete or unknown")
    if state["state"] != "idle" or state["freshOperationCompleted"] is not True:
        raise CrashReportValidationError("post-relaunch recovery state is not proven")
    observed = _timestamp(state["observedAt"], "postRelaunchState.observedAt")
    if observed < relaunch:
        raise CrashReportValidationError("post-relaunch observation predates relaunch")

    recovery = _object(document["recoveryResult"], "recoveryResult")
    if set(recovery) != {"status", "verifiedAt", "evidence"}:
        raise CrashReportValidationError("recoveryResult fields are incomplete or unknown")
    if recovery["status"] != "proven":
        raise CrashReportValidationError("recovery result is not proven")
    evidence = recovery["evidence"]
    if not isinstance(evidence, list) or not evidence:
        raise CrashReportValidationError("recoveryResult.evidence must not be empty")
    for index, item in enumerate(evidence):
        _artifact(item, f"recoveryResult.evidence[{index}]", root)
    verified = _timestamp(recovery["verifiedAt"], "recoveryResult.verifiedAt")
    if verified < observed:
        raise CrashReportValidationError("recovery verification predates post-relaunch observation")

    redaction = _object(document["redaction"], "redaction")
    if set(redaction) != {"rulesVersion", "applied", "removedFields", "reviewedBy"}:
        raise CrashReportValidationError("redaction fields are incomplete or unknown")
    _text(redaction["rulesVersion"], "redaction.rulesVersion", pattern=re.compile(r"^H12\.4-[0-9]+$"))
    if redaction["applied"] is not True or not isinstance(redaction["removedFields"], list):
        raise CrashReportValidationError("redaction must be explicitly applied with a field list")
    if redaction["removedFields"] != sorted(set(redaction["removedFields"])):
        raise CrashReportValidationError("redaction.removedFields must be sorted and unique")
    for field in redaction["removedFields"]:
        _text(field, "redaction.removedFields entry")
    _text(redaction["reviewedBy"], "redaction.reviewedBy", pattern=re.compile(r"^[A-Za-z0-9._-]{1,64}$"))
    return {"schemaVersion": SCHEMA_VERSION, "sourceRevision": document["sourceRevision"], "recovery": "proven"}


def load(path: pathlib.Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise CrashReportValidationError(f"cannot read JSON report: {error}") from error
    return _object(value, "report")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=pathlib.Path)
    args = parser.parse_args()
    try:
        result = validate(load(args.report), args.report.parent.resolve())
    except CrashReportValidationError as error:
        parser.exit(1, f"crash report validation failed: {error}\n")
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
