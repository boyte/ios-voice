# Voice quality

AppLocalVoice prefers the best installed Apple voice for the requested locale:
Premium, then Enhanced, then Compact. The requested locale is explicit on every
`SpeechConfiguration`; the default captures `Locale.current` when that
configuration is created for source compatibility. Synthesis does not read the
process-wide current locale later.

Selection is deterministic:

1. An explicitly requested voice identifier must exist and use the requested language.
2. An installed voice for the exact requested locale wins.
3. If the exact region is unavailable, another installed voice for the same language is used.
4. The requested quality (`compact`, `enhanced`, or `premium`) is resolved
   within the best locale match; the catalog preserves Apple's actual quality.
5. If no voice for the requested language is installed, synthesis fails with `speechVoiceUnavailable` rather than silently speaking in the current locale or English.

The package can inspect installed voices:

```swift
import AppLocalVoice

let voice = AppLocalVoice()
let locale = Locale(identifier: "vi-VN")
do {
    let voices = await voice.availableVoices(for: locale)
    let enhanced = voices.first { $0.quality == .enhanced }
    let playback = try await voice.speakImmediately(
        "Xin chào",
        configuration: SpeechConfiguration(
            locale: locale,
            voiceIdentifier: enhanced?.id
        )
    )
    _ = try await voice.waitForSpeechPlayback(id: playback.playbackID)
    await voice.close()
} catch {
    await voice.close()
    throw error
}
```

iOS does not provide a supported API for an app to silently download enhanced or
premium system voices. The host app should explain that users can install one
in **Settings → Accessibility → Read & Speak → Voices**. The package must
continue working with compact voices when higher-quality assets are unavailable.

Voice selection is local and does not require a provider account.

`SpeechConfiguration.maximumCharactersPerUtterance` accepts 128...32,000
UTF-16 code units. AppLocalVoice splits longer responses at sentence and word
boundaries; the upper bound keeps one Apple utterance and its recovery timer
bounded even when a host passes an unusually large configuration value.
