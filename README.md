# AppLocalVoice

Local Apple speech-to-text and text-to-speech for iOS 26 apps.

AppLocalVoice adds two things to an existing app:

- a push-to-talk recognition session that returns editable text; and
- immediate or queued speech playback for text your app chooses to speak.

It does not provide chat UI, a keyboard extension, networking, message storage,
analytics, or a backend. Your app owns its composer, messages, and submit
action.

> Early access: `0.1.0` is public and useful for experimentation, but it is
> not device-qualified. Please report reproducible, privacy-safe bugs through
> the [issue tracker](https://github.com/boyte/ios-voice/issues/new?template=bug_report.md).

## Requirements

- iOS 26 or later
- Xcode 26 or later, Swift 6.2
- `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription`
  in the host app's `Info.plist`

The package uses Apple’s local speech APIs. It has no network client, account
system, analytics SDK, or credential storage. A host can explicitly permit
Apple to install a missing local recognition model.

## Install

Add the package in Xcode with this URL:

```text
https://github.com/boyte/ios-voice.git
```

Or add it to `Package.swift`:

```swift
.package(url: "https://github.com/boyte/ios-voice.git", from: "0.1.0")
```

Add `AppLocalVoice` to the target's dependencies. For unreleased work, use a
local package dependency instead.

## Add push-to-talk

Create one service at the app or scene composition root. Pass it to the model
or controller that owns the chat composer. Do not create a service per view or
button; audio sessions are process-wide.

```swift
import AppLocalVoice

@MainActor
final class ChatVoiceController {
    let voice: AppLocalVoice
    var composerText = ""

    private var sessionID: RecognitionSessionID?
    private var draftBeforeVoice = ""

    init(voice: AppLocalVoice) {
        self.voice = voice
    }

    func beginVoiceTurn() async {
        draftBeforeVoice = composerText
        do {
            let accepted = try await voice.startSession()
            sessionID = accepted.sessionID
        } catch {
            // Keep the draft and show the host app's error UI.
        }
    }

    func finishVoiceTurn() async {
        guard let sessionID else { return }
        do {
            composerText = try await voice.finishSession(id: sessionID).text
            self.sessionID = nil
        } catch {
            // Keep the draft and offer retry or discard.
        }
    }

    func cancelVoiceTurn() async {
        if let sessionID { await voice.cancelSession(id: sessionID) }
        self.sessionID = nil
        composerText = draftBeforeVoice
    }
}
```

Subscribe to `voiceEvents()` before a turn if the host wants live previews.
Filter recognition events by the current `RecognitionSessionID`, and apply a
newer preview to the host-owned draft. A final transcript is never an implicit
submit. The host decides whether and when to send `composerText` to a backend.

## Speak text

Use the queue for replies that should have replay/history. Keep the returned
`SpeechItemID` beside the host message ID.

```swift
let accepted = try await voice.enqueueSpeech(replyText)
let result = try await voice.waitForSpeechPlayback(id: accepted.playbackID)
```

Use `speakImmediately` for a one-off prompt that needs no queue history:

```swift
let accepted = try await voice.speakImmediately("Voice mode is ready.")
let result = try await voice.waitForSpeechPlayback(id: accepted.playbackID)
```

Queue acceptance is not playback completion. Use `waitForSpeechPlayback(id:)`
or terminal `voiceEvents()` queue events for the outcome. Playback progress is
advisory UTF-16 text-range data for optional highlighting.

## Prepare recognition

Capability checks are side-effect-free. They do not prompt, install a model,
or open the microphone.

```swift
let locale = Locale(identifier: "en-US")
let snapshot = await voice.capabilitySnapshot(for: locale)

if case .notInstalled(installationAvailable: true) = snapshot.recognition.modelReadiness {
    try await voice.prepareRecognition(for: locale, policy: .allowModelInstallation)
}
```

Call preparation from a user-meaningful action, such as enabling voice in
settings. A successful preflight is not a guarantee that a later session will
start; permissions, routes, and installed assets can change.

## Lifecycle

Use `recoveryState` to decide whether new audio work is available. If an event
stream fails, call `runtimeSnapshot()` and reconcile host controls. On app or
scene retirement, cancel observers and then call `close()` on the service owner.
If it returns `.blocked`, keep voice controls disabled and retry cleanup; do
not create another service to work around a blocked audio lease.

## Reference app and guides

- [Quickstart](Documentation/Quickstart.md): complete chat wiring
- [Local Echo](Examples/LocalEcho/README.md): a small iOS reference app
- [On-device speech](Documentation/OnDeviceSpeech.md): permissions, models, and voices
- [Recovery](Documentation/Recovery.md): typed failures and host actions
- [Audio lifecycle](Documentation/AudioLifecycle.md): audio-session behavior
- [Public API](Documentation/PublicAPI.md): generated API inventory
- [DocC speech-to-text](Documentation/AppLocalVoice.docc/BasicSpeechToText.md),
  [speech output](Documentation/AppLocalVoice.docc/BasicTextToSpeech.md),
  [model preparation](Documentation/AppLocalVoice.docc/ModelInstallation.md),
  and [recovery](Documentation/AppLocalVoice.docc/RecoveryGuide.md)

## Validation and support

Simulator builds and deterministic tests do not validate routes, interruptions,
AirPods, external audio, model availability, or endurance. Test those on the
devices your app supports before making production claims.

When reporting a bug, include the package version, iOS/Xcode version, device
class, locale/model state, audio route, lifecycle sequence, and typed error or
recovery state. Do not include recordings, transcript or TTS text, credentials,
raw crash dumps, or unredacted logs. See [SUPPORT.md](SUPPORT.md).

## Contributing

Issues and focused proposals are welcome. The maintainer does not merge outside
pull requests directly; a pull request can still be useful as a minimal
reproduction or proposed fix. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

See [LICENSE](LICENSE).
