# Local Echo

Local Echo is the small reference app for AppLocalVoice. It records speech,
displays the transcript, and speaks the same text back. It has no chat
backend, account, API key, app integrations, or cloud speech service.

The example targets iOS 26 and demonstrates local Apple speech APIs in an
ordinary application target. It is not a keyboard extension and is not a
backend adapter. For an existing chat app, keep the app's current composer,
submit path, message store, and backend; use the host-owned session and queue
flow described in the [Quickstart](../../Documentation/Quickstart.md).

## Open the ready-made project

From the repository root, open `Examples/LocalEcho/LocalEcho.xcodeproj` in Xcode 26 or later. This checked-in Xcode project is the runnable integration; a separate SwiftPM executable is not needed because the example is an iOS application target. It already contains the three Swift source files, links the local `AppLocalVoice` package through the portable relative path `../../`, sets the deployment target to iOS 26, and includes the required privacy configuration. The reference UI includes Listen, End, Cancel, Speak, Pause, Resume, and Stop controls, plus on-device model readiness and enhanced-voice guidance.

Select the `LocalEcho` scheme, choose an iOS 26 simulator or a connected iPhone/iPad, and press Run. A simulator can verify the UI and package integration; microphone capture and on-device speech behavior require a real device.

## Try the Kokoro voice (device only)

Local Echo also demonstrates the `SpeechSynthesizer` plug-in contract. The
`LocalEchoKokoro/` folder is a one-file local package that enables the
repository's `Kokoro` package trait and re-exports the engine; the app links
it and decides at launch which engine to construct.

To hear Kokoro instead of Apple's synthesizer:

1. Run Local Echo on a physical iPhone or iPad with an Apple GPU (MLX does
   not run on the simulator; the simulator always uses Apple's voice).
2. Copy `kokoro-v1_0.safetensors` and `voices.npz` into the app's Documents
   folder — via the Files app, AirDrop, or Finder file sharing (the app
   declares `UIFileSharingEnabled`). The files are not part of this
   repository; the [KokoroTestApp](https://github.com/mlalma/KokoroTestApp)
   repository carries both under `Resources/` (Git LFS, about 330 MB).
3. Relaunch the app. The "Speech engine" line shows `Kokoro · af_heart` and
   Speak now uses the Kokoro voice. Set a different voice name from
   `voices.npz` with the `KokoroVoice` user default if you want another
   speaker. Remove the files and relaunch to return to Apple's voice.

The first Speak after a cold launch waits for the model to finish loading;
`prepare()` starts at launch to hide most of that cost.

You can also build it from the repository root:

```sh
xcodebuild \
  -project Examples/LocalEcho/LocalEcho.xcodeproj \
  -scheme LocalEcho \
  -destination 'generic/platform=iOS' \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO \
  build
```

The project has no external package dependencies. Its only package dependency is the checked-out repository itself, so the example remains importable after the repository is moved to another directory or cloned elsewhere.

## Build the example into another app

If you are using Local Echo as a reference rather than running the project, copy the three Swift files in this directory into an iOS 26 app target and add the repository root as a local Swift package. Keep the app’s package product dependency named `AppLocalVoice`.

Add this key to the app’s `Info.plist`:

```xml
<key>NSMicrophoneUsageDescription</key>
<string>Local Echo uses the microphone to transcribe your speech.</string>
```

Also add `NSSpeechRecognitionUsageDescription` with a clear explanation of how
the app uses recognized speech. The provider uses local
`SpeechAnalyzer`/`SpeechTranscriber` and keeps voice audio on-device. Apple's
current SpeechAnalyzer authorization behavior is still a physical-device gate,
so this key remains in the sample until that supported-device evidence permits
the package guidance to be narrowed.

The ready-made project’s [Info.plist](Info.plist) is the canonical configuration for this example. The sample uses `allowModelInstallation` when Listen is pressed so a supported device can prepare the local recognition model; the package still reports when the locale or device cannot provide on-device recognition.

The same walkthrough is available in the package’s [DocC Local Echo guide](../../Documentation/AppLocalVoice.docc/LocalEcho.md).

## Adapt the example to an existing app

Local Echo keeps its UI intentionally small and uses one identified recognition
session plus the canonical event stream. A chat host should keep one app-scoped
`AppLocalVoice`, subscribe once with
`voiceEvents()`, and use `startSession(configuration:)` for click-to-speak:

- apply newer `TranscriptPreview.text` values to the existing composer;
- call `finishSession(id:)` on release and copy the returned final text into the
  editable draft;
- let the host own editing, submit, backend calls, persistence, and discard;
- call `cancelSession(id:)` and restore the pre-voice composer snapshot on
  discard;
- enqueue selected returned text with `enqueueSpeech(_:)`, map the returned
  `SpeechItemID` to the host message ID, and use `replaySpeech(itemID:)` for a
  replay button;
- use `pauseSpeechQueue()`, `resumeSpeechQueue()`, and `stopSpeechQueue()` for
  playback controls.

Cancel the `voiceEvents()` observation task before calling `close()`. If it
returns `.blocked`, keep the voice surface in recovery and offer an explicit
retry before starting another operation. No host backend or Botnoy type is
passed into AppLocalVoice.
