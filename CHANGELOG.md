# Changelog

All notable changes to AppLocalVoice are documented here.

This file describes the current source worktree. It is not a release history:
this checkout has no Git history, remote, tag, or published release from which
to reconstruct one. The first published version will receive a dated section
only after its tag, release evidence, and release notes are created.

## Unreleased

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

### Known limitations and release gates

- No AppLocalVoice version has been tagged or published yet, so no previous
  public API exists for a release-to-release compatibility comparison.
- Physical-device validation remains required for microphone routes, Bluetooth
  and wired audio, interruptions, model and voice availability, endurance,
  thermal/energy behavior, and crash/relaunch behavior.
- A Git host, canonical package URL, real CODEOWNERS identities, private
  vulnerability reporting, protected branches, required checks, first-tag
  validation, signing policy, and published artifacts remain outstanding.
- Test and public-symbol totals are intentionally omitted until the current
  generated inventories and native release evidence are reconciled.
