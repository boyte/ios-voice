# Testing

The test target is intentionally split between deterministic contract tests and physical-device validation.

## Deterministic tests

`Tests/AppLocalVoiceTests/DeterministicFailureHarnessTests.swift` uses actor-backed fakes to exercise permission failures (including restricted authorization), unsupported locales, model-installation failure and cancellation at the `SpeechInput` boundary, partial/final results, cancellation, stale callbacks, TTS cancellation, and idempotent close without hardware or a network. The fake covers the coordinator contract; Apple model download behavior remains device-only.

`FacadeContractTests.swift` exercises the injected public facade, including
empty-text no-op behavior, public event ordering, transient startup-failure
states, and interruption-before-finalization recovery. `RecoveryLifecycleAuditTests.swift` is the focused lifecycle audit. It sweeps
all injectable provider failures, retries each failed generation, verifies
interruption and route terminal outcomes, asserts exactly-once cleanup through
the resource ledger, and proves that a closed facade can be released without
leaving provider resources held. Run it with:

```sh
xcodebuild test -project Testing/AppLocalVoice.xcodeproj -scheme AppLocalVoiceTests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:AppLocalVoiceTests/RecoveryLifecycleAuditTests
```

The audit intentionally does not claim that an `AppLocalVoice` deinitializer
can perform asynchronous cleanup. Hosts should call `close()` before releasing
the facade; the deallocation assertion verifies that explicit close leaves no
retained lifecycle work or provider resource.

Every production bug should become a deterministic reproduction before it is fixed. Fakes should be able to delay results, fail startup, complete after cancellation, and simulate interruption or route-change events.

The state-machine suite also injects a provider that retains ownership after a
failed cleanup attempt. It verifies that the coordinator stays in `.failed`,
does not publish `.idle` or permit a new operation, emits one terminal outcome,
and becomes reusable only after a later `close()` reconciles the provider.

The release tooling is tested separately with only the Python standard library:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s Scripts/tests -p 'test_*.py' -v
```

These tests cover fail-closed artifact manifests, reproducible timestamps and
hashes, API graph fingerprints and compatibility reports, and semantic-version
source archives with relocatable checksums. A green package test run without a
green script suite is not sufficient release evidence.

CI also reconciles the generated XCTest inventory by exact class-qualified test
identity, not only by total count. The native `xcresulttool` test-details JSON
must contain the same unique `TestClass.testMethod` set as
`Documentation/TestInventory.json`; the one permitted SDK skip is checked by
identity and documented reason. A count match with a substituted test is not
accepted.

`AudioBufferConverterTests.swift` uses in-memory `AVAudioPCMBuffer` values to
cover the converter's same-format fast path, Apple-provided sample-rate and
channel conversion, timestamp/order preservation, empty-buffer rejection, and
idempotent end-of-stream flushing. The tests assert that a tail, when the
Apple converter produces one, is emitted once and never duplicated by a second
flush.

`AudioEngineSafetyTests.swift` exercises the internal engine-safety seam with
a recording fake. It proves tap installation, preparation, start, and removal
are distinct fail-closed operations and verifies notification mapping plus
malformed hardware-format rejection. It does not simulate Objective-C
exceptions, AVAudioEngine internals, audio-daemon behavior, or a physical
route; those remain device-only validation requirements.

The test target deliberately does not attempt to fabricate an
`AVAudioEngine` input tap, a hardware route, or a malformed `AVAudioPCMBuffer`
by bypassing Apple's invariants. `AVAudioFormat` may construct zero-rate and
zero-channel descriptor objects instead of returning `nil`; the converter
therefore validates those descriptors at its own boundary. Physical input
format negotiation, converter
behavior for a particular microphone route, and audio-daemon failures remain
device-only evidence and belong in the device matrix below.

## Bounded fuzz/property campaign

`DeterministicFuzzTests.swift` is a deterministic, time-bounded fuzz-style
campaign. It exercises locale identifiers, malformed speech configurations,
Unicode and chunk limits, duplicate provider notifications, transcript timing,
and terminal event ordering without requiring a microphone, network, or Apple
speech model. It uses the checked-in `DeterministicRandom` generator and has
hard upper bounds on every case and step loop.

The default campaign runs 24 seeds, 24 value cases per seed, and 32 lifecycle
steps per seed. Environment variables may select a reproducer, but are always
clamped by the test:

```sh
APPLOCALVOICE_FUZZ_SEED=42 \\
APPLOCALVOICE_FUZZ_CASES=1 \\
APPLOCALVOICE_FUZZ_STEPS=32 \\
xcodebuild test -project Testing/AppLocalVoice.xcodeproj -scheme AppLocalVoiceTests \\
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \\
  -only-testing:AppLocalVoiceTests/DeterministicFuzzTests
```

`APPLOCALVOICE_FUZZ_SEED` accepts decimal or `0x` hexadecimal. Cases are
bounded to 1–64 and lifecycle steps to 1–64; the event collector has a fixed
64-event bound and stops at the terminal idle event. The XCTest/xcodebuild
watchdog supplies the wall-clock bound. A failure must include its seed in the
XCTest output so the exact run can be replayed. The campaign asserts totality
and independent invariants, not a particular Foundation locale normalization or
provider timing. The chunk property uses generated inputs whose individual
Unicode characters fit within the generated limit, so its maximum-size
assertion cannot pass merely because an oversized character exists.

The seeded race suite records operation errors instead of discarding them. It
requires only the documented `invalidState`/`cancelled` race outcomes, exactly
one listening or speech terminal event, and a balanced deterministic resource
ledger. Model-startup cancellation, media-services reset mapping, and host
audio coexistence rejection are deterministic harness contracts; they are not
physical validation of Apple's runtime behavior.

## Device matrix

Before a release candidate, test at least one current and one older supported iPhone with the built-in route, AirPods, and a wired headset. Include music playback, phone calls, Siri, notification/alarm interruptions, foreground/background transitions, missing models, denied permissions, rapid restart, long transcripts, long TTS, and 30-minute repeated turns.

Record latency, errors, crashes, duplicated/stale events, memory growth, and audio-session leaks. Device results are evidence, not a substitute for deterministic tests.

## Running locally

On a Mac with the iOS 26 SDK installed:

```sh
xcrun simctl shutdown all || true
xcrun simctl boot 'iPhone 17 Pro'
xcrun simctl bootstatus 'iPhone 17 Pro' -b
xcodebuild test -project Testing/AppLocalVoice.xcodeproj -scheme AppLocalVoiceTests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -destination-timeout 120 \
  -parallel-testing-enabled NO \
  -maximum-parallel-testing-workers 1 \
  -resultBundlePath "$TMPDIR/AppLocalVoice.xcresult" 2>&1 | tee "$TMPDIR/AppLocalVoice.xcodebuild.log"
xcrun simctl shutdown 'iPhone 17 Pro'
```

The CI workflow follows the same ownership protocol: one workflow run per
ref, one simulator-test job after the package build, a clean erase/boot, one
XCTest worker, a 30-minute job bound, and an always-run diagnostics/upload
path. These controls do not repair Xcode or CoreSimulator; they make a worker
materialization stall bounded and diagnosable instead of leaving an ambiguous
runner behind.

When investigating a stall, preserve the uploaded `.xcresult`, the
`xcodebuild` log, the simulator list, and the recent CoreSimulator log. The
meaningful distinction is whether the stall occurs before test discovery,
while workers materialize, during a test, or during result collection.

If the repository is opened in Xcode without a generated scheme, use the package’s test action from the Swift Package project navigator.
