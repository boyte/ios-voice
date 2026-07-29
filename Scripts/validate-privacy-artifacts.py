#!/usr/bin/env python3
"""Fail-closed privacy scanner for portable release evidence artifacts.

Only Markdown, JSON, text, and log files are inspected.  The scanner is
deliberately lexical: it never attempts to reconstruct or redact speech.  A
successful run means that every inspected file is readable, JSON is valid, and
no disallowed content or path was found.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
from dataclasses import dataclass
from typing import Any, Iterable


class PrivacyArtifactError(ValueError):
    """An input, policy, or artifact violates the privacy boundary."""


ARTIFACT_SUFFIXES = frozenset({".md", ".markdown", ".json", ".txt", ".text", ".log"})
SAFE_METADATA_FIELDS = frozenset(
    {
        "activeOperation.id",
        "activeOperation.kind",
        "activeOperation.phase",
        "artifacts[].path",
        "device.model",
        "device.osName",
        "device.osVersion",
        "device.osBuild",
        "event",
        "localeIdentifier",
        "operationId",
        "routeClass",
        "schemaVersion",
        "sourceRevision",
        "state",
        "status",
        "timingMs",
        "durationMs",
        "result",
        "errorCategory",
        "measurements[].name",
        "measurements[].notes",
    }
)
DEFAULT_SAFE_METADATA_FIELDS = frozenset(
    {
        "activeOperation.id", "activeOperation.kind", "activeOperation.phase",
        "device.model", "device.osName", "device.osVersion", "device.osBuild",
        "localeIdentifier", "operationId", "routeClass", "state", "status",
        "timingMs", "durationMs", "errorCategory", "schemaVersion", "sourceRevision",
    }
)
_SAFE_SCALAR = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._:/+@-]{0,127}$")
_ABSOLUTE_PATH = re.compile(
    r"(?:/(?:Users|home|private|var|tmp|etc|opt|Volumes|Applications)(?:/|$)|[A-Za-z]:\\(?:Users|Windows|ProgramData)\\)",
    re.IGNORECASE,
)
_SPEECH = re.compile(
    r"\b(?:raw[\s_-]+audio|audio[\s_-]+payload|transcript(?:ion)?|utterance|"
    r"speech(?:[\s_-]+text|[\s_-]+content|[\s_-]+started|Text|Content)|"
    r"tts(?:[\s_-]+text|[\s_-]+content|Text|Content)|"
    r"spoken[\s_-]+text|recognized[\s_-]+text)\b",
    re.IGNORECASE,
)
_CREDENTIAL = re.compile(
    r"(?:api[_ -]?key|access[_ -]?token|bearer\s+[A-Za-z0-9._-]+|client[_ -]?secret|cookie|password|private[_ -]?key|secret[_ -]?key|session[_ -]?token|-----BEGIN|(?:sk|gh[opsu])_[A-Za-z0-9]{12,}|AKIA[0-9A-Z]{16})",
    re.IGNORECASE,
)
# A raw Apple UDID is not useful release evidence. Detect it in an explicit
# device-identity label without treating a source revision or diagnostic UUID
# as private data.
_DEVICE_UDID = re.compile(
    r"\b(?:device[\s_-]*(?:udid|id|identifier)|udid)\s*[:=]\s*"
    r"[A-Fa-f0-9]{40}\b",
    re.IGNORECASE,
)
_REDACTION_MARKER = re.compile(r"^\[REDACTED: [A-Z_+]+\]$")


@dataclass(frozen=True, order=True)
class Finding:
    path: str
    line: int
    code: str
    message: str

    def render(self) -> str:
        return f"{self.path}:{self.line}:{self.code}: {self.message}"


def _normal_key(key: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", key.lower())


def _field_allowed(path: str, allowlist: frozenset[str]) -> bool:
    normalized = re.sub(r"\[\d+\]", "[]", path)
    return normalized in DEFAULT_SAFE_METADATA_FIELDS or normalized in allowlist


def load_allowlist(path: pathlib.Path) -> frozenset[str]:
    """Load exact safe metadata field names; unknown names fail closed."""
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise PrivacyArtifactError(f"cannot read metadata allowlist {path}: {error}") from error
    if not isinstance(value, dict) or set(value) != {"metadata"} or not isinstance(value["metadata"], list):
        raise PrivacyArtifactError("metadata allowlist must be {\"metadata\": [field, ...]}")
    fields = value["metadata"]
    if any(not isinstance(item, str) or not item.strip() for item in fields):
        raise PrivacyArtifactError("metadata allowlist entries must be non-empty strings")
    if fields != sorted(set(fields)):
        raise PrivacyArtifactError("metadata allowlist entries must be sorted and unique")
    unknown = sorted(set(fields) - SAFE_METADATA_FIELDS)
    if unknown:
        raise PrivacyArtifactError("metadata allowlist contains unsupported field(s): " + ", ".join(unknown))
    return frozenset(fields)


def _value_findings(value: str, label: str, path: str, line: int, allowlisted: bool) -> list[Finding]:
    findings: list[Finding] = []
    if _REDACTION_MARKER.fullmatch(value.strip()):
        return findings
    if _ABSOLUTE_PATH.search(value):
        findings.append(Finding(path, line, "PRIVATE_PATH", f"{label} contains an absolute private path"))
    if _CREDENTIAL.search(value):
        findings.append(Finding(path, line, "CREDENTIAL", f"{label} contains credential-like content"))
    if _DEVICE_UDID.search(value):
        findings.append(Finding(path, line, "DEVICE_UDID", f"{label} contains a raw physical-device identifier"))
    if not allowlisted and _SPEECH.search(value):
        findings.append(Finding(path, line, "SPEECH_CONTENT", f"{label} contains speech, transcript, or TTS content"))
    return findings


def _scan_json(value: Any, path: str, line_by_path: dict[str, int], logical: str, allowlist: frozenset[str]) -> list[Finding]:
    findings: list[Finding] = []
    if isinstance(value, dict):
        for key in sorted(value):
            if not isinstance(key, str):
                findings.append(Finding(logical, 1, "JSON_SCHEMA", "object keys must be strings"))
                continue
            child_path = f"{path}.{key}" if path else key
            line = line_by_path.get(child_path, line_by_path.get(path, 1))
            key_norm = _normal_key(key)
            if key_norm in {
                "transcript", "transcription", "utterance", "speechtext", "speechcontent",
                "ttstext", "ttscontent", "rawaudio", "audiopayload", "spokentext",
            }:
                findings.append(Finding(logical, line, "SPEECH_FIELD", f"field {child_path} is not permitted"))
            if key_norm in {"apikey", "accesstoken", "authtoken", "authorization", "cookie", "password", "privatekey", "secretkey", "sessiontoken"}:
                findings.append(Finding(logical, line, "CREDENTIAL_FIELD", f"field {child_path} is not permitted"))
            if key_norm in {"deviceudid", "deviceidentifier", "udid"}:
                findings.append(Finding(logical, line, "DEVICE_UDID_FIELD", f"field {child_path} is not permitted"))
            findings.extend(_scan_json(value[key], child_path, line_by_path, logical, allowlist))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            findings.extend(_scan_json(child, f"{path}[{index}]", line_by_path, logical, allowlist))
    elif isinstance(value, str):
        findings.extend(_value_findings(value, path or "value", logical, line_by_path.get(path, 1), _field_allowed(path, allowlist)))
    return findings


def _json_lines(text: str) -> dict[str, int]:
    """Map common JSON property paths to source lines for stable diagnostics."""
    result: dict[str, int] = {}
    for number, raw in enumerate(text.splitlines(), 1):
        match = re.search(r'"([^"\\]+)"\s*:', raw)
        if match:
            result.setdefault(match.group(1), number)
    return result


def scan_file(path: pathlib.Path, logical: str | None = None, allowlist: frozenset[str] = frozenset()) -> list[Finding]:
    """Scan one supported artifact and return sorted deterministic findings."""
    name = logical or path.name
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        return [Finding(name, 1, "UNREADABLE", f"cannot read artifact: {error}")]
    findings: list[Finding] = []
    if path.suffix.lower() == ".json":
        try:
            decoded = json.loads(text)
        except json.JSONDecodeError as error:
            return [Finding(name, error.lineno, "MALFORMED_JSON", "JSON must be valid")]
        findings.extend(_scan_json(decoded, "", _json_lines(text), name, allowlist))
    else:
        for line_number, line in enumerate(text.splitlines(), 1):
            findings.extend(_value_findings(line, "line", name, line_number, False))
    return sorted(findings)


def _files(inputs: Iterable[pathlib.Path]) -> list[tuple[pathlib.Path, str]]:
    selected: list[tuple[pathlib.Path, str]] = []
    seen: set[pathlib.Path] = set()
    for raw in inputs:
        path = pathlib.Path(os.path.abspath(raw))
        try:
            info = path.lstat()
        except OSError as error:
            raise PrivacyArtifactError(f"input does not exist or is inaccessible: {raw}: {error}") from error
        if path.is_symlink():
            raise PrivacyArtifactError(f"input must not be a symlink: {raw}")
        if path.is_file():
            if path.suffix.lower() not in ARTIFACT_SUFFIXES:
                raise PrivacyArtifactError(f"unsupported artifact type: {raw}")
            candidate = (path, path.name)
            if path in seen:
                raise PrivacyArtifactError(f"duplicate artifact input: {raw}")
            seen.add(path)
            selected.append(candidate)
        elif path.is_dir():
            for child in sorted(path.rglob("*"), key=os.fspath):
                if child.is_symlink():
                    raise PrivacyArtifactError(f"input contains a symlink: {child}")
                if child.is_dir():
                    continue
                if not child.is_file():
                    raise PrivacyArtifactError(f"input contains a non-regular file: {child}")
                if child.suffix.lower() not in ARTIFACT_SUFFIXES:
                    continue
                if child in seen:
                    raise PrivacyArtifactError(f"duplicate artifact input: {child}")
                seen.add(child)
                selected.append((child, pathlib.PurePosixPath(child.relative_to(path).as_posix()).as_posix()))
        else:
            raise PrivacyArtifactError(f"input is not a regular file or directory: {raw}")
    if not selected:
        raise PrivacyArtifactError("no Markdown, JSON, text, or log artifacts found")
    return sorted(selected, key=lambda item: item[1])


def scan(inputs: Iterable[pathlib.Path], allowlist: frozenset[str] = frozenset()) -> list[Finding]:
    findings: list[Finding] = []
    for path, logical in _files(inputs):
        findings.extend(scan_file(path, logical, allowlist))
    return sorted(findings)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifact", nargs="+", type=pathlib.Path, help="artifact file(s) or directories")
    parser.add_argument("--metadata-allowlist", type=pathlib.Path, help="JSON file listing exact safe metadata fields")
    args = parser.parse_args()
    try:
        allowlist = load_allowlist(args.metadata_allowlist) if args.metadata_allowlist else frozenset()
        findings = scan(args.artifact, allowlist)
    except PrivacyArtifactError as error:
        parser.exit(2, f"privacy artifact validation failed: {error}\n")
    if findings:
        for finding in findings:
            print(finding.render())
        return 1
    print("privacy artifact validation passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
