# Recover from interruptions and failures

Voice operations own shared audio resources. When an operation fails or the
system interrupts audio, AppLocalVoice releases those resources and returns to
a state where the host can retry explicitly.

## Handle a turn

```swift
@MainActor
func handleTurn() async {
    let voice = AppLocalVoice()
    do {
        try await voice.startListening()
        let text = try await voice.finishListening()
        try await voice.speak(text)
        await voice.close()
    } catch let error as VoiceError {
        await voice.close()
        switch error {
        case .cancelled:
            break
        case .microphonePermissionDenied, .speechPermissionDenied:
            print("Show permission instructions.")
        case .interrupted(_):
            print("The turn ended; show an explicit retry control.")
        default:
            print("Show a retry control.")
        }
    } catch {
        await voice.close()
        print("Show a retry control.")
    }
}
```

Do not automatically restart after a phone call, Siri, route change,
application backgrounding, or other interruption. A synchronous interruption
reported while starting or finishing
a turn is thrown as ``VoiceError/interrupted(_:)``. An asynchronous interruption
can terminate the active turn and publish an interruption terminal event before
the host calls ``AppLocalVoice/finishListening()``; in that case, a later finish call can
report ``VoiceError/invalidState(_:)`` because the turn has already ended. In both
cases, show a retry affordance and begin a new explicit turn only after the
user chooses it. Match ``VoiceError`` cases or ``VoiceError/category`` rather
than localized error strings.

## Always close the service

Call ``AppLocalVoice/close()`` when the voice surface disappears or the host
no longer needs it. `close()` is idempotent and cancels active capture or
playback. It returns `true` only after every owned resource is released;
`false` means cleanup remains pending and the host must retry before starting
another operation. Use a cancellation-safe cleanup path, such as the
`do`/`catch` pattern above, so cleanup is awaited on both success and failure.
For the full state and recovery contract, see the repository's
[recovery guide](../Recovery.md) and [state machine](../StateMachine.md).
