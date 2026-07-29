# Run the Local Echo example

Local Echo is the smallest complete app built with AppLocalVoice. It records
speech, displays the transcript, and speaks that transcript back without a
chat backend or cloud speech service.

## Open the project

Open `Examples/LocalEcho/LocalEcho.xcodeproj` in Xcode 26 or later. Select the
`LocalEcho` scheme, choose an iOS 26 simulator or connected device, and run.
The project links the repository package through a relative path, so it can be
moved or cloned without changing package settings.

Microphone capture and on-device recognition require a real iPhone or iPad.
The simulator is useful for checking project integration and UI behavior.

## Copy the integration

The reference implementation is in
[`Examples/LocalEcho`](../../Examples/LocalEcho). Copy its three Swift files
into an iOS 26 app target, add the repository as a local Swift package, and
add `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription`
to `Info.plist`. The iOS 26 local `SpeechAnalyzer`/`SpeechTranscriber` path
keeps voice audio on-device and does not use the legacy server-recognition flow.

The example intentionally leaves chat, agent, persistence, and endpoint
integration to the host app.
