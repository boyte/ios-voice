# ``AppLocalVoice``

Add on-device speech input and speech output to an iPhone or iPad app without
adding a speech cloud service.

AppLocalVoice has one job:

```text
speech → text
text → speech
```

The host app owns chat, agents, endpoints, persistence, credentials, and UI.

## First voice turn

```swift
import AppLocalVoice

@MainActor
func runVoiceTurn() async throws {
    let voice = AppLocalVoice()
    do {
        try await voice.startListening()
        let text = try await voice.finishListening()
        try await voice.speak(text)
        await voice.close()
    } catch {
        await voice.close()
        throw error
    }
}
```

Add `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription`
to the host app's `Info.plist`. The local iOS 26 `SpeechAnalyzer` path keeps
voice audio on-device and does not use the legacy server-recognition flow.

## Topics

### Guides

- <doc:BasicSpeechToText>
- <doc:BasicTextToSpeech>
- <doc:LocalEcho>
- <doc:ModelInstallation>
- <doc:RecoveryGuide>

### Main facade

- ``AppLocalVoice``
- ``VoiceState``
- ``VoiceEvent``
- ``VoiceTerminationReason``
- ``VoiceError``
- ``VoiceErrorCategory``

### Recognition

- ``RecognitionConfiguration``
- ``SpeechModelPolicy``
- ``TranscriptUpdate``
- ``SpeechCapabilities``

### Synthesis

- ``SpeechConfiguration``
- ``SpeechVoice``
- ``SpeechVoiceQuality``

Recognition and synthesis requests are bounded at 1,048,576 UTF-16 code units.
Oversized text fails closed with the textTooLong error category before the
provider retains or speaks it.

## Scope boundary

The default package has no networking, chat client, agent protocol, persistence,
analytics, or third-party runtime dependency. A host may send the returned text
to any endpoint and pass the response text to ``AppLocalVoice/speak(_:configuration:)``.

Read the repository's [compatibility contract](../Compatibility.md),
[state machine](../StateMachine.md), [privacy boundary](../Privacy.md), and
[recovery guide](../Recovery.md) before shipping a voice surface. Providers
remain internal test seams; privacy-safe lifecycle diagnostics are available
only when the host explicitly supplies a `VoiceDiagnosticsSink`.

The complete symbol-by-symbol contract is indexed in the repository's
[Public API contract](../PublicAPI.md). The package intentionally does not expose
a `transcribe()` convenience method: the host must define the end of a user
turn so cancellation, interruption, and push-to-talk behavior remain
deterministic.

For a failed active listening turn with successful cleanup, consumers receive
`failure`, then `listeningFinished(.failed(...))`, `stateChanged(.failed)`,
and finally `stateChanged(.idle)`. If provider cleanup also fails, cleanup
remains observable through the failure and the eventual public state remains
`.failed` until a later `close()` succeeds.
