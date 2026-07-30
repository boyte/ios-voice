# AppLocalVoice

**Local Apple speech-to-text and text-to-speech for iOS chat interfaces.**

AppLocalVoice is a backend-agnostic Swift package for iOS 26+ that gives an
existing app a safe click-to-speak flow and reliable playback of selected text.
It owns Apple speech, audio-session coordination, lifecycle recovery, and a
bounded speech queue. Your app continues to own its UI, composer, messages,
networking, persistence, and the decision to send or speak text.

> **Project status:** AppLocalVoice is publicly available as a Swift package
> from [`boyte/ios-voice`](https://github.com/boyte/ios-voice), beginning with
> version `0.1.0`, and includes a runnable reference app. This is an early 0.x
> release. It is useful for early adopters, but it is not device-qualified.
> Please [report reproducible bugs](https://github.com/boyte/ios-voice/issues/new?template=bug_report.md), especially route, interruption, model, or endurance failures, without including audio or speech content.

## Scope boundary

### What AppLocalVoice does—and does not—do

Apple's speech frameworks are capable, but an app has to solve the surrounding
problems: one process-wide audio session, interrupted or lost routes, model
readiness, final-versus-partial transcript ownership, playback ordering, and
cleanup that can be proved complete. AppLocalVoice puts those mechanics behind
one small, host-owned service.

| AppLocalVoice handles | Your app handles |
| --- | --- |
| On-device Apple recognition and synthesis | Chat UI, composer, and message model |
| Recognition session identities and finalization | Whether a final transcript is submitted |
| Audio-session serialization and recovery state | Backend, streaming protocol, and credentials |
| Bounded TTS queue, priorities, replay, and progress | Persistence, analytics, and product policy |
| Capability checks, permissions, and opted-in model preparation | Privacy policy and user-facing error presentation |

It is deliberately **not** a chat framework, backend client, keyboard
extension, cloud transcription SDK, background recorder, or full-duplex voice
assistant.

## Requirements

- iOS 26 or later
- Xcode 26 or later and Swift 6.2
- `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription` in
  the host app's `Info.plist`
- A real iPhone or iPad for microphone, routing, interruption, external-audio,
  AirPods, and endurance validation

The default providers use Apple's local speech APIs. AppLocalVoice contains no
HTTP client, WebSocket client, analytics, account system, credential storage,
or AppLocalVoice server. A host may explicitly allow Apple to install a
missing local recognition model; that system-managed model download can use
network connectivity, while microphone audio remains local.

## Install

Add the package from GitHub, or use a local checkout while developing against
unreleased changes.

### Xcode application

1. Choose **File → Add Package Dependencies…**.
2. Enter `https://github.com/boyte/ios-voice.git`.
3. Select version `0.1.0` or later, subject to your compatibility policy.
4. Add the `AppLocalVoice` library product to your iOS app target.

### Swift package

In the host package's `Package.swift`:

```swift
.package(url: "https://github.com/boyte/ios-voice.git", from: "0.1.0")
```

Then add `"AppLocalVoice"` to the target's dependencies.

### Local checkout

For unreleased development, use Xcode's **Add Local…** option or point a host
package at the checkout:

```swift
.package(path: "../ios-voice")
```

### Privacy usage text

Add clear, app-specific explanations to the host application's `Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>This app uses the microphone to turn your speech into editable text.</string>
<key>NSSpeechRecognitionUsageDescription</key>
<string>This app recognizes speech on your device so you can compose messages by voice.</string>
```

The iOS 26 `SpeechAnalyzer` / `SpeechTranscriber` path is local, but the
speech-recognition usage key remains part of the supported-device configuration.

## Basic use

### Add voice to an existing chat composer

Create **one app-owned** `AppLocalVoice` instance and inject it into every
screen or feature that needs voice. Do not construct one service per view or
per button press: recognition, synthesis, and `AVAudioSession` are
process-wide resources. In SwiftUI, keep it in an app-scoped model or service
container; in UIKit, keep it in an app/scene coordinator, root controller, or
equivalent composition root. A child view or controller may cancel its own
observation task, but must not close, clear, or take over shared voice work.

The canonical chat API is the session API plus one `voiceEvents()` observer.
The host keeps the composer as the source of truth: previews replace its
voice-owned draft; the final transcript is copied into that draft; only the
host's existing submit action sends anything to a backend.

```swift
import AppLocalVoice

@MainActor
final class ChatVoiceController {
    let voice = AppLocalVoice()

    var composerText = ""                 // Host-owned UI state
    private var textBeforeVoice = ""
    private var activeSessionID: RecognitionSessionID?
    private var lastPreviewRevision: UInt64 = 0

    func observeVoiceEvents() async {
        let stream = await voice.voiceEvents()
        do {
            for try await event in stream {
                switch event {
                case .recognition(let recognition):
                    guard recognition.sessionID == activeSessionID else { continue }
                    if case .transcript(.preview(let preview)) = recognition.kind,
                       preview.revision > lastPreviewRevision {
                        lastPreviewRevision = preview.revision
                        composerText = preview.text
                    }
                case .speechQueue:
                    // Update host playback UI from acceptance and terminal events.
                    break
                case .speechProgress:
                    // Optional UTF-16 progress for text highlighting.
                    break
                case .recovery:
                    // Present a host retry/reconcile action; do not silently restart.
                    break
                case .snapshot:
                    // Reconcile UI when a new observer begins.
                    break
                }
            }
        } catch {
            // The stream reports a delivery gap explicitly. Fetch runtimeSnapshot()
            // and reconcile host UI before offering the next action.
        }
    }

    func pressToTalk() async {
        textBeforeVoice = composerText
        do {
            let acceptance = try await voice.startSession(
                configuration: .init(publicationPolicy: .previewAndFinal)
            )
            activeSessionID = acceptance.sessionID
            lastPreviewRevision = 0
        } catch {
            // Keep the existing draft and present the host's error UI.
        }
    }

    func releaseToFinish() async {
        guard let activeSessionID else { return }
        do {
            composerText = try await voice.finishSession(id: activeSessionID).text
            self.activeSessionID = nil
        } catch {
            // Keep the draft. The host decides whether to retry or discard it.
        }
    }

    func cancelVoiceTurn() async {
        if let activeSessionID { await voice.cancelSession(id: activeSessionID) }
        activeSessionID = nil
        composerText = textBeforeVoice
    }
}
```

Start the observation task before a voice turn. On **app/service shutdown**,
cancel observers before the app-owned service owner calls `close()`; ordinary
screens must not close the shared service. If `close()` reports `.blocked`,
keep voice controls disabled and offer an explicit retry; do not begin another
audio operation until cleanup reports `.released`. For active UI, use
`recoveryState == .ready` as the authority for whether new audio work can be
offered; `.idle` alone is not a readiness signal.

## Speak selected text or backend responses

The package never receives a backend client or message object. Once your app
has decided that text should be spoken, enqueue it and retain the returned item
identity next to your own message identity:

```swift
let acceptance = try await voice.enqueueSpeech(
    assistantReplyText,
    priority: .normal,
    policy: .append
)

let messageSpeechItemID = acceptance.itemID

// A replay retains the item identity and creates a new playback identity.
let replay = try await voice.replaySpeech(itemID: messageSpeechItemID)
let terminalResult = try await voice.waitForSpeechPlayback(id: replay.playbackID)
```

Queue acceptance is immediate; it is not proof that audio has finished. Consume
`.speechQueue` terminal events or await `waitForSpeechPlayback(id:)` for the
outcome. Use `pauseSpeechQueue()`, `resumeSpeechQueue()`,
`stopSpeechQueue()`, `skipSpeechQueue()`, and `clearPendingSpeechQueue()` for
host playback controls. `speechProgress` delivers advisory original-text
UTF-16 ranges for precise highlighting; it may be coalesced, so terminal queue
events remain authoritative.

For a one-off local prompt without replay history, use `speakImmediately`.

## Prepare local recognition deliberately

Capability checks are side-effect-free: they do not prompt, install a model,
open the microphone, acquire audio ownership, or create a session. Perform
preparation at a user-meaningful moment, such as enabling voice settings or
before the first press-to-talk action:

```swift
let locale = Locale(identifier: "en-US")
let readiness = await voice.capabilitySnapshot(for: locale)

if case .notInstalled(installationAvailable: true) = readiness.recognition.modelReadiness {
    try await voice.prepareRecognition(
        for: locale,
        policy: .allowModelInstallation
    )
}
```

By default, recognition uses only an installed model. Passing
`.allowModelInstallation` explicitly opts into Apple's model-install flow; it
still does not start capture. Availability is device-, locale-, and
OS-dependent, so handle a failed start even after a successful preflight.

| Readiness result | Host action |
| --- | --- |
| `.installed` | Enable press-to-talk; a later session can still fail if route or permission changes. |
| `.notInstalled(installationAvailable: true)` | Offer an explicit preparation action; do not start capture just to install. |
| `.notInstalled(installationAvailable: false)` or `.unavailable` | Keep voice input unavailable and explain the locale/device limitation. |
| permission denied/restricted | Direct the user to the host app’s relevant Settings guidance. |

## Choose a playback lane

| Intent | Call | Completion authority |
| --- | --- | --- |
| Speak a chat reply, retain replay/history | `enqueueSpeech` | `.speechQueue` terminal event or `waitForSpeechPlayback` |
| Speak one local prompt, do not retain it | `speakImmediately` | `waitForSpeechPlayback` |
| Drive controls or text highlighting | queue controls / `.speechProgress` | terminal outcome; progress is advisory and UTF-16 indexed |

Acceptance only means the library reserved a playback identity. It is not a
success result and it never implies that audio began. `speechProgress` may skip
intermediate values; use it only to render optional highlighting, never to
persist message state.

## API guide

| Need | Use |
| --- | --- |
| Chat push-to-talk | `startSession(configuration:)`, `finishSession(id:)`, `cancelSession(id:)` |
| Unified lifecycle observation | `voiceEvents()` and `runtimeSnapshot()` |
| Preview/final transcript behavior | `TranscriptPublicationPolicy` (`.previewAndFinal`, `.finalOnly`, or stable chunks) |
| Model and permission readiness | `capabilitySnapshot(for:)`, `prepareRecognition(for:policy:progress:)` |
| Queue, ordering, replay | `enqueueSpeech`, `replaySpeech`, queue controls, and `waitForSpeechPlayback` |
| One immediate utterance | `speakImmediately` |
| Safe retirement | cancel observer, then `close()` and retry if blocked |

The session APIs are preferred for a chat composer because PTT release awaits
the **finalized transcript**, rather than reading the latest partial preview.
No transcript event implies a submit, discard, network request, or chat action.

## Lifecycle and recovery model

```text
Host composer / message UI      Host backend and storage
           │                              │
           │ sessions, selected text      │ host-only submit / persistence
           ▼                              ▼
     AppLocalVoice ──────────────── no network boundary
           │
           ├─ local Apple speech recognition
           ├─ local Apple speech synthesis + bounded queue
           └─ serialized AVAudioSession ownership and recovery
```

- Treat `VoiceRecoveryState`, recovery events, and a blocked `close()` result
  as actionable host state. Do not loop retries or silently restart capture
  after interruptions, backgrounding, route loss, or delivery gaps.
- Recognition and speech are serialized so microphone and synthesizer audio
  ownership do not overlap.
- The queue, transcript/event buffers, and retained playback history are
  bounded. Retain your own message text and IDs; do not use the package as a
  message store.
- Completion carries typed outcomes. A queue item being accepted does not make
  it completed, and a preview does not make it final.

See [Audio lifecycle](Documentation/AudioLifecycle.md),
[recovery](Documentation/Recovery.md), and the [public API contract](Documentation/PublicAPI.md)
for the complete semantic contract.

## Reference application

[Local Echo](Examples/LocalEcho/README.md) is a small iOS 26 reference app
that records speech, displays the transcript, and speaks it back. It has no
chat backend or accounts. Open
`Examples/LocalEcho/LocalEcho.xcodeproj` in Xcode, choose an iOS 26 simulator
or connected device, and run the `LocalEcho` scheme. It uses a relative local
package dependency, so it remains usable when this checkout moves.

Local Echo demonstrates the same session and queue flow shown above.

## Build and verify this checkout

The package has a strict SwiftPM build, an Xcode test project, documentation
and public-API validators, plus the reference app's structural check. From the
repository root:

```sh
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
swift build --build-tests \
  --sdk "$SDK" \
  --triple arm64-apple-ios26.0-simulator \
  -Xcc -isysroot -Xcc "$SDK" \
  -Xswiftc -warnings-as-errors

python3 Scripts/validate-documentation.py
python3 -m unittest discover -s Scripts/tests -p 'test_*.py'
python3 Examples/LocalEcho/validate.py

xcodebuild -quiet \
  -project Testing/AppLocalVoice.xcodeproj \
  -scheme AppLocalVoiceTests \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' build
```

Simulator and current-inventory evidence are being reconciled in the active
release work graph, so this README intentionally does not publish a test count.
That work is not a replacement for the device matrix. See
[Testing](Documentation/Testing.md), [Device Matrix](Documentation/DeviceMatrix.md),
and [Release Checklist](Documentation/ReleaseChecklist.md) before a public
release. Do not mistake a README claim for release evidence.

## Privacy and security

AppLocalVoice does not log, persist, or export microphone audio, transcripts,
speech text, credentials, provider error descriptions, voice names, or device
names. Its optional diagnostics are bounded and content-free; do not use them
as application state.

Your app remains responsible for any text it sends to a backend, its own
analytics/logging, consent flows, retention policy, and backend security. Read
the [privacy boundary](Documentation/Privacy.md) and
[security policy](SECURITY.md) before shipping.

## Report a bug

Early reports make the package better. Include the package version, iOS/Xcode
versions, device class (never its identifier), locale/model readiness, audio
route, a content-free lifecycle sequence, and the typed error or recovery state.
Do not attach recordings, transcript/TTS text, credentials, raw crash dumps, or
unredacted logs. See [Support](SUPPORT.md) for the full privacy-safe checklist.

## Documentation

- [Quickstart](Documentation/Quickstart.md) — canonical chat wiring
- [Public API](Documentation/PublicAPI.md) — checked API inventory
- [Diagnostics](Documentation/Diagnostics.md) — safe observability contract
- [Troubleshooting](Documentation/Troubleshooting.md) — common integration and
  recovery failures
- [First open-source release](Documentation/FirstOpenSourceRelease.md) —
  first-tag and publication handoff
- [Speech-to-text](Documentation/AppLocalVoice.docc/BasicSpeechToText.md)
  and [text-to-speech](Documentation/AppLocalVoice.docc/BasicTextToSpeech.md)
  — focused canonical walkthroughs
- [Model installation](Documentation/AppLocalVoice.docc/ModelInstallation.md)
  and [recovery guide](Documentation/AppLocalVoice.docc/RecoveryGuide.md) —
  readiness and recovery details
- [Contributing guide](CONTRIBUTING.md) — issue and development expectations

## Contributing

> *About Contributions:* Please don't take this the wrong way, but I do not accept outside contributions for any of my projects. I simply don't have the mental bandwidth to review anything, and it's my name on the thing, so I'm responsible for any problems it causes; thus, the risk-reward is highly asymmetric from my perspective. I'd also have to worry about other "stakeholders," which seems unwise for tools I mostly make for myself for free. Feel free to submit issues, and even PRs if you want to illustrate a proposed fix, but know I won't merge them directly. Instead, I'll have Claude or Codex review submissions via `gh` and independently decide whether and how to address them. Bug reports in particular are welcome. Sorry if this offends, but I want to avoid wasted time and hurt feelings. I understand this isn't in sync with the prevailing open-source ethos that seeks community contributions, but it's the only way I can move at this velocity and keep my sanity.

## License

See [LICENSE](LICENSE).
