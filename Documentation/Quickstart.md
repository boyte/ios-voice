# Quickstart

AppLocalVoice is the local speech layer for an ordinary iPhone or iPad app on
iOS 26 and later. It turns microphone speech into transcript publications and
text into spoken audio. The host app keeps its existing chat composer, message
model, backend client, persistence, and submit button.

There is no keyboard extension requirement and no Botnoy-specific or backend
coupling in the package. AppLocalVoice receives speech configuration and text;
the host decides what that text means.

## Install

Add this repository as a Swift Package dependency and select the `AppLocalVoice`
product. Add the microphone usage description to the host application's
`Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>This app uses the microphone to turn speech into text.</string>
```

Also add `NSSpeechRecognitionUsageDescription` with a clear explanation of how
your app uses recognized speech. The iOS 26 local
`SpeechAnalyzer`/`SpeechTranscriber` path keeps voice audio on-device; it does
not use the legacy server-recognition authorization flow.

## Ordinary chat integration

Create one app-scoped `AppLocalVoice` service and one observation task for the
voice surface. Keep the existing composer as the source of truth for editable
text:

1. On the click-to-speak button, save the current composer text and call
   ``AppLocalVoice/startSession(configuration:)``.
2. Consume ``AppLocalVoice/voiceEvents()``. Apply each newer
   `TranscriptPreview.text` to the voice-owned composer range. A preview is a
   complete replacement, not a delta.
3. On button release or an explicit Done action, call
   ``AppLocalVoice/finishSession(id:)``. Copy the returned `FinalTranscript.text`
   into the composer, then let the user edit it normally.
4. On Cancel or Discard, call
   ``AppLocalVoice/cancelSession(id:)`` when a session is active and restore the
   saved composer text. AppLocalVoice does not own submit or discard.
5. When the user submits, send the current edited composer text through the
   existing backend callback. A transcript event is never an implicit submit.

The core session wiring looks like this. `composerText`,
`preVoiceComposerText`, and the error/recovery presentation are host state:

```swift
import AppLocalVoice

@MainActor
final class ChatVoiceController {
    let voice = AppLocalVoice()
    var composerText = ""
    private var preVoiceComposerText = ""
    private var activeSessionID: RecognitionSessionID?
    private var lastPreviewRevision: UInt64 = 0

    func observeVoiceEvents() async {
        let events = await voice.voiceEvents()
        do {
            for try await event in events {
                switch event {
                case .recognition(let event):
                    guard let activeSessionID,
                          event.sessionID == activeSessionID else { continue }
                    switch event.kind {
                    case .transcript(.preview(let preview)):
                        guard preview.revision > lastPreviewRevision else { continue }
                        lastPreviewRevision = preview.revision
                        composerText = preview.text
                    case .transcript(.finalTranscript(let final)):
                        composerText = final.text
                    case .accepted, .stateChanged, .transcript(.stableChunk), .outcome:
                        break
                    }
                case .speechQueue:
                    // Update host playback controls from queue events.
                    break
                case .recovery:
                    // Show or clear host recovery UI from recovery events.
                    break
                }
            }
        } catch {
            // A delivery gap is a host recovery condition; reconcile explicitly.
        }
    }

    func beginVoiceTurn() async {
        preVoiceComposerText = composerText
        do {
            let acceptance = try await voice.startSession(
                configuration: .init(publicationPolicy: .previewAndFinal)
            )
            activeSessionID = acceptance.sessionID
            lastPreviewRevision = 0
        } catch {
            // Keep the existing composer unchanged and present the error.
        }
    }

    func finishVoiceTurn() async {
        guard let activeSessionID else { return }
        do {
            let final = try await voice.finishSession(id: activeSessionID)
            composerText = final.text
            self.activeSessionID = nil
        } catch {
            // Keep the draft and present the host's retry/recovery action.
        }
    }

    func discardVoiceTurn() async {
        if let activeSessionID {
            await voice.cancelSession(id: activeSessionID)
        }
        self.activeSessionID = nil
        composerText = preVoiceComposerText
    }
}
```

The host may use `.finalOnly` for a command that does not need live composer
previews, or `.stableChunks(...)` for an append-only sink. Editable chat drafts
are ordinary host composer behavior built from `.previewAndFinal`.

## Speak returned text

After the host submits its edited composer text, it handles the backend response
and decides whether each returned message should be spoken. The backend is not
passed to AppLocalVoice:

```swift
let acceptance = try await voice.enqueueSpeech(
    returnedMessageText,
    priority: .normal,
    policy: .append
)

// Store acceptance.itemID beside the host message ID.
let speechItemID = acceptance.itemID
```

Acceptance is immediate and does not mean playback has finished. Observe
`.speechQueue` values from `voiceEvents()` for accepted, started, paused,
resumed, and terminal outcome events. Keep the host message usable even when
queue capacity, voice availability, or playback fails.

For a replay button, use the stored item identity. Replay keeps the
`SpeechItemID` and creates a new `SpeechPlaybackID`:

```swift
let replay = try await voice.replaySpeech(itemID: speechItemID)
```

The host owns whether to autoplay, which returned messages qualify, and how a
message maps to its `SpeechItemID`.

## Pause, resume, and stop

Use the queue controls for returned chat text:

```swift
_ = await voice.pauseSpeechQueue()
_ = await voice.resumeSpeechQueue()
let stopped = await voice.stopSpeechQueue()
```

Use `pauseSpeaking()`, `resumeSpeaking()`, and `stopSpeaking()` for one direct
``AppLocalVoice/speak(_:configuration:)`` request. The queue APIs are usually
the better fit for assistant messages because they support acceptance,
ordering, and replay.

## Close and recover explicitly

Cancel the event-observation task before retiring the voice surface. The
canonical `voiceEvents()` stream does not end merely because `close()` is
called. Then await cleanup:

```swift
observationTask.cancel()

if case .blocked = await voice.close() {
    // Keep voice controls disabled and offer an explicit retry-close action.
    showVoiceRecovery = true
}
```

Start another recognition or playback operation only after `close()` reports
`.released`. Interruption, backgrounding, route loss, and event-delivery gaps are
recoverable host states; do not silently restart capture. Let the user retry,
discard the partial draft, reconcile the event stream, or close again as
appropriate.

## Local-only model policy

The default recognition policy uses an installed Apple speech model. A host may
explicitly allow model installation before a click-to-speak turn:

```swift
let voice = AppLocalVoice()
try await voice.startListening(
    configuration: .init(policy: .allowModelInstallation)
)
await voice.cancelListening()
await voice.close()
```

Model installation is separate from recognition. AppLocalVoice does not upload
microphone audio and has no cloud fallback.

## Why there is no one-shot transcribe

Recognition has an explicit start and finish boundary because chat hosts need to
show previews, let the user edit or discard the draft, and decide when text is
submitted. The session APIs make those ownership boundaries visible. Hosts that
want a one-shot command can call `startSession`, wait for the final event, and
call `finishSession`; the package intentionally does not hide that lifecycle in
an API that could imply automatic submission.
