# Basic speech-to-text

Use ``AppLocalVoice`` to capture one explicit speaking turn and receive a
final transcript. The host app owns the turn boundary; this keeps push-to-talk,
voice-activity, and interruption behavior predictable.

## Start and finish a turn

```swift
import AppLocalVoice

@MainActor
func readOneTurn() async throws -> String {
    let voice = AppLocalVoice()
    do {
        try await voice.startListening()
        let transcript = try await voice.finishListening()
        await voice.close()
        return transcript
    } catch {
        await voice.close()
        throw error
    }
}
```

Add `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription`
to the application target's `Info.plist`. The local iOS 26 path keeps voice
audio on-device and does not use the legacy server-recognition flow. Use
``AppLocalVoice/cancelListening()`` when the user discards a turn.

## Observe live text

Subscribe before starting capture so the first update cannot be missed:

```swift
@MainActor
func observeEvents() async {
    let voice = AppLocalVoice()
    let events = await voice.events()
    for await event in events {
        if case .transcript(let update) = event {
            print(update.text, update.isFinal)
        }
    }
    await voice.close()
}
```

Each ``TranscriptUpdate`` is a complete snapshot, not a text delta.
The event stream does not end merely because ``AppLocalVoice/close()`` is
called; cancel the consuming task when the voice surface disappears. The
service is closed after iteration exits.
