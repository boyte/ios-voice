#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${1:-${ROOT_DIR}/.build/memory-sweep-artifacts}"
OUTPUT_DIR="$(mkdir -p "$OUTPUT_DIR" && cd "$OUTPUT_DIR" && pwd)"
RESULT_BUNDLE="${OUTPUT_DIR}/AppLocalVoice-memory-sweep.xcresult"
LOG="${OUTPUT_DIR}/AppLocalVoice-memory-sweep.log"
ARTIFACT="${OUTPUT_DIR}/AppLocalVoice-memory-sweep.json"
NATIVE_SUMMARY="${OUTPUT_DIR}/AppLocalVoice-memory-sweep-test-summary.json"
DERIVED_DATA="${OUTPUT_DIR}.derived-data"

# Usage: run-memory-sweep.sh [output-directory]
#
# Publication is fail-closed: the selected XCTest must produce the expected
# three samples, a non-empty .xcresult bundle, a native Passed summary for
# exactly one test with zero failures/skips/expected failures, and the
# xcodebuild TEST SUCCEEDED marker. The native summary is retained beside the
# artifact so reviewers can inspect the evidence used for reconciliation.

rm -rf "$RESULT_BUNDLE" "$DERIVED_DATA"

SIMULATOR_NAME="${APPLOCALVOICE_SIMULATOR_NAME:-iPhone 17 Pro}"
SIMULATOR_RUNTIME="${APPLOCALVOICE_SIMULATOR_RUNTIME:-iOS-26-0}"
# Hosted jobs have an isolated runner and do not need an erase before these
# deterministic proxy tests. Erase is opt-in for a deliberately clean local
# campaign because CoreSimulator erase can hang independently of the test.
ERASE_SIMULATOR="${APPLOCALVOICE_ERASE_SIMULATOR:-0}"
SIMULATOR_JSON="${OUTPUT_DIR}/simulators.json"
trap 'rm -f "$SIMULATOR_JSON"' EXIT
if ! xcrun simctl list devices available --json >"$SIMULATOR_JSON"; then
  echo "unable to enumerate available iPhone 17 Pro simulators" >&2
  exit 2
fi
DEVICE_ID="$(python3 -c '
import json
import sys

name, requested_runtime = sys.argv[1:]
document = json.load(sys.stdin)
candidates = []
for runtime, devices in document.get("devices", {}).items():
    if requested_runtime and not (runtime == requested_runtime or runtime.endswith(requested_runtime)):
        continue
    for device in devices:
        if device.get("isAvailable", True) and device.get("name") == name and device.get("udid"):
            candidates.append((runtime, device["udid"]))
if len(candidates) != 1:
    if not candidates:
        raise SystemExit(f"required simulator unavailable: {name!r}" + (f" runtime {requested_runtime!r}" if requested_runtime else ""))
    raise SystemExit("simulator selection is ambiguous; set APPLOCALVOICE_SIMULATOR_RUNTIME to one of: " + ", ".join(runtime for runtime, _ in sorted(candidates)))
print(candidates[0][1])
' "$SIMULATOR_NAME" "$SIMULATOR_RUNTIME" <"$SIMULATOR_JSON")" || {
  echo "unable to select a unique $SIMULATOR_NAME simulator" >&2
  exit 2
}
rm -f "$SIMULATOR_JSON"
test -n "$DEVICE_ID"

cleanup() {
  xcrun simctl shutdown "$DEVICE_ID" >/dev/null 2>&1 || true
  rm -f "$SIMULATOR_JSON"
}
trap cleanup EXIT

xcrun simctl shutdown "$DEVICE_ID" >/dev/null 2>&1 || true
case "$ERASE_SIMULATOR" in
  0) ;;
  1) xcrun simctl erase "$DEVICE_ID" ;;
  *) echo "APPLOCALVOICE_ERASE_SIMULATOR must be 0 or 1" >&2; exit 2 ;;
esac
xcrun simctl boot "$DEVICE_ID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$DEVICE_ID" -b

set -o pipefail
xcodebuild test \
  -project "$ROOT_DIR/Testing/AppLocalVoice.xcodeproj" \
  -scheme AppLocalVoiceTests \
  -destination "platform=iOS Simulator,id=$DEVICE_ID" \
  -destination-timeout 120 \
  -derivedDataPath "$DERIVED_DATA" \
  -only-testing:AppLocalVoiceTests/MemorySweepTests \
  -resultBundlePath "$RESULT_BUNDLE" \
  -parallel-testing-enabled NO \
  -maximum-parallel-testing-workers 1 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$LOG"

# Keep the machine-readable memory sample coupled to the XCTest evidence that
# generated it.  A parsed log without a result bundle is not release evidence.
if [[ ! -d "$RESULT_BUNDLE" ]] || [[ -z "$(find "$RESULT_BUNDLE" -mindepth 1 -print -quit)" ]]; then
  echo "memory-sweep result bundle is missing or empty: $RESULT_BUNDLE" >&2
  exit 1
fi
if ! grep -q "TEST SUCCEEDED" "$LOG"; then
  echo "memory-sweep log has no xcodebuild TEST SUCCEEDED marker: $LOG" >&2
  exit 1
fi

if ! xcrun xcresulttool get test-results summary \
  --path "$RESULT_BUNDLE" --format json >"$NATIVE_SUMMARY"; then
  echo "unable to read native memory-sweep XCTest summary: $RESULT_BUNDLE" >&2
  exit 1
fi
printf '{"testMethods":1}\n' | python3 "${ROOT_DIR}/Scripts/validate-test-result.py" \
  --inventory /dev/stdin --summary "$NATIVE_SUMMARY" --max-skipped 0 \
  || { echo "native memory-sweep XCTest summary failed reconciliation: $NATIVE_SUMMARY" >&2; exit 1; }

python3 - "$LOG" "$ARTIFACT" <<'PY'
import json
import pathlib
import re
import sys

log = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
output = pathlib.Path(sys.argv[2])
pattern = re.compile(
    r"AppLocalVoice memory sweep turns=(?P<turns>\d+) "
    r"before=Optional\((?P<before>\d+)\) after=Optional\((?P<after>\d+)\)"
)
samples = [
    {
        "turns": int(match.group("turns")),
        "residentBytesBefore": int(match.group("before")),
        "residentBytesAfter": int(match.group("after")),
    }
    for match in pattern.finditer(log)
]
if [sample["turns"] for sample in samples] != [100, 1000, 10000]:
    raise SystemExit(f"expected 100/1000/10000 sweep samples, got {samples}")
document = {
    "schemaVersion": 1,
    "hardwareFree": True,
    "test": "MemorySweepTests.testResourceAndResidentMemorySweepAcrossTurnBudgets",
    "samples": samples,
}
output.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
print(f"validated memory sweep artifact: {output}")
PY

# Never publish the raw xcodebuild log; retain only its deterministic sanitized
# form under the stable artifact filename.
SANITIZED_LOG="${LOG}.sanitized"
python3 "${ROOT_DIR}/Scripts/sanitize-evidence-log.py" "$LOG" "$SANITIZED_LOG" >&2
mv "$SANITIZED_LOG" "$LOG"
