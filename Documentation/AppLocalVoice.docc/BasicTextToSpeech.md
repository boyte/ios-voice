# Text to speech

Pass text to AppLocalVoice only after the host has decided it should be spoken.
Use the queue for message playback and `speakImmediately` for one-off local
prompts.

```swift
let accepted = try await voice.enqueueSpeech(replyText)
let result = try await voice.waitForSpeechPlayback(id: accepted.playbackID)
```

Queue controls affect queued playback only. `pauseSpeechQueue`,
`resumeSpeechQueue`, `skipSpeechQueue`, and `stopSpeechQueue` are safe to bind
to host controls. Use `replaySpeech(itemID:)` when the host has retained the
associated item identity.

## Speaking through a different engine

Apple's `AVSpeechSynthesizer` is the default. To use another on-device voice,
pass any ``SpeechSynthesizer`` at construction:

```swift
let voice = AppLocalVoice(synthesizer: engine)
```

Everything else is unchanged: the queue, playback identities, events, pause
and resume, barge-in, interruptions, and progress behave the same for every
engine. The engine only turns one bounded chunk of text into
``SynthesizedSpeech`` samples; AppLocalVoice synthesizes the first chunk
before acquiring the audio session, then plays each chunk while the next one
is synthesized, and publishes progress as the exact UTF-16 range of each
completed chunk. An engine is host-owned so the host can call `prepare()`
early and `unload()` on memory pressure. Engines never touch `AVAudioSession`
and never log the text they receive.
