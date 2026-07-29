# Public API contract

This page defines the intentionally small public surface of AppLocalVoice.
The facade owns the Apple-native speech lifecycle; implementation classes and
provider protocols remain internal test seams. Privacy-safe diagnostics are an
opt-in public callback surface.

## Application facade

The application facade owns the lifecycle and is the only runtime service type
intended for ordinary host applications.

## Recommended integration

Use one `@MainActor AppLocalVoice` instance. The host owns the turn boundary:
call `startSession(configuration:)`, publish previews into the existing chat
composer, and submit the host's edited text through its own backend. Call
`enqueueSpeech(_:)` for returned assistant text, or `speak(_:)` when the host
wants to await one item. `voiceEvents()` is the canonical stream for recognition,
queue/playback, and recovery; `recognitionEvents()` and `events()` remain
compatibility projections. Call `close()` when the voice surface disappears.

## Advanced coordinator contracts

The coordinator rejects illegal operations before acquiring resources and
serializes terminal events. Its lifecycle rules are defined in the state
machine and compatibility documents.

## Public contract

A single recognition transcript or synthesis request is limited to 1,048,576
UTF-16 code units. Oversized text fails closed with the stable textTooLong
error category before the provider retains or speaks it.

- `AppLocalVoice` is the only runtime service type.
- Recognition and synthesis use Apple frameworks locally; the package has no
  network or third-party runtime dependency.
- `RecognitionConfiguration` controls locale and speech-model installation
  policy.
- `SpeechConfiguration` controls locale, voice, quality, rate, volume, and
  bounded utterance size. The per-utterance limit must be 128...32,000 UTF-16
  code units.
- `SpeechCapabilities` and `availableVoices(for:)` expose device-dependent
  availability without promising that every locale/model/voice exists.
- `recoveryState` is the authoritative snapshot for whether audio work is
  ready, being reconciled, or blocked; hosts should use its typed failure and
  recommended action to render recovery UI rather than infer readiness from
  lifecycle callbacks.
- `enqueueSpeech`, `replaySpeech`, `pauseSpeechQueue`, `resumeSpeechQueue`,
  `skipSpeechQueue`, `clearPendingSpeechQueue`, and `stopSpeechQueue` provide
  provider-neutral local playback controls; queue acceptance is separate from
  playback start and has bounded pending/history memory.
- `speakImmediately` accepts one non-replayable direct speech attempt and
  returns the same playback identity/result shape as queued work. Its item ID
  is correlation metadata only and cannot be passed to `replaySpeech`.
- `stopAndClearSpeechQueue()` cancels current playback and pending queue work
  with typed playback results, then leaves the queue suspended until the host
  explicitly resumes it.
- `voiceEvents()` delivers typed recognition, speech-queue, and process-recovery
  events with explicit subscriber-limit and durable-overflow errors.
- `VoiceEventStreamEvent.speechProgress(_:)` is a coalescible advisory event
  with a `SpeechPlaybackID` and an exact UTF-16 range in the original request.
  It contains no speech text; terminal playback results remain authoritative.
- `prepareRecognition(for:policy:progress:)` is the explicit permission/model-install
  boundary. It does not create a session, acquire audio, or open capture. Its
  defaulted progress callback carries content-free checking, downloading, and
  installed phases on the main actor. A system `.downloading` status remains
  in flight until installed, terminal provider state, or caller cancellation.
- Recognition sessions default to a 120-second capture limit after listening
  begins; use `nil` for no library limit. Expiry finalizes normally and emits
  `durationLimitReached` rather than a timeout failure.
- `VoiceEvent` contains state, transcript, speech, and terminal lifecycle
  snapshots. `TranscriptUpdate.text` is a complete snapshot, not a delta.
- Each event stream retains the newest eight events; at most eight active
  subscriptions are retained, and a ninth subscription finishes the oldest.
- `VoiceState` contains only actionable lifecycle states, including the
  transient `.preparing` startup state; interruption is
  represented by `VoiceTerminationReason.interrupted(_:)` with a typed
  `VoiceInterruptionReason`, rather than a stale
  long-lived state.
- `VoiceError` cases and `VoiceError.category` are stable machine-facing
  categories; associated strings are for display only. Recognition-model
  installation failures may retain only provider domain and numeric code;
  provider descriptions and userInfo never enter the public failure event.
- `diagnostics()` returns a bounded, content-free `VoiceDiagnosticsStream`;
  `VoiceDiagnosticsSink` is an optional callback adapter. Diagnostic records
  contain lifecycle metadata only; the host owns retention and export.
- `VoiceTerminationReason` is emitted exactly once per reserved listening turn.
- `speak("")` and whitespace-only text are intentional no-ops: they do not
  reserve an operation or emit speech lifecycle events.
- `close()` releases active resources and returns `.released` only after the
  provider has confirmed cleanup. `.blocked(VoiceFailure)` leaves cleanup
  unresolved; retry close before starting another operation. It does not finish existing
  `events()` streams. Consumers cancel stream iteration when their voice
  surface is discarded; the same service may be reused after a successful
  close.
- Event ordering and resource ownership are defined in
  [`StateMachine.md`](StateMachine.md) and [`Compatibility.md`](Compatibility.md).

### v1 lifecycle cleanup

The v1 public contract removes the four transitional lifecycle cases
`pauseSpeechAndStopListening`, `continueWhenPossible`,
`pauseSpeechAndRequireExplicitResume`, and
`retryOnceThenRequireExplicitRetry`. Hosts must use the remaining conservative
policies: stop on background, stop and require an explicit restart after a
route change, stop on interruption, and require an explicit cleanup retry.
These removals are intentional breaking lifecycle cleanup and are not v1
compatibility promises.

`VoiceState` and `VoiceEvent` are public enums and may gain cases in a future
release. Consumers should use `default` or `@unknown default` when switching
over them; exhaustive switches are intentionally coupled to the released case
set.

## Machine checking and release upgrades

`PublicAPISymbols.json` is generated from a production-only symbol graph. The
checked-in baseline and this document are validated together:

```sh
Scripts/emit-public-symbol-graph.sh \
  /tmp/AppLocalVoice-symbol-graphs \
  /tmp/AppLocalVoice-DerivedData
python3 Scripts/validate-public-api.py \
  --symbol-graph /tmp/AppLocalVoice-symbol-graphs/AppLocalVoice.symbols.json
```

The script deliberately avoids SwiftPM's test-visible `@testable` graph. Once
a tagged release exists, compare the candidate precise-symbol set with the
previous tag before updating the baseline. Public actor isolation,
`Sendable`, error categories, event ordering, and resource ownership are all
compatibility-sensitive.

## Value semantics

Public configuration and result values carry stable machine-facing fields;
display strings and device-dependent availability remain descriptive.

## Recognition values

Recognition returns complete transcript snapshots and preserves the host-owned
turn boundary; empty and unavailable results follow the compatibility contract.

## Synthesis values

Synthesis configuration makes locale, voice, quality, and bounded utterance
policy explicit.

## Deliberately not public

`VoiceCoordinator`, `AppleSpeechInput`, `AppleSpeechOutput`, `SpeechInput`,
`SpeechOutput`, and authorization helpers are internal.
They remain injectable through `@testable import` for deterministic tests. A
future provider integration should be a separately versioned adapter product,
not a permanent expansion of the default package surface.

## Generated API evidence

The guidance above is the human-facing API contract. The following precise
identifiers are generated evidence from a production-only symbol graph and are
checked by `Scripts/validate-public-api.py`. Keep this as one inventory section:
do not edit individual entries by hand or add parallel generated blocks. Update
the source API and regenerate the baseline and markers together.

