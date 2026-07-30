# Quickstart

Use AppLocalVoice as one app-owned service. The package manages local Apple
speech and audio-session cleanup. The host keeps the composer, messages,
backend, persistence, and submit action.

## 1. Configure the host app

Add these keys to the host app's `Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>This app uses the microphone to turn speech into editable text.</string>
<key>NSSpeechRecognitionUsageDescription</key>
<string>This app recognizes speech on this device so you can compose by voice.</string>
```

## 2. Keep one service at the composition root

SwiftUI keeps the controller at the app root; UIKit can keep the same pair in
an app or scene coordinator.

```swift
@main
struct ChatApp: App {
    @State private var voice = ChatVoiceController(voice: AppLocalVoice())

    var body: some Scene {
        WindowGroup { ChatView(voice: voice) }
    }
}
```

Child views receive the existing controller or service. They may cancel their
own event-observation task, but they do not call `close()` on shared work.

## 3. Start, preview, and finish a turn

Start one session when the user presses a voice button. Finish that same
session when the user releases it. Copy the final text into the host draft,
then let the existing submit button handle it.

```swift
@MainActor
final class ChatVoiceController {
    let voice: AppLocalVoice
    var composerText = ""

    private var sessionID: RecognitionSessionID?
    private var previewRevision: UInt64 = 0

    init(voice: AppLocalVoice) {
        self.voice = voice
    }

    func observe() async {
        let events = await voice.voiceEvents()
        do {
            for try await event in events {
                guard case .recognition(let recognition) = event,
                      recognition.sessionID == sessionID,
                      case .transcript(.preview(let preview)) = recognition.kind,
                      preview.revision > previewRevision else { continue }
                previewRevision = preview.revision
                composerText = preview.text
            }
        } catch {
            // Reconcile UI with await voice.runtimeSnapshot().
        }
    }

    func begin() async throws {
        let accepted = try await voice.startSession()
        sessionID = accepted.sessionID
        previewRevision = 0
    }

    func finish() async throws {
        guard let sessionID else { return }
        composerText = try await voice.finishSession(id: sessionID).text
        self.sessionID = nil
    }

    func cancel() async {
        if let sessionID { await voice.cancelSession(id: sessionID) }
        self.sessionID = nil
    }
}
```

`TranscriptPreview` is a replacement for the voice-owned draft range, not a
delta. Do not submit a preview or final transcript automatically.

## 4. Check readiness when it helps the user

```swift
let locale = Locale(identifier: "en-US")
let snapshot = await voice.capabilitySnapshot(for: locale)

if case .notInstalled(installationAvailable: true) = snapshot.recognition.modelReadiness {
    try await voice.prepareRecognition(for: locale, policy: .allowModelInstallation)
}
```

Capability checks do not start audio. Preparation is optional and explicit; it
can request permission or a system-managed local model installation, but it
does not create a session.

## 5. Speak text your app selected

```swift
let accepted = try await voice.enqueueSpeech(replyText)
let result = try await voice.waitForSpeechPlayback(id: accepted.playbackID)
```

Use `enqueueSpeech` for replies with replay/history and `speakImmediately` for
a one-off prompt. Queue acceptance is not completion. Use terminal queue
events or `waitForSpeechPlayback(id:)` for the result.

## 6. Retire the service explicitly

Cancel the event task, then call `close()` from the app or scene owner. A
`.blocked` result means cleanup needs another explicit attempt. Keep voice
controls disabled until `recoveryState` is ready.

For edge cases, read [Recovery](Recovery.md), [Audio lifecycle](AudioLifecycle.md),
and [On-device speech](OnDeviceSpeech.md).
