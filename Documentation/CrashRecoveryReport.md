# Crash/relaunch evidence report

Scripts/validate-crash-report.py validates the H12.4 host/device evidence
record. It is a report-time tool: it adds no runtime package API and does not
collect, upload, or interpret speech data.

## Schema 1.0

The report is UTF-8 JSON with exactly these top-level fields:

| Field | Required contents |
|---|---|
| schemaVersion | 1.0 |
| device | model, stable identifier, osName, osVersion, and exact osBuild |
| sourceRevision | 7–64 hexadecimal source revision, or unpublished-worktree |
| activeOperation | opaque id, bounded kind, and phase |
| crashTimestamp, relaunchTimestamp | explicit UTC ISO-8601 timestamps; relaunch must be later |
| crashArtifact | retained relative path and lowercase SHA-256 sha256 |
| attachedLogs | retained host and device path/hash references |
| postRelaunchState | state idle, observedAt after relaunch, and freshOperationCompleted true |
| recoveryResult | status proven, verifiedAt after observation, and retained evidence |
| redaction | H12.4-1 rules, applied true, sorted removed-field names, and reviewer |

Run it from the report directory; all artifact paths are relative to that
directory:

    python3 Scripts/validate-crash-report.py Documentation/evidence/crash-relaunch.json

Referenced files must be regular, non-symlink files and their SHA-256 digests
must match. Absolute paths, parent traversal, empty or missing files, unknown
fields, unknown/redacted values, unsupported schema versions, and timestamps
that move backward are rejected. Recovery is accepted only when a fresh
operation completed and the report contains retained proof.

## Redaction rules

Before retaining or sharing a report, remove microphone recordings, raw crash
dumps, transcript or utterance text, TTS text, credentials, tokens, account
identifiers, contact data, arbitrary user input, and host-private absolute
paths. Use synthetic phrases only in a host/device log. Keep stable operation
IDs, coarse operation phases, device/OS identity, source revision, timestamps,
artifact hashes, and stable recovery/error categories.

The validator fails closed on unknown fields so a future field must first be
added to a reviewed schema revision. Do not work around that rule by placing
private data in a free-form object or log filename.