<!-- api-symbol: s:13AppLocalVoice06SpeechC0V -->
- `SpeechVoice` (swift.struct)
<!-- api-symbol: s:13AppLocalVoice06SpeechC0V18languageIdentifierSSvp -->
- `languageIdentifier` (swift.property)
<!-- api-symbol: s:13AppLocalVoice06SpeechC0V2id4name18languageIdentifier7qualityACSS_S2SAA0dC7QualityOtcfc -->
- `init(id:name:languageIdentifier:quality:)` (swift.init)
<!-- api-symbol: s:13AppLocalVoice06SpeechC0V2idSSvp -->
- `id` (swift.property)
<!-- api-symbol: s:13AppLocalVoice06SpeechC0V4nameSSvp -->
- `name` (swift.property)
<!-- api-symbol: s:13AppLocalVoice06SpeechC0V7qualityAA0dC7QualityOvp -->
- `quality` (swift.property)
<!-- api-symbol: s:13AppLocalVoice06SpeechC7QualityO -->
- `SpeechVoiceQuality` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice06SpeechC7QualityO7compactyA2CmF -->
- `SpeechVoiceQuality.compact` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice06SpeechC7QualityO8enhancedyA2CmF -->
- `SpeechVoiceQuality.enhanced` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice06SpeechC7QualityO7premiumyA2CmF -->
- `SpeechVoiceQuality.premium` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO -->
- `VoiceErrorCategory` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO06speechC11UnavailableyA2CmF -->
- `VoiceErrorCategory.speechVoiceUnavailable` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO11textTooLongyA2CmF -->
- `VoiceErrorCategory.textTooLong` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO10underlyingyA2CmF -->
- `VoiceErrorCategory.underlying` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO11interruptedyA2CmF -->
- `VoiceErrorCategory.interrupted` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO12invalidStateyA2CmF -->
- `VoiceErrorCategory.invalidState` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO17unsupportedLocaleyA2CmF -->
- `VoiceErrorCategory.unsupportedLocale` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO22speechPermissionDeniedyA2CmF -->
- `VoiceErrorCategory.speechPermissionDenied` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO23audioSessionUnavailableyA2CmF -->
- `VoiceErrorCategory.audioSessionUnavailable` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO26invalidSpeechConfigurationyA2CmF -->
- `VoiceErrorCategory.invalidSpeechConfiguration` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO26microphonePermissionDeniedyA2CmF -->
- `VoiceErrorCategory.microphonePermissionDenied` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO26speechSynthesisUnavailableyA2CmF -->
- `VoiceErrorCategory.speechSynthesisUnavailable` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO30onDeviceRecognitionUnavailableyA2CmF -->
- `VoiceErrorCategory.onDeviceRecognitionUnavailable` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO9cancelledyA2CmF -->
- `VoiceErrorCategory.cancelled` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C17TerminationReasonO -->
- `VoiceTerminationReason` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice0C17TerminationReasonO11interruptedyAcA0c12InterruptionE0OcACmF -->
- `VoiceTerminationReason.interrupted(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C17TerminationReasonO6failedyAcA0C5ErrorOcACmF -->
- `VoiceTerminationReason.failed(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C17TerminationReasonO9cancelledyA2CmF -->
- `VoiceTerminationReason.cancelled` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C17TerminationReasonO9completedyA2CmF -->
- `VoiceTerminationReason.completed` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO -->
- `VoiceError` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO06speechC11UnavailableyACSScACmF -->
- `VoiceError.speechVoiceUnavailable(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO11textTooLongyACSi_tcACmF -->
- `VoiceError.textTooLong(maximumUTF16Length:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO10underlyingyACSScACmF -->
- `VoiceError.underlying(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO11interruptedyACSScACmF -->
- `VoiceError.interrupted(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO12invalidStateyACSScACmF -->
- `VoiceError.invalidState(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO16errorDescriptionSSSgvp -->
- `errorDescription` (swift.property)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO17unsupportedLocaleyAC10Foundation0F0VcACmF -->
- `VoiceError.unsupportedLocale(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO22speechPermissionDeniedyA2CmF -->
- `VoiceError.speechPermissionDenied` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO23audioSessionUnavailableyACSScACmF -->
- `VoiceError.audioSessionUnavailable(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO26invalidSpeechConfigurationyACSScACmF -->
- `VoiceError.invalidSpeechConfiguration(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO26microphonePermissionDeniedyA2CmF -->
- `VoiceError.microphonePermissionDenied` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO26speechSynthesisUnavailableyACSScACmF -->
- `VoiceError.speechSynthesisUnavailable(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO30onDeviceRecognitionUnavailableyAC10Foundation6LocaleVcACmF -->
- `VoiceError.onDeviceRecognitionUnavailable(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO8categoryAA0cD8CategoryOvp -->
- `category` (swift.property)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO9cancelledyA2CmF -->
- `VoiceError.cancelled` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5EventO -->
- `VoiceEvent` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice0C5EventO10transcriptyAcA16TranscriptUpdateVcACmF -->
- `VoiceEvent.transcript(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5EventO12stateChangedyAcA0C5StateOcACmF -->
- `VoiceEvent.stateChanged(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5EventO13speechStartedyA2CmF -->
- `VoiceEvent.speechStarted` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5EventO14speechFinishedyA2CmF -->
- `VoiceEvent.speechFinished` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5EventO15speechCancelledyA2CmF -->
- `VoiceEvent.speechCancelled` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5EventO17listeningFinishedyAcA0C17TerminationReasonOcACmF -->
- `VoiceEvent.listeningFinished(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5EventO7failureyAcA0C5ErrorOcACmF -->
- `VoiceEvent.failure(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5StateO -->
- `VoiceState` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice0C5StateO10finalizingyA2CmF -->
- `VoiceState.finalizing` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5StateO4idleyA2CmF -->
- `VoiceState.idle` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5StateO6failedyA2CmF -->
- `VoiceState.failed` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5StateO9preparingyA2CmF -->
- `VoiceState.preparing` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5StateO8speakingyA2CmF -->
- `VoiceState.speaking` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5StateO9listeningyA2CmF -->
- `VoiceState.listening` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice16TranscriptUpdateV -->
- `TranscriptUpdate` (swift.struct)
<!-- api-symbol: s:13AppLocalVoice16TranscriptUpdateV4text7isFinalACSS_Sbtcfc -->
- `init(text:isFinal:)` (swift.init)
<!-- api-symbol: s:13AppLocalVoice16TranscriptUpdateV4textSSvp -->
- `text` (swift.property)
<!-- api-symbol: s:13AppLocalVoice16TranscriptUpdateV7isFinalSbvp -->
- `isFinal` (swift.property)
<!-- api-symbol: s:13AppLocalVoice17SpeechModelPolicyO -->
- `SpeechModelPolicy` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice17SpeechModelPolicyO05allowE12InstallationyA2CmF -->
- `SpeechModelPolicy.allowModelInstallation` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice17SpeechModelPolicyO19installedModelsOnlyyA2CmF -->
- `SpeechModelPolicy.installedModelsOnly` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice18SpeechCapabilitiesV -->
- `SpeechCapabilities` (swift.struct)
<!-- api-symbol: s:13AppLocalVoice18SpeechCapabilitiesV11isSupportedSbvp -->
- `isSupported` (swift.property)
<!-- api-symbol: s:13AppLocalVoice18SpeechCapabilitiesV16supportsOnDeviceSbvp -->
- `supportsOnDevice` (swift.property)
<!-- api-symbol: s:13AppLocalVoice18SpeechCapabilitiesV6locale10Foundation6LocaleVvp -->
- `locale` (swift.property)
<!-- api-symbol: s:13AppLocalVoice18SpeechCapabilitiesV6locale11isSupported16supportsOnDevice6reasonAC10Foundation6LocaleV_S2bSSSgtcfc -->
- `init(locale:isSupported:supportsOnDevice:reason:)` (swift.init)
<!-- api-symbol: s:13AppLocalVoice18SpeechCapabilitiesV6reasonSSSgvp -->
- `reason` (swift.property)
<!-- api-symbol: s:13AppLocalVoice19SpeechConfigurationV -->
- `SpeechConfiguration` (swift.struct)
<!-- api-symbol: s:13AppLocalVoice19SpeechConfigurationV15voiceIdentifierSSSgvp -->
- `voiceIdentifier` (swift.property)
<!-- api-symbol: s:13AppLocalVoice19SpeechConfigurationV16preferredQualityAA0dcG0Ovp -->
- `preferredQuality` (swift.property)
<!-- api-symbol: s:13AppLocalVoice19SpeechConfigurationV29maximumCharactersPerUtteranceSivp -->
- `maximumCharactersPerUtterance` (swift.property)
<!-- api-symbol: s:13AppLocalVoice19SpeechConfigurationV4rateSfvp -->
- `rate` (swift.property)
<!-- api-symbol: s:13AppLocalVoice19SpeechConfigurationV6locale10Foundation6LocaleVvp -->
- `locale` (swift.property)
<!-- api-symbol: s:13AppLocalVoice19SpeechConfigurationV6locale15voiceIdentifier16preferredQuality4rate6volume29maximumCharactersPerUtteranceAC10Foundation6LocaleV_SSSgAA0dcJ0OS2fSitcfc -->
- `init(locale:voiceIdentifier:preferredQuality:rate:volume:maximumCharactersPerUtterance:)` (swift.init)
<!-- api-symbol: s:13AppLocalVoice19SpeechConfigurationV6volumeSfvp -->
- `volume` (swift.property)
<!-- api-symbol: s:13AppLocalVoice24RecognitionConfigurationV -->
- `RecognitionConfiguration` (swift.struct)
<!-- api-symbol: s:13AppLocalVoice24RecognitionConfigurationV6locale10Foundation6LocaleVvp -->
- `locale` (swift.property)
<!-- api-symbol: s:13AppLocalVoice24RecognitionConfigurationV6locale6policyAC10Foundation6LocaleV_AA17SpeechModelPolicyOtcfc -->
- `init(locale:policy:)` (swift.init)
<!-- api-symbol: s:13AppLocalVoice24RecognitionConfigurationV6policyAA17SpeechModelPolicyOvp -->
- `policy` (swift.property)
<!-- api-symbol: s:13AppLocalVoiceAAC -->
- `AppLocalVoice` (swift.class)
<!-- api-symbol: s:13AppLocalVoiceAAC12capabilities3forAA18SpeechCapabilitiesV10Foundation6LocaleV_tYaF -->
- `capabilities(for:)` (swift.method)
<!-- api-symbol: s:13AppLocalVoiceAAC12stopSpeakingyyYaF -->
- `stopSpeaking()` (swift.method)
<!-- api-symbol: s:13AppLocalVoiceAAC13pauseSpeakingyyYaF -->
- `pauseSpeaking()` (swift.method)
<!-- api-symbol: s:13AppLocalVoiceAAC14resumeSpeakingyyYaF -->
- `resumeSpeaking()` (swift.method)
<!-- api-symbol: s:13AppLocalVoiceAAC14startListening13configurationyAA24RecognitionConfigurationV_tYaKF -->
- `startListening(configuration:)` (swift.method)
<!-- api-symbol: s:13AppLocalVoiceAAC15availableVoices3forSayAA06SpeechC0VG10Foundation6LocaleV_tYaF -->
- `availableVoices(for:)` (swift.method)
<!-- api-symbol: s:13AppLocalVoiceAAC15cancelListeningyyYaF -->
- `cancelListening()` (swift.method)
<!-- api-symbol: s:13AppLocalVoiceAAC15finishListeningSSyYaKF -->
- `finishListening()` (swift.method)
<!-- api-symbol: s:13AppLocalVoiceAAC5closeAA13CleanupResultOyYaF -->
- `close()` (swift.method)
<!-- api-symbol: s:13AppLocalVoiceAAC5speak_13configurationySS_AA19SpeechConfigurationVtYaKF -->
- `speak(_:configuration:)` (swift.method)
<!-- api-symbol: s:13AppLocalVoiceAAC5stateAA0C5StateOvp -->
- `state` (swift.property)
<!-- api-symbol: s:13AppLocalVoiceAAC13recoveryStateAA0c8RecoveryE0Ovp -->
- `recoveryState` (swift.property)
<!-- api-symbol: s:13AppLocalVoiceAAC6eventsScSyAA0C5EventOGyYaF -->
- `events()` (swift.method)

<!-- api-symbol: s:13AppLocalVoiceAAC15skipSpeechQueueAA0E14PlaybackResultVSgyYaF -->
- `skipSpeechQueue()` (swift.method)
<!-- api-symbol: s:13AppLocalVoiceAAC23clearPendingSpeechQueueSayAA0F14PlaybackResultVGyYaF -->
- `clearPendingSpeechQueue()` (swift.method)
<!-- api-symbol: s:13AppLocalVoice0C11EventStreama -->
- `s:13AppLocalVoice0C11EventStreama`
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO12serviceInUseyA2CmF -->
- `s:13AppLocalVoice0C13ErrorCategoryO12serviceInUseyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO14cleanupPendingyA2CmF -->
- `s:13AppLocalVoice0C13ErrorCategoryO14cleanupPendingyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO15itemUnavailableyA2CmF -->
- `s:13AppLocalVoice0C13ErrorCategoryO15itemUnavailableyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO17invalidSpeechItemyA2CmF -->
- `s:13AppLocalVoice0C13ErrorCategoryO17invalidSpeechItemyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO17operationTimedOutyA2CmF -->
- `s:13AppLocalVoice0C13ErrorCategoryO17operationTimedOutyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO21audioRouteUnavailableyA2CmF -->
- `s:13AppLocalVoice0C13ErrorCategoryO21audioRouteUnavailableyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO21eventDeliveryOverflowyA2CmF -->
- `s:13AppLocalVoice0C13ErrorCategoryO21eventDeliveryOverflowyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO21transcriptConsistencyyA2CmF -->
- `s:13AppLocalVoice0C13ErrorCategoryO21transcriptConsistencyyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO26speechPermissionRestrictedyA2CmF -->
- `s:13AppLocalVoice0C13ErrorCategoryO26speechPermissionRestrictedyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO27eventSubscriberLimitReachedyA2CmF -->
- `s:13AppLocalVoice0C13ErrorCategoryO27eventSubscriberLimitReachedyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO30microphonePermissionRestrictedyA2CmF -->
- `s:13AppLocalVoice0C13ErrorCategoryO30microphonePermissionRestrictedyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO31invalidRecognitionConfigurationyA2CmF -->
- `s:13AppLocalVoice0C13ErrorCategoryO31invalidRecognitionConfigurationyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO31invalidSpeechQueueConfigurationyA2CmF -->
- `s:13AppLocalVoice0C13ErrorCategoryO31invalidSpeechQueueConfigurationyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO34recognitionModelInstallationFailedyA2CmF -->
- `s:13AppLocalVoice0C13ErrorCategoryO34recognitionModelInstallationFailedyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO9queueFullyA2CmF -->
- `s:13AppLocalVoice0C13ErrorCategoryO9queueFullyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C13RecoveryEventV -->
- `s:13AppLocalVoice0C13RecoveryEventV`
<!-- api-symbol: s:13AppLocalVoice0C13RecoveryEventV12eventOrdinal4kindACs6UInt64V_AA0cdE4KindOtcfc -->
- `s:13AppLocalVoice0C13RecoveryEventV12eventOrdinal4kindACs6UInt64V_AA0cdE4KindOtcfc`
<!-- api-symbol: s:13AppLocalVoice0C13RecoveryEventV12eventOrdinals6UInt64Vvp -->
- `s:13AppLocalVoice0C13RecoveryEventV12eventOrdinals6UInt64Vvp`
<!-- api-symbol: s:13AppLocalVoice0C13RecoveryEventV4kindAA0cdE4KindOvp -->
- `s:13AppLocalVoice0C13RecoveryEventV4kindAA0cdE4KindOvp`
<!-- api-symbol: s:13AppLocalVoice0C13RecoveryStateO -->
- `s:13AppLocalVoice0C13RecoveryStateO`
<!-- api-symbol: s:13AppLocalVoice0C13RecoveryStateO11reconcilingyA2CmF -->
- `s:13AppLocalVoice0C13RecoveryStateO11reconcilingyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C13RecoveryStateO5readyyA2CmF -->
- `s:13AppLocalVoice0C13RecoveryStateO5readyyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C13RecoveryStateO7blockedyAcA0C7FailureVcACmF -->
- `s:13AppLocalVoice0C13RecoveryStateO7blockedyAcA0C7FailureVcACmF`
<!-- api-symbol: s:13AppLocalVoice0C14RecoveryActionO -->
- `s:13AppLocalVoice0C14RecoveryActionO`
<!-- api-symbol: s:13AppLocalVoice0C14RecoveryActionO015chooseInstalledC0yA2CmF -->
- `s:13AppLocalVoice0C14RecoveryActionO015chooseInstalledC0yA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C14RecoveryActionO11shortenTextyA2CmF -->
- `s:13AppLocalVoice0C14RecoveryActionO11shortenTextyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C14RecoveryActionO11waitForIdleyA2CmF -->
- `s:13AppLocalVoice0C14RecoveryActionO11waitForIdleyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C14RecoveryActionO12openSettingsyA2CmF -->
- `s:13AppLocalVoice0C14RecoveryActionO12openSettingsyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C14RecoveryActionO12retryCleanupyA2CmF -->
- `s:13AppLocalVoice0C14RecoveryActionO12retryCleanupyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C14RecoveryActionO13reenqueueItemyA2CmF -->
- `s:13AppLocalVoice0C14RecoveryActionO13reenqueueItemyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C14RecoveryActionO14makeQueueSpaceyA2CmF -->
- `s:13AppLocalVoice0C14RecoveryActionO14makeQueueSpaceyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C14RecoveryActionO16useOwningServiceyA2CmF -->
- `s:13AppLocalVoice0C14RecoveryActionO16useOwningServiceyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C14RecoveryActionO18showPermissionHelpyA2CmF -->
- `s:13AppLocalVoice0C14RecoveryActionO18showPermissionHelpyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C14RecoveryActionO19changeConfigurationyA2CmF -->
- `s:13AppLocalVoice0C14RecoveryActionO19changeConfigurationyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C14RecoveryActionO19reconcileEventStateyA2CmF -->
- `s:13AppLocalVoice0C14RecoveryActionO19reconcileEventStateyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C14RecoveryActionO21chooseSupportedLocaleyA2CmF -->
- `s:13AppLocalVoice0C14RecoveryActionO21chooseSupportedLocaleyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C14RecoveryActionO22retryAfterInterruptionyA2CmF -->
- `s:13AppLocalVoice0C14RecoveryActionO22retryAfterInterruptionyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C14RecoveryActionO22reviewRecognitionModelyA2CmF -->
- `s:13AppLocalVoice0C14RecoveryActionO22reviewRecognitionModelyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C14RecoveryActionO24discardPartialTranscriptyA2CmF -->
- `s:13AppLocalVoice0C14RecoveryActionO24discardPartialTranscriptyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C14RecoveryActionO4noneyA2CmF -->
- `s:13AppLocalVoice0C14RecoveryActionO4noneyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C14RecoveryActionO5retryyA2CmF -->
- `s:13AppLocalVoice0C14RecoveryActionO5retryyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C16BackgroundPolicyO -->
- `s:13AppLocalVoice0C16BackgroundPolicyO`
<!-- api-symbol: s:13AppLocalVoice0C16BackgroundPolicyO4stopyA2CmF -->
- `s:13AppLocalVoice0C16BackgroundPolicyO4stopyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C16PermissionStatusO -->
- `s:13AppLocalVoice0C16PermissionStatusO`
<!-- api-symbol: s:13AppLocalVoice0C16PermissionStatusO10authorizedyA2CmF -->
- `s:13AppLocalVoice0C16PermissionStatusO10authorizedyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C16PermissionStatusO10restrictedyA2CmF -->
- `s:13AppLocalVoice0C16PermissionStatusO10restrictedyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C16PermissionStatusO13notDeterminedyA2CmF -->
- `s:13AppLocalVoice0C16PermissionStatusO13notDeterminedyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C16PermissionStatusO6deniedyA2CmF -->
- `s:13AppLocalVoice0C16PermissionStatusO6deniedyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C17RecoveryEventKindO -->
- `s:13AppLocalVoice0C17RecoveryEventKindO`
<!-- api-symbol: s:13AppLocalVoice0C17RecoveryEventKindO11reconcilingyA2CmF -->
- `s:13AppLocalVoice0C17RecoveryEventKindO11reconcilingyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C17RecoveryEventKindO5readyyA2CmF -->
- `s:13AppLocalVoice0C17RecoveryEventKindO5readyyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C17RecoveryEventKindO7blockedyAcA0C7FailureVcACmF -->
- `s:13AppLocalVoice0C17RecoveryEventKindO7blockedyAcA0C7FailureVcACmF`
<!-- api-symbol: s:13AppLocalVoice0C17RouteChangePolicyO -->
- `s:13AppLocalVoice0C17RouteChangePolicyO`
<!-- api-symbol: s:13AppLocalVoice0C17RouteChangePolicyO21stopAndRequireRestartyA2CmF -->
- `s:13AppLocalVoice0C17RouteChangePolicyO21stopAndRequireRestartyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C18CapabilitySnapshotV -->
- `s:13AppLocalVoice0C18CapabilitySnapshotV`
<!-- api-symbol: s:13AppLocalVoice0C18CapabilitySnapshotV11recognitionAA011RecognitionD0Vvp -->
- `s:13AppLocalVoice0C18CapabilitySnapshotV11recognitionAA011RecognitionD0Vvp`
<!-- api-symbol: s:13AppLocalVoice0C18CapabilitySnapshotV12availability3forAA0cD12AvailabilityOSgAA0C7FeatureO_tF -->
- `s:13AppLocalVoice0C18CapabilitySnapshotV12availability3forAA0cD12AvailabilityOSgAA0C7FeatureO_tF`
<!-- api-symbol: s:13AppLocalVoice0C18CapabilitySnapshotV15installedVoicesSayAA06SpeechC0VGvp -->
- `s:13AppLocalVoice0C18CapabilitySnapshotV15installedVoicesSayAA06SpeechC0VGvp`
<!-- api-symbol: s:13AppLocalVoice0C18CapabilitySnapshotV20microphonePermission017speechRecognitionG011recognition15installedVoices8featuresAcA0cG6StatusO_AjA0iD0VSayAA06SpeechC0VGSDyAA0C7FeatureOAA0cD12AvailabilityOGtcfc -->
- `s:13AppLocalVoice0C18CapabilitySnapshotV20microphonePermission017speechRecognitionG011recognition15installedVoices8featuresAcA0cG6StatusO_AjA0iD0VSayAA06SpeechC0VGSDyAA0C7FeatureOAA0cD12AvailabilityOGtcfc`
<!-- api-symbol: s:13AppLocalVoice0C18CapabilitySnapshotV20microphonePermissionAA0cG6StatusOvp -->
- `s:13AppLocalVoice0C18CapabilitySnapshotV20microphonePermissionAA0cG6StatusOvp`
<!-- api-symbol: s:13AppLocalVoice0C18CapabilitySnapshotV27speechRecognitionPermissionAA0cH6StatusOvp -->
- `s:13AppLocalVoice0C18CapabilitySnapshotV27speechRecognitionPermissionAA0cH6StatusOvp`
<!-- api-symbol: s:13AppLocalVoice0C18CapabilitySnapshotV8featuresSDyAA0C7FeatureOAA0cD12AvailabilityOGvp -->
- `s:13AppLocalVoice0C18CapabilitySnapshotV8featuresSDyAA0C7FeatureOAA0cD12AvailabilityOGvp`
<!-- api-symbol: s:13AppLocalVoice0C18InterruptionPolicyO -->
- `s:13AppLocalVoice0C18InterruptionPolicyO`
<!-- api-symbol: s:13AppLocalVoice0C18InterruptionPolicyO4stopyA2CmF -->
- `s:13AppLocalVoice0C18InterruptionPolicyO4stopyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C18InterruptionReasonO -->
- `s:13AppLocalVoice0C18InterruptionReasonO`
<!-- api-symbol: s:13AppLocalVoice0C18InterruptionReasonO06systemD0yA2CmF -->
- `s:13AppLocalVoice0C18InterruptionReasonO06systemD0yA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C18InterruptionReasonO11routeChangeyA2CmF -->
- `s:13AppLocalVoice0C18InterruptionReasonO11routeChangeyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C18InterruptionReasonO13appBackgroundyA2CmF -->
- `s:13AppLocalVoice0C18InterruptionReasonO13appBackgroundyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C18InterruptionReasonO18mediaServicesResetyA2CmF -->
- `s:13AppLocalVoice0C18InterruptionReasonO18mediaServicesResetyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C20CleanupFailurePolicyO -->
- `s:13AppLocalVoice0C20CleanupFailurePolicyO`
<!-- api-symbol: s:13AppLocalVoice0C20CleanupFailurePolicyO20requireExplicitRetryyA2CmF -->
- `s:13AppLocalVoice0C20CleanupFailurePolicyO20requireExplicitRetryyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C22CapabilityAvailabilityO -->
- `s:13AppLocalVoice0C22CapabilityAvailabilityO`
<!-- api-symbol: s:13AppLocalVoice0C22CapabilityAvailabilityO11unavailableyAcA0C7FailureVcACmF -->
- `s:13AppLocalVoice0C22CapabilityAvailabilityO11unavailableyAcA0C7FailureVcACmF`
<!-- api-symbol: s:13AppLocalVoice0C22CapabilityAvailabilityO9availableyA2CmF -->
- `s:13AppLocalVoice0C22CapabilityAvailabilityO9availableyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO12serviceInUseyA2CmF -->
- `s:13AppLocalVoice0C5ErrorO12serviceInUseyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO14cleanupPendingyA2CmF -->
- `s:13AppLocalVoice0C5ErrorO14cleanupPendingyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO15itemUnavailableyAcA12SpeechItemIDVcACmF -->
- `s:13AppLocalVoice0C5ErrorO15itemUnavailableyAcA12SpeechItemIDVcACmF`
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO17invalidSpeechItemyACSScACmF -->
- `s:13AppLocalVoice0C5ErrorO17invalidSpeechItemyACSScACmF`
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO17operationTimedOutyA2CmF -->
- `s:13AppLocalVoice0C5ErrorO17operationTimedOutyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO21audioRouteUnavailableyA2CmF -->
- `s:13AppLocalVoice0C5ErrorO21audioRouteUnavailableyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO21eventDeliveryOverflowyACSi_AA05EventF6CursorOtcACmF -->
- `s:13AppLocalVoice0C5ErrorO21eventDeliveryOverflowyACSi_AA05EventF6CursorOtcACmF`
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO21transcriptConsistencyyA2CmF -->
- `s:13AppLocalVoice0C5ErrorO21transcriptConsistencyyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO25recommendedRecoveryActionAA0cfG0Ovp -->
- `s:13AppLocalVoice0C5ErrorO25recommendedRecoveryActionAA0cfG0Ovp`
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO26speechPermissionRestrictedyA2CmF -->
- `s:13AppLocalVoice0C5ErrorO26speechPermissionRestrictedyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO27eventSubscriberLimitReachedyACSi_SitcACmF -->
- `s:13AppLocalVoice0C5ErrorO27eventSubscriberLimitReachedyACSi_SitcACmF`
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO30microphonePermissionRestrictedyA2CmF -->
- `s:13AppLocalVoice0C5ErrorO30microphonePermissionRestrictedyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO31invalidRecognitionConfigurationyACSScACmF -->
- `s:13AppLocalVoice0C5ErrorO31invalidRecognitionConfigurationyACSScACmF`
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO31invalidSpeechQueueConfigurationyACSScACmF -->
- `s:13AppLocalVoice0C5ErrorO31invalidSpeechQueueConfigurationyACSScACmF`
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO34recognitionModelInstallationFailedyAC10Foundation6LocaleV_AA0c8ProviderD4CodeVSgtcACmF -->
- `VoiceError.recognitionModelInstallationFailed(_:providerError:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO7failureAA0C7FailureVvp -->
- `s:13AppLocalVoice0C5ErrorO7failureAA0C7FailureVvp`
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO9queueFullyACSi_tcACmF -->
- `s:13AppLocalVoice0C5ErrorO9queueFullyACSi_tcACmF`
<!-- api-symbol: s:13AppLocalVoice0C7FailureV -->
- `s:13AppLocalVoice0C7FailureV`
<!-- api-symbol: s:13AppLocalVoice0C7FailureV17recommendedActionAA0c8RecoveryF0Ovp -->
- `s:13AppLocalVoice0C7FailureV17recommendedActionAA0c8RecoveryF0Ovp`
<!-- api-symbol: s:13AppLocalVoice0C7FailureV8category17recommendedActionAcA0C13ErrorCategoryO_AA0c8RecoveryG0Otcfc -->
- `s:13AppLocalVoice0C7FailureV8category17recommendedActionAcA0C13ErrorCategoryO_AA0c8RecoveryG0Otcfc`
<!-- api-symbol: s:13AppLocalVoice0C7FailureV8categoryAA0C13ErrorCategoryOvp -->
- `s:13AppLocalVoice0C7FailureV8categoryAA0C13ErrorCategoryOvp`
<!-- api-symbol: s:13AppLocalVoice0C7FeatureO -->
- `s:13AppLocalVoice0C7FeatureO`
<!-- api-symbol: s:13AppLocalVoice0C7FeatureO11speechQueueyA2CmF -->
- `s:13AppLocalVoice0C7FeatureO11speechQueueyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C7FeatureO15speechSynthesisyA2CmF -->
- `s:13AppLocalVoice0C7FeatureO15speechSynthesisyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C7FeatureO17modelInstallationyA2CmF -->
- `s:13AppLocalVoice0C7FeatureO17modelInstallationyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C7FeatureO17speechPauseResumeyA2CmF -->
- `s:13AppLocalVoice0C7FeatureO17speechPauseResumeyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C7FeatureO17speechRecognitionyA2CmF -->
- `s:13AppLocalVoice0C7FeatureO17speechRecognitionyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C7FeatureO21liveTranscriptPreviewyA2CmF -->
- `s:13AppLocalVoice0C7FeatureO21liveTranscriptPreviewyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C7FeatureO22stableTranscriptChunksyA2CmF -->
- `s:13AppLocalVoice0C7FeatureO22stableTranscriptChunksyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0c11EventStreamD0O -->
- `s:13AppLocalVoice0c11EventStreamD0O`
<!-- api-symbol: s:13AppLocalVoice0c11EventStreamD0O11recognitionyAcA011RecognitionD0VcACmF -->
- `s:13AppLocalVoice0c11EventStreamD0O11recognitionyAcA011RecognitionD0VcACmF`
<!-- api-symbol: s:13AppLocalVoice0c11EventStreamD0O11speechQueueyAcA06SpeechgD0VcACmF -->
- `s:13AppLocalVoice0c11EventStreamD0O11speechQueueyAcA06SpeechgD0VcACmF`
<!-- api-symbol: s:13AppLocalVoice0c11EventStreamD0O12eventOrdinals6UInt64Vvp -->
- `s:13AppLocalVoice0c11EventStreamD0O12eventOrdinals6UInt64Vvp`
<!-- api-symbol: s:13AppLocalVoice0c11EventStreamD0O6cursorAA0D14DeliveryCursorOvp -->
- `s:13AppLocalVoice0c11EventStreamD0O6cursorAA0D14DeliveryCursorOvp`
<!-- api-symbol: s:13AppLocalVoice0c11EventStreamD0O8recoveryyAcA0c8RecoveryD0VcACmF -->
- `s:13AppLocalVoice0c11EventStreamD0O8recoveryyAcA0c8RecoveryD0VcACmF`
<!-- api-symbol: s:13AppLocalVoice10SpeechItemV -->
- `s:13AppLocalVoice10SpeechItemV`
<!-- api-symbol: s:13AppLocalVoice10SpeechItemV13configurationAA0D13ConfigurationVvp -->
- `s:13AppLocalVoice10SpeechItemV13configurationAA0D13ConfigurationVvp`
<!-- api-symbol: s:13AppLocalVoice10SpeechItemV2idAA0dE2IDVvp -->
- `s:13AppLocalVoice10SpeechItemV2idAA0dE2IDVvp`
<!-- api-symbol: s:13AppLocalVoice10SpeechItemV4textSSvp -->
- `s:13AppLocalVoice10SpeechItemV4textSSvp`
<!-- api-symbol: s:13AppLocalVoice10SpeechItemV8priorityAA0D8PriorityOvp -->
- `s:13AppLocalVoice10SpeechItemV8priorityAA0D8PriorityOvp`
<!-- api-symbol: s:13AppLocalVoice12SpeechItemIDV -->
- `s:13AppLocalVoice12SpeechItemIDV`
<!-- api-symbol: s:13AppLocalVoice12SpeechItemIDV11descriptionSSvp -->
- `s:13AppLocalVoice12SpeechItemIDV11descriptionSSvp`
<!-- api-symbol: s:13AppLocalVoice12SpeechItemIDV8rawValue10Foundation4UUIDVvp -->
- `s:13AppLocalVoice12SpeechItemIDV8rawValue10Foundation4UUIDVvp`
<!-- api-symbol: s:13AppLocalVoice13CleanupResultO -->
- `s:13AppLocalVoice13CleanupResultO`
<!-- api-symbol: s:13AppLocalVoice13CleanupResultO7blockedyAcA0C7FailureVcACmF -->
- `s:13AppLocalVoice13CleanupResultO7blockedyAcA0C7FailureVcACmF`
<!-- api-symbol: s:13AppLocalVoice13CleanupResultO8releasedyA2CmF -->
- `s:13AppLocalVoice13CleanupResultO8releasedyA2CmF`
<!-- api-symbol: s:13AppLocalVoice14SpeechPriorityO -->
- `s:13AppLocalVoice14SpeechPriorityO`
<!-- api-symbol: s:13AppLocalVoice14SpeechPriorityO13userInitiatedyA2CmF -->
- `s:13AppLocalVoice14SpeechPriorityO13userInitiatedyA2CmF`
<!-- api-symbol: s:13AppLocalVoice14SpeechPriorityO1loiySbAC_ACtFZ -->
- `s:13AppLocalVoice14SpeechPriorityO1loiySbAC_ACtFZ`
<!-- api-symbol: s:13AppLocalVoice14SpeechPriorityO6normalyA2CmF -->
- `s:13AppLocalVoice14SpeechPriorityO6normalyA2CmF`
<!-- api-symbol: s:13AppLocalVoice14SpeechPriorityO8rawValueACSgSi_tcfc -->
- `s:13AppLocalVoice14SpeechPriorityO8rawValueACSgSi_tcfc`
<!-- api-symbol: s:13AppLocalVoice15FinalTranscriptV -->
- `s:13AppLocalVoice15FinalTranscriptV`
<!-- api-symbol: s:13AppLocalVoice15FinalTranscriptV4textSSvp -->
- `s:13AppLocalVoice15FinalTranscriptV4textSSvp`
<!-- api-symbol: s:13AppLocalVoice15FinalTranscriptV9sessionIDAA018RecognitionSessionG0Vvp -->
- `s:13AppLocalVoice15FinalTranscriptV9sessionIDAA018RecognitionSessionG0Vvp`
<!-- api-symbol: s:13AppLocalVoice15FinalTranscriptV9timeRangeAA0e4TimeG0VSgvp -->
- `s:13AppLocalVoice15FinalTranscriptV9timeRangeAA0e4TimeG0VSgvp`
<!-- api-symbol: s:13AppLocalVoice15SpeechItemEventa -->
- `s:13AppLocalVoice15SpeechItemEventa`
<!-- api-symbol: s:13AppLocalVoice15SpeechQueueModeO -->
- `s:13AppLocalVoice15SpeechQueueModeO`
<!-- api-symbol: s:13AppLocalVoice15SpeechQueueModeO7runningyA2CmF -->
- `s:13AppLocalVoice15SpeechQueueModeO7runningyA2CmF`
<!-- api-symbol: s:13AppLocalVoice15SpeechQueueModeO9suspendedyA2CmF -->
- `s:13AppLocalVoice15SpeechQueueModeO9suspendedyA2CmF`
<!-- api-symbol: s:13AppLocalVoice16RecognitionEventV -->
- `s:13AppLocalVoice16RecognitionEventV`
<!-- api-symbol: s:13AppLocalVoice16RecognitionEventV08acceptedE7Ordinals6UInt64VvpZ -->
- `s:13AppLocalVoice16RecognitionEventV08acceptedE7Ordinals6UInt64VvpZ`
<!-- api-symbol: s:13AppLocalVoice16RecognitionEventV10duplicatesySbACF -->
- `s:13AppLocalVoice16RecognitionEventV10duplicatesySbACF`
<!-- api-symbol: s:13AppLocalVoice16RecognitionEventV12eventOrdinals6UInt64Vvp -->
- `s:13AppLocalVoice16RecognitionEventV12eventOrdinals6UInt64Vvp`
<!-- api-symbol: s:13AppLocalVoice16RecognitionEventV18immediatelyFollowsySbACF -->
- `s:13AppLocalVoice16RecognitionEventV18immediatelyFollowsySbACF`
<!-- api-symbol: s:13AppLocalVoice16RecognitionEventV4kindAA0dE4KindOvp -->
- `s:13AppLocalVoice16RecognitionEventV4kindAA0dE4KindOvp`
<!-- api-symbol: s:13AppLocalVoice16RecognitionEventV9sessionIDAA0d7SessionG0Vvp -->
- `s:13AppLocalVoice16RecognitionEventV9sessionIDAA0d7SessionG0Vvp`
<!-- api-symbol: s:13AppLocalVoice16SpeechPlaybackIDV -->
- `s:13AppLocalVoice16SpeechPlaybackIDV`
<!-- api-symbol: s:13AppLocalVoice16SpeechPlaybackIDV11descriptionSSvp -->
- `s:13AppLocalVoice16SpeechPlaybackIDV11descriptionSSvp`
<!-- api-symbol: s:13AppLocalVoice16SpeechPlaybackIDV8rawValue10Foundation4UUIDVvp -->
- `s:13AppLocalVoice16SpeechPlaybackIDV8rawValue10Foundation4UUIDVvp`
<!-- api-symbol: s:13AppLocalVoice16SpeechQueueEventV -->
- `s:13AppLocalVoice16SpeechQueueEventV`
<!-- api-symbol: s:13AppLocalVoice16SpeechQueueEventV10playbackIDAA0d8PlaybackH0Vvp -->
- `s:13AppLocalVoice16SpeechQueueEventV10playbackIDAA0d8PlaybackH0Vvp`
<!-- api-symbol: s:13AppLocalVoice16SpeechQueueEventV12eventOrdinals6UInt64Vvp -->
- `s:13AppLocalVoice16SpeechQueueEventV12eventOrdinals6UInt64Vvp`
<!-- api-symbol: s:13AppLocalVoice16SpeechQueueEventV18immediatelyFollowsySbACF -->
- `s:13AppLocalVoice16SpeechQueueEventV18immediatelyFollowsySbACF`
<!-- api-symbol: s:13AppLocalVoice16SpeechQueueEventV4kindAA0deF4KindOvp -->
- `s:13AppLocalVoice16SpeechQueueEventV4kindAA0deF4KindOvp`
<!-- api-symbol: s:13AppLocalVoice16SpeechQueueEventV6itemIDAA0d4ItemH0Vvp -->
- `s:13AppLocalVoice16SpeechQueueEventV6itemIDAA0d4ItemH0Vvp`
<!-- api-symbol: s:13AppLocalVoice17SpeechItemRequestV -->
- `s:13AppLocalVoice17SpeechItemRequestV`
<!-- api-symbol: s:13AppLocalVoice17SpeechItemRequestV13configurationAA0D13ConfigurationVvp -->
- `s:13AppLocalVoice17SpeechItemRequestV13configurationAA0D13ConfigurationVvp`
<!-- api-symbol: s:13AppLocalVoice17SpeechItemRequestV18maximumUTF16LengthSivpZ -->
- `s:13AppLocalVoice17SpeechItemRequestV18maximumUTF16LengthSivpZ`
<!-- api-symbol: s:13AppLocalVoice17SpeechItemRequestV4text8priority13configurationACSS_AA0D8PriorityOAA0D13ConfigurationVtKcfc -->
- `s:13AppLocalVoice17SpeechItemRequestV4text8priority13configurationACSS_AA0D8PriorityOAA0D13ConfigurationVtKcfc`
<!-- api-symbol: s:13AppLocalVoice17SpeechItemRequestV4textSSvp -->
- `s:13AppLocalVoice17SpeechItemRequestV4textSSvp`
<!-- api-symbol: s:13AppLocalVoice17SpeechItemRequestV8priorityAA0D8PriorityOvp -->
- `s:13AppLocalVoice17SpeechItemRequestV8priorityAA0D8PriorityOvp`
<!-- api-symbol: s:13AppLocalVoice17StableChunkPolicyV -->
- `s:13AppLocalVoice17StableChunkPolicyV`
<!-- api-symbol: s:13AppLocalVoice17StableChunkPolicyV11recommendedACvpZ -->
- `s:13AppLocalVoice17StableChunkPolicyV11recommendedACvpZ`
<!-- api-symbol: s:13AppLocalVoice17StableChunkPolicyV15intervalSecondsACSi_tKcfc -->
- `s:13AppLocalVoice17StableChunkPolicyV15intervalSecondsACSi_tKcfc`
<!-- api-symbol: s:13AppLocalVoice17StableChunkPolicyV15intervalSecondsSivp -->
- `s:13AppLocalVoice17StableChunkPolicyV15intervalSecondsSivp`
<!-- api-symbol: s:13AppLocalVoice17StableChunkPolicyV22defaultIntervalSecondsSivpZ -->
- `s:13AppLocalVoice17StableChunkPolicyV22defaultIntervalSecondsSivpZ`
<!-- api-symbol: s:13AppLocalVoice17StableChunkPolicyV22maximumIntervalSecondsSivpZ -->
- `s:13AppLocalVoice17StableChunkPolicyV22maximumIntervalSecondsSivpZ`
<!-- api-symbol: s:13AppLocalVoice17StableChunkPolicyV22minimumIntervalSecondsSivpZ -->
- `s:13AppLocalVoice17StableChunkPolicyV22minimumIntervalSecondsSivpZ`
<!-- api-symbol: s:13AppLocalVoice17TranscriptPreviewV -->
- `s:13AppLocalVoice17TranscriptPreviewV`
<!-- api-symbol: s:13AppLocalVoice17TranscriptPreviewV4textSSvp -->
- `s:13AppLocalVoice17TranscriptPreviewV4textSSvp`
<!-- api-symbol: s:13AppLocalVoice17TranscriptPreviewV8revisions6UInt64Vvp -->
- `s:13AppLocalVoice17TranscriptPreviewV8revisions6UInt64Vvp`
<!-- api-symbol: s:13AppLocalVoice17TranscriptPreviewV9sessionIDAA018RecognitionSessionG0Vvp -->
- `s:13AppLocalVoice17TranscriptPreviewV9sessionIDAA018RecognitionSessionG0Vvp`
<!-- api-symbol: s:13AppLocalVoice17TranscriptPreviewV9timeRangeAA0d4TimeG0VSgvp -->
- `s:13AppLocalVoice17TranscriptPreviewV9timeRangeAA0d4TimeG0VSgvp`
<!-- api-symbol: s:13AppLocalVoice18RecognitionOutcomeO -->
- `s:13AppLocalVoice18RecognitionOutcomeO`
<!-- api-symbol: s:13AppLocalVoice18RecognitionOutcomeO11interruptedyAcA0C18InterruptionReasonOcACmF -->
- `s:13AppLocalVoice18RecognitionOutcomeO11interruptedyAcA0C18InterruptionReasonOcACmF`
<!-- api-symbol: s:13AppLocalVoice18RecognitionOutcomeO6failedyAcA0C7FailureVcACmF -->
- `s:13AppLocalVoice18RecognitionOutcomeO6failedyAcA0C7FailureVcACmF`
<!-- api-symbol: s:13AppLocalVoice18RecognitionOutcomeO9cancelledyA2CmF -->
- `s:13AppLocalVoice18RecognitionOutcomeO9cancelledyA2CmF`
<!-- api-symbol: s:13AppLocalVoice18RecognitionOutcomeO9completedyA2CmF -->
- `s:13AppLocalVoice18RecognitionOutcomeO9completedyA2CmF`
<!-- api-symbol: s:13AppLocalVoice18SpeechQueueCommandO -->
- `s:13AppLocalVoice18SpeechQueueCommandO`
<!-- api-symbol: s:13AppLocalVoice18SpeechQueueCommandO12clearPendingyA2CmF -->
- `s:13AppLocalVoice18SpeechQueueCommandO12clearPendingyA2CmF`
<!-- api-symbol: s:13AppLocalVoice18SpeechQueueCommandO12stopAndClearyA2CmF -->
- `s:13AppLocalVoice18SpeechQueueCommandO12stopAndClearyA2CmF`
<!-- api-symbol: s:13AppLocalVoice18SpeechQueueCommandO4skipyA2CmF -->
- `s:13AppLocalVoice18SpeechQueueCommandO4skipyA2CmF`
<!-- api-symbol: s:13AppLocalVoice18SpeechQueueCommandO4stopyA2CmF -->
- `s:13AppLocalVoice18SpeechQueueCommandO4stopyA2CmF`
<!-- api-symbol: s:13AppLocalVoice18SpeechQueueCommandO5pauseyA2CmF -->
- `s:13AppLocalVoice18SpeechQueueCommandO5pauseyA2CmF`
<!-- api-symbol: s:13AppLocalVoice18SpeechQueueCommandO6replayyAcA0D6ItemIDV_AA0D13EnqueuePolicyOtcACmF -->
- `s:13AppLocalVoice18SpeechQueueCommandO6replayyAcA0D6ItemIDV_AA0D13EnqueuePolicyOtcACmF`
<!-- api-symbol: s:13AppLocalVoice18SpeechQueueCommandO6resumeyA2CmF -->
- `s:13AppLocalVoice18SpeechQueueCommandO6resumeyA2CmF`
<!-- api-symbol: s:13AppLocalVoice18SpeechQueueCommandO7enqueueyAcA0D11ItemRequestV_AA0D13EnqueuePolicyOtcACmF -->
- `s:13AppLocalVoice18SpeechQueueCommandO7enqueueyAcA0D11ItemRequestV_AA0D13EnqueuePolicyOtcACmF`
<!-- api-symbol: s:13AppLocalVoice19EventDeliveryCursorO -->
- `s:13AppLocalVoice19EventDeliveryCursorO`
<!-- api-symbol: s:13AppLocalVoice19EventDeliveryCursorO11recognitionyAcA20RecognitionSessionIDV_s6UInt64VtcACmF -->
- `s:13AppLocalVoice19EventDeliveryCursorO11recognitionyAcA20RecognitionSessionIDV_s6UInt64VtcACmF`
<!-- api-symbol: s:13AppLocalVoice19EventDeliveryCursorO11speechQueueyAcA12SpeechItemIDV_AA0i8PlaybackK0Vs6UInt64VtcACmF -->
- `s:13AppLocalVoice19EventDeliveryCursorO11speechQueueyAcA12SpeechItemIDV_AA0i8PlaybackK0Vs6UInt64VtcACmF`
<!-- api-symbol: s:13AppLocalVoice19EventDeliveryCursorO14processRuntimeyACs6UInt64V_tcACmF -->
- `s:13AppLocalVoice19EventDeliveryCursorO14processRuntimeyACs6UInt64V_tcACmF`
<!-- api-symbol: s:13AppLocalVoice19ExternalAudioPolicyO -->
- `s:13AppLocalVoice19ExternalAudioPolicyO`
<!-- api-symbol: s:13AppLocalVoice19ExternalAudioPolicyO3mixyA2CmF -->
- `s:13AppLocalVoice19ExternalAudioPolicyO3mixyA2CmF`
<!-- api-symbol: s:13AppLocalVoice19ExternalAudioPolicyO4duckyA2CmF -->
- `s:13AppLocalVoice19ExternalAudioPolicyO4duckyA2CmF`
<!-- api-symbol: s:13AppLocalVoice19ExternalAudioPolicyO6rejectyA2CmF -->
- `s:13AppLocalVoice19ExternalAudioPolicyO6rejectyA2CmF`
<!-- api-symbol: s:13AppLocalVoice19ExternalAudioPolicyO9interruptyA2CmF -->
- `s:13AppLocalVoice19ExternalAudioPolicyO9interruptyA2CmF`
<!-- api-symbol: s:13AppLocalVoice19SpeechControlResultO -->
- `s:13AppLocalVoice19SpeechControlResultO`
<!-- api-symbol: s:13AppLocalVoice19SpeechControlResultO14alreadyAppliedyA2CmF -->
- `s:13AppLocalVoice19SpeechControlResultO14alreadyAppliedyA2CmF`
<!-- api-symbol: s:13AppLocalVoice19SpeechControlResultO16noActivePlaybackyA2CmF -->
- `s:13AppLocalVoice19SpeechControlResultO16noActivePlaybackyA2CmF`
<!-- api-symbol: s:13AppLocalVoice19SpeechControlResultO16providerRejectedyA2CmF -->
- `s:13AppLocalVoice19SpeechControlResultO16providerRejectedyA2CmF`
<!-- api-symbol: s:13AppLocalVoice19SpeechControlResultO7appliedyA2CmF -->
- `s:13AppLocalVoice19SpeechControlResultO7appliedyA2CmF`
<!-- api-symbol: s:13AppLocalVoice19SpeechEnqueuePolicyO -->
- `s:13AppLocalVoice19SpeechEnqueuePolicyO`
<!-- api-symbol: s:13AppLocalVoice19SpeechEnqueuePolicyO10replaceAllyA2CmF -->
- `s:13AppLocalVoice19SpeechEnqueuePolicyO10replaceAllyA2CmF`
<!-- api-symbol: s:13AppLocalVoice19SpeechEnqueuePolicyO14replaceCurrentyA2CmF -->
- `s:13AppLocalVoice19SpeechEnqueuePolicyO14replaceCurrentyA2CmF`
<!-- api-symbol: s:13AppLocalVoice19SpeechEnqueuePolicyO6appendyA2CmF -->
- `s:13AppLocalVoice19SpeechEnqueuePolicyO6appendyA2CmF`
<!-- api-symbol: s:13AppLocalVoice19SpeechEnqueuePolicyO8playNextyA2CmF -->
- `s:13AppLocalVoice19SpeechEnqueuePolicyO8playNextyA2CmF`
<!-- api-symbol: s:13AppLocalVoice19TranscriptTimeRangeV -->
- `s:13AppLocalVoice19TranscriptTimeRangeV`
<!-- api-symbol: s:13AppLocalVoice19TranscriptTimeRangeV15endMillisecondss6UInt64Vvp -->
- `s:13AppLocalVoice19TranscriptTimeRangeV15endMillisecondss6UInt64Vvp`
<!-- api-symbol: s:13AppLocalVoice19TranscriptTimeRangeV17startMilliseconds03endH0ACs6UInt64V_AGtKcfc -->
- `s:13AppLocalVoice19TranscriptTimeRangeV17startMilliseconds03endH0ACs6UInt64V_AGtKcfc`
<!-- api-symbol: s:13AppLocalVoice19TranscriptTimeRangeV17startMillisecondss6UInt64Vvp -->
- `s:13AppLocalVoice19TranscriptTimeRangeV17startMillisecondss6UInt64Vvp`
<!-- api-symbol: s:13AppLocalVoice19TranscriptTimeRangeV20durationMillisecondss6UInt64Vvp -->
- `s:13AppLocalVoice19TranscriptTimeRangeV20durationMillisecondss6UInt64Vvp`
<!-- api-symbol: s:13AppLocalVoice20AudioLifecyclePolicyV -->
- `s:13AppLocalVoice20AudioLifecyclePolicyV`
<!-- api-symbol: s:13AppLocalVoice20AudioLifecyclePolicyV08externalD010background12interruption11routeChange14cleanupFailureAcA08ExternaldF0O_AA0c10BackgroundF0OAA0c12InterruptionF0OAA0c5RoutekF0OAA0c7CleanupmF0Otcfc -->
- `s:13AppLocalVoice20AudioLifecyclePolicyV08externalD010background12interruption11routeChange14cleanupFailureAcA08ExternaldF0O_AA0c10BackgroundF0OAA0c12InterruptionF0OAA0c5RoutekF0OAA0c7CleanupmF0Otcfc`
<!-- api-symbol: s:13AppLocalVoice20AudioLifecyclePolicyV08externalD0AA08ExternaldF0Ovp -->
- `s:13AppLocalVoice20AudioLifecyclePolicyV08externalD0AA08ExternaldF0Ovp`
<!-- api-symbol: s:13AppLocalVoice20AudioLifecyclePolicyV10backgroundAA0c10BackgroundF0Ovp -->
- `s:13AppLocalVoice20AudioLifecyclePolicyV10backgroundAA0c10BackgroundF0Ovp`
<!-- api-symbol: s:13AppLocalVoice20AudioLifecyclePolicyV11routeChangeAA0c5RoutehF0Ovp -->
- `s:13AppLocalVoice20AudioLifecyclePolicyV11routeChangeAA0c5RoutehF0Ovp`
<!-- api-symbol: s:13AppLocalVoice20AudioLifecyclePolicyV12interruptionAA0c12InterruptionF0Ovp -->
- `s:13AppLocalVoice20AudioLifecyclePolicyV12interruptionAA0c12InterruptionF0Ovp`
<!-- api-symbol: s:13AppLocalVoice20AudioLifecyclePolicyV14cleanupFailureAA0c7CleanuphF0Ovp -->
- `s:13AppLocalVoice20AudioLifecyclePolicyV14cleanupFailureAA0c7CleanuphF0Ovp`
<!-- api-symbol: s:13AppLocalVoice20RecognitionEventKindO -->
- `s:13AppLocalVoice20RecognitionEventKindO`
<!-- api-symbol: s:13AppLocalVoice20RecognitionEventKindO10isAcceptedSbvp -->
- `s:13AppLocalVoice20RecognitionEventKindO10isAcceptedSbvp`
<!-- api-symbol: s:13AppLocalVoice20RecognitionEventKindO10isTerminalSbvp -->
- `s:13AppLocalVoice20RecognitionEventKindO10isTerminalSbvp`
<!-- api-symbol: s:13AppLocalVoice20RecognitionEventKindO10transcriptyAcA21TranscriptPublicationOcACmF -->
- `s:13AppLocalVoice20RecognitionEventKindO10transcriptyAcA21TranscriptPublicationOcACmF`
<!-- api-symbol: s:13AppLocalVoice20RecognitionEventKindO12stateChangedyAcA0D12SessionStateOcACmF -->
- `s:13AppLocalVoice20RecognitionEventKindO12stateChangedyAcA0D12SessionStateOcACmF`
<!-- api-symbol: s:13AppLocalVoice20RecognitionEventKindO7outcomeyAcA0D7OutcomeOcACmF -->
- `s:13AppLocalVoice20RecognitionEventKindO7outcomeyAcA0D7OutcomeOcACmF`
<!-- api-symbol: s:13AppLocalVoice20RecognitionEventKindO8acceptedyA2CmF -->
- `s:13AppLocalVoice20RecognitionEventKindO8acceptedyA2CmF`
<!-- api-symbol: s:13AppLocalVoice20RecognitionSessionIDV -->
- `s:13AppLocalVoice20RecognitionSessionIDV`
<!-- api-symbol: s:13AppLocalVoice20RecognitionSessionIDV11descriptionSSvp -->
- `s:13AppLocalVoice20RecognitionSessionIDV11descriptionSSvp`
<!-- api-symbol: s:13AppLocalVoice20RecognitionSessionIDV8rawValue10Foundation4UUIDVvp -->
- `s:13AppLocalVoice20RecognitionSessionIDV8rawValue10Foundation4UUIDVvp`
<!-- api-symbol: s:13AppLocalVoice20SpeechPlaybackResultV -->
- `s:13AppLocalVoice20SpeechPlaybackResultV`
<!-- api-symbol: s:13AppLocalVoice20SpeechPlaybackResultV10playbackIDAA0deH0Vvp -->
- `s:13AppLocalVoice20SpeechPlaybackResultV10playbackIDAA0deH0Vvp`
<!-- api-symbol: s:13AppLocalVoice20SpeechPlaybackResultV20terminalEventOrdinals6UInt64Vvp -->
- `s:13AppLocalVoice20SpeechPlaybackResultV20terminalEventOrdinals6UInt64Vvp`
<!-- api-symbol: s:13AppLocalVoice20SpeechPlaybackResultV6itemIDAA0d4ItemH0Vvp -->
- `s:13AppLocalVoice20SpeechPlaybackResultV6itemIDAA0d4ItemH0Vvp`
<!-- api-symbol: s:13AppLocalVoice20SpeechPlaybackResultV7outcomeAA0dE7OutcomeOvp -->
- `s:13AppLocalVoice20SpeechPlaybackResultV7outcomeAA0dE7OutcomeOvp`
<!-- api-symbol: s:13AppLocalVoice20SpeechQueueEventKindO -->
- `s:13AppLocalVoice20SpeechQueueEventKindO`
<!-- api-symbol: s:13AppLocalVoice20SpeechQueueEventKindO10isTerminalSbvp -->
- `s:13AppLocalVoice20SpeechQueueEventKindO10isTerminalSbvp`
<!-- api-symbol: s:13AppLocalVoice20SpeechQueueEventKindO6pausedyA2CmF -->
- `s:13AppLocalVoice20SpeechQueueEventKindO6pausedyA2CmF`
<!-- api-symbol: s:13AppLocalVoice20SpeechQueueEventKindO7outcomeyAcA0D15PlaybackOutcomeOcACmF -->
- `s:13AppLocalVoice20SpeechQueueEventKindO7outcomeyAcA0D15PlaybackOutcomeOcACmF`
<!-- api-symbol: s:13AppLocalVoice20SpeechQueueEventKindO7resumedyA2CmF -->
- `s:13AppLocalVoice20SpeechQueueEventKindO7resumedyA2CmF`
<!-- api-symbol: s:13AppLocalVoice20SpeechQueueEventKindO7startedyA2CmF -->
- `s:13AppLocalVoice20SpeechQueueEventKindO7startedyA2CmF`
<!-- api-symbol: s:13AppLocalVoice20SpeechQueueEventKindO8acceptedyA2CmF -->
- `s:13AppLocalVoice20SpeechQueueEventKindO8acceptedyA2CmF`
<!-- api-symbol: s:13AppLocalVoice20TranscriptUTF16RangeV -->
- `s:13AppLocalVoice20TranscriptUTF16RangeV`
<!-- api-symbol: s:13AppLocalVoice20TranscriptUTF16RangeV11endLocationSivp -->
- `s:13AppLocalVoice20TranscriptUTF16RangeV11endLocationSivp`
<!-- api-symbol: s:13AppLocalVoice20TranscriptUTF16RangeV6lengthSivp -->
- `s:13AppLocalVoice20TranscriptUTF16RangeV6lengthSivp`
<!-- api-symbol: s:13AppLocalVoice20TranscriptUTF16RangeV8location6lengthACSi_SitKcfc -->
- `s:13AppLocalVoice20TranscriptUTF16RangeV8location6lengthACSi_SitKcfc`
<!-- api-symbol: s:13AppLocalVoice20TranscriptUTF16RangeV8locationSivp -->
- `s:13AppLocalVoice20TranscriptUTF16RangeV8locationSivp`
<!-- api-symbol: s:13AppLocalVoice21RecognitionCapabilityV -->
- `s:13AppLocalVoice21RecognitionCapabilityV`
<!-- api-symbol: s:13AppLocalVoice21RecognitionCapabilityV12availabilityAA0cE12AvailabilityOvp -->
- `s:13AppLocalVoice21RecognitionCapabilityV12availabilityAA0cE12AvailabilityOvp`
<!-- api-symbol: s:13AppLocalVoice21RecognitionCapabilityV14modelReadinessAA0d5ModelG0Ovp -->
- `s:13AppLocalVoice21RecognitionCapabilityV14modelReadinessAA0d5ModelG0Ovp`
<!-- api-symbol: s:13AppLocalVoice21RecognitionCapabilityV14resolvedLocale10Foundation0G0VSgvp -->
- `s:13AppLocalVoice21RecognitionCapabilityV14resolvedLocale10Foundation0G0VSgvp`
<!-- api-symbol: s:13AppLocalVoice21RecognitionCapabilityV15requestedLocale08resolvedG014modelReadiness12availabilityAC10Foundation0G0V_AJSgAA0d5ModelJ0OAA0cE12AvailabilityOtcfc -->
- `s:13AppLocalVoice21RecognitionCapabilityV15requestedLocale08resolvedG014modelReadiness12availabilityAC10Foundation0G0V_AJSgAA0d5ModelJ0OAA0cE12AvailabilityOtcfc`
<!-- api-symbol: s:13AppLocalVoice21RecognitionCapabilityV15requestedLocale10Foundation0G0Vvp -->
- `s:13AppLocalVoice21RecognitionCapabilityV15requestedLocale10Foundation0G0Vvp`
<!-- api-symbol: s:13AppLocalVoice21SpeechPlaybackOutcomeO -->
- `s:13AppLocalVoice21SpeechPlaybackOutcomeO`
<!-- api-symbol: s:13AppLocalVoice21SpeechPlaybackOutcomeO11interruptedyAcA0C18InterruptionReasonOcACmF -->
- `s:13AppLocalVoice21SpeechPlaybackOutcomeO11interruptedyAcA0C18InterruptionReasonOcACmF`
<!-- api-symbol: s:13AppLocalVoice21SpeechPlaybackOutcomeO6failedyAcA0C7FailureVcACmF -->
- `s:13AppLocalVoice21SpeechPlaybackOutcomeO6failedyAcA0C7FailureVcACmF`
<!-- api-symbol: s:13AppLocalVoice21SpeechPlaybackOutcomeO7skippedyA2CmF -->
- `s:13AppLocalVoice21SpeechPlaybackOutcomeO7skippedyA2CmF`
<!-- api-symbol: s:13AppLocalVoice21SpeechPlaybackOutcomeO8finishedyA2CmF -->
- `s:13AppLocalVoice21SpeechPlaybackOutcomeO8finishedyA2CmF`
<!-- api-symbol: s:13AppLocalVoice21SpeechPlaybackOutcomeO9cancelledyAcA0dE18CancellationReasonOcACmF -->
- `s:13AppLocalVoice21SpeechPlaybackOutcomeO9cancelledyAcA0dE18CancellationReasonOcACmF`
<!-- api-symbol: s:13AppLocalVoice21StableTranscriptChunkV -->
- `s:13AppLocalVoice21StableTranscriptChunkV`
<!-- api-symbol: s:13AppLocalVoice21StableTranscriptChunkV10utf16RangeAA0e5UTF16H0Vvp -->
- `s:13AppLocalVoice21StableTranscriptChunkV10utf16RangeAA0e5UTF16H0Vvp`
<!-- api-symbol: s:13AppLocalVoice21StableTranscriptChunkV4textSSvp -->
- `s:13AppLocalVoice21StableTranscriptChunkV4textSSvp`
<!-- api-symbol: s:13AppLocalVoice21StableTranscriptChunkV8sequences6UInt64Vvp -->
- `s:13AppLocalVoice21StableTranscriptChunkV8sequences6UInt64Vvp`
<!-- api-symbol: s:13AppLocalVoice21StableTranscriptChunkV9sessionIDAA018RecognitionSessionH0Vvp -->
- `s:13AppLocalVoice21StableTranscriptChunkV9sessionIDAA018RecognitionSessionH0Vvp`
<!-- api-symbol: s:13AppLocalVoice21StableTranscriptChunkV9timeRangeAA0e4TimeH0VSgvp -->
- `s:13AppLocalVoice21StableTranscriptChunkV9timeRangeAA0e4TimeH0VSgvp`
<!-- api-symbol: s:13AppLocalVoice21TranscriptPublicationO -->
- `s:13AppLocalVoice21TranscriptPublicationO`
<!-- api-symbol: s:13AppLocalVoice21TranscriptPublicationO05finalD0yAcA05FinalD0VcACmF -->
- `s:13AppLocalVoice21TranscriptPublicationO05finalD0yAcA05FinalD0VcACmF`
<!-- api-symbol: s:13AppLocalVoice21TranscriptPublicationO11stableChunkyAcA06StabledG0VcACmF -->
- `s:13AppLocalVoice21TranscriptPublicationO11stableChunkyAcA06StabledG0VcACmF`
<!-- api-symbol: s:13AppLocalVoice21TranscriptPublicationO4kindAA0dE4KindOvp -->
- `s:13AppLocalVoice21TranscriptPublicationO4kindAA0dE4KindOvp`
<!-- api-symbol: s:13AppLocalVoice21TranscriptPublicationO7previewyAcA0D7PreviewVcACmF -->
- `s:13AppLocalVoice21TranscriptPublicationO7previewyAcA0D7PreviewVcACmF`
<!-- api-symbol: s:13AppLocalVoice21TranscriptPublicationO9sessionIDAA018RecognitionSessionG0Vvp -->
- `s:13AppLocalVoice21TranscriptPublicationO9sessionIDAA018RecognitionSessionG0Vvp`
<!-- api-symbol: s:13AppLocalVoice23RecognitionSessionStateO -->
- `s:13AppLocalVoice23RecognitionSessionStateO`
<!-- api-symbol: s:13AppLocalVoice23RecognitionSessionStateO10finalizingyA2CmF -->
- `s:13AppLocalVoice23RecognitionSessionStateO10finalizingyA2CmF`
<!-- api-symbol: s:13AppLocalVoice23RecognitionSessionStateO9listeningyA2CmF -->
- `s:13AppLocalVoice23RecognitionSessionStateO9listeningyA2CmF`
<!-- api-symbol: s:13AppLocalVoice23RecognitionSessionStateO9preparingyA2CmF -->
- `s:13AppLocalVoice23RecognitionSessionStateO9preparingyA2CmF`
<!-- api-symbol: s:13AppLocalVoice24SpeechPlaybackAcceptanceV -->
- `s:13AppLocalVoice24SpeechPlaybackAcceptanceV`
<!-- api-symbol: s:13AppLocalVoice24SpeechPlaybackAcceptanceV10playbackIDAA0deH0Vvp -->
- `s:13AppLocalVoice24SpeechPlaybackAcceptanceV10playbackIDAA0deH0Vvp`
<!-- api-symbol: s:13AppLocalVoice24SpeechPlaybackAcceptanceV20acceptedEventOrdinals6UInt64Vvp -->
- `s:13AppLocalVoice24SpeechPlaybackAcceptanceV20acceptedEventOrdinals6UInt64Vvp`
<!-- api-symbol: s:13AppLocalVoice24SpeechPlaybackAcceptanceV6itemIDAA0d4ItemH0Vvp -->
- `s:13AppLocalVoice24SpeechPlaybackAcceptanceV6itemIDAA0d4ItemH0Vvp`
<!-- api-symbol: s:13AppLocalVoice24SpeechQueueConfigurationV -->
- `s:13AppLocalVoice24SpeechQueueConfigurationV`
<!-- api-symbol: s:13AppLocalVoice24SpeechQueueConfigurationV11initialModeAA0deH0Ovp -->
- `s:13AppLocalVoice24SpeechQueueConfigurationV11initialModeAA0deH0Ovp`
<!-- api-symbol: s:13AppLocalVoice24SpeechQueueConfigurationV14overflowPolicyAA0de8OverflowH0Ovp -->
- `s:13AppLocalVoice24SpeechQueueConfigurationV14overflowPolicyAA0de8OverflowH0Ovp`
<!-- api-symbol: s:13AppLocalVoice24SpeechQueueConfigurationV23maximumPendingItemCount0g13ReplayHistoryiJ00gH15TextUTF16Length0gklmnO014overflowPolicy11initialModeACSi_S3iAA0de8OverflowQ0OAA0deS0OtKcfc -->
- `s:13AppLocalVoice24SpeechQueueConfigurationV23maximumPendingItemCount0g13ReplayHistoryiJ00gH15TextUTF16Length0gklmnO014overflowPolicy11initialModeACSi_S3iAA0de8OverflowQ0OAA0deS0OtKcfc`
<!-- api-symbol: s:13AppLocalVoice24SpeechQueueConfigurationV23maximumPendingItemCountSivp -->
- `s:13AppLocalVoice24SpeechQueueConfigurationV23maximumPendingItemCountSivp`
<!-- api-symbol: s:13AppLocalVoice24SpeechQueueConfigurationV23maximumPendingItemCountSivpZ -->
- `s:13AppLocalVoice24SpeechQueueConfigurationV23maximumPendingItemCountSivpZ`
<!-- api-symbol: s:13AppLocalVoice24SpeechQueueConfigurationV23minimumPendingItemCountSivpZ -->
- `s:13AppLocalVoice24SpeechQueueConfigurationV23minimumPendingItemCountSivpZ`
<!-- api-symbol: s:13AppLocalVoice24SpeechQueueConfigurationV29maximumPendingTextUTF16LengthSivp -->
- `s:13AppLocalVoice24SpeechQueueConfigurationV29maximumPendingTextUTF16LengthSivp`
<!-- api-symbol: s:13AppLocalVoice24SpeechQueueConfigurationV29maximumPendingTextUTF16LengthSivpZ -->
- `s:13AppLocalVoice24SpeechQueueConfigurationV29maximumPendingTextUTF16LengthSivpZ`
<!-- api-symbol: s:13AppLocalVoice24SpeechQueueConfigurationV29minimumPendingTextUTF16LengthSivpZ -->
- `s:13AppLocalVoice24SpeechQueueConfigurationV29minimumPendingTextUTF16LengthSivpZ`
<!-- api-symbol: s:13AppLocalVoice24SpeechQueueConfigurationV29maximumReplayHistoryItemCountSivp -->
- `s:13AppLocalVoice24SpeechQueueConfigurationV29maximumReplayHistoryItemCountSivp`
<!-- api-symbol: s:13AppLocalVoice24SpeechQueueConfigurationV29maximumReplayHistoryItemCountSivpZ -->
- `s:13AppLocalVoice24SpeechQueueConfigurationV29maximumReplayHistoryItemCountSivpZ`
<!-- api-symbol: s:13AppLocalVoice24SpeechQueueConfigurationV29minimumReplayHistoryItemCountSivpZ -->
- `s:13AppLocalVoice24SpeechQueueConfigurationV29minimumReplayHistoryItemCountSivpZ`
<!-- api-symbol: s:13AppLocalVoice24SpeechQueueConfigurationV30defaultMaximumPendingItemCountSivpZ -->
- `s:13AppLocalVoice24SpeechQueueConfigurationV30defaultMaximumPendingItemCountSivpZ`
<!-- api-symbol: s:13AppLocalVoice24SpeechQueueConfigurationV36defaultMaximumReplayHistoryItemCountSivpZ -->
- `s:13AppLocalVoice24SpeechQueueConfigurationV36defaultMaximumReplayHistoryItemCountSivpZ`
<!-- api-symbol: s:13AppLocalVoice24SpeechQueueConfigurationV35maximumReplayHistoryTextUTF16LengthSivp -->
- `s:13AppLocalVoice24SpeechQueueConfigurationV35maximumReplayHistoryTextUTF16LengthSivp`
<!-- api-symbol: s:13AppLocalVoice24SpeechQueueConfigurationV35maximumReplayHistoryTextUTF16LengthSivpZ -->
- `s:13AppLocalVoice24SpeechQueueConfigurationV35maximumReplayHistoryTextUTF16LengthSivpZ`
<!-- api-symbol: s:13AppLocalVoice24SpeechQueueConfigurationV35minimumReplayHistoryTextUTF16LengthSivpZ -->
- `s:13AppLocalVoice24SpeechQueueConfigurationV35minimumReplayHistoryTextUTF16LengthSivpZ`
<!-- api-symbol: s:13AppLocalVoice24SpeechQueueConfigurationV36defaultMaximumPendingTextUTF16LengthSivpZ -->
- `s:13AppLocalVoice24SpeechQueueConfigurationV36defaultMaximumPendingTextUTF16LengthSivpZ`
<!-- api-symbol: s:13AppLocalVoice24SpeechQueueConfigurationV42defaultMaximumReplayHistoryTextUTF16LengthSivpZ -->
- `s:13AppLocalVoice24SpeechQueueConfigurationV42defaultMaximumReplayHistoryTextUTF16LengthSivpZ`
<!-- api-symbol: s:13AppLocalVoice24SpeechQueueConfigurationVACycfc -->
- `s:13AppLocalVoice24SpeechQueueConfigurationVACycfc`
<!-- api-symbol: s:13AppLocalVoice25RecognitionModelReadinessO -->
- `s:13AppLocalVoice25RecognitionModelReadinessO`
<!-- api-symbol: s:13AppLocalVoice25RecognitionModelReadinessO11unavailableyA2CmF -->
- `s:13AppLocalVoice25RecognitionModelReadinessO11unavailableyA2CmF`
<!-- api-symbol: s:13AppLocalVoice25RecognitionModelReadinessO12notInstalledyACSb_tcACmF -->
- `s:13AppLocalVoice25RecognitionModelReadinessO12notInstalledyACSb_tcACmF`
<!-- api-symbol: s:13AppLocalVoice25RecognitionModelReadinessO7unknownyA2CmF -->
- `s:13AppLocalVoice25RecognitionModelReadinessO7unknownyA2CmF`
<!-- api-symbol: s:13AppLocalVoice25RecognitionModelReadinessO9installedyA2CmF -->
- `s:13AppLocalVoice25RecognitionModelReadinessO9installedyA2CmF`
<!-- api-symbol: s:13AppLocalVoice25SpeechQueueOverflowPolicyO -->
- `s:13AppLocalVoice25SpeechQueueOverflowPolicyO`
<!-- api-symbol: s:13AppLocalVoice25SpeechQueueOverflowPolicyO17dropOldestPendingyA2CmF -->
- `s:13AppLocalVoice25SpeechQueueOverflowPolicyO17dropOldestPendingyA2CmF`
<!-- api-symbol: s:13AppLocalVoice25SpeechQueueOverflowPolicyO9rejectNewyA2CmF -->
- `s:13AppLocalVoice25SpeechQueueOverflowPolicyO9rejectNewyA2CmF`
<!-- api-symbol: s:13AppLocalVoice25TranscriptPublicationKindO -->
- `s:13AppLocalVoice25TranscriptPublicationKindO`
<!-- api-symbol: s:13AppLocalVoice25TranscriptPublicationKindO05finalD0yA2CmF -->
- `s:13AppLocalVoice25TranscriptPublicationKindO05finalD0yA2CmF`
<!-- api-symbol: s:13AppLocalVoice25TranscriptPublicationKindO11stableChunkyA2CmF -->
- `s:13AppLocalVoice25TranscriptPublicationKindO11stableChunkyA2CmF`
<!-- api-symbol: s:13AppLocalVoice25TranscriptPublicationKindO7previewyA2CmF -->
- `s:13AppLocalVoice25TranscriptPublicationKindO7previewyA2CmF`
<!-- api-symbol: s:13AppLocalVoice27TranscriptPublicationPolicyO -->
- `s:13AppLocalVoice27TranscriptPublicationPolicyO`
<!-- api-symbol: s:13AppLocalVoice27TranscriptPublicationPolicyO12stableChunksyAcA011StableChunkF0VcACmF -->
- `s:13AppLocalVoice27TranscriptPublicationPolicyO12stableChunksyAcA011StableChunkF0VcACmF`
<!-- api-symbol: s:13AppLocalVoice27TranscriptPublicationPolicyO15previewAndFinalyA2CmF -->
- `s:13AppLocalVoice27TranscriptPublicationPolicyO15previewAndFinalyA2CmF`
<!-- api-symbol: s:13AppLocalVoice27TranscriptPublicationPolicyO9finalOnlyyA2CmF -->
- `s:13AppLocalVoice27TranscriptPublicationPolicyO9finalOnlyyA2CmF`
<!-- api-symbol: s:13AppLocalVoice28RecognitionSessionAcceptanceV -->
- `s:13AppLocalVoice28RecognitionSessionAcceptanceV`
<!-- api-symbol: s:13AppLocalVoice28RecognitionSessionAcceptanceV20acceptedEventOrdinals6UInt64Vvp -->
- `s:13AppLocalVoice28RecognitionSessionAcceptanceV20acceptedEventOrdinals6UInt64Vvp`
<!-- api-symbol: s:13AppLocalVoice28RecognitionSessionAcceptanceV9sessionIDAA0deH0Vvp -->
- `s:13AppLocalVoice28RecognitionSessionAcceptanceV9sessionIDAA0deH0Vvp`
<!-- api-symbol: s:13AppLocalVoice30RecognitionEventDeliveryLimitsO -->
- `s:13AppLocalVoice30RecognitionEventDeliveryLimitsO`
<!-- api-symbol: s:13AppLocalVoice30RecognitionEventDeliveryLimitsO014maximumDurableE18CountPerSubscriberSivpZ -->
- `s:13AppLocalVoice30RecognitionEventDeliveryLimitsO014maximumDurableE18CountPerSubscriberSivpZ`
<!-- api-symbol: s:13AppLocalVoice30RecognitionEventDeliveryLimitsO22maximumSubscriberCountSivpZ -->
- `s:13AppLocalVoice30RecognitionEventDeliveryLimitsO22maximumSubscriberCountSivpZ`
<!-- api-symbol: s:13AppLocalVoice30RecognitionEventDeliveryLimitsO36maximumNonPreviewEventsPerSubscriberSivpZ -->
- `s:13AppLocalVoice30RecognitionEventDeliveryLimitsO36maximumNonPreviewEventsPerSubscriberSivpZ`
<!-- api-symbol: s:13AppLocalVoice31RecognitionSessionConfigurationV -->
- `s:13AppLocalVoice31RecognitionSessionConfigurationV`
<!-- api-symbol: s:13AppLocalVoice31RecognitionSessionConfigurationV11recognitionAA0dF0Vvp -->
- `s:13AppLocalVoice31RecognitionSessionConfigurationV11recognitionAA0dF0Vvp`
<!-- api-symbol: s:13AppLocalVoice31RecognitionSessionConfigurationV15lifecyclePolicyAA014AudioLifecycleH0Vvp -->
- `s:13AppLocalVoice31RecognitionSessionConfigurationV15lifecyclePolicyAA014AudioLifecycleH0Vvp`
<!-- api-symbol: s:13AppLocalVoice31RecognitionSessionConfigurationV17publicationPolicyAA021TranscriptPublicationH0Ovp -->
- `s:13AppLocalVoice31RecognitionSessionConfigurationV17publicationPolicyAA021TranscriptPublicationH0Ovp`
<!-- api-symbol: s:13AppLocalVoice32SpeechPlaybackCancellationReasonO -->
- `s:13AppLocalVoice32SpeechPlaybackCancellationReasonO`
<!-- api-symbol: s:13AppLocalVoice32SpeechPlaybackCancellationReasonO14closeRequestedyA2CmF -->
- `s:13AppLocalVoice32SpeechPlaybackCancellationReasonO14closeRequestedyA2CmF`
<!-- api-symbol: s:13AppLocalVoice32SpeechPlaybackCancellationReasonO23supersededByRecognitionyA2CmF -->
- `s:13AppLocalVoice32SpeechPlaybackCancellationReasonO23supersededByRecognitionyA2CmF`
<!-- api-symbol: s:13AppLocalVoice32SpeechPlaybackCancellationReasonO7clearedyA2CmF -->
- `s:13AppLocalVoice32SpeechPlaybackCancellationReasonO7clearedyA2CmF`
<!-- api-symbol: s:13AppLocalVoice32SpeechPlaybackCancellationReasonO7stoppedyA2CmF -->
- `s:13AppLocalVoice32SpeechPlaybackCancellationReasonO7stoppedyA2CmF`
<!-- api-symbol: s:13AppLocalVoice32SpeechPlaybackCancellationReasonO8overflowyA2CmF -->
- `s:13AppLocalVoice32SpeechPlaybackCancellationReasonO8overflowyA2CmF`
<!-- api-symbol: s:13AppLocalVoice32SpeechPlaybackCancellationReasonO8replacedyA2CmF -->
- `s:13AppLocalVoice32SpeechPlaybackCancellationReasonO8replacedyA2CmF`
<!-- api-symbol: s:13AppLocalVoiceAAC11voiceEventsScsyAA0c11EventStreamF0Os5Error_pGyYaF -->
- `s:13AppLocalVoiceAAC11voiceEventsScsyAA0c11EventStreamF0Os5Error_pGyYaF`
<!-- api-symbol: s:13AppLocalVoiceAAC12replaySpeech6itemID6policyAA0E18PlaybackAcceptanceVAA0e4ItemG0V_AA0E13EnqueuePolicyOtYaKF -->
- `s:13AppLocalVoiceAAC12replaySpeech6itemID6policyAA0E18PlaybackAcceptanceVAA0e4ItemG0V_AA0E13EnqueuePolicyOtYaKF`
<!-- api-symbol: s:13AppLocalVoiceAAC12startSession13configurationAA011RecognitionE10AcceptanceVAA0gE13ConfigurationV_tYaKF -->
- `s:13AppLocalVoiceAAC12startSession13configurationAA011RecognitionE10AcceptanceVAA0gE13ConfigurationV_tYaKF`
<!-- api-symbol: s:13AppLocalVoiceAAC13cancelSession2idyAA011RecognitionE2IDV_tYaF -->
- `s:13AppLocalVoiceAAC13cancelSession2idyAA011RecognitionE2IDV_tYaF`
<!-- api-symbol: s:13AppLocalVoiceAAC13enqueueSpeech_8priority13configuration6policyAA0E18PlaybackAcceptanceVSS_AA0E8PriorityOAA0E13ConfigurationVAA0E13EnqueuePolicyOtYaKF -->
- `s:13AppLocalVoiceAAC13enqueueSpeech_8priority13configuration6policyAA0E18PlaybackAcceptanceVSS_AA0E8PriorityOAA0E13ConfigurationVAA0E13EnqueuePolicyOtYaKF`
<!-- api-symbol: s:13AppLocalVoiceAAC13finishSession2idAA15FinalTranscriptVAA011RecognitionE2IDV_tYaKF -->
- `s:13AppLocalVoiceAAC13finishSession2idAA15FinalTranscriptVAA011RecognitionE2IDV_tYaKF`
<!-- api-symbol: s:13AppLocalVoiceAAC15stopSpeechQueueSayAA0E14PlaybackResultVGyYaF -->
- `s:13AppLocalVoiceAAC15stopSpeechQueueSayAA0E14PlaybackResultVGyYaF`
<!-- api-symbol: s:13AppLocalVoiceAAC23stopAndClearSpeechQueueSayAA0G14PlaybackResultVGyYaF -->
- `stopAndClearSpeechQueue()` (swift.method)
<!-- api-symbol: s:13AppLocalVoiceAAC16pauseSpeechQueueAA0E13ControlResultOyYaF -->
- `s:13AppLocalVoiceAAC16pauseSpeechQueueAA0E13ControlResultOyYaF`
<!-- api-symbol: s:13AppLocalVoiceAAC17recognitionEventsScsyAA16RecognitionEventVs5Error_pGyYaF -->
- `s:13AppLocalVoiceAAC17recognitionEventsScsyAA16RecognitionEventVs5Error_pGyYaF`
<!-- api-symbol: s:13AppLocalVoiceAAC17resumeSpeechQueueAA0E13ControlResultOyYaF -->
- `s:13AppLocalVoiceAAC17resumeSpeechQueueAA0E13ControlResultOyYaF`



## Newly added API evidence

<!-- api-symbol: s:13AppLocalVoiceAAC16speakImmediately_13configurationAA24SpeechPlaybackAcceptanceVSS_AA0G13ConfigurationVtYaKF -->
- `s:13AppLocalVoiceAAC16speakImmediately_13configurationAA24SpeechPlaybackAcceptanceVSS_AA0G13ConfigurationVtYaKF`

<!-- api-symbol: s:13AppLocalVoice0C17DiagnosticsStreama -->
- `s:13AppLocalVoice0C17DiagnosticsStreama`
<!-- api-symbol: s:13AppLocalVoiceAAC11diagnosticsScSyAA0C10DiagnosticVGyF -->
- `s:13AppLocalVoiceAAC11diagnosticsScSyAA0C10DiagnosticVGyF`

<!-- api-symbol: s:13AppLocalVoice0C10DiagnosticV -->
- `s:13AppLocalVoice0C10DiagnosticV`
<!-- api-symbol: s:13AppLocalVoice0C10DiagnosticV10routeClassAA0c5RouteF0Ovp -->
- `s:13AppLocalVoice0C10DiagnosticV10routeClassAA0c5RouteF0Ovp`
<!-- api-symbol: s:13AppLocalVoice0C10DiagnosticV11operationID0E05phase5state13errorCategory10routeClass19durationNanosecondsAC10Foundation4UUIDV_AA0cD9OperationOAA0cD5PhaseOAA0C5StateOAA0c5ErrorJ0OSgAA0c5RouteL0Os6UInt64Vtcfc -->
- `s:13AppLocalVoice0C10DiagnosticV11operationID0E05phase5state13errorCategory10routeClass19durationNanosecondsAC10Foundation4UUIDV_AA0cD9OperationOAA0cD5PhaseOAA0C5StateOAA0c5ErrorJ0OSgAA0c5RouteL0Os6UInt64Vtcfc`
<!-- api-symbol: s:13AppLocalVoice0C10DiagnosticV11operationID10Foundation4UUIDVvp -->
- `s:13AppLocalVoice0C10DiagnosticV11operationID10Foundation4UUIDVvp`
<!-- api-symbol: s:13AppLocalVoice0C10DiagnosticV13errorCategoryAA0c5ErrorF0OSgvp -->
- `s:13AppLocalVoice0C10DiagnosticV13errorCategoryAA0c5ErrorF0OSgvp`
<!-- api-symbol: s:13AppLocalVoice0C10DiagnosticV19durationNanosecondss6UInt64Vvp -->
- `s:13AppLocalVoice0C10DiagnosticV19durationNanosecondss6UInt64Vvp`
<!-- api-symbol: s:13AppLocalVoice0C10DiagnosticV5phaseAA0cD5PhaseOvp -->
- `s:13AppLocalVoice0C10DiagnosticV5phaseAA0cD5PhaseOvp`
<!-- api-symbol: s:13AppLocalVoice0C10DiagnosticV5stateAA0C5StateOvp -->
- `s:13AppLocalVoice0C10DiagnosticV5stateAA0C5StateOvp`
<!-- api-symbol: s:13AppLocalVoice0C10DiagnosticV9operationAA0cD9OperationOvp -->
- `s:13AppLocalVoice0C10DiagnosticV9operationAA0cD9OperationOvp`
<!-- api-symbol: s:13AppLocalVoice0C10RouteClassO -->
- `s:13AppLocalVoice0C10RouteClassO`
<!-- api-symbol: s:13AppLocalVoice0C10RouteClassO14builtInSpeakeryA2CmF -->
- `s:13AppLocalVoice0C10RouteClassO14builtInSpeakeryA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C10RouteClassO15builtInReceiveryA2CmF -->
- `s:13AppLocalVoice0C10RouteClassO15builtInReceiveryA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C10RouteClassO3caryA2CmF -->
- `s:13AppLocalVoice0C10RouteClassO3caryA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C10RouteClassO3usbyA2CmF -->
- `s:13AppLocalVoice0C10RouteClassO3usbyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C10RouteClassO5otheryA2CmF -->
- `s:13AppLocalVoice0C10RouteClassO5otheryA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C10RouteClassO5wiredyA2CmF -->
- `s:13AppLocalVoice0C10RouteClassO5wiredyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C10RouteClassO7airPlayyA2CmF -->
- `s:13AppLocalVoice0C10RouteClassO7airPlayyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C10RouteClassO7unknownyA2CmF -->
- `s:13AppLocalVoice0C10RouteClassO7unknownyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C10RouteClassO9bluetoothyA2CmF -->
- `s:13AppLocalVoice0C10RouteClassO9bluetoothyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C15DiagnosticPhaseO -->
- `s:13AppLocalVoice0C15DiagnosticPhaseO`
<!-- api-symbol: s:13AppLocalVoice0C15DiagnosticPhaseO6failedyA2CmF -->
- `s:13AppLocalVoice0C15DiagnosticPhaseO6failedyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C15DiagnosticPhaseO7startedyA2CmF -->
- `s:13AppLocalVoice0C15DiagnosticPhaseO7startedyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C15DiagnosticPhaseO9cancelledyA2CmF -->
- `s:13AppLocalVoice0C15DiagnosticPhaseO9cancelledyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C15DiagnosticPhaseO9completedyA2CmF -->
- `s:13AppLocalVoice0C15DiagnosticPhaseO9completedyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C15DiagnosticsSinka -->
- `s:13AppLocalVoice0C15DiagnosticsSinka`
<!-- api-symbol: s:13AppLocalVoice0C19DiagnosticOperationO -->
- `s:13AppLocalVoice0C19DiagnosticOperationO`
<!-- api-symbol: s:13AppLocalVoice0C19DiagnosticOperationO5closeyA2CmF -->
- `s:13AppLocalVoice0C19DiagnosticOperationO5closeyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C19DiagnosticOperationO8speakingyA2CmF -->
- `s:13AppLocalVoice0C19DiagnosticOperationO8speakingyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C19DiagnosticOperationO9listeningyA2CmF -->
- `s:13AppLocalVoice0C19DiagnosticOperationO9listeningyA2CmF`
<!-- api-symbol: s:13AppLocalVoiceAAC18queueConfiguration15lifecyclePolicy11diagnosticsAbA011SpeechQueueE0V_AA014AudioLifecycleG0VyAA0C10DiagnosticVScMYccSgtcfc -->
- `s:13AppLocalVoiceAAC18queueConfiguration15lifecyclePolicy11diagnosticsAbA011SpeechQueueE0V_AA014AudioLifecycleG0VyAA0C10DiagnosticVScMYccSgtcfc`

<!-- api-symbol: s:13AppLocalVoice0c11EventStreamD0O8snapshotyAcA0C15RuntimeSnapshotVcACmF -->
- `VoiceEventStreamEvent.snapshot(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoiceAAC18capabilitySnapshot3forAA0c10CapabilityE0V10Foundation6LocaleV_tYaF -->
- `AppLocalVoice.capabilitySnapshot(for:)` (swift.method)
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO23queueTextBudgetExceededyA2CmF -->
- `s:13AppLocalVoice0C13ErrorCategoryO23queueTextBudgetExceededyA2CmF`
<!-- api-symbol: s:13AppLocalVoice0C15RuntimeSnapshotV -->
- `s:13AppLocalVoice0C15RuntimeSnapshotV`
<!-- api-symbol: s:13AppLocalVoice0C15RuntimeSnapshotV10generations6UInt64Vvp -->
- `s:13AppLocalVoice0C15RuntimeSnapshotV10generations6UInt64Vvp`
<!-- api-symbol: s:13AppLocalVoice0C15RuntimeSnapshotV11recognitionAA0c11RecognitionE0VSgvp -->
- `s:13AppLocalVoice0C15RuntimeSnapshotV11recognitionAA0c11RecognitionE0VSgvp`
<!-- api-symbol: s:13AppLocalVoice0C15RuntimeSnapshotV13recoveryStateAA0c8RecoveryG0Ovp -->
- `s:13AppLocalVoice0C15RuntimeSnapshotV13recoveryStateAA0c8RecoveryG0Ovp`
<!-- api-symbol: s:13AppLocalVoice0C15RuntimeSnapshotV5queueAA011SpeechQueueE0Vvp -->
- `s:13AppLocalVoice0C15RuntimeSnapshotV5queueAA011SpeechQueueE0Vvp`
<!-- api-symbol: s:13AppLocalVoice0C15RuntimeSnapshotV5state13recoveryState11recognition5queue10generationAcA0cH0O_AA0c8RecoveryH0OAA0c11RecognitionE0VSgAA011SpeechQueueE0Vs6UInt64Vtcfc -->
- `s:13AppLocalVoice0C15RuntimeSnapshotV5state13recoveryState11recognition5queue10generationAcA0cH0O_AA0c8RecoveryH0OAA0c11RecognitionE0VSgAA011SpeechQueueE0Vs6UInt64Vtcfc`
<!-- api-symbol: s:13AppLocalVoice0C15RuntimeSnapshotV5stateAA0C5StateOvp -->
- `s:13AppLocalVoice0C15RuntimeSnapshotV5stateAA0C5StateOvp`
<!-- api-symbol: s:13AppLocalVoice0C19RecognitionSnapshotV -->
- `s:13AppLocalVoice0C19RecognitionSnapshotV`
<!-- api-symbol: s:13AppLocalVoice0C19RecognitionSnapshotV13latestPreviewAA010TranscriptG0VSgvp -->
- `s:13AppLocalVoice0C19RecognitionSnapshotV13latestPreviewAA010TranscriptG0VSgvp`
<!-- api-symbol: s:13AppLocalVoice0C19RecognitionSnapshotV5stateAA0D12SessionStateOvp -->
- `s:13AppLocalVoice0C19RecognitionSnapshotV5stateAA0D12SessionStateOvp`
<!-- api-symbol: s:13AppLocalVoice0C19RecognitionSnapshotV9sessionID5state13latestPreviewAcA0d7SessionG0V_AA0dK5StateOAA010TranscriptJ0VSgtcfc -->
- `s:13AppLocalVoice0C19RecognitionSnapshotV9sessionID5state13latestPreviewAcA0d7SessionG0V_AA0dK5StateOAA010TranscriptJ0VSgtcfc`
<!-- api-symbol: s:13AppLocalVoice0C19RecognitionSnapshotV9sessionIDAA0d7SessionG0Vvp -->
- `s:13AppLocalVoice0C19RecognitionSnapshotV9sessionIDAA0d7SessionG0Vvp`
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO23queueTextBudgetExceededyACSi_tcACmF -->
- `s:13AppLocalVoice0C5ErrorO23queueTextBudgetExceededyACSi_tcACmF`
<!-- api-symbol: s:13AppLocalVoice19SpeechQueueSnapshotV -->
- `s:13AppLocalVoice19SpeechQueueSnapshotV`
<!-- api-symbol: s:13AppLocalVoice19SpeechQueueSnapshotV10generations6UInt64Vvp -->
- `s:13AppLocalVoice19SpeechQueueSnapshotV10generations6UInt64Vvp`
<!-- api-symbol: s:13AppLocalVoice19SpeechQueueSnapshotV15retainedItemIDsSayAA0dH2IDVGvp -->
- `s:13AppLocalVoice19SpeechQueueSnapshotV15retainedItemIDsSayAA0dH2IDVGvp`
<!-- api-symbol: s:13AppLocalVoice19SpeechQueueSnapshotV4modeAA0dE4ModeOvp -->
- `s:13AppLocalVoice19SpeechQueueSnapshotV4modeAA0dE4ModeOvp`
<!-- api-symbol: s:13AppLocalVoice19SpeechQueueSnapshotV6activeAA0de7AttemptF0VSgvp -->
- `s:13AppLocalVoice19SpeechQueueSnapshotV6activeAA0de7AttemptF0VSgvp`
<!-- api-symbol: s:13AppLocalVoice19SpeechQueueSnapshotV7pendingSayAA0de7AttemptF0VGvp -->
- `s:13AppLocalVoice19SpeechQueueSnapshotV7pendingSayAA0de7AttemptF0VGvp`
<!-- api-symbol: s:13AppLocalVoice26SpeechQueueAttemptSnapshotV -->
- `s:13AppLocalVoice26SpeechQueueAttemptSnapshotV`
<!-- api-symbol: s:13AppLocalVoice26SpeechQueueAttemptSnapshotV10playbackIDAA0d8PlaybackI0Vvp -->
- `s:13AppLocalVoice26SpeechQueueAttemptSnapshotV10playbackIDAA0d8PlaybackI0Vvp`
<!-- api-symbol: s:13AppLocalVoice26SpeechQueueAttemptSnapshotV15textUTF16LengthSivp -->
- `s:13AppLocalVoice26SpeechQueueAttemptSnapshotV15textUTF16LengthSivp`
<!-- api-symbol: s:13AppLocalVoice26SpeechQueueAttemptSnapshotV6itemIDAA0d4ItemI0Vvp -->
- `s:13AppLocalVoice26SpeechQueueAttemptSnapshotV6itemIDAA0d4ItemI0Vvp`
<!-- api-symbol: s:13AppLocalVoice26SpeechQueueAttemptSnapshotV8priorityAA0D8PriorityOvp -->
- `s:13AppLocalVoice26SpeechQueueAttemptSnapshotV8priorityAA0D8PriorityOvp`
<!-- api-symbol: s:13AppLocalVoiceAAC15runtimeSnapshotAA0c7RuntimeE0VyYaF -->
- `s:13AppLocalVoiceAAC15runtimeSnapshotAA0c7RuntimeE0VyYaF`
<!-- api-symbol: s:13AppLocalVoiceAAC21waitForSpeechPlayback2idAA0fG6ResultVAA0fG2IDV_tYaKF -->
- `s:13AppLocalVoiceAAC21waitForSpeechPlayback2idAA0fG6ResultVAA0fG2IDV_tYaKF`
<!-- api-symbol: s:13AppLocalVoice0c11EventStreamD0O14speechProgressyAcA014SpeechPlaybackG0VcACmF -->
- `VoiceEventStreamEvent.speechProgress(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice22SpeechPlaybackProgressV -->
- `SpeechPlaybackProgress` (swift.struct)
<!-- api-symbol: s:13AppLocalVoice22SpeechPlaybackProgressV10playbackIDAA0deH0Vvp -->
- `SpeechPlaybackProgress.playbackID` (swift.property)
<!-- api-symbol: s:13AppLocalVoice22SpeechPlaybackProgressV10utf16RangeSnySiGvp -->
- `SpeechPlaybackProgress.utf16Range` (swift.property)
<!-- api-symbol: s:13AppLocalVoice22SpeechPlaybackProgressV6itemID08playbackH010utf16RangeAcA0d4ItemH0V_AA0deH0VSnySiGtcfc -->
- `SpeechPlaybackProgress.init(itemID:playbackID:utf16Range:)` (swift.init)
<!-- api-symbol: s:13AppLocalVoice22SpeechPlaybackProgressV6itemIDAA0d4ItemH0Vvp -->
- `SpeechPlaybackProgress.itemID` (swift.property)
<!-- api-symbol: s:13AppLocalVoice0C17TerminationReasonO20durationLimitReachedyA2CmF -->
- `VoiceTerminationReason.durationLimitReached` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice18RecognitionOutcomeO20durationLimitReachedyA2CmF -->
- `RecognitionOutcome.durationLimitReached` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice28RecognitionPreparationResultV -->
- `RecognitionPreparationResult` (swift.struct)
<!-- api-symbol: s:13AppLocalVoice28RecognitionPreparationResultV14installedModelSbvp -->
- `RecognitionPreparationResult.installedModel` (swift.property)
<!-- api-symbol: s:13AppLocalVoice28RecognitionPreparationResultV18capabilitySnapshot14installedModelAcA0c10CapabilityH0V_Sbtcfc -->
- `RecognitionPreparationResult.init(capabilitySnapshot:installedModel:)` (swift.init)
<!-- api-symbol: s:13AppLocalVoice28RecognitionPreparationResultV18capabilitySnapshotAA0c10CapabilityH0Vvp -->
- `RecognitionPreparationResult.capabilitySnapshot` (swift.property)
<!-- api-symbol: s:13AppLocalVoice27RecognitionPreparationPhaseO -->
- `RecognitionPreparationPhase` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice27RecognitionPreparationPhaseO17checkingReadinessyA2CmF -->
- `RecognitionPreparationPhase.checkingReadiness` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice27RecognitionPreparationPhaseO16downloadingModelyAcA0dH16DownloadProgressOcACmF -->
- `RecognitionPreparationPhase.downloadingModel(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice27RecognitionPreparationPhaseO14modelInstalledyA2CmF -->
- `RecognitionPreparationPhase.modelInstalled` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice32RecognitionModelDownloadProgressO -->
- `RecognitionModelDownloadProgress` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice32RecognitionModelDownloadProgressO13indeterminateyA2CmF -->
- `RecognitionModelDownloadProgress.indeterminate` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice32RecognitionModelDownloadProgressO17fractionCompletedyACSdcACmF -->
- `RecognitionModelDownloadProgress.fractionCompleted(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice37RecognitionPreparationProgressHandlera -->
- `RecognitionPreparationProgressHandler` (swift.typealias)
<!-- api-symbol: s:13AppLocalVoice0C17ProviderErrorCodeV -->
- `VoiceProviderErrorCode` (swift.struct)
<!-- api-symbol: s:13AppLocalVoice0C17ProviderErrorCodeV6domainSSvp -->
- `VoiceProviderErrorCode.domain` (swift.property)
<!-- api-symbol: s:13AppLocalVoice0C17ProviderErrorCodeV4codeSivp -->
- `VoiceProviderErrorCode.code` (swift.property)
<!-- api-symbol: s:13AppLocalVoice0C17ProviderErrorCodeV6domain4codeACSS_Sitcfc -->
- `VoiceProviderErrorCode.init(domain:code:)` (swift.init)
<!-- api-symbol: s:13AppLocalVoice31RecognitionSessionConfigurationV014defaultMaximumD8Durations0I0VvpZ -->
- `RecognitionSessionConfiguration.defaultMaximumRecognitionDuration` (swift.property)
<!-- api-symbol: s:13AppLocalVoice31RecognitionSessionConfigurationV014maximumMaximumD8Durations0I0VvpZ -->
- `RecognitionSessionConfiguration.maximumMaximumRecognitionDuration` (swift.property)
<!-- api-symbol: s:13AppLocalVoice31RecognitionSessionConfigurationV014minimumMaximumD8Durations0I0VvpZ -->
- `RecognitionSessionConfiguration.minimumMaximumRecognitionDuration` (swift.property)
<!-- api-symbol: s:13AppLocalVoice31RecognitionSessionConfigurationV07maximumD8Durations0H0VSgvp -->
- `RecognitionSessionConfiguration.maximumRecognitionDuration` (swift.property)
<!-- api-symbol: s:13AppLocalVoice31RecognitionSessionConfigurationV11recognition17publicationPolicy09lifecycleI007maximumD8DurationAcA0dF0V_AA021TranscriptPublicationI0OAA014AudioLifecycleI0Vs0L0VSgtcfc -->
- `RecognitionSessionConfiguration.init(recognition:publicationPolicy:lifecyclePolicy:maximumRecognitionDuration:)` (swift.init)
<!-- api-symbol: s:13AppLocalVoiceAAC18prepareRecognition3for6policy8progressAA0E17PreparationResultV10Foundation6LocaleV_AA17SpeechModelPolicyOyAA0eI5PhaseOScMYccSgtYaKF -->
- `AppLocalVoice.prepareRecognition(for:policy:progress:)` (swift.method)
