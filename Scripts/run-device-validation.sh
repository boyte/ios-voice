#!/usr/bin/env bash
set -euo pipefail

# Run the package's test action on a connected physical iPhone or iPad and
# capture the toolchain/device evidence needed for a release report.
# Hardware behavior still requires the manual scenarios in
# Documentation/DeviceMatrix.md; this script makes the build/test evidence
# reproducible and prevents a simulator from being mistaken for a device.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DEVICE_ID="${1:-}"
# Device UDIDs authenticate the Xcode destination but are not release
# evidence. Keep them out of report filenames as well as report content.
REPORT_PATH="${2:-Documentation/device-reports/$(date -u +%Y-%m-%dT%H-%M-%SZ).md}"
MANIFEST_PATH=""

if [[ "${3:-}" == "--manifest" ]]; then
  MANIFEST_PATH="${4:-}"
  if [[ -z "$MANIFEST_PATH" ]]; then
    echo "usage: $0 <physical-device-udid> [report-path] [--manifest manifest-path]" >&2
    exit 2
  fi
elif [[ "${3:-}" != "" ]]; then
  echo "usage: $0 <physical-device-udid> [report-path] [--manifest manifest-path]" >&2
  exit 2
fi
if [[ -n "$MANIFEST_PATH" && "${5:-}" != "" ]]; then
  echo "usage: $0 <physical-device-udid> [report-path] [--manifest manifest-path]" >&2
  exit 2
fi

if [[ -z "$DEVICE_ID" ]]; then
  echo "usage: $0 <physical-device-udid> [report-path] [--manifest manifest-path]" >&2
  echo >&2
  echo "Connected devices:" >&2
  xcrun xctrace list devices >&2 || true
  exit 2
fi

if ! DEVICE_LIST="$(xcrun xctrace list devices)"; then
  echo "unable to enumerate connected devices with xctrace" >&2
  exit 2
fi
DEVICE_LINE="$(printf '%s\n' "$DEVICE_LIST" | awk -v id="$DEVICE_ID" 'index($0, "(" id ")") { print; exit }')"
if [[ -z "$DEVICE_LINE" || "$DEVICE_LINE" == *Simulator* ]]; then
  echo "The supplied identifier is not a connected physical device: $DEVICE_ID" >&2
  printf '%s\n' "$DEVICE_LIST" >&2
  exit 2
fi

mkdir -p "$(dirname "$REPORT_PATH")"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/applocalvoice-device.XXXXXX")"
cleanup() {
  # Cleanup is best effort. It must never replace the xcodebuild status or
  # make a truthful failure report look like a hardware pass.
  if [[ -n "${TEMP_DIR:-}" ]] && [[ -d "$TEMP_DIR" ]]; then
    rm -rf "$TEMP_DIR" || echo "warning: unable to remove temporary evidence directory: $TEMP_DIR" >&2
  fi
  return 0
}
trap cleanup EXIT
RESULT_BUNDLE="${TEMP_DIR}/AppLocalVoice-device.xcresult"
REPORT_DIR="$(dirname "$REPORT_PATH")"
REPORT_STEM="$(basename "$REPORT_PATH" .md)"
RETAINED_RESULT="${REPORT_DIR}/${REPORT_STEM}.xcresult"
RETAINED_LOG="${REPORT_DIR}/${REPORT_STEM}.log"

if ! xcrun devicectl list devices --json-output "$TEMP_DIR/devices.json" >/dev/null 2>&1; then
  echo "unable to collect exact physical-device model, OS version, and OS build" >&2
  exit 2
fi
if ! DEVICE_FACTS="$(python3 "$(dirname "$0")/device-validation-evidence.py" "$TEMP_DIR/devices.json" "$DEVICE_ID")"; then
  echo "unable to collect complete physical-device identity for $DEVICE_ID" >&2
  exit 2
fi
IFS=$'\t' read -r DEVICE_NAME DEVICE_MODEL_IDENTIFIER IOS_VERSION IOS_BUILD <<<"$DEVICE_FACTS"
if [[ -z "$DEVICE_NAME" || -z "$DEVICE_MODEL_IDENTIFIER" || -z "$IOS_VERSION" || -z "$IOS_BUILD" ]]; then
  echo "unable to collect complete physical-device identity for $DEVICE_ID" >&2
  exit 2
