## Summary

<!-- What behavior changes, and what failure mode does it address? -->

## Checklist

- [ ] Deterministic tests added or updated for the behavior change
- [ ] `xcodebuild test -project Testing/AppLocalVoice.xcodeproj -scheme AppLocalVoiceTests -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -parallel-testing-enabled NO` passes locally
- [ ] No microphone audio, transcript text, or TTS text was added to logs or diagnostics
- [ ] No networking, credentials, persistence, analytics, or provider SDK was added to the core package
- [ ] Public API changes: baseline regenerated, `Documentation/PublicAPI.md` and `CHANGELOG.md` updated
- [ ] Audio/lifecycle changes: physical-device observations listed below

## Device notes

<!-- Device, iOS version, route, locale, and interruption/route scenarios for audio changes. Leave blank for non-audio changes. -->
