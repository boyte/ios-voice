# Contract decisions

This is the semantic authority for the public package. The checked symbol
inventory is in [PublicAPI.md](PublicAPI.md); this document explains the
decisions behind it.

| Decision | Rule |
| --- | --- |
| Host boundary | The package owns Apple speech, audio lifecycle, recovery, and bounded delivery. The host owns UI, draft text, messages, persistence, backend traffic, and the submit/speak decision. |
| Service ownership | One app-owned `AppLocalVoice` is injected into consumers. A child view may stop observing, but cannot close or take over shared work. |
| Recognition | A session ID is assigned at admission. PTT release awaits `finishSession(id:)`; a preview is never a final transcript or a submit action. |
| Readiness | Capability snapshots are side-effect-free. Permission/model preparation is explicit and never opens capture or acquires the audio lease. |
| Playback | Queue acceptance and playback completion are distinct. Each playback has an identity and one typed terminal outcome. Immediate playback is separate from queue history. |
| Audio | Recognition and synthesis never overlap. The library treats `AVAudioSession` as process-wide host state and does not restore stale configuration. |
| Recovery | Event delivery can fail explicitly. The host reconciles with `runtimeSnapshot()` and uses `recoveryState`; blocked cleanup requires an explicit retry. |
| Privacy | The library retains no host transcript, TTS text, audio, credentials, voice/device names, or provider text in diagnostics. |

## Integration rules

Subscribe to `voiceEvents()` before starting a recognition turn. Filter events
by the active session or playback identity. Preview events are advisory and may
coalesce; `FinalTranscript` and terminal playback results are authoritative.

Use `capabilitySnapshot(for:)` for UI readiness, and call
`prepareRecognition(for:policy:progress:)` only at a user-meaningful point.
After a blocked `close()`, do not start new audio work until a later close
reports `.released`.

Queue and event buffers are deliberately bounded. A host that wants chat
history or retryable text keeps it in its own storage.

## Change policy

No compatibility adapter or alias is added without a documented adoption need.
Before 1.0, a simplifying breaking change is preferable to two co-equal ways
to perform the same lifecycle action. Public changes require source docs, a
regenerated API baseline, a changelog entry, and focused regression coverage.
