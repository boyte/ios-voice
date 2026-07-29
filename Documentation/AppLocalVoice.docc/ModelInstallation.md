# Install an on-device speech model

Recognition can require an Apple speech model for the requested locale. The
model policy is explicit on ``RecognitionConfiguration`` so an app can choose
whether a missing model is an error or may be installed before capture.

## Require an existing model

Use the default policy for an immediate, local-only start:

```swift
@MainActor
func startWithInstalledModel() async throws {
    let voice = AppLocalVoice()
    let configuration = RecognitionConfiguration(
        locale: Locale(identifier: "en-US"),
        policy: .installedModelsOnly
    )
    do {
        try await voice.startListening(configuration: configuration)
    } catch {
        await voice.close()
        throw error
    }
    await voice.close()
}
```

If the model is unavailable, the call throws a typed ``VoiceError``. The host
can explain the requirement and offer a retry after the user installs the
asset.

## Permit installation

For a first-run experience, prepare explicitly and allow the system to install
the model. The optional progress handler runs on the main actor and carries
only content-free phases:

```swift
@MainActor
func prepareAndStart() async throws {
    let voice = AppLocalVoice()
    _ = try await voice.prepareRecognition(
        for: Locale(identifier: "en-US"),
        policy: .allowModelInstallation,
        progress: { phase in
            // Render checking, indeterminate/determinate download, or ready.
            render(phase)
        }
    )
    do {
        try await voice.startListening(configuration: .init(
            locale: Locale(identifier: "en-US"),
            policy: .installedModelsOnly
        ))
    } catch {
        await voice.close()
        throw error
    }
    await voice.close()
}
```

Installation may take time and can depend on device connectivity. It is still
used only to obtain Apple's local model; microphone audio is not sent to an
AppLocalVoice service. A system status of `downloading` remains an in-flight
state: preparation waits without imposing a wall-clock download timeout and
ends only when Apple reports installed, reports a genuine terminal state, or
the caller cancels. The wait retains one task and one latest progress sample
and polls at a fixed cadence. Download progress reaching 100% and
`downloadAndInstall()` returning do not prove readiness. After an owned request,
a joined download, or a nil request, both `downloading` and `supported` remain
cancellable nonterminal states until `AssetInventory` reports exact
`installed`; no elapsed-time threshold manufactures an installation failure.
An authoritative `unsupported` state maps to on-device unavailability.
AppLocalVoice does not provide cloud fallback.

If Apple throws a terminal installation error, the typed ``VoiceError`` keeps
only its provider domain and numeric code. Provider descriptions and `userInfo`
are discarded and never enter lifecycle diagnostics.

`RecognitionPreparationResult.installedModel` is true only when this call
owned a system installation request that succeeded and reconciled to installed.
It is false when preparation joined an existing download, found a model already
installed, or received a nil request and merely observed the eventual result.
