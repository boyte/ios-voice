# Model installation

Readiness checks do not prompt, install a model, open the microphone, or
create a recognition session.

```swift
let readiness = await voice.capabilitySnapshot(for: Locale(identifier: "en-US"))
if case .notInstalled(installationAvailable: true) = readiness.recognition.modelReadiness {
    try await voice.prepareRecognition(
        for: Locale(identifier: "en-US"),
        policy: .allowModelInstallation
    )
}
```

Preparation is an explicit user-meaningful action. A successful readiness
check is not a promise that a later session can start: permission, route, and
device state can still change.
