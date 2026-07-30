# Standalone AppLocalVoice support decision

Status: **approved for implementation**  
Owner/task: E0-T06  
Decision date: 2026-07-11
Approved by: package maintainer (implementation gate)

## Recommendation

Ship standalone AppLocalVoice as an iOS 26-only Swift package for ordinary
iPhone and iPad applications, built with Xcode 26.x, Swift tools 6.2, the Swift
6 language mode, and the iOS 26 SDK. Treat locale, on-device recognition-model,
and installed speech-voice availability as runtime capabilities rather than a
static compatibility list. Require physical-device evidence before making
production audio claims.

Ordinary iOS apps are in scope. **Custom keyboard extensions are out of scope.**
This is a support boundary only: it does not create extension implementation,
entitlement, packaging, example, CI, or test work.

The detailed contract is [SupportMatrix.md](SupportMatrix.md).

## Why this is the current-code decision

1. `Package.swift` already requires iOS 26, Swift tools 6.2, and Swift 6.
   Recognition directly references the new Speech framework types, so lowering
   the deployment target would require a different provider or pervasive
   availability isolation; it would not be a documentation-only correction.
2. The Apple input provider uses `SpeechTranscriber.isAvailable`,
   `supportedLocale(equivalentTo:)`, `installedLocales`, and `AssetInventory`.
   Support therefore cannot honestly be expressed as a permanent list of
   devices or locales. The public `VoiceCapabilitySnapshot` and typed errors
   model the correct runtime boundary.
3. Synthesis enumerates installed `AVSpeechSynthesisVoice` values. Exact locale
   matches precede same-language fallbacks, quality preference is deterministic,
   and absent or mismatched voices fail instead of silently switching language.
   Apple, not the package, controls which voices are present.
4. Input and output both participate in application lifecycle and the
   process-wide `AVAudioSession`. The code imports UIKit and observes
   `UIApplication.didEnterBackgroundNotification`; CI and Local Echo exercise
   an ordinary application host. There is no app-extension-safe build or
   keyboard lifecycle/audio contract to support.
5. CI pins Xcode 26.0 and iOS 26.0 simulator destinations. The recorded local
   replay on Xcode 26.5.1 and iOS 26.5 broadens point-release evidence, but all
   hardware-dependent behavior remains explicitly unverified until the device
   matrix is complete.

## Exact implementation implications after approval

Approval of this decision should result in the following bounded follow-up. No
item below is implemented by this documentation task.

- Keep `Package.swift` at iOS 26, Swift tools 6.2, and Swift 6. Do not add a
  legacy recognizer or lower the deployment target without a separate design
  and support decision.
- Keep CI's minimum lane pinned to Xcode 26.0 / iOS 26.0. Validate the latest
  supported Xcode 26.x and iOS 26.x point release for release evidence. Do not
  imply support for a future Xcode or iOS major version solely because it
  compiles.
- Align README, compatibility, quickstart, and release text with the matrix:
  ordinary iOS app targets only; iPhone and iPad; simulator for deterministic
  evidence; physical hardware for audio claims; no background-recording promise.
- Preserve runtime capability checks. Do not hard-code a locale, device, model,
  or voice allowlist. Continue returning Apple's resolved recognition locale
  and handling capability changes at operation start.
- Preserve `.installedModelsOnly` as the safe default and
  `.allowModelInstallation` as explicit host opt-in. Do not add cloud fallback,
  package-managed asset downloads, or installation-progress promises.
- Preserve deterministic installed-voice selection and failure on a missing or
  wrong-language explicit voice. Keep Personal Voice outside the core until a
  separately reviewed authorization and consent design exists.
- Do not add `APPLICATION_EXTENSION_API_ONLY`, a keyboard target, extension
  entitlements, extension examples, or extension-specific public API/tests.
  A future extension request must begin with a separate feasibility and privacy
  decision rather than being treated as a bug in this package.
- Once the iOS 26 floor is approved, remove or document as intentionally
  unreachable the legacy pre-iOS-26 speech-authorization branch in a separate
  Swift change. That cleanup must receive normal API/behavior review even
  though it should not alter the supported runtime contract.
- Complete the physical matrix before release: current and older supported
  iPhone plus current iPad; built-in, Bluetooth/AirPods, and wired routes where
  available; permissions; installed/missing/interrupted model installation;
  compact/enhanced/premium/missing voice cases; interruptions, backgrounding,
  lock, media-services reset, endurance, and cleanup.

## Rejected alternatives

- **Lower the iOS deployment target while keeping the same implementation.**
  Rejected because the recognition provider directly depends on iOS 26 APIs.
- **Publish a static supported-locale or supported-voice list.** Rejected
  because Apple's resolved locales, assets, device capability, and installed
  voice catalog are live and may change between devices and OS point releases.
- **Call simulator success full device support.** Rejected because the
  simulator does not prove microphone routes, framework assets, interruptions,
  audible synthesis, energy, thermal behavior, or cleanup against the audio
  daemon.
- **Include custom keyboard extensions in the initial support promise.**
  Rejected because current lifecycle, audio-session ownership, package
  validation, and examples are application-host assumptions. Extension support
  would be a separate product and privacy decision, not incidental compatibility.
