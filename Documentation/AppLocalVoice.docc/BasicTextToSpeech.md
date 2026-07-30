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
