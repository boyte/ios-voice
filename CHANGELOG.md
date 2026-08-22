# Changelog

All notable changes to AppLocalVoice are documented here.

## Unreleased

### Completed local audio-file recognition

- Added `RecognitionInput.audioFile` for a completed local recording on iPhone
  and iPad. It uses the same identified session, locale/model readiness,
  transcript, cancellation, and finalization contracts as microphone input.
- File recognition is bounded by decoded duration and file size, and does not
  request microphone permission, install a microphone tap, or modify the
  process audio session. The host retains transfer, storage, submission, and
  deletion decisions.

### Canonical API cleanup (breaking under 1.0)

- Removed the pre-iOS-26 compatibility facade and aliases. New integrations use
  identified recognition sessions, `voiceEvents()`, explicit readiness, and
  identified immediate or queued playback.
- Rebuilt Local Echo and the public integration guides around the canonical
  app-owned service model. Added explicit early-access support and privacy-safe
  bug-report guidance; physical-device qualification remains unclaimed.

- The next release must use an appropriate pre-1.0 breaking-version increment
  and compare its public API with `v0.1.0` before publication.
  Physical-device qualification remains separate evidence.

### Public API reductions (breaking under 1.0)

- Removed `SpeechQueueCommand` (never produced or consumed by the package),
  `SpeechControlResult.noActivePlayback` and `.providerRejected` (never
  returned), and the single-case `VoiceBackgroundPolicy`,
  `VoiceInterruptionPolicy`, `VoiceRouteChangePolicy`, and
  `VoiceCleanupFailurePolicy` enums together with their never-read
  `AudioLifecyclePolicy` fields. `AudioLifecyclePolicy.init(externalAudio:)`
  is the remaining initializer; backgrounding, interruptions, route
  invalidation, and blocked cleanup keep their documented fixed behavior.
  Migration: delete the removed arguments from `AudioLifecyclePolicy(...)`
  calls and remove any `switch` arms over the deleted cases.

### Internal simplification

- Deleted the internal legacy lifecycle seam (`startListening`,
  `finishListening`, `cancelListening`, `speak`, `pauseSpeaking`,
  `resumeSpeaking`, `events()`, `recognitionEvents()`) and the parallel
  internal `VoiceEvent` plane. The identified session, playback, and
  `voiceEvents()` APIs are the only lifecycle surface; tests exercise them
  through a test-target adapter.
- Collapsed the provider seams to one requirement each
  (`SpeechInput.start(configuration:input:lifecyclePolicy:)`,
  `SpeechOutput.speak(_:configuration:lifecyclePolicy:)`,
  `AudioSessionDriver.configure(for:externalAudio:isOtherAudioPlaying:)`) and
  merged the internal `SpeechAuthorization` enum into `VoicePermissionStatus`.

### Tooling

- Removed the release-evidence manifest, test-inventory, evidence-log
  sanitizer, privacy-artifact scanner, crash-report and device-report
  validators, and the benchmark/memory-sweep CI jobs. None gated a shipped
  behavior. CI now validates the strict build, DocC, the public API baseline,
  documentation links, and (on release tags and manual runs) the simulator
  test suite.

## 0.1.0 — 2026-07-29

### Public API and integration

- Added the app-owned `AppLocalVoice` facade for local Apple speech recognition
  and text-to-speech in ordinary iPhone and iPad apps on iOS 26.
- Added canonical, typed recognition sessions with explicit start, finish, and
  cancel boundaries. A finalized transcript remains host-owned draft text; the
  package never submits it to a backend.
- Added a unified canonical event stream, recovery snapshots, explicit
  recognition preparation, and bounded, content-free diagnostics.
- Kept the package backend-neutral. Chat UI, keyboard UI, messages,
  persistence, endpoints, streaming protocols, credentials, and submit policy
  remain host responsibilities.

### Recognition and speech output

- Added side-effect-free capability checks and explicit, cancellable local
  model preparation. Apple model installation is opt-in and separate from
  microphone capture.
- Added transcript preview, stable-chunk, and final-transcript publication
  contracts with typed identities, bounded retention, UTF-16 accounting, and
  stale-callback protection.
- Added bounded text-to-speech chunking, a serialized queue, priorities,
  replacement policies, replayable item identities, per-attempt playback
  identities, and advisory UTF-16 playback progress.

### Reliability, lifecycle, and privacy

- Added process-aware audio-session ownership, conservative interruption,
  background, route-change, and cleanup-recovery semantics.
- Added deterministic coverage for cancellation, stale callbacks, queue/event
  overflow, bounded resources, audio-session reconciliation, and provider
  failure seams.
- Made diagnostics and typed failure surfaces content-free: they do not carry
  microphone audio, transcript text, TTS text, credentials, voice/device names,
  or arbitrary provider descriptions.

### Documentation and tooling

- Added the public API inventory, DocC guides, chat-adoption quickstart,
  lifecycle/recovery/privacy documentation, Local Echo reference app, release
  checklists, and privacy-safe evidence tooling.
- Added documentation for local SwiftPM use, source-release preparation, and
  the boundaries between simulator evidence, physical-device validation, and
  hosted-release requirements.
