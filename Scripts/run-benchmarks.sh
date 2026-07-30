#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${1:-${ROOT_DIR}/.build/benchmark-artifacts}"
OUTPUT_DIR="$(mkdir -p "$OUTPUT_DIR" && cd "$OUTPUT_DIR" && pwd)"
RESULT_BUNDLE="${OUTPUT_DIR}/AppLocalVoice-benchmarks.xcresult"
ARTIFACT="${OUTPUT_DIR}/AppLocalVoice-benchmarks.json"
LOG="${OUTPUT_DIR}/AppLocalVoice-benchmarks.log"
NATIVE_SUMMARY="${OUTPUT_DIR}/AppLocalVoice-benchmarks-test-summary.json"
DERIVED_DATA="${OUTPUT_DIR}.derived-data"

# Usage: run-benchmarks.sh [output-directory]
#
# Publication is fail-closed: the selected XCTest must produce a non-empty
# canonical artifact, a non-empty .xcresult bundle, a native Passed summary
# for exactly one test with zero failures/skips/expected failures, and the
# xcodebuild TEST SUCCEEDED marker. The native summary is retained beside the
# artifact so reviewers can inspect the evidence used for reconciliation.

rm -rf "$RESULT_BUNDLE"
rm -rf "$DERIVED_DATA"

SIMULATOR_NAME="${APPLOCALVOICE_SIMULATOR_NAME:-iPhone 17 Pro}"
SIMULATOR_RUNTIME="${APPLOCALVOICE_SIMULATOR_RUNTIME:-iOS-26-0}"
# Hosted jobs have an isolated runner and do not need an erase before these
# deterministic proxy tests. Erase is opt-in for a deliberately clean local
# campaign because CoreSimulator erase can hang independently of the test.
ERASE_SIMULATOR="${APPLOCALVOICE_ERASE_SIMULATOR:-0}"
# Keep the benchmark identity stable. Override APPLOCALVOICE_SIMULATOR_RUNTIME
# only when deliberately changing the supported runtime; never silently
# substitute another phone or runtime.
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

case "$ERASE_SIMULATOR" in
  0) ;;
  1)
    xcrun simctl shutdown "$DEVICE_ID" >/dev/null 2>&1 || true
    xcrun simctl erase "$DEVICE_ID"
    ;;
  *) echo "APPLOCALVOICE_ERASE_SIMULATOR must be 0 or 1" >&2; exit 2 ;;
esac

# xcodebuild owns booting the selected destination. Asking simctl to boot it
# first adds an unbounded CoreSimulator call before xcodebuild's own
# destination-timeout can produce useful evidence on a hosted runner.

env APPLOCALVOICE_BENCHMARK_OUTPUT="$ARTIFACT" xcodebuild test \
  -project "$ROOT_DIR/Testing/AppLocalVoice.xcodeproj" \
  -scheme AppLocalVoiceTests \
  -destination "platform=iOS Simulator,id=$DEVICE_ID" \
  -destination-timeout 120 \
  -derivedDataPath "$DERIVED_DATA" \
  -only-testing:AppLocalVoiceTests/BenchmarkTests \
  -resultBundlePath "$RESULT_BUNDLE" \
  -parallel-testing-enabled NO \
  -maximum-parallel-testing-workers 1 \
  CODE_SIGNING_ALLOWED=NO 2>&1 | tee "$LOG"

# Do not publish a measurement without the durable XCTest evidence that
# produced it.  The JSON alone is not proof that the test target completed.
if [[ ! -d "$RESULT_BUNDLE" ]] || [[ -z "$(find "$RESULT_BUNDLE" -mindepth 1 -print -quit)" ]]; then
  echo "benchmark result bundle is missing or empty: $RESULT_BUNDLE" >&2
  exit 1
fi
if ! grep -q "TEST SUCCEEDED" "$LOG"; then
  echo "benchmark log has no xcodebuild TEST SUCCEEDED marker: $LOG" >&2
  exit 1
fi

if ! xcrun xcresulttool get test-results summary \
  --path "$RESULT_BUNDLE" --format json >"$NATIVE_SUMMARY"; then
  echo "unable to read native benchmark XCTest summary: $RESULT_BUNDLE" >&2
  exit 1
fi
printf '{"testMethods":2}\n' | python3 "${ROOT_DIR}/Scripts/validate-test-result.py" \
  --inventory /dev/stdin --summary "$NATIVE_SUMMARY" --max-skipped 0 \
  || { echo "native benchmark XCTest summary failed reconciliation: $NATIVE_SUMMARY" >&2; exit 1; }

if [[ ! -s "$ARTIFACT" ]]; then
  python3 - "$LOG" "$ARTIFACT" <<'PY'
import pathlib
import sys

log = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
output = pathlib.Path(sys.argv[2])
begin = "APPLOCALVOICE_BENCHMARK_JSON_BEGIN\n"
end = "\nAPPLOCALVOICE_BENCHMARK_JSON_END"
start = log.rfind(begin)
finish = log.rfind(end)
if start < 0 or finish <= start:
    raise SystemExit("benchmark artifact was not emitted by the simulator test")
output.write_text(log[start + len(begin):finish] + "\n", encoding="utf-8")
PY
fi
test -s "$ARTIFACT"
python3 - "$ARTIFACT" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
document = json.loads(path.read_text())
# The XCTest writer includes the current wall clock time. Remove it from the
# checked artifact so rerunning the same campaign does not create metadata-only
# diffs and the JSON can be moved between machines without a false timestamp.
document.pop("generatedAt", None)
path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
assert document["schemaVersion"] == 1
assert document["hardwareFree"] is True
assert len(document["measurements"]) == 5
for measurement in document["measurements"]:
    assert measurement["samples"] > 0
    assert measurement["iterations"] > 0
    assert measurement["medianNanoseconds"] <= measurement["p95Nanoseconds"] <= measurement["maxNanoseconds"]
    assert measurement["deviceOnly"] is False
print(f"validated canonical benchmark artifact: {path}")
PY

# Never publish the raw xcodebuild log. Keep the same stable filename after
# deterministic path/payload sanitization so downstream manifests remain easy
# to consume.
SANITIZED_LOG="${LOG}.sanitized"
python3 "${ROOT_DIR}/Scripts/sanitize-evidence-log.py" "$LOG" "$SANITIZED_LOG" >&2
mv "$SANITIZED_LOG" "$LOG"
