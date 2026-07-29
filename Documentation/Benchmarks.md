# Performance and memory benchmarks

Performance claims are device and OS specific. Do not publish a single latency
number as a universal guarantee.

## Required measurements

Record median, p95, and maximum for:

- time from `startListening` to first partial transcript;
- time from `finishListening` to final text;
- time from `speak` to first audible output;
- teardown time after cancellation;
- model capability lookup;
- long-text TTS chunk transitions.

Record peak resident memory and memory growth for 100, 1,000, and 10,000
simulated turns, plus a 30-minute physical-device session. Also record CPU and
energy when Instruments is available.

## Checked-in hardware-free campaign

`Tests/AppLocalVoiceTests/BenchmarkTests.swift` emits five bounded proxy
measurements:

- startup/teardown through the deterministic provider boundary;
- repeated capture turns with one final transcript;
- Unicode-safe TTS chunk transitions;
- a slow consumer receiving 256 partials before consuming the bounded stream;
- microphone and speech resource acquisition/release counts.

Each measurement runs one warm-up, five samples, and a fixed iteration count.
The artifact reports median, p95, maximum, before/after resident memory, peak
resident memory when available, and resource counts. These are regression
signals, not universal latency or memory promises. The suite uses no microphone,
SpeechAnalyzer model, AVAudioSession, network, or audible output.

Run it locally with:

```sh
Scripts/run-benchmarks.sh
```

The script writes a canonical JSON artifact, an `.xcresult` bundle, and an
xcodebuild log to `.build/benchmark-artifacts` (or to the directory passed as
its first argument). The JSON has sorted keys, a trailing newline, and omits
the run timestamp so metadata-only reruns do not create diffs. It contains no
absolute paths or device claims, and is suitable for moving between machines
or attaching to CI. It must not be copied into a release report as device
performance evidence.

The runner selects, erases, and boots an available iPhone Simulator, then shuts
it down on exit. Build products are kept in an output-adjacent derived-data
directory rather than in the default per-user location. It never requires a
connected iPhone or iPad; “hardware-free” means
that all speech and audio providers are deterministic fakes or pure functions.

The XCTest result also contains native `XCTClockMetric` and `XCTMemoryMetric`
measurements for the chunk-transition proxy. Native metrics are useful for
Xcode trend inspection; the JSON artifact is the reproducible cross-run record.

The lifecycle memory sweep runs 100, 1,000, and 10,000 start/cancel turns with
the deterministic provider. It records resident-memory before and after each
budget and fails on any resource-ledger imbalance:

```sh
xcodebuild test -project Testing/AppLocalVoice.xcodeproj -scheme AppLocalVoiceTests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO \
  -maximum-parallel-testing-workers 1 \
  -only-testing:AppLocalVoiceTests/MemorySweepTests \
  -resultBundlePath "$PWD/Documentation/evidence/memory-sweep.xcresult" \
  CODE_SIGNING_ALLOWED=NO
```

The sweep is a leak/regression signal for the coordinator and test providers;
it is not a claim about physical-device RSS, thermal behavior, or energy use.
For a machine-readable record, run `Scripts/run-memory-sweep.sh`; it writes the
JSON artifact, result bundle, and log to `.build/memory-sweep-artifacts` (or the
directory passed as its first argument).

CI uploads the benchmark JSON, result bundle, and log as benchmark regression
artifacts, plus a separate text/JSON coverage report from the simulator test
result. Neither upload is hardware evidence.

Hardware-only metrics remain separate: real microphone startup/finalization,
audible-output latency, voice downloads, route changes, CPU, energy, thermal
behavior, and 30-minute memory stability require the device matrix and must be
marked `deviceOnly: true` in any report.

## Method

Use fixed locale, route, model state, text fixtures, device, OS build, and
toolchain. Warm-up runs must be reported separately. Simulator numbers are
useful for regression detection but do not represent microphone, Bluetooth,
voice-download, energy, or thermal behavior.

Every benchmark artifact must state whether it used real audio or a deterministic
fake. A benchmark is not a release gate until its budget, variance, and device
configuration are recorded in the release report.

## Initial budgets

The finite retention and cleanup values are fixed in
[ResourceBudgets.md](ResourceBudgets.md). They are safety ceilings, not
universal latency or resident-memory promises. CI must enforce deterministic
resource balancing and fixed retention semantics, then flag rather than silently
accept measured memory growth against the checked-in baseline.
