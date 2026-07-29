# AppLocalVoice support matrix

This matrix is the proposed support contract for standalone `AppLocalVoice`.
It records the current implementation boundary; it does not expand the public
API or change `Package.swift`. The decision and implementation consequences are
in [SupportDecision.md](SupportDecision.md).

## Supported product boundary

| Dimension | Supported contract | Evidence and qualification |
|---|---|---|
| host | Ordinary foreground-capable iOS applications | The package is a standalone Swift package with no third-party runtime dependency. “Standalone” means that it does not require another product or cloud speech service; it does not mean app-extension compatible. |
| app extensions | **Custom keyboard extensions are out of scope** | The implementation imports UIKit, observes `UIApplication` lifecycle notifications, requests microphone permission, and owns process-wide `AVAudioSession` leases. No extension-safe build, lifecycle, or audio validation exists. This decision creates no keyboard-extension implementation work. |
| operating system | iOS 26.0 and later within the iOS 26 release family | `Package.swift` declares `.iOS(.v26)`. Recognition directly uses iOS 26 `SpeechAnalyzer`, `SpeechTranscriber`, and `AssetInventory` APIs without a back-deployment implementation. A later major iOS release is not claimed until CI and physical-device validation are recorded. |
| platforms not claimed | macOS, Mac Catalyst, tvOS, watchOS, visionOS, and all app-extension products | The manifest exposes only iOS and the implementation uses iOS application/audio lifecycle APIs. |
| toolchain | Xcode 26.x with the Swift 6.2 toolchain and iOS 26 SDK; Swift 6 language mode | The manifest requires Swift tools 6.2 and declares Swift language mode 6. CI is pinned to Xcode 26.0 and the iOS 26.0 simulator runtime. Local evidence also records Xcode 26.5.1 / Swift 6.2 / iOS 26.5. New Xcode major versions require validation before being added to the contract. |
| device families | iPhone and iPad that run a supported iOS 26 release | Package compatibility does not guarantee that Apple's transcriber, locale asset, microphone route, or selected voice is available. Those are live capability checks. |
| simulator | Build, integration, UI, state-machine, and deterministic-provider testing | Simulator success is not evidence for microphone capture, model installation, audio routes, interruptions, voice catalogs, playback quality, energy, or thermal behavior. |
| physical devices | Required for production audio claims | Before release, validate a current iPhone, an older supported iPhone, and a current iPad using the scenarios in [DeviceMatrix.md](DeviceMatrix.md). An untested matrix cell remains unknown. |
| execution model | One serialized `AppLocalVoice` service per host-owned voice surface | Listening and speaking are not full duplex. The host provides the recognition turn boundary, cancels work when appropriate, and calls `close()` before discarding the service. |
| background behavior | No background recording or background speech promise | Entering the background terminates active Apple input/output work conservatively. Background modes are not part of the supported contract. |

## Locale, recognition model, and voice behavior

| Area | Supported behavior | Not promised |
|---|---|---|
| recognition locale | The host supplies a `Locale` (default: the value of `Locale.current` when configuration is created). AppLocalVoice asks `SpeechTranscriber.supportedLocale(equivalentTo:)`; Apple may resolve a same-language regional equivalent, which is returned by `capabilities(for:)`. | A fixed locale list, every regional variant, or identical availability across devices and iOS point releases. |
| recognition capability | `isSupported` means Apple can resolve the requested locale. `supportsOnDevice` means `SpeechTranscriber` is available and a matching model is currently installed. Hosts should query capability at runtime and handle typed startup errors even after a successful query. | Capability results remaining stable after an OS update, asset removal, storage change, or route/lifecycle transition. |
| recognition privacy | Captured audio is analyzed on device. The package contains no speech-network client and has no cloud recognition fallback. | Offline installation of an absent Apple asset. Apple may use the network for a system-managed asset download when the host explicitly allows installation. |
| default model policy | `.installedModelsOnly`; fail with `onDeviceRecognitionUnavailable` when the required asset is absent. | Silent installation or automatic fallback to cloud recognition. |
| opt-in model policy | `.allowModelInstallation` may request Apple's system-managed installation before capture. The host presents an indeterminate preparing state, supports cancellation, and handles download/storage failure. | Installation progress, guaranteed installation success, or a package-controlled download. |
| synthesis locale | The host supplies a `Locale` (again captured from `Locale.current` at configuration creation by default). Only installed voices whose language matches are candidates; exact locale/region matches rank ahead of same-language fallbacks. | Speaking with an unrelated current-locale or English voice when no requested-language voice exists. |
| automatic voice choice | For the default `.premium` preference: Premium, then Enhanced, then Compact within the best locale match, followed by deterministic name and identifier ordering. Other explicit quality preferences use their documented preference order. | A particular voice name or quality being installed on every device. |
| explicit voice choice | A supplied stable Apple voice identifier must exist and match the requested language or the request fails. | Treating display names as stable identifiers. |
| Personal Voice | Not selected automatically and rejected when requested explicitly by the current implementation. | Personal Voice authorization or consent UI. |
| voice installation | The package lists and selects installed voices. The host may direct users to Settings to install Enhanced or Premium voices. Compact voice operation remains valid. | Silently downloading Apple system voices from the app. |

## Current evidence status

| Gate | Current status |
|---|---|
| manifest, strict package/test compilation, clean-client import | Passing for arm64 iOS 26 simulator builds |
| deterministic XCTest suite | Checked by repository tooling and simulator CI; current inventory/result reconciliation remains open, so no count or device claim is published here. See [ReleaseAudit.md](ReleaseAudit.md). |
| DocC and repository documentation validation | Passing in the recorded local baseline and required by CI |
| Local Echo ordinary-app integration | Generic iOS build and project validator passing |
| physical iPhone/iPad audio matrix | Open release gate |
| model installation and installed voice catalogs on hardware | Open release gate |
| app-extension or custom-keyboard build/runtime validation | Not planned; out of scope |
