# On-device speech

AppLocalVoice uses Apple `SpeechAnalyzer` and `SpeechTranscriber` for recognition and `AVSpeechSynthesizer` for synthesis.

## Privacy boundary

## Authorization evidence and current implementation boundary

The package's recognition provider is `SpeechAnalyzer`/`SpeechTranscriber`,
not an `SFSpeechRecognizer` recognition task. Apple's current authorization
guide says that SpeechAnalyzer transcriber modules do not send the user's voice
audio to Apple's servers, while its `SFSpeechRecognizer` authorization steps
apply to server-recognition APIs. The guide also retains general Speech
framework `NSSpeechRecognitionUsageDescription` guidance, so the package must
not infer the shipped local-only prompt behavior from prose alone.

The iOS 26 provider now treats local `SpeechAnalyzer` authorization as already
available and requests only microphone permission before capture. Its legacy
`SFSpeechRecognizer` authorization fallback is guarded for pre-iOS-26
execution and is not used on the package's supported deployment target.
REC-01 still requires a supported iOS 26 physical-device check using the exact
package build to establish the actual Info.plist and prompt behavior, including
whether the speech privacy key is required when no `SFSpeechRecognizer` task is
created. Until that evidence exists, package guidance retains the key and does
not claim that it is optional for every supported device/OS combination.

The decision record must cite Apple's current
[speech-recognition authorization guide](https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition)
and [SpeechAnalyzer documentation](https://developer.apple.com/documentation/speech/speechanalyzer), plus the physical-device report. No cloud-recognition fallback is permitted regardless of the eventual authorization result.

The package contains no networking code and never sends microphone audio to a service. A host app may send the returned text wherever it chooses; that is outside AppLocalVoice’s control and scope.

Apple speech assets may need to be installed. `.installedModelsOnly` fails clearly when an asset is missing. `.allowModelInstallation` permits Apple’s supported asset installation flow before capture begins; Apple may use network connectivity for that system-managed download, but AppLocalVoice never uploads microphone audio.

Explicit `prepareRecognition(policy:progress:)` exposes only content-free
checking, bounded/indeterminate download progress, and installed phases. The
host should keep cancellation available through the task. Progress reaching
100% is not readiness: both `downloading` and `supported` remain cancellable
finalization states until `AssetInventory` reports exact `installed`.
Provider installation errors preserve only NSError domain and numeric code;
authoritative module unavailability and caller cancellation remain distinct
typed failures. The host should offer retry and Apple’s Settings/storage
guidance. Capability queries are not cached by AppLocalVoice, so every call
reflects the provider’s current device state. See
<doc:ModelInstallation> for the complete preparation contract.

## Capability checks

Call `capabilities(for:)` before presenting a voice action when the host wants
to explain support proactively. `isSupported` means the locale is recognized by
`SpeechTranscriber`; `supportsOnDevice` additionally requires a device that can
run the transcriber and a ready local asset. The returned `locale` is Apple's
resolved locale, which may be a same-language regional fallback. Distinguish
unsupported locales, unavailable hardware, missing models, and permission
denial rather than treating them as one generic failure.

## Voices

The host can inspect `availableVoices(for:)`. Enhanced and premium voices are
installed by the user in iOS Settings; an app cannot silently download them
through a supported public API. A host app should offer a Settings explanation
when only compact voices are available.

## Limitations

Availability varies by iOS release, device, locale, and installed Apple assets. AppLocalVoice intentionally does not promise universal locale coverage or automatic cloud fallback.

Recognition has no hidden maximum-duration timer in 0.1. The host owns the
turn boundary and must call `finishListening()` or `cancelListening()`; the
bounded event buffer and 1,048,576-UTF-16 transcript ceiling prevent an
unbounded text accumulation if a host leaves a turn open or sends an oversized
request. A host that needs a maximum duration should cancel the task using its
own product policy.
