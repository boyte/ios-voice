# Recovery and failure handling

AppLocalVoice treats audio hardware and Apple speech assets as temporary
resources. The host app should surface a retry affordance instead of silently
restarting a microphone session.

## Recovery table

| Condition | Observable result | Host action |
|---|---|---|
| microphone denied | `microphonePermissionDenied` | explain Settings and offer retry |
| speech permission denied | `speechPermissionDenied` | explain recognition permission |
| unsupported locale | `unsupportedLocale` | choose a supported locale |
| model absent in installed-only mode | `onDeviceRecognitionUnavailable` | install the model or use explicit installation policy |
| model installation failure | `onDeviceRecognitionUnavailable` | show retry and storage/network guidance from Apple |
| audio activation/start failure | `audioSessionUnavailable` | release other audio and retry |
| interruption or route loss | terminal failure/event | wait for the system event to end, then explicit retry |
| audio media services lost/reset | interrupted terminal failure/event | wait for the audio daemon to recover, then explicitly retry |
| application enters background | interrupted terminal failure/event | return to the foreground, then explicitly retry |
| analyzer failure | terminal failure/event | discard the generation and retry |
| TTS voice unavailable | `speechVoiceUnavailable` | select an installed voice or show voice settings |
| invalid TTS configuration | `invalidSpeechConfiguration` | correct rate, volume, or utterance limit |
| TTS delegate never completes | `speechSynthesisUnavailable` | stop the failed turn, show retry, and start a fresh request |

Apple's synthesizer is expected to deliver a delegate completion for every
utterance. As a last-resort recovery boundary, AppLocalVoice applies an
internal watchdog per utterance: 30 seconds minimum, scaled by text length and
rate, and capped at 300 seconds. The watchdog is not a latency guarantee and is
intentionally not configurable in the public API. It stops the synthesizer,
finishes the request with `speechSynthesisUnavailable`, releases the audio
lease, and suppresses late delegate callbacks. Cancellation and interruption
always win over the watchdog when they arrive first.

Recognition and synthesis also fail closed when one text request exceeds
1,048,576 UTF-16 code units. This textTooLong result is checked before TTS
chunking and during transcript assembly, and does not contain the rejected
speech text.

If the synthesizer rejects a stop request, AppLocalVoice retains the active
utterance and audio lease instead of reporting clean teardown. A later
queue stop controls or close() retries the stop boundary; resourcesAreReleased is
not considered true until the request is accepted and the lease is restored.

## Host retry rule

Never retry in a tight loop. A retry should be initiated by a user action or a
bounded app policy after the system interruption has ended. Before retrying,
inspect `state`, optionally call `capabilities(for:)`, and use a fresh
configuration when the route or locale changed.

## Deterministic lifecycle guarantees

The recovery contract is exercised without hardware by
`RecoveryLifecycleAuditTests.swift`. Run it with:

```sh
xcodebuild test -project Testing/AppLocalVoice.xcodeproj -scheme AppLocalVoiceTests \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -parallel-testing-enabled NO \
  -maximum-parallel-testing-workers 1 \
  -only-testing:AppLocalVoiceTests/RecoveryLifecycleAuditTests \
  CODE_SIGNING_ALLOWED=NO
```

The suite sweeps every injectable input
boundary—permission, authorization, capability, model, session activation,
analyzer, converter, and engine startup—and then starts a fresh turn after the
failure. It also covers finalization failure, synthesis failure, interruption,
route loss, repeated `close()`, and facade deallocation after close.

Ordinary terminal paths must satisfy the following invariants:

1. The public state returns to `.idle` after ordinary provider cleanup.
2. A resource acquired by a fake provider is released exactly once.
3. A listening generation emits no more than one `listeningFinished` event.
4. A subsequent operation can start after the failed generation is discarded
   and provider cleanup is confirmed.
5. Calling `close()` again is safe and retries unresolved microphone cleanup;
   the service does not claim `.idle` while a tap or analyzer remains owned.
   An active speaking operation is stopped once.

An unresolved provider cleanup is the explicit exception: the public state
remains `.failed`, no new operation is accepted, and a later `close()` must
reconcile the resource before `.idle` is emitted.

The tests deliberately assert recovery at the provider seam, not Apple
framework behavior. Real route acceptance, interruption timing, model
installation, and audio-daemon recovery remain physical-device evidence.

## Crash-safe boundary

The package protects known Objective-C audio-engine exception points, but no
Swift library can make process termination recoverable inside the same process.
Hosts should attach their crash reporter to record only privacy-safe context:
package version, OS/device, route class, state, operation identifier, timing,
and error category. Never attach raw audio, transcript text, TTS text, or
credentials.

The opt-in public diagnostic sink supplies the operation identifier, coarse route
class, state, monotonic timing, and stable error category for package tests and
adapter validation. It is an evidence seam, not a crash reporter; an
application's own crash reporter remains responsible for privacy-safe sampling
and retention. See [privacy-safe diagnostics](Diagnostics.md).