fi
if ! XCODE_VERSION="$(xcodebuild -version | tr '\n' '; ' | sed 's/; $//')" || [[ -z "$XCODE_VERSION" ]]; then
  echo "unable to collect exact Xcode toolchain version" >&2
  exit 2
fi
if ! SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version)" || [[ -z "$SDK_VERSION" ]]; then
  echo "unable to collect exact iPhoneOS SDK version" >&2
  exit 2
fi
MATRIX_LINK="$(python3 - "$REPORT_PATH" <<'PY'
import os
import sys
print(os.path.relpath("Documentation/DeviceMatrix.md", os.path.dirname(sys.argv[1]) or "."))
PY
)"

set +e
Scripts/run-with-timeout.pl 1800 physical-device xcodebuild test \
  -project "$ROOT_DIR/Testing/AppLocalVoice.xcodeproj" \
  -scheme AppLocalVoiceTests \
  -destination "platform=iOS,id=$DEVICE_ID" \
  -destination-timeout 120 \
  -derivedDataPath "$TEMP_DIR/DerivedData" \
  -resultBundlePath "$RESULT_BUNDLE" \
  CODE_SIGNING_ALLOWED=YES \
  2>&1 | tee "$TEMP_DIR/xcodebuild.log"
TEST_STATUS=${PIPESTATUS[0]}
set -e

TEST_EVIDENCE='[ ]'
[[ "$TEST_STATUS" -eq 0 ]] && TEST_EVIDENCE='[x]'
RESULT_EVIDENCE='[ ]'
LOG_EVIDENCE='[ ]'

ARTIFACT_STATUS=0
if [[ -d "$RESULT_BUNDLE" ]]; then
  if ! rm -rf "$RETAINED_RESULT" || ! cp -R "$RESULT_BUNDLE" "$RETAINED_RESULT"; then
    echo "unable to retain physical-device result bundle: $RETAINED_RESULT" >&2
    ARTIFACT_STATUS=1
  fi
else
  echo "physical-device result bundle was not produced: $RESULT_BUNDLE" >&2
  ARTIFACT_STATUS=1
