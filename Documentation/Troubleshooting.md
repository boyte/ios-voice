# Troubleshooting

## “Microphone permission is required”

Add `NSMicrophoneUsageDescription` to the host app’s `Info.plist`, then request listening from a user action. The package does not request permissions during unrelated onboarding.

## “Speech recognition permission is required”

Include `NSSpeechRecognitionUsageDescription` for every host app that uses this
package's Speech framework integration. The iOS 26 local path keeps audio
on-device and does not use the legacy server-recognition authorization flow;
this error is retained for compatibility with injected and legacy providers.

## On-device recognition is unavailable

Check the requested locale with `capabilities(for:)`. If the locale is supported but the model is missing, either install it in the host app’s preparation flow or use `.allowModelInstallation` when starting a turn.

## Audio starts and immediately fails

Stop other audio and retry. If the problem follows AirPods or a wired headset, treat it as a route change and restart capture explicitly. Capture should never be automatically restarted in a loop.

## Enhanced voices sound unavailable

Open Settings → Accessibility → Read & Speak → Voices and install an Enhanced Quality voice for the desired language. AppLocalVoice can select installed voices but cannot silently download Apple system voices.

## Debugging a device-only failure

Record the device model, iOS version, locale, installed-model state, audio route, permission state, operation, and whether an interruption or route change occurred. Do not include microphone audio, transcript text, or TTS text in issue reports.
