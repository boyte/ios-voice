## Summary

<!-- What behavior changes, and what failure mode does it address? -->

## Tests

- [ ] Deterministic tests added or updated
- [ ] `xcodebuild test -project Testing/AppLocalVoice.xcodeproj -scheme AppLocalVoiceTests -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -parallel-testing-enabled NO` passes, or the exact host limitation is documented
- [ ] strict `xcodebuild build-for-testing` passes for package changes
- [ ] Physical-device testing performed for audio changes

## Privacy and scope

- [ ] No microphone audio, transcript text, or TTS text was added to logs
- [ ] No networking, credentials, persistence, analytics, or provider SDK was added to the core package
- [ ] Documentation updated, if behavior or public API changed
- [ ] DocC catalog builds, if public API or operational behavior changed
- [ ] Compatibility contract/changelog updated, if public behavior changed

## Device notes

<!-- Include device, iOS version, route, locale, and interruption/route scenarios for audio changes. -->

## Evidence

<!-- Link deterministic tests, benchmark output, symbol-graph diffs, DocC output, or device reports. -->

- [ ] Tracker task IDs and evidence links are updated.
- [ ] If a gate cannot run here, the PR names the exact hardware or Git-remote
      dependency instead of marking it complete.
