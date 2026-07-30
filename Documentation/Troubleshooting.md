# Troubleshooting

## Recognition will not start

Call `capabilitySnapshot(for:)` and inspect permission, locale, and model
readiness separately. Add both microphone and speech-recognition usage text to
the host app. If a model is missing, offer explicit preparation with
`.allowModelInstallation`; do not start capture to install it.

## Audio fails after a route change or interruption

End the current host voice state and let the user try again. Do not restart
capture automatically. AirPods, wired headsets, calls, Siri, backgrounding, and
media-services resets all require a fresh operation.

## Playback does not complete

Queue acceptance is not completion. Wait for the accepted `SpeechPlaybackID`
with `waitForSpeechPlayback(id:)`, or handle its terminal queue event. Check
that the requested locale has an installed compatible voice.

## Cleanup remains blocked

Only the app-owned service owner should call `close()`. If it returns
`.blocked`, keep voice controls disabled and retry `close()` later. Do not
create another service instance to bypass unresolved audio cleanup.

## Reporting a device-only failure

Record the package version, iOS/Xcode version, device class, locale/model
state, audio route, lifecycle sequence, and typed failure. Do not include
recordings, transcript text, speech text, credentials, raw crash dumps, or
unredacted logs.
