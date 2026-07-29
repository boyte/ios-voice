# Changelog

All notable changes to AppLocalVoice are documented here.

## Unreleased

### Corrective release work

- Track CI, documentation, governance, and privacy corrections for the next
  patch release. Physical-device qualification remains separate release
  evidence and is not implied by this work.
- Fixed the hosted XCTest warning-policy conflict, allowed bounded cold-run
  benchmark setup time, and made simulator, benchmark, and memory evidence
  jobs independent of documentation linting.
- Added a tested first-tag release-validation bootstrap path; later releases
  continue to require a reachable prior semantic tag and public-API comparison.

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

### Known limitations

- Physical-device validation remains required for microphone routes, Bluetooth
  and wired audio, interruptions, model and voice availability, endurance,
  thermal/energy behavior, and crash/relaunch behavior.
- The initial `v0.1.0` release predates the corrective hosted-CI run. The
  `v0.1.1` candidate must pass the full hosted matrix and compare its public
  API with `v0.1.0` before publication, as described in
  [RELEASING.md](RELEASING.md).
