#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/applocalvoice-evidence-validator.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

# The checked-in inventory is a safe, portable JSON evidence artifact.
python3 "$ROOT_DIR/Scripts/validate-privacy-artifacts.py" \
  "$ROOT_DIR/Documentation/TestInventory.json"

python3 - "$TMP_DIR" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
for name, contents in {
    "crash.ips": "fixture crash artifact\n",
    "host.log": "state=idle\n",
    "device.log": "state=idle\n",
    "recovery.log": "recovery=proven\n",
}.items():
    (root / name).write_text(contents, encoding="utf-8")

def ref(name: str) -> dict[str, str]:
    data = (root / name).read_bytes()
    return {"path": name, "sha256": hashlib.sha256(data).hexdigest()}

report = {
    "schemaVersion": "1.0",
    "device": {
        "model": "CI fixture device",
        "identifier": "ci-fixture",
        "osName": "iOS",
        "osVersion": "26.0",
        "osBuild": "26A000",
    },
    "sourceRevision": "unpublished-worktree",
    "activeOperation": {"id": "ci-op", "kind": "listen", "phase": "listening"},
    "crashTimestamp": "2026-01-01T00:00:00Z",
    "relaunchTimestamp": "2026-01-01T00:00:01Z",
    "crashArtifact": ref("crash.ips"),
    "attachedLogs": {"host": ref("host.log"), "device": ref("device.log")},
    "postRelaunchState": {
        "state": "idle",
        "observedAt": "2026-01-01T00:00:02Z",
        "freshOperationCompleted": True,
    },
    "recoveryResult": {
        "status": "proven",
        "verifiedAt": "2026-01-01T00:00:03Z",
        "evidence": [ref("recovery.log")],
    },
    "redaction": {
        "rulesVersion": "H12.4-1",
        "applied": True,
        "removedFields": ["credentials", "raw audio", "speech text"],
        "reviewedBy": "ci",
    },
}
(root / "crash-relaunch.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
PY

python3 "$ROOT_DIR/Scripts/validate-crash-report.py" "$TMP_DIR/crash-relaunch.json"
