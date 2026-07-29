# Basic text-to-speech

Use ``AppLocalVoice/speak(_:configuration:)`` to speak text with an installed
Apple voice. The call completes after playback finishes.

## Speak text

```swift
import Foundation
import AppLocalVoice

@MainActor
func say(_ text: String) async throws {
    let voice = AppLocalVoice()
    let configuration = SpeechConfiguration(locale: Locale(identifier: "en-US"))
    do {
        try await voice.speak(text, configuration: configuration)
        await voice.close()
    } catch {
        await voice.close()
        throw error
    }
}
```

Long text is split into bounded utterances. Use
``AppLocalVoice/stopSpeaking()`` to cancel playback, or
``AppLocalVoice/pauseSpeaking()`` and ``AppLocalVoice/resumeSpeaking()`` for
temporary control.

One synthesis request may contain at most 1,048,576 UTF-16 code units. Larger
requests fail before audio resources are acquired with the textTooLong error;
hosts should normally apply a smaller response or sentence policy.

## Choose an installed voice

Voice availability depends on the device and locale. The default policy prefers
the best installed voice (Premium, then Enhanced, then Compact):

```swift
@MainActor
func sayWithBestInstalledVoice(_ text: String) async throws {
    let voice = AppLocalVoice()
    let locale = Locale(identifier: "en-US")
    let voices = await voice.availableVoices(for: locale)
    let best = voices.first
    let configuration = SpeechConfiguration(
        locale: locale,
        voiceIdentifier: best?.id
    )
    do {
        try await voice.speak(text, configuration: configuration)
        await voice.close()
    } catch {
        await voice.close()
        throw error
    }
}
```

If no enhanced or premium voice is available, direct the user to Settings → Accessibility
→ Read & Speak → Voices. AppLocalVoice can select installed voices but cannot
silently download Apple system voices.
