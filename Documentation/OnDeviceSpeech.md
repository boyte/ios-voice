# On-device speech

AppLocalVoice uses Apple `SpeechAnalyzer` and `SpeechTranscriber` for
recognition, plus `AVSpeechSynthesizer` for output. The package has no cloud
recognition fallback and no network client.

## Permissions and local models

Add `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription`
to the host app. Use `capabilitySnapshot(for:)` to inspect permission, locale,
model, and voice readiness without starting audio.

If a supported locale needs a model, offer a user-initiated
`prepareRecognition(for:policy:)` action with `.allowModelInstallation`.
Preparation can request Apple’s system-managed local model installation, but
it never starts capture. A successful preflight is temporary; routes,
permissions, storage, and installed assets may change before a session starts.

## Voices

Use `availableVoices(for:)` to inspect installed voices. The package chooses
the best matching installed voice for the requested locale and configuration.
It cannot silently install enhanced or premium iOS voices. Direct users to
Settings when the app needs a voice that is not installed.

Availability depends on device, locale, iOS version, and installed Apple
assets. Test the permission and model flow on the physical devices your app
supports.