fi
if [[ ! -d "$RETAINED_RESULT" || -z "$(find "$RETAINED_RESULT" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
  echo "physical-device result bundle was not retained: $RETAINED_RESULT" >&2
  ARTIFACT_STATUS=1
else
  RESULT_EVIDENCE='[x]'
fi
SANITIZED_DEVICE_LOG="${TEMP_DIR}/xcodebuild.sanitized.log"
if ! python3 "$(dirname "$0")/sanitize-evidence-log.py" \
    "$TEMP_DIR/xcodebuild.log" "$SANITIZED_DEVICE_LOG" >&2; then
  echo "physical-device test log could not be sanitized" >&2
  ARTIFACT_STATUS=1
elif ! cp "$SANITIZED_DEVICE_LOG" "$RETAINED_LOG" || [[ ! -s "$RETAINED_LOG" ]]; then
  echo "physical-device test log was not retained: $RETAINED_LOG" >&2
  ARTIFACT_STATUS=1
else
  LOG_EVIDENCE='[x]'
fi

cat > "$REPORT_PATH" <<EOF
# AppLocalVoice device validation report

- Date (UTC): $(date -u +%Y-%m-%dT%H:%M:%SZ)
- Device: ${DEVICE_NAME:-unknown}
- Device model identifier: ${DEVICE_MODEL_IDENTIFIER:-unknown}
- Device class: physical iPhone/iPad
- iOS: ${IOS_VERSION:-unknown}
- iOS build: ${IOS_BUILD:-unknown}
- Toolchain: $XCODE_VERSION
- SDK: $SDK_VERSION
- Package test action exit code: $TEST_STATUS
- Result bundle: ${RETAINED_RESULT}
- Test log: ${RETAINED_LOG}

## Automated evidence

- $TEST_EVIDENCE Physical-device package tests passed.
- [x] No signing or deployment workaround was used.
- $LOG_EVIDENCE Test log retained with the release artifacts.
- $RESULT_EVIDENCE The `.xcresult` bundle above is retained with the release artifacts.

## Manual scenarios

Complete the matrix in [DeviceMatrix.md]($MATRIX_LINK), including every row below.

| Scenario ID | Result | Notes / issue |
|---|---|---|
| route.builtin | _pending_ | Built-in microphone and speaker |
| route.bluetooth.hfp | _pending_ | Connect/disconnect Bluetooth HFP |
| route.wired | _pending_ | Wired headset where supported |
| permission.first-run | _pending_ | First request and approval |
| permission.denied-retry | _pending_ | Denial, Settings approval, retry |
| model.installed | _pending_ | Installed on-device model |
| model.missing-install | _pending_ | Explicit installation policy |
| model.install-interrupted | _pending_ | Installation interruption/retry |
| interruption.phone-call | _pending_ | Phone call interruption |
| interruption.siri | _pending_ | Siri interruption |
| interruption.notification | _pending_ | Alarm/notification interruption |
| interruption.media-services-reset | _pending_ | Audio media services lost/reset |
| route.bluetooth-reconnect | _pending_ | Disconnect/reconnect during idle and capture |
| lifecycle.background-foreground | _pending_ | Background and foreground |
| lifecycle.screen-lock | _pending_ | Screen lock and unlock |
| lifecycle.rapid-turns | _pending_ | Repeated start/finish/cancel turns |
| audio.music-playing | _pending_ | Other audio already playing |
| model.low-storage | _pending_ | Low storage during installation |
| voice.compact | _pending_ | Compact voice selection |
| voice.enhanced | _pending_ | Enhanced voice selection/download |
| voice.premium | _pending_ | Premium voice selection/download |
| lifecycle.active-close | _pending_ | Close during active capture and speech |
| lifecycle.process-relaunch | _pending_ | Relaunch after controlled process termination |
| capability.hardware-availability | _pending_ | SpeechTranscriber availability matches startup |
| endurance.30-minutes | _pending_ | 30-minute repeated use |

## Privacy check

- [ ] No raw device identifier, audio, transcript text, TTS text, or credentials were included in the report or logs.

EOF

MANIFEST_STATUS=0
if [[ -n "$MANIFEST_PATH" ]]; then
  if ! python3 - "$MANIFEST_PATH" "$REPORT_PATH" <<'PY'
import json
import os
import pathlib
import sys

manifest = pathlib.Path(sys.argv[1]).expanduser()
report = pathlib.Path(sys.argv[2]).expanduser().resolve()
try:
    document = json.loads(manifest.read_text(encoding="utf-8")) if manifest.exists() else {"reports": []}
    if not isinstance(document, dict) or not isinstance(document.get("reports"), list):
        raise ValueError("manifest must contain a reports array")
    if any(not isinstance(value, str) or not value.strip() for value in document["reports"]):
        raise ValueError("manifest reports must be non-empty strings")
    manifest.parent.mkdir(parents=True, exist_ok=True)
    relative = os.path.relpath(report, manifest.parent.resolve())
    existing = []
    for value in document["reports"]:
        candidate = pathlib.Path(value).expanduser()
        if not candidate.is_absolute():
            candidate = manifest.parent / candidate
        if candidate.resolve() == report:
            continue
        existing.append(value)
    document["reports"] = existing + [relative]
    temporary = manifest.with_name(manifest.name + ".tmp")
    temporary.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, manifest)
except (OSError, json.JSONDecodeError, ValueError) as error:
    print(f"unable to update device report manifest: {error}", file=sys.stderr)
    try:
        temporary.unlink()
    except (NameError, OSError):
        pass
    raise SystemExit(2)
PY
  then
    MANIFEST_STATUS=1
  else
    echo "Device report manifest updated: $MANIFEST_PATH"
  fi
fi

if [[ "$TEST_STATUS" -ne 0 ]]; then
  echo "Physical-device test action failed; report written to $REPORT_PATH" >&2
  exit "$TEST_STATUS"
fi
if [[ "$ARTIFACT_STATUS" -ne 0 || "$MANIFEST_STATUS" -ne 0 ]]; then
  echo "Physical-device evidence was incomplete; report written to $REPORT_PATH" >&2
  exit 1
fi

echo "Automated physical-device package test passed; complete the manual matrix in $REPORT_PATH"
