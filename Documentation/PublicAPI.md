# Public API contract

AppLocalVoice has one host-facing model: create one app-owned `AppLocalVoice`,
start and finish recognition with a session identity, and decide in the host
what to do with the resulting text. The package never submits a transcript,
models a message, or contacts a backend.

## The two integration recipes

For a chat composer, subscribe to `voiceEvents()`, call
`startSession(configuration:)` when press-to-talk begins, then await
`finishSession(id:)` when it ends. Apply preview events to the host-owned
draft and copy the final transcript into that draft. `cancelSession(id:)` only
cancels the matching turn.

For text your app has already chosen to speak, use `enqueueSpeech` when it
needs ordering, replay, or controls; use `speakImmediately` for a one-off.
Both return a playback identity. A terminal queue event or
`waitForSpeechPlayback(id:)` is the outcome authority.

## Readiness, recovery, and ownership

`capabilitySnapshot(for:)` is side-effect-free. `prepareRecognition` is the
explicit permission/model-installation boundary and never opens capture. Query
`runtimeSnapshot()` after an event-delivery failure, and use `recoveryState`
to decide whether new audio work may begin. Only the app-owned service owner
calls `close()`; `.blocked` requires an explicit retry.

The public types deliberately contain no backend, chat, persistence, audio,
or transcript-retention abstraction. Detailed host recipes are in
[Quickstart](Quickstart.md), [Recovery](Recovery.md), and
[Testing](Testing.md).

## Generated API inventory

The following production-only symbol inventory is generated from the pinned
toolchain. It is checked against `PublicAPIBaseline.json`; edit public source
first, then regenerate this evidence with
`Scripts/emit-public-symbol-graph.sh` and
`Scripts/generate-public-api-baseline.py`.

## Machine checking and release upgrades

Generate the production symbol graph, validate it against the checked baseline,
and compare it with the prior release before changing a published contract.
Simulator evidence does not replace the physical-device matrix.

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
<!-- api-symbol: s:13AppLocalVoice06SpeechC7QualityO7premiumyA2CmF -->
- `SpeechVoiceQuality.premium` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice06SpeechC7QualityO8enhancedyA2CmF -->
- `SpeechVoiceQuality.enhanced` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C10DiagnosticV -->
- `VoiceDiagnostic` (swift.struct)
<!-- api-symbol: s:13AppLocalVoice0C10DiagnosticV10routeClassAA0c5RouteF0Ovp -->
- `routeClass` (swift.property)
<!-- api-symbol: s:13AppLocalVoice0C10DiagnosticV11operationID0E05phase5state13errorCategory10routeClass19durationNanosecondsAC10Foundation4UUIDV_AA0cD9OperationOAA0cD5PhaseOAA0C5StateOAA0c5ErrorJ0OSgAA0c5RouteL0Os6UInt64Vtcfc -->
- `init(operationID:operation:phase:state:errorCategory:routeClass:durationNanoseconds:)` (swift.init)
<!-- api-symbol: s:13AppLocalVoice0C10DiagnosticV11operationID10Foundation4UUIDVvp -->
- `operationID` (swift.property)
<!-- api-symbol: s:13AppLocalVoice0C10DiagnosticV13errorCategoryAA0c5ErrorF0OSgvp -->
- `errorCategory` (swift.property)
<!-- api-symbol: s:13AppLocalVoice0C10DiagnosticV19durationNanosecondss6UInt64Vvp -->
- `durationNanoseconds` (swift.property)
<!-- api-symbol: s:13AppLocalVoice0C10DiagnosticV5phaseAA0cD5PhaseOvp -->
- `phase` (swift.property)
<!-- api-symbol: s:13AppLocalVoice0C10DiagnosticV5stateAA0C5StateOvp -->
- `state` (swift.property)
<!-- api-symbol: s:13AppLocalVoice0C10DiagnosticV9operationAA0cD9OperationOvp -->
- `operation` (swift.property)
<!-- api-symbol: s:13AppLocalVoice0C10RouteClassO -->
- `VoiceRouteClass` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice0C10RouteClassO14builtInSpeakeryA2CmF -->
- `VoiceRouteClass.builtInSpeaker` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C10RouteClassO15builtInReceiveryA2CmF -->
- `VoiceRouteClass.builtInReceiver` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C10RouteClassO3caryA2CmF -->
- `VoiceRouteClass.car` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C10RouteClassO3usbyA2CmF -->
- `VoiceRouteClass.usb` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C10RouteClassO5otheryA2CmF -->
- `VoiceRouteClass.other` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C10RouteClassO5wiredyA2CmF -->
- `VoiceRouteClass.wired` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C10RouteClassO7airPlayyA2CmF -->
- `VoiceRouteClass.airPlay` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C10RouteClassO7unknownyA2CmF -->
- `VoiceRouteClass.unknown` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C10RouteClassO9bluetoothyA2CmF -->
- `VoiceRouteClass.bluetooth` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C11EventStreama -->
- `VoiceEventStream` (swift.typealias)
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO -->
- `VoiceErrorCategory` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO06speechC11UnavailableyA2CmF -->
- `VoiceErrorCategory.speechVoiceUnavailable` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO10underlyingyA2CmF -->
- `VoiceErrorCategory.underlying` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO11interruptedyA2CmF -->
- `VoiceErrorCategory.interrupted` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO11textTooLongyA2CmF -->
- `VoiceErrorCategory.textTooLong` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO12invalidStateyA2CmF -->
- `VoiceErrorCategory.invalidState` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO12serviceInUseyA2CmF -->
- `VoiceErrorCategory.serviceInUse` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO14cleanupPendingyA2CmF -->
- `VoiceErrorCategory.cleanupPending` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO15itemUnavailableyA2CmF -->
- `VoiceErrorCategory.itemUnavailable` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO17invalidSpeechItemyA2CmF -->
- `VoiceErrorCategory.invalidSpeechItem` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO17operationTimedOutyA2CmF -->
- `VoiceErrorCategory.operationTimedOut` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO17unsupportedLocaleyA2CmF -->
- `VoiceErrorCategory.unsupportedLocale` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO21audioRouteUnavailableyA2CmF -->
- `VoiceErrorCategory.audioRouteUnavailable` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO21eventDeliveryOverflowyA2CmF -->
- `VoiceErrorCategory.eventDeliveryOverflow` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO21transcriptConsistencyyA2CmF -->
- `VoiceErrorCategory.transcriptConsistency` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO22speechPermissionDeniedyA2CmF -->
- `VoiceErrorCategory.speechPermissionDenied` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO23audioSessionUnavailableyA2CmF -->
- `VoiceErrorCategory.audioSessionUnavailable` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO23queueTextBudgetExceededyA2CmF -->
- `VoiceErrorCategory.queueTextBudgetExceeded` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO26invalidSpeechConfigurationyA2CmF -->
- `VoiceErrorCategory.invalidSpeechConfiguration` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO26microphonePermissionDeniedyA2CmF -->
- `VoiceErrorCategory.microphonePermissionDenied` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO26speechPermissionRestrictedyA2CmF -->
- `VoiceErrorCategory.speechPermissionRestricted` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO26speechSynthesisUnavailableyA2CmF -->
- `VoiceErrorCategory.speechSynthesisUnavailable` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO27eventSubscriberLimitReachedyA2CmF -->
- `VoiceErrorCategory.eventSubscriberLimitReached` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO30microphonePermissionRestrictedyA2CmF -->
- `VoiceErrorCategory.microphonePermissionRestricted` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO30onDeviceRecognitionUnavailableyA2CmF -->
- `VoiceErrorCategory.onDeviceRecognitionUnavailable` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO31invalidRecognitionConfigurationyA2CmF -->
- `VoiceErrorCategory.invalidRecognitionConfiguration` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO31invalidSpeechQueueConfigurationyA2CmF -->
- `VoiceErrorCategory.invalidSpeechQueueConfiguration` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO34recognitionModelInstallationFailedyA2CmF -->
- `VoiceErrorCategory.recognitionModelInstallationFailed` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO9cancelledyA2CmF -->
- `VoiceErrorCategory.cancelled` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C13ErrorCategoryO9queueFullyA2CmF -->
- `VoiceErrorCategory.queueFull` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C13RecoveryEventV -->
- `VoiceRecoveryEvent` (swift.struct)
<!-- api-symbol: s:13AppLocalVoice0C13RecoveryEventV12eventOrdinal4kindACs6UInt64V_AA0cdE4KindOtcfc -->
- `init(eventOrdinal:kind:)` (swift.init)
<!-- api-symbol: s:13AppLocalVoice0C13RecoveryEventV12eventOrdinals6UInt64Vvp -->
- `eventOrdinal` (swift.property)
<!-- api-symbol: s:13AppLocalVoice0C13RecoveryEventV4kindAA0cdE4KindOvp -->
- `kind` (swift.property)
<!-- api-symbol: s:13AppLocalVoice0C13RecoveryStateO -->
- `VoiceRecoveryState` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice0C13RecoveryStateO11reconcilingyA2CmF -->
- `VoiceRecoveryState.reconciling` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C13RecoveryStateO5readyyA2CmF -->
- `VoiceRecoveryState.ready` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C13RecoveryStateO7blockedyAcA0C7FailureVcACmF -->
- `VoiceRecoveryState.blocked(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C14RecoveryActionO -->
- `VoiceRecoveryAction` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice0C14RecoveryActionO015chooseInstalledC0yA2CmF -->
- `VoiceRecoveryAction.chooseInstalledVoice` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C14RecoveryActionO11shortenTextyA2CmF -->
- `VoiceRecoveryAction.shortenText` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C14RecoveryActionO11waitForIdleyA2CmF -->
- `VoiceRecoveryAction.waitForIdle` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C14RecoveryActionO12openSettingsyA2CmF -->
- `VoiceRecoveryAction.openSettings` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C14RecoveryActionO12retryCleanupyA2CmF -->
- `VoiceRecoveryAction.retryCleanup` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C14RecoveryActionO13reenqueueItemyA2CmF -->
- `VoiceRecoveryAction.reenqueueItem` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C14RecoveryActionO14makeQueueSpaceyA2CmF -->
- `VoiceRecoveryAction.makeQueueSpace` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C14RecoveryActionO16useOwningServiceyA2CmF -->
- `VoiceRecoveryAction.useOwningService` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C14RecoveryActionO18showPermissionHelpyA2CmF -->
- `VoiceRecoveryAction.showPermissionHelp` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C14RecoveryActionO19changeConfigurationyA2CmF -->
- `VoiceRecoveryAction.changeConfiguration` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C14RecoveryActionO19reconcileEventStateyA2CmF -->
- `VoiceRecoveryAction.reconcileEventState` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C14RecoveryActionO21chooseSupportedLocaleyA2CmF -->
- `VoiceRecoveryAction.chooseSupportedLocale` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C14RecoveryActionO22retryAfterInterruptionyA2CmF -->
- `VoiceRecoveryAction.retryAfterInterruption` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C14RecoveryActionO22reviewRecognitionModelyA2CmF -->
- `VoiceRecoveryAction.reviewRecognitionModel` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C14RecoveryActionO24discardPartialTranscriptyA2CmF -->
- `VoiceRecoveryAction.discardPartialTranscript` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C14RecoveryActionO4noneyA2CmF -->
- `VoiceRecoveryAction.none` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C14RecoveryActionO5retryyA2CmF -->
- `VoiceRecoveryAction.retry` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C15DiagnosticPhaseO -->
- `VoiceDiagnosticPhase` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice0C15DiagnosticPhaseO6failedyA2CmF -->
- `VoiceDiagnosticPhase.failed` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C15DiagnosticPhaseO7startedyA2CmF -->
- `VoiceDiagnosticPhase.started` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C15DiagnosticPhaseO9cancelledyA2CmF -->
- `VoiceDiagnosticPhase.cancelled` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C15DiagnosticPhaseO9completedyA2CmF -->
- `VoiceDiagnosticPhase.completed` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C15DiagnosticsSinka -->
- `VoiceDiagnosticsSink` (swift.typealias)
<!-- api-symbol: s:13AppLocalVoice0C15RuntimeSnapshotV -->
- `VoiceRuntimeSnapshot` (swift.struct)
<!-- api-symbol: s:13AppLocalVoice0C15RuntimeSnapshotV10generations6UInt64Vvp -->
- `generation` (swift.property)
<!-- api-symbol: s:13AppLocalVoice0C15RuntimeSnapshotV11recognitionAA0c11RecognitionE0VSgvp -->
- `recognition` (swift.property)
<!-- api-symbol: s:13AppLocalVoice0C15RuntimeSnapshotV13recoveryStateAA0c8RecoveryG0Ovp -->
- `recoveryState` (swift.property)
<!-- api-symbol: s:13AppLocalVoice0C15RuntimeSnapshotV5queueAA011SpeechQueueE0Vvp -->
- `queue` (swift.property)
<!-- api-symbol: s:13AppLocalVoice0C15RuntimeSnapshotV5state13recoveryState11recognition5queue10generationAcA0cH0O_AA0c8RecoveryH0OAA0c11RecognitionE0VSgAA011SpeechQueueE0Vs6UInt64Vtcfc -->
- `init(state:recoveryState:recognition:queue:generation:)` (swift.init)
<!-- api-symbol: s:13AppLocalVoice0C15RuntimeSnapshotV5stateAA0C5StateOvp -->
- `state` (swift.property)
<!-- api-symbol: s:13AppLocalVoice0C16BackgroundPolicyO -->
- `VoiceBackgroundPolicy` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice0C16BackgroundPolicyO4stopyA2CmF -->
- `VoiceBackgroundPolicy.stop` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C16PermissionStatusO -->
- `VoicePermissionStatus` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice0C16PermissionStatusO10authorizedyA2CmF -->
- `VoicePermissionStatus.authorized` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C16PermissionStatusO10restrictedyA2CmF -->
- `VoicePermissionStatus.restricted` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C16PermissionStatusO13notDeterminedyA2CmF -->
- `VoicePermissionStatus.notDetermined` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C16PermissionStatusO6deniedyA2CmF -->
- `VoicePermissionStatus.denied` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C17DiagnosticsStreama -->
- `VoiceDiagnosticsStream` (swift.typealias)
<!-- api-symbol: s:13AppLocalVoice0C17ProviderErrorCodeV -->
- `VoiceProviderErrorCode` (swift.struct)
<!-- api-symbol: s:13AppLocalVoice0C17ProviderErrorCodeV4codeSivp -->
- `code` (swift.property)
<!-- api-symbol: s:13AppLocalVoice0C17ProviderErrorCodeV6domain4codeACSS_Sitcfc -->
- `init(domain:code:)` (swift.init)
<!-- api-symbol: s:13AppLocalVoice0C17ProviderErrorCodeV6domainSSvp -->
- `domain` (swift.property)
<!-- api-symbol: s:13AppLocalVoice0C17RecoveryEventKindO -->
- `VoiceRecoveryEventKind` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice0C17RecoveryEventKindO11reconcilingyA2CmF -->
- `VoiceRecoveryEventKind.reconciling` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C17RecoveryEventKindO5readyyA2CmF -->
- `VoiceRecoveryEventKind.ready` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C17RecoveryEventKindO7blockedyAcA0C7FailureVcACmF -->
- `VoiceRecoveryEventKind.blocked(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C17RouteChangePolicyO -->
- `VoiceRouteChangePolicy` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice0C17RouteChangePolicyO21stopAndRequireRestartyA2CmF -->
- `VoiceRouteChangePolicy.stopAndRequireRestart` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C17TerminationReasonO -->
- `VoiceTerminationReason` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice0C17TerminationReasonO11interruptedyAcA0c12InterruptionE0OcACmF -->
- `VoiceTerminationReason.interrupted(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C17TerminationReasonO20durationLimitReachedyA2CmF -->
- `VoiceTerminationReason.durationLimitReached` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C17TerminationReasonO6failedyAcA0C5ErrorOcACmF -->
- `VoiceTerminationReason.failed(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C17TerminationReasonO9cancelledyA2CmF -->
- `VoiceTerminationReason.cancelled` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C17TerminationReasonO9completedyA2CmF -->
- `VoiceTerminationReason.completed` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C18CapabilitySnapshotV -->
- `VoiceCapabilitySnapshot` (swift.struct)
<!-- api-symbol: s:13AppLocalVoice0C18CapabilitySnapshotV11recognitionAA011RecognitionD0Vvp -->
- `recognition` (swift.property)
<!-- api-symbol: s:13AppLocalVoice0C18CapabilitySnapshotV12availability3forAA0cD12AvailabilityOSgAA0C7FeatureO_tF -->
- `availability(for:)` (swift.method)
<!-- api-symbol: s:13AppLocalVoice0C18CapabilitySnapshotV15installedVoicesSayAA06SpeechC0VGvp -->
- `installedVoices` (swift.property)
<!-- api-symbol: s:13AppLocalVoice0C18CapabilitySnapshotV20microphonePermission017speechRecognitionG011recognition15installedVoices8featuresAcA0cG6StatusO_AjA0iD0VSayAA06SpeechC0VGSDyAA0C7FeatureOAA0cD12AvailabilityOGtcfc -->
- `init(microphonePermission:speechRecognitionPermission:recognition:installedVoices:features:)` (swift.init)
<!-- api-symbol: s:13AppLocalVoice0C18CapabilitySnapshotV20microphonePermissionAA0cG6StatusOvp -->
- `microphonePermission` (swift.property)
<!-- api-symbol: s:13AppLocalVoice0C18CapabilitySnapshotV27speechRecognitionPermissionAA0cH6StatusOvp -->
- `speechRecognitionPermission` (swift.property)
<!-- api-symbol: s:13AppLocalVoice0C18CapabilitySnapshotV8featuresSDyAA0C7FeatureOAA0cD12AvailabilityOGvp -->
- `features` (swift.property)
<!-- api-symbol: s:13AppLocalVoice0C18InterruptionPolicyO -->
- `VoiceInterruptionPolicy` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice0C18InterruptionPolicyO4stopyA2CmF -->
- `VoiceInterruptionPolicy.stop` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C18InterruptionReasonO -->
- `VoiceInterruptionReason` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice0C18InterruptionReasonO06systemD0yA2CmF -->
- `VoiceInterruptionReason.systemInterruption` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C18InterruptionReasonO11routeChangeyA2CmF -->
- `VoiceInterruptionReason.routeChange` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C18InterruptionReasonO13appBackgroundyA2CmF -->
- `VoiceInterruptionReason.appBackground` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C18InterruptionReasonO18mediaServicesResetyA2CmF -->
- `VoiceInterruptionReason.mediaServicesReset` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C19DiagnosticOperationO -->
- `VoiceDiagnosticOperation` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice0C19DiagnosticOperationO5closeyA2CmF -->
- `VoiceDiagnosticOperation.close` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C19DiagnosticOperationO8speakingyA2CmF -->
- `VoiceDiagnosticOperation.speaking` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C19DiagnosticOperationO9listeningyA2CmF -->
- `VoiceDiagnosticOperation.listening` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C19RecognitionSnapshotV -->
- `VoiceRecognitionSnapshot` (swift.struct)
<!-- api-symbol: s:13AppLocalVoice0C19RecognitionSnapshotV13latestPreviewAA010TranscriptG0VSgvp -->
- `latestPreview` (swift.property)
<!-- api-symbol: s:13AppLocalVoice0C19RecognitionSnapshotV5stateAA0D12SessionStateOvp -->
- `state` (swift.property)
<!-- api-symbol: s:13AppLocalVoice0C19RecognitionSnapshotV9sessionID5state13latestPreviewAcA0d7SessionG0V_AA0dK5StateOAA010TranscriptJ0VSgtcfc -->
- `init(sessionID:state:latestPreview:)` (swift.init)
<!-- api-symbol: s:13AppLocalVoice0C19RecognitionSnapshotV9sessionIDAA0d7SessionG0Vvp -->
- `sessionID` (swift.property)
<!-- api-symbol: s:13AppLocalVoice0C20CleanupFailurePolicyO -->
- `VoiceCleanupFailurePolicy` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice0C20CleanupFailurePolicyO20requireExplicitRetryyA2CmF -->
- `VoiceCleanupFailurePolicy.requireExplicitRetry` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C22CapabilityAvailabilityO -->
- `VoiceCapabilityAvailability` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice0C22CapabilityAvailabilityO11unavailableyAcA0C7FailureVcACmF -->
- `VoiceCapabilityAvailability.unavailable(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C22CapabilityAvailabilityO9availableyA2CmF -->
- `VoiceCapabilityAvailability.available` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO -->
- `VoiceError` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO06speechC11UnavailableyACSScACmF -->
- `VoiceError.speechVoiceUnavailable(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO10underlyingyACSScACmF -->
- `VoiceError.underlying(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO11interruptedyACSScACmF -->
- `VoiceError.interrupted(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO11textTooLongyACSi_tcACmF -->
- `VoiceError.textTooLong(maximumUTF16Length:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO12invalidStateyACSScACmF -->
- `VoiceError.invalidState(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO12serviceInUseyA2CmF -->
- `VoiceError.serviceInUse` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO14cleanupPendingyA2CmF -->
- `VoiceError.cleanupPending` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO15itemUnavailableyAcA12SpeechItemIDVcACmF -->
- `VoiceError.itemUnavailable(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO16errorDescriptionSSSgvp -->
- `errorDescription` (swift.property)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO17invalidSpeechItemyACSScACmF -->
- `VoiceError.invalidSpeechItem(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO17operationTimedOutyA2CmF -->
- `VoiceError.operationTimedOut` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO17unsupportedLocaleyAC10Foundation0F0VcACmF -->
- `VoiceError.unsupportedLocale(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO21audioRouteUnavailableyA2CmF -->
- `VoiceError.audioRouteUnavailable` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO21eventDeliveryOverflowyACSi_AA05EventF6CursorOtcACmF -->
- `VoiceError.eventDeliveryOverflow(capacity:firstUndelivered:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO21transcriptConsistencyyA2CmF -->
- `VoiceError.transcriptConsistency` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO22speechPermissionDeniedyA2CmF -->
- `VoiceError.speechPermissionDenied` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO23audioSessionUnavailableyACSScACmF -->
- `VoiceError.audioSessionUnavailable(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO23queueTextBudgetExceededyACSi_tcACmF -->
- `VoiceError.queueTextBudgetExceeded(maximumUTF16Length:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO25recommendedRecoveryActionAA0cfG0Ovp -->
- `recommendedRecoveryAction` (swift.property)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO26invalidSpeechConfigurationyACSScACmF -->
- `VoiceError.invalidSpeechConfiguration(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO26microphonePermissionDeniedyA2CmF -->
- `VoiceError.microphonePermissionDenied` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO26speechPermissionRestrictedyA2CmF -->
- `VoiceError.speechPermissionRestricted` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO26speechSynthesisUnavailableyACSScACmF -->
- `VoiceError.speechSynthesisUnavailable(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO27eventSubscriberLimitReachedyACSi_SitcACmF -->
- `VoiceError.eventSubscriberLimitReached(maximum:active:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO30microphonePermissionRestrictedyA2CmF -->
- `VoiceError.microphonePermissionRestricted` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO30onDeviceRecognitionUnavailableyAC10Foundation6LocaleVcACmF -->
- `VoiceError.onDeviceRecognitionUnavailable(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO31invalidRecognitionConfigurationyACSScACmF -->
- `VoiceError.invalidRecognitionConfiguration(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO31invalidSpeechQueueConfigurationyACSScACmF -->
- `VoiceError.invalidSpeechQueueConfiguration(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO34recognitionModelInstallationFailedyAC10Foundation6LocaleV_AA0c8ProviderD4CodeVSgtcACmF -->
- `VoiceError.recognitionModelInstallationFailed(_:providerError:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO7failureAA0C7FailureVvp -->
- `failure` (swift.property)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO8categoryAA0cD8CategoryOvp -->
- `category` (swift.property)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO9cancelledyA2CmF -->
- `VoiceError.cancelled` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5ErrorO9queueFullyACSi_tcACmF -->
- `VoiceError.queueFull(maximumPendingItemCount:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5StateO -->
- `VoiceState` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice0C5StateO10finalizingyA2CmF -->
- `VoiceState.finalizing` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5StateO4idleyA2CmF -->
- `VoiceState.idle` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5StateO6failedyA2CmF -->
- `VoiceState.failed` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5StateO8speakingyA2CmF -->
- `VoiceState.speaking` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5StateO9listeningyA2CmF -->
- `VoiceState.listening` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C5StateO9preparingyA2CmF -->
- `VoiceState.preparing` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C7FailureV -->
- `VoiceFailure` (swift.struct)
<!-- api-symbol: s:13AppLocalVoice0C7FailureV17recommendedActionAA0c8RecoveryF0Ovp -->
- `recommendedAction` (swift.property)
<!-- api-symbol: s:13AppLocalVoice0C7FailureV8category17recommendedActionAcA0C13ErrorCategoryO_AA0c8RecoveryG0Otcfc -->
- `init(category:recommendedAction:)` (swift.init)
<!-- api-symbol: s:13AppLocalVoice0C7FailureV8categoryAA0C13ErrorCategoryOvp -->
- `category` (swift.property)
<!-- api-symbol: s:13AppLocalVoice0C7FeatureO -->
- `VoiceFeature` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice0C7FeatureO11speechQueueyA2CmF -->
- `VoiceFeature.speechQueue` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C7FeatureO15speechSynthesisyA2CmF -->
- `VoiceFeature.speechSynthesis` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C7FeatureO17modelInstallationyA2CmF -->
- `VoiceFeature.modelInstallation` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C7FeatureO17speechPauseResumeyA2CmF -->
- `VoiceFeature.speechPauseResume` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C7FeatureO17speechRecognitionyA2CmF -->
- `VoiceFeature.speechRecognition` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C7FeatureO21liveTranscriptPreviewyA2CmF -->
- `VoiceFeature.liveTranscriptPreview` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0C7FeatureO22stableTranscriptChunksyA2CmF -->
- `VoiceFeature.stableTranscriptChunks` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0c11EventStreamD0O -->
- `VoiceEventStreamEvent` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice0c11EventStreamD0O11recognitionyAcA011RecognitionD0VcACmF -->
- `VoiceEventStreamEvent.recognition(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0c11EventStreamD0O11speechQueueyAcA06SpeechgD0VcACmF -->
- `VoiceEventStreamEvent.speechQueue(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0c11EventStreamD0O12eventOrdinals6UInt64Vvp -->
- `eventOrdinal` (swift.property)
<!-- api-symbol: s:13AppLocalVoice0c11EventStreamD0O14speechProgressyAcA014SpeechPlaybackG0VcACmF -->
- `VoiceEventStreamEvent.speechProgress(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0c11EventStreamD0O6cursorAA0D14DeliveryCursorOvp -->
- `cursor` (swift.property)
<!-- api-symbol: s:13AppLocalVoice0c11EventStreamD0O8recoveryyAcA0c8RecoveryD0VcACmF -->
- `VoiceEventStreamEvent.recovery(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice0c11EventStreamD0O8snapshotyAcA0C15RuntimeSnapshotVcACmF -->
- `VoiceEventStreamEvent.snapshot(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice10SpeechItemV -->
- `SpeechItem` (swift.struct)
<!-- api-symbol: s:13AppLocalVoice10SpeechItemV13configurationAA0D13ConfigurationVvp -->
- `configuration` (swift.property)
<!-- api-symbol: s:13AppLocalVoice10SpeechItemV2idAA0dE2IDVvp -->
- `id` (swift.property)
<!-- api-symbol: s:13AppLocalVoice10SpeechItemV4textSSvp -->
- `text` (swift.property)
<!-- api-symbol: s:13AppLocalVoice10SpeechItemV8priorityAA0D8PriorityOvp -->
- `priority` (swift.property)
<!-- api-symbol: s:13AppLocalVoice12SpeechItemIDV -->
- `SpeechItemID` (swift.struct)
<!-- api-symbol: s:13AppLocalVoice12SpeechItemIDV11descriptionSSvp -->
- `description` (swift.property)
<!-- api-symbol: s:13AppLocalVoice12SpeechItemIDV8rawValue10Foundation4UUIDVvp -->
- `rawValue` (swift.property)
<!-- api-symbol: s:13AppLocalVoice13CleanupResultO -->
- `CleanupResult` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice13CleanupResultO7blockedyAcA0C7FailureVcACmF -->
- `CleanupResult.blocked(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice13CleanupResultO8releasedyA2CmF -->
- `CleanupResult.released` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice14SpeechPriorityO -->
- `SpeechPriority` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice14SpeechPriorityO13userInitiatedyA2CmF -->
- `SpeechPriority.userInitiated` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice14SpeechPriorityO1loiySbAC_ACtFZ -->
- `<(_:_:)` (swift.func.op)
<!-- api-symbol: s:13AppLocalVoice14SpeechPriorityO6normalyA2CmF -->
- `SpeechPriority.normal` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice14SpeechPriorityO8rawValueACSgSi_tcfc -->
- `init(rawValue:)` (swift.init)
<!-- api-symbol: s:13AppLocalVoice15FinalTranscriptV -->
- `FinalTranscript` (swift.struct)
<!-- api-symbol: s:13AppLocalVoice15FinalTranscriptV4textSSvp -->
- `text` (swift.property)
<!-- api-symbol: s:13AppLocalVoice15FinalTranscriptV9sessionIDAA018RecognitionSessionG0Vvp -->
- `sessionID` (swift.property)
<!-- api-symbol: s:13AppLocalVoice15FinalTranscriptV9timeRangeAA0e4TimeG0VSgvp -->
- `timeRange` (swift.property)
<!-- api-symbol: s:13AppLocalVoice15SpeechQueueModeO -->
- `SpeechQueueMode` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice15SpeechQueueModeO7runningyA2CmF -->
- `SpeechQueueMode.running` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice15SpeechQueueModeO9suspendedyA2CmF -->
- `SpeechQueueMode.suspended` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice16RecognitionEventV -->
- `RecognitionEvent` (swift.struct)
<!-- api-symbol: s:13AppLocalVoice16RecognitionEventV08acceptedE7Ordinals6UInt64VvpZ -->
- `acceptedEventOrdinal` (swift.type.property)
<!-- api-symbol: s:13AppLocalVoice16RecognitionEventV10duplicatesySbACF -->
- `duplicates(_:)` (swift.method)
<!-- api-symbol: s:13AppLocalVoice16RecognitionEventV12eventOrdinals6UInt64Vvp -->
- `eventOrdinal` (swift.property)
<!-- api-symbol: s:13AppLocalVoice16RecognitionEventV18immediatelyFollowsySbACF -->
- `immediatelyFollows(_:)` (swift.method)
<!-- api-symbol: s:13AppLocalVoice16RecognitionEventV4kindAA0dE4KindOvp -->
- `kind` (swift.property)
<!-- api-symbol: s:13AppLocalVoice16RecognitionEventV9sessionIDAA0d7SessionG0Vvp -->
- `sessionID` (swift.property)
<!-- api-symbol: s:13AppLocalVoice16SpeechPlaybackIDV -->
- `SpeechPlaybackID` (swift.struct)
<!-- api-symbol: s:13AppLocalVoice16SpeechPlaybackIDV11descriptionSSvp -->
- `description` (swift.property)
<!-- api-symbol: s:13AppLocalVoice16SpeechPlaybackIDV8rawValue10Foundation4UUIDVvp -->
- `rawValue` (swift.property)
<!-- api-symbol: s:13AppLocalVoice16SpeechQueueEventV -->
- `SpeechQueueEvent` (swift.struct)
<!-- api-symbol: s:13AppLocalVoice16SpeechQueueEventV10playbackIDAA0d8PlaybackH0Vvp -->
- `playbackID` (swift.property)
<!-- api-symbol: s:13AppLocalVoice16SpeechQueueEventV12eventOrdinals6UInt64Vvp -->
- `eventOrdinal` (swift.property)
<!-- api-symbol: s:13AppLocalVoice16SpeechQueueEventV18immediatelyFollowsySbACF -->
- `immediatelyFollows(_:)` (swift.method)
<!-- api-symbol: s:13AppLocalVoice16SpeechQueueEventV4kindAA0deF4KindOvp -->
- `kind` (swift.property)
<!-- api-symbol: s:13AppLocalVoice16SpeechQueueEventV6itemIDAA0d4ItemH0Vvp -->
- `itemID` (swift.property)
<!-- api-symbol: s:13AppLocalVoice17SpeechItemRequestV -->
- `SpeechItemRequest` (swift.struct)
<!-- api-symbol: s:13AppLocalVoice17SpeechItemRequestV13configurationAA0D13ConfigurationVvp -->
- `configuration` (swift.property)
<!-- api-symbol: s:13AppLocalVoice17SpeechItemRequestV18maximumUTF16LengthSivpZ -->
- `maximumUTF16Length` (swift.type.property)
<!-- api-symbol: s:13AppLocalVoice17SpeechItemRequestV4text8priority13configurationACSS_AA0D8PriorityOAA0D13ConfigurationVtKcfc -->
- `init(text:priority:configuration:)` (swift.init)
<!-- api-symbol: s:13AppLocalVoice17SpeechItemRequestV4textSSvp -->
- `text` (swift.property)
<!-- api-symbol: s:13AppLocalVoice17SpeechItemRequestV8priorityAA0D8PriorityOvp -->
- `priority` (swift.property)
<!-- api-symbol: s:13AppLocalVoice17SpeechModelPolicyO -->
- `SpeechModelPolicy` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice17SpeechModelPolicyO05allowE12InstallationyA2CmF -->
- `SpeechModelPolicy.allowModelInstallation` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice17SpeechModelPolicyO19installedModelsOnlyyA2CmF -->
- `SpeechModelPolicy.installedModelsOnly` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice17StableChunkPolicyV -->
- `StableChunkPolicy` (swift.struct)
<!-- api-symbol: s:13AppLocalVoice17StableChunkPolicyV11recommendedACvpZ -->
- `recommended` (swift.type.property)
<!-- api-symbol: s:13AppLocalVoice17StableChunkPolicyV15intervalSecondsACSi_tKcfc -->
- `init(intervalSeconds:)` (swift.init)
<!-- api-symbol: s:13AppLocalVoice17StableChunkPolicyV15intervalSecondsSivp -->
- `intervalSeconds` (swift.property)
<!-- api-symbol: s:13AppLocalVoice17StableChunkPolicyV22defaultIntervalSecondsSivpZ -->
- `defaultIntervalSeconds` (swift.type.property)
<!-- api-symbol: s:13AppLocalVoice17StableChunkPolicyV22maximumIntervalSecondsSivpZ -->
- `maximumIntervalSeconds` (swift.type.property)
<!-- api-symbol: s:13AppLocalVoice17StableChunkPolicyV22minimumIntervalSecondsSivpZ -->
- `minimumIntervalSeconds` (swift.type.property)
<!-- api-symbol: s:13AppLocalVoice17TranscriptPreviewV -->
- `TranscriptPreview` (swift.struct)
<!-- api-symbol: s:13AppLocalVoice17TranscriptPreviewV4textSSvp -->
- `text` (swift.property)
<!-- api-symbol: s:13AppLocalVoice17TranscriptPreviewV8revisions6UInt64Vvp -->
- `revision` (swift.property)
<!-- api-symbol: s:13AppLocalVoice17TranscriptPreviewV9sessionIDAA018RecognitionSessionG0Vvp -->
- `sessionID` (swift.property)
<!-- api-symbol: s:13AppLocalVoice17TranscriptPreviewV9timeRangeAA0d4TimeG0VSgvp -->
- `timeRange` (swift.property)
<!-- api-symbol: s:13AppLocalVoice18RecognitionOutcomeO -->
- `RecognitionOutcome` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice18RecognitionOutcomeO11interruptedyAcA0C18InterruptionReasonOcACmF -->
- `RecognitionOutcome.interrupted(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice18RecognitionOutcomeO20durationLimitReachedyA2CmF -->
- `RecognitionOutcome.durationLimitReached` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice18RecognitionOutcomeO6failedyAcA0C7FailureVcACmF -->
- `RecognitionOutcome.failed(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice18RecognitionOutcomeO9cancelledyA2CmF -->
- `RecognitionOutcome.cancelled` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice18RecognitionOutcomeO9completedyA2CmF -->
- `RecognitionOutcome.completed` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice18SpeechQueueCommandO -->
- `SpeechQueueCommand` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice18SpeechQueueCommandO12clearPendingyA2CmF -->
- `SpeechQueueCommand.clearPending` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice18SpeechQueueCommandO12stopAndClearyA2CmF -->
- `SpeechQueueCommand.stopAndClear` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice18SpeechQueueCommandO4skipyA2CmF -->
- `SpeechQueueCommand.skip` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice18SpeechQueueCommandO4stopyA2CmF -->
- `SpeechQueueCommand.stop` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice18SpeechQueueCommandO5pauseyA2CmF -->
- `SpeechQueueCommand.pause` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice18SpeechQueueCommandO6replayyAcA0D6ItemIDV_AA0D13EnqueuePolicyOtcACmF -->
- `SpeechQueueCommand.replay(_:policy:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice18SpeechQueueCommandO6resumeyA2CmF -->
- `SpeechQueueCommand.resume` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice18SpeechQueueCommandO7enqueueyAcA0D11ItemRequestV_AA0D13EnqueuePolicyOtcACmF -->
- `SpeechQueueCommand.enqueue(_:policy:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice19EventDeliveryCursorO -->
- `EventDeliveryCursor` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice19EventDeliveryCursorO11recognitionyAcA20RecognitionSessionIDV_s6UInt64VtcACmF -->
- `EventDeliveryCursor.recognition(sessionID:eventOrdinal:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice19EventDeliveryCursorO11speechQueueyAcA12SpeechItemIDV_AA0i8PlaybackK0Vs6UInt64VtcACmF -->
- `EventDeliveryCursor.speechQueue(itemID:playbackID:eventOrdinal:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice19EventDeliveryCursorO14processRuntimeyACs6UInt64V_tcACmF -->
- `EventDeliveryCursor.processRuntime(eventOrdinal:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice19ExternalAudioPolicyO -->
- `ExternalAudioPolicy` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice19ExternalAudioPolicyO3mixyA2CmF -->
- `ExternalAudioPolicy.mix` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice19ExternalAudioPolicyO4duckyA2CmF -->
- `ExternalAudioPolicy.duck` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice19ExternalAudioPolicyO6rejectyA2CmF -->
- `ExternalAudioPolicy.reject` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice19ExternalAudioPolicyO9interruptyA2CmF -->
- `ExternalAudioPolicy.interrupt` (swift.enum.case)
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
<!-- api-symbol: s:13AppLocalVoice19SpeechControlResultO -->
- `SpeechControlResult` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice19SpeechControlResultO14alreadyAppliedyA2CmF -->
- `SpeechControlResult.alreadyApplied` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice19SpeechControlResultO16noActivePlaybackyA2CmF -->
- `SpeechControlResult.noActivePlayback` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice19SpeechControlResultO16providerRejectedyA2CmF -->
- `SpeechControlResult.providerRejected` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice19SpeechControlResultO7appliedyA2CmF -->
- `SpeechControlResult.applied` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice19SpeechEnqueuePolicyO -->
- `SpeechEnqueuePolicy` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice19SpeechEnqueuePolicyO10replaceAllyA2CmF -->
- `SpeechEnqueuePolicy.replaceAll` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice19SpeechEnqueuePolicyO14replaceCurrentyA2CmF -->
- `SpeechEnqueuePolicy.replaceCurrent` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice19SpeechEnqueuePolicyO6appendyA2CmF -->
- `SpeechEnqueuePolicy.append` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice19SpeechEnqueuePolicyO8playNextyA2CmF -->
- `SpeechEnqueuePolicy.playNext` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice19SpeechQueueSnapshotV -->
- `SpeechQueueSnapshot` (swift.struct)
<!-- api-symbol: s:13AppLocalVoice19SpeechQueueSnapshotV10generations6UInt64Vvp -->
- `generation` (swift.property)
<!-- api-symbol: s:13AppLocalVoice19SpeechQueueSnapshotV15retainedItemIDsSayAA0dH2IDVGvp -->
- `retainedItemIDs` (swift.property)
<!-- api-symbol: s:13AppLocalVoice19SpeechQueueSnapshotV4modeAA0dE4ModeOvp -->
- `mode` (swift.property)
<!-- api-symbol: s:13AppLocalVoice19SpeechQueueSnapshotV6activeAA0de7AttemptF0VSgvp -->
- `active` (swift.property)
<!-- api-symbol: s:13AppLocalVoice19SpeechQueueSnapshotV7pendingSayAA0de7AttemptF0VGvp -->
- `pending` (swift.property)
<!-- api-symbol: s:13AppLocalVoice19TranscriptTimeRangeV -->
- `TranscriptTimeRange` (swift.struct)
<!-- api-symbol: s:13AppLocalVoice19TranscriptTimeRangeV15endMillisecondss6UInt64Vvp -->
- `endMilliseconds` (swift.property)
<!-- api-symbol: s:13AppLocalVoice19TranscriptTimeRangeV17startMilliseconds03endH0ACs6UInt64V_AGtKcfc -->
- `init(startMilliseconds:endMilliseconds:)` (swift.init)
<!-- api-symbol: s:13AppLocalVoice19TranscriptTimeRangeV17startMillisecondss6UInt64Vvp -->
- `startMilliseconds` (swift.property)
<!-- api-symbol: s:13AppLocalVoice19TranscriptTimeRangeV20durationMillisecondss6UInt64Vvp -->
- `durationMilliseconds` (swift.property)
<!-- api-symbol: s:13AppLocalVoice20AudioLifecyclePolicyV -->
- `AudioLifecyclePolicy` (swift.struct)
<!-- api-symbol: s:13AppLocalVoice20AudioLifecyclePolicyV08externalD010background12interruption11routeChange14cleanupFailureAcA08ExternaldF0O_AA0c10BackgroundF0OAA0c12InterruptionF0OAA0c5RoutekF0OAA0c7CleanupmF0Otcfc -->
- `init(externalAudio:background:interruption:routeChange:cleanupFailure:)` (swift.init)
<!-- api-symbol: s:13AppLocalVoice20AudioLifecyclePolicyV08externalD0AA08ExternaldF0Ovp -->
- `externalAudio` (swift.property)
<!-- api-symbol: s:13AppLocalVoice20AudioLifecyclePolicyV10backgroundAA0c10BackgroundF0Ovp -->
- `background` (swift.property)
<!-- api-symbol: s:13AppLocalVoice20AudioLifecyclePolicyV11routeChangeAA0c5RoutehF0Ovp -->
- `routeChange` (swift.property)
<!-- api-symbol: s:13AppLocalVoice20AudioLifecyclePolicyV12interruptionAA0c12InterruptionF0Ovp -->
- `interruption` (swift.property)
<!-- api-symbol: s:13AppLocalVoice20AudioLifecyclePolicyV14cleanupFailureAA0c7CleanuphF0Ovp -->
- `cleanupFailure` (swift.property)
<!-- api-symbol: s:13AppLocalVoice20RecognitionEventKindO -->
- `RecognitionEventKind` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice20RecognitionEventKindO10isAcceptedSbvp -->
- `isAccepted` (swift.property)
<!-- api-symbol: s:13AppLocalVoice20RecognitionEventKindO10isTerminalSbvp -->
- `isTerminal` (swift.property)
<!-- api-symbol: s:13AppLocalVoice20RecognitionEventKindO10transcriptyAcA21TranscriptPublicationOcACmF -->
- `RecognitionEventKind.transcript(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice20RecognitionEventKindO12stateChangedyAcA0D12SessionStateOcACmF -->
- `RecognitionEventKind.stateChanged(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice20RecognitionEventKindO7outcomeyAcA0D7OutcomeOcACmF -->
- `RecognitionEventKind.outcome(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice20RecognitionEventKindO8acceptedyA2CmF -->
- `RecognitionEventKind.accepted` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice20RecognitionSessionIDV -->
- `RecognitionSessionID` (swift.struct)
<!-- api-symbol: s:13AppLocalVoice20RecognitionSessionIDV11descriptionSSvp -->
- `description` (swift.property)
<!-- api-symbol: s:13AppLocalVoice20RecognitionSessionIDV8rawValue10Foundation4UUIDVvp -->
- `rawValue` (swift.property)
<!-- api-symbol: s:13AppLocalVoice20SpeechPlaybackResultV -->
- `SpeechPlaybackResult` (swift.struct)
<!-- api-symbol: s:13AppLocalVoice20SpeechPlaybackResultV10playbackIDAA0deH0Vvp -->
- `playbackID` (swift.property)
<!-- api-symbol: s:13AppLocalVoice20SpeechPlaybackResultV20terminalEventOrdinals6UInt64Vvp -->
- `terminalEventOrdinal` (swift.property)
<!-- api-symbol: s:13AppLocalVoice20SpeechPlaybackResultV6itemIDAA0d4ItemH0Vvp -->
- `itemID` (swift.property)
<!-- api-symbol: s:13AppLocalVoice20SpeechPlaybackResultV7outcomeAA0dE7OutcomeOvp -->
- `outcome` (swift.property)
<!-- api-symbol: s:13AppLocalVoice20SpeechQueueEventKindO -->
- `SpeechQueueEventKind` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice20SpeechQueueEventKindO10isTerminalSbvp -->
- `isTerminal` (swift.property)
<!-- api-symbol: s:13AppLocalVoice20SpeechQueueEventKindO6pausedyA2CmF -->
- `SpeechQueueEventKind.paused` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice20SpeechQueueEventKindO7outcomeyAcA0D15PlaybackOutcomeOcACmF -->
- `SpeechQueueEventKind.outcome(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice20SpeechQueueEventKindO7resumedyA2CmF -->
- `SpeechQueueEventKind.resumed` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice20SpeechQueueEventKindO7startedyA2CmF -->
- `SpeechQueueEventKind.started` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice20SpeechQueueEventKindO8acceptedyA2CmF -->
- `SpeechQueueEventKind.accepted` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice20TranscriptUTF16RangeV -->
- `TranscriptUTF16Range` (swift.struct)
<!-- api-symbol: s:13AppLocalVoice20TranscriptUTF16RangeV11endLocationSivp -->
- `endLocation` (swift.property)
<!-- api-symbol: s:13AppLocalVoice20TranscriptUTF16RangeV6lengthSivp -->
- `length` (swift.property)
<!-- api-symbol: s:13AppLocalVoice20TranscriptUTF16RangeV8location6lengthACSi_SitKcfc -->
- `init(location:length:)` (swift.init)
<!-- api-symbol: s:13AppLocalVoice20TranscriptUTF16RangeV8locationSivp -->
- `location` (swift.property)
<!-- api-symbol: s:13AppLocalVoice21RecognitionCapabilityV -->
- `RecognitionCapability` (swift.struct)
<!-- api-symbol: s:13AppLocalVoice21RecognitionCapabilityV12availabilityAA0cE12AvailabilityOvp -->
- `availability` (swift.property)
<!-- api-symbol: s:13AppLocalVoice21RecognitionCapabilityV14modelReadinessAA0d5ModelG0Ovp -->
- `modelReadiness` (swift.property)
<!-- api-symbol: s:13AppLocalVoice21RecognitionCapabilityV14resolvedLocale10Foundation0G0VSgvp -->
- `resolvedLocale` (swift.property)
<!-- api-symbol: s:13AppLocalVoice21RecognitionCapabilityV15requestedLocale08resolvedG014modelReadiness12availabilityAC10Foundation0G0V_AJSgAA0d5ModelJ0OAA0cE12AvailabilityOtcfc -->
- `init(requestedLocale:resolvedLocale:modelReadiness:availability:)` (swift.init)
<!-- api-symbol: s:13AppLocalVoice21RecognitionCapabilityV15requestedLocale10Foundation0G0Vvp -->
- `requestedLocale` (swift.property)
<!-- api-symbol: s:13AppLocalVoice21SpeechPlaybackOutcomeO -->
- `SpeechPlaybackOutcome` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice21SpeechPlaybackOutcomeO11interruptedyAcA0C18InterruptionReasonOcACmF -->
- `SpeechPlaybackOutcome.interrupted(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice21SpeechPlaybackOutcomeO6failedyAcA0C7FailureVcACmF -->
- `SpeechPlaybackOutcome.failed(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice21SpeechPlaybackOutcomeO7skippedyA2CmF -->
- `SpeechPlaybackOutcome.skipped` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice21SpeechPlaybackOutcomeO8finishedyA2CmF -->
- `SpeechPlaybackOutcome.finished` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice21SpeechPlaybackOutcomeO9cancelledyAcA0dE18CancellationReasonOcACmF -->
- `SpeechPlaybackOutcome.cancelled(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice21StableTranscriptChunkV -->
- `StableTranscriptChunk` (swift.struct)
<!-- api-symbol: s:13AppLocalVoice21StableTranscriptChunkV10utf16RangeAA0e5UTF16H0Vvp -->
- `utf16Range` (swift.property)
<!-- api-symbol: s:13AppLocalVoice21StableTranscriptChunkV4textSSvp -->
- `text` (swift.property)
<!-- api-symbol: s:13AppLocalVoice21StableTranscriptChunkV8sequences6UInt64Vvp -->
- `sequence` (swift.property)
<!-- api-symbol: s:13AppLocalVoice21StableTranscriptChunkV9sessionIDAA018RecognitionSessionH0Vvp -->
- `sessionID` (swift.property)
<!-- api-symbol: s:13AppLocalVoice21StableTranscriptChunkV9timeRangeAA0e4TimeH0VSgvp -->
- `timeRange` (swift.property)
<!-- api-symbol: s:13AppLocalVoice21TranscriptPublicationO -->
- `TranscriptPublication` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice21TranscriptPublicationO05finalD0yAcA05FinalD0VcACmF -->
- `TranscriptPublication.finalTranscript(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice21TranscriptPublicationO11stableChunkyAcA06StabledG0VcACmF -->
- `TranscriptPublication.stableChunk(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice21TranscriptPublicationO4kindAA0dE4KindOvp -->
- `kind` (swift.property)
<!-- api-symbol: s:13AppLocalVoice21TranscriptPublicationO7previewyAcA0D7PreviewVcACmF -->
- `TranscriptPublication.preview(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice21TranscriptPublicationO9sessionIDAA018RecognitionSessionG0Vvp -->
- `sessionID` (swift.property)
<!-- api-symbol: s:13AppLocalVoice22SpeechPlaybackProgressV -->
- `SpeechPlaybackProgress` (swift.struct)
<!-- api-symbol: s:13AppLocalVoice22SpeechPlaybackProgressV10playbackIDAA0deH0Vvp -->
- `playbackID` (swift.property)
<!-- api-symbol: s:13AppLocalVoice22SpeechPlaybackProgressV10utf16RangeSnySiGvp -->
- `utf16Range` (swift.property)
<!-- api-symbol: s:13AppLocalVoice22SpeechPlaybackProgressV6itemID08playbackH010utf16RangeAcA0d4ItemH0V_AA0deH0VSnySiGtcfc -->
- `init(itemID:playbackID:utf16Range:)` (swift.init)
<!-- api-symbol: s:13AppLocalVoice22SpeechPlaybackProgressV6itemIDAA0d4ItemH0Vvp -->
- `itemID` (swift.property)
<!-- api-symbol: s:13AppLocalVoice23RecognitionSessionStateO -->
- `RecognitionSessionState` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice23RecognitionSessionStateO10finalizingyA2CmF -->
- `RecognitionSessionState.finalizing` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice23RecognitionSessionStateO9listeningyA2CmF -->
- `RecognitionSessionState.listening` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice23RecognitionSessionStateO9preparingyA2CmF -->
- `RecognitionSessionState.preparing` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice24RecognitionConfigurationV -->
- `RecognitionConfiguration` (swift.struct)
<!-- api-symbol: s:13AppLocalVoice24RecognitionConfigurationV6locale10Foundation6LocaleVvp -->
- `locale` (swift.property)
<!-- api-symbol: s:13AppLocalVoice24RecognitionConfigurationV6locale6policyAC10Foundation6LocaleV_AA17SpeechModelPolicyOtcfc -->
- `init(locale:policy:)` (swift.init)
<!-- api-symbol: s:13AppLocalVoice24RecognitionConfigurationV6policyAA17SpeechModelPolicyOvp -->
- `policy` (swift.property)
<!-- api-symbol: s:13AppLocalVoice24SpeechPlaybackAcceptanceV -->
- `SpeechPlaybackAcceptance` (swift.struct)
<!-- api-symbol: s:13AppLocalVoice24SpeechPlaybackAcceptanceV10playbackIDAA0deH0Vvp -->
- `playbackID` (swift.property)
<!-- api-symbol: s:13AppLocalVoice24SpeechPlaybackAcceptanceV20acceptedEventOrdinals6UInt64Vvp -->
- `acceptedEventOrdinal` (swift.property)
<!-- api-symbol: s:13AppLocalVoice24SpeechPlaybackAcceptanceV6itemIDAA0d4ItemH0Vvp -->
- `itemID` (swift.property)
<!-- api-symbol: s:13AppLocalVoice24SpeechQueueConfigurationV -->
- `SpeechQueueConfiguration` (swift.struct)
<!-- api-symbol: s:13AppLocalVoice24SpeechQueueConfigurationV11initialModeAA0deH0Ovp -->
- `initialMode` (swift.property)
<!-- api-symbol: s:13AppLocalVoice24SpeechQueueConfigurationV14overflowPolicyAA0de8OverflowH0Ovp -->
- `overflowPolicy` (swift.property)
<!-- api-symbol: s:13AppLocalVoice24SpeechQueueConfigurationV23maximumPendingItemCount0g13ReplayHistoryiJ00gH15TextUTF16Length0gklmnO014overflowPolicy11initialModeACSi_S3iAA0de8OverflowQ0OAA0deS0OtKcfc -->
- `init(maximumPendingItemCount:maximumReplayHistoryItemCount:maximumPendingTextUTF16Length:maximumReplayHistoryTextUTF16Length:overflowPolicy:initialMode:)` (swift.init)
<!-- api-symbol: s:13AppLocalVoice24SpeechQueueConfigurationV23maximumPendingItemCountSivp -->
- `maximumPendingItemCount` (swift.property)
<!-- api-symbol: s:13AppLocalVoice24SpeechQueueConfigurationV23maximumPendingItemCountSivpZ -->
- `maximumPendingItemCount` (swift.type.property)
<!-- api-symbol: s:13AppLocalVoice24SpeechQueueConfigurationV23minimumPendingItemCountSivpZ -->
- `minimumPendingItemCount` (swift.type.property)
<!-- api-symbol: s:13AppLocalVoice24SpeechQueueConfigurationV29maximumPendingTextUTF16LengthSivp -->
- `maximumPendingTextUTF16Length` (swift.property)
<!-- api-symbol: s:13AppLocalVoice24SpeechQueueConfigurationV29maximumPendingTextUTF16LengthSivpZ -->
- `maximumPendingTextUTF16Length` (swift.type.property)
<!-- api-symbol: s:13AppLocalVoice24SpeechQueueConfigurationV29maximumReplayHistoryItemCountSivp -->
- `maximumReplayHistoryItemCount` (swift.property)
<!-- api-symbol: s:13AppLocalVoice24SpeechQueueConfigurationV29maximumReplayHistoryItemCountSivpZ -->
- `maximumReplayHistoryItemCount` (swift.type.property)
<!-- api-symbol: s:13AppLocalVoice24SpeechQueueConfigurationV29minimumPendingTextUTF16LengthSivpZ -->
- `minimumPendingTextUTF16Length` (swift.type.property)
<!-- api-symbol: s:13AppLocalVoice24SpeechQueueConfigurationV29minimumReplayHistoryItemCountSivpZ -->
- `minimumReplayHistoryItemCount` (swift.type.property)
<!-- api-symbol: s:13AppLocalVoice24SpeechQueueConfigurationV30defaultMaximumPendingItemCountSivpZ -->
- `defaultMaximumPendingItemCount` (swift.type.property)
<!-- api-symbol: s:13AppLocalVoice24SpeechQueueConfigurationV35maximumReplayHistoryTextUTF16LengthSivp -->
- `maximumReplayHistoryTextUTF16Length` (swift.property)
<!-- api-symbol: s:13AppLocalVoice24SpeechQueueConfigurationV35maximumReplayHistoryTextUTF16LengthSivpZ -->
- `maximumReplayHistoryTextUTF16Length` (swift.type.property)
<!-- api-symbol: s:13AppLocalVoice24SpeechQueueConfigurationV35minimumReplayHistoryTextUTF16LengthSivpZ -->
- `minimumReplayHistoryTextUTF16Length` (swift.type.property)
<!-- api-symbol: s:13AppLocalVoice24SpeechQueueConfigurationV36defaultMaximumPendingTextUTF16LengthSivpZ -->
- `defaultMaximumPendingTextUTF16Length` (swift.type.property)
<!-- api-symbol: s:13AppLocalVoice24SpeechQueueConfigurationV36defaultMaximumReplayHistoryItemCountSivpZ -->
- `defaultMaximumReplayHistoryItemCount` (swift.type.property)
<!-- api-symbol: s:13AppLocalVoice24SpeechQueueConfigurationV42defaultMaximumReplayHistoryTextUTF16LengthSivpZ -->
- `defaultMaximumReplayHistoryTextUTF16Length` (swift.type.property)
<!-- api-symbol: s:13AppLocalVoice24SpeechQueueConfigurationVACycfc -->
- `init()` (swift.init)
<!-- api-symbol: s:13AppLocalVoice25RecognitionModelReadinessO -->
- `RecognitionModelReadiness` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice25RecognitionModelReadinessO11unavailableyA2CmF -->
- `RecognitionModelReadiness.unavailable` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice25RecognitionModelReadinessO12notInstalledyACSb_tcACmF -->
- `RecognitionModelReadiness.notInstalled(installationAvailable:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice25RecognitionModelReadinessO7unknownyA2CmF -->
- `RecognitionModelReadiness.unknown` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice25RecognitionModelReadinessO9installedyA2CmF -->
- `RecognitionModelReadiness.installed` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice25SpeechQueueOverflowPolicyO -->
- `SpeechQueueOverflowPolicy` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice25SpeechQueueOverflowPolicyO17dropOldestPendingyA2CmF -->
- `SpeechQueueOverflowPolicy.dropOldestPending` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice25SpeechQueueOverflowPolicyO9rejectNewyA2CmF -->
- `SpeechQueueOverflowPolicy.rejectNew` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice25TranscriptPublicationKindO -->
- `TranscriptPublicationKind` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice25TranscriptPublicationKindO05finalD0yA2CmF -->
- `TranscriptPublicationKind.finalTranscript` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice25TranscriptPublicationKindO11stableChunkyA2CmF -->
- `TranscriptPublicationKind.stableChunk` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice25TranscriptPublicationKindO7previewyA2CmF -->
- `TranscriptPublicationKind.preview` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice26SpeechQueueAttemptSnapshotV -->
- `SpeechQueueAttemptSnapshot` (swift.struct)
<!-- api-symbol: s:13AppLocalVoice26SpeechQueueAttemptSnapshotV10playbackIDAA0d8PlaybackI0Vvp -->
- `playbackID` (swift.property)
<!-- api-symbol: s:13AppLocalVoice26SpeechQueueAttemptSnapshotV15textUTF16LengthSivp -->
- `textUTF16Length` (swift.property)
<!-- api-symbol: s:13AppLocalVoice26SpeechQueueAttemptSnapshotV6itemIDAA0d4ItemI0Vvp -->
- `itemID` (swift.property)
<!-- api-symbol: s:13AppLocalVoice26SpeechQueueAttemptSnapshotV8priorityAA0D8PriorityOvp -->
- `priority` (swift.property)
<!-- api-symbol: s:13AppLocalVoice27RecognitionPreparationPhaseO -->
- `RecognitionPreparationPhase` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice27RecognitionPreparationPhaseO14modelInstalledyA2CmF -->
- `RecognitionPreparationPhase.modelInstalled` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice27RecognitionPreparationPhaseO16downloadingModelyAcA0dH16DownloadProgressOcACmF -->
- `RecognitionPreparationPhase.downloadingModel(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice27RecognitionPreparationPhaseO17checkingReadinessyA2CmF -->
- `RecognitionPreparationPhase.checkingReadiness` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice27TranscriptPublicationPolicyO -->
- `TranscriptPublicationPolicy` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice27TranscriptPublicationPolicyO12stableChunksyAcA011StableChunkF0VcACmF -->
- `TranscriptPublicationPolicy.stableChunks(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice27TranscriptPublicationPolicyO15previewAndFinalyA2CmF -->
- `TranscriptPublicationPolicy.previewAndFinal` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice27TranscriptPublicationPolicyO9finalOnlyyA2CmF -->
- `TranscriptPublicationPolicy.finalOnly` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice28RecognitionPreparationResultV -->
- `RecognitionPreparationResult` (swift.struct)
<!-- api-symbol: s:13AppLocalVoice28RecognitionPreparationResultV14installedModelSbvp -->
- `installedModel` (swift.property)
<!-- api-symbol: s:13AppLocalVoice28RecognitionPreparationResultV18capabilitySnapshot14installedModelAcA0c10CapabilityH0V_Sbtcfc -->
- `init(capabilitySnapshot:installedModel:)` (swift.init)
<!-- api-symbol: s:13AppLocalVoice28RecognitionPreparationResultV18capabilitySnapshotAA0c10CapabilityH0Vvp -->
- `capabilitySnapshot` (swift.property)
<!-- api-symbol: s:13AppLocalVoice28RecognitionSessionAcceptanceV -->
- `RecognitionSessionAcceptance` (swift.struct)
<!-- api-symbol: s:13AppLocalVoice28RecognitionSessionAcceptanceV20acceptedEventOrdinals6UInt64Vvp -->
- `acceptedEventOrdinal` (swift.property)
<!-- api-symbol: s:13AppLocalVoice28RecognitionSessionAcceptanceV9sessionIDAA0deH0Vvp -->
- `sessionID` (swift.property)
<!-- api-symbol: s:13AppLocalVoice30RecognitionEventDeliveryLimitsO -->
- `RecognitionEventDeliveryLimits` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice30RecognitionEventDeliveryLimitsO014maximumDurableE18CountPerSubscriberSivpZ -->
- `maximumDurableEventCountPerSubscriber` (swift.type.property)
<!-- api-symbol: s:13AppLocalVoice30RecognitionEventDeliveryLimitsO22maximumSubscriberCountSivpZ -->
- `maximumSubscriberCount` (swift.type.property)
<!-- api-symbol: s:13AppLocalVoice31RecognitionSessionConfigurationV -->
- `RecognitionSessionConfiguration` (swift.struct)
<!-- api-symbol: s:13AppLocalVoice31RecognitionSessionConfigurationV014defaultMaximumD8Durations0I0VvpZ -->
- `defaultMaximumRecognitionDuration` (swift.type.property)
<!-- api-symbol: s:13AppLocalVoice31RecognitionSessionConfigurationV014maximumMaximumD8Durations0I0VvpZ -->
- `maximumMaximumRecognitionDuration` (swift.type.property)
<!-- api-symbol: s:13AppLocalVoice31RecognitionSessionConfigurationV014minimumMaximumD8Durations0I0VvpZ -->
- `minimumMaximumRecognitionDuration` (swift.type.property)
<!-- api-symbol: s:13AppLocalVoice31RecognitionSessionConfigurationV07maximumD8Durations0H0VSgvp -->
- `maximumRecognitionDuration` (swift.property)
<!-- api-symbol: s:13AppLocalVoice31RecognitionSessionConfigurationV11recognition17publicationPolicy09lifecycleI007maximumD8DurationAcA0dF0V_AA021TranscriptPublicationI0OAA014AudioLifecycleI0Vs0L0VSgtcfc -->
- `init(recognition:publicationPolicy:lifecyclePolicy:maximumRecognitionDuration:)` (swift.init)
<!-- api-symbol: s:13AppLocalVoice31RecognitionSessionConfigurationV11recognitionAA0dF0Vvp -->
- `recognition` (swift.property)
<!-- api-symbol: s:13AppLocalVoice31RecognitionSessionConfigurationV15lifecyclePolicyAA014AudioLifecycleH0Vvp -->
- `lifecyclePolicy` (swift.property)
<!-- api-symbol: s:13AppLocalVoice31RecognitionSessionConfigurationV17publicationPolicyAA021TranscriptPublicationH0Ovp -->
- `publicationPolicy` (swift.property)
<!-- api-symbol: s:13AppLocalVoice32RecognitionModelDownloadProgressO -->
- `RecognitionModelDownloadProgress` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice32RecognitionModelDownloadProgressO13indeterminateyA2CmF -->
- `RecognitionModelDownloadProgress.indeterminate` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice32RecognitionModelDownloadProgressO17fractionCompletedyACSdcACmF -->
- `RecognitionModelDownloadProgress.fractionCompleted(_:)` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice32SpeechPlaybackCancellationReasonO -->
- `SpeechPlaybackCancellationReason` (swift.enum)
<!-- api-symbol: s:13AppLocalVoice32SpeechPlaybackCancellationReasonO14closeRequestedyA2CmF -->
- `SpeechPlaybackCancellationReason.closeRequested` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice32SpeechPlaybackCancellationReasonO23supersededByRecognitionyA2CmF -->
- `SpeechPlaybackCancellationReason.supersededByRecognition` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice32SpeechPlaybackCancellationReasonO7clearedyA2CmF -->
- `SpeechPlaybackCancellationReason.cleared` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice32SpeechPlaybackCancellationReasonO7stoppedyA2CmF -->
- `SpeechPlaybackCancellationReason.stopped` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice32SpeechPlaybackCancellationReasonO8overflowyA2CmF -->
- `SpeechPlaybackCancellationReason.overflow` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice32SpeechPlaybackCancellationReasonO8replacedyA2CmF -->
- `SpeechPlaybackCancellationReason.replaced` (swift.enum.case)
<!-- api-symbol: s:13AppLocalVoice37RecognitionPreparationProgressHandlera -->
- `RecognitionPreparationProgressHandler` (swift.typealias)
<!-- api-symbol: s:13AppLocalVoiceAAC -->
- `AppLocalVoice` (swift.class)
<!-- api-symbol: s:13AppLocalVoiceAAC11diagnosticsScSyAA0C10DiagnosticVGyF -->
- `diagnostics()` (swift.method)
<!-- api-symbol: s:13AppLocalVoiceAAC11voiceEventsScsyAA0c11EventStreamF0Os5Error_pGyYaF -->
- `voiceEvents()` (swift.method)
<!-- api-symbol: s:13AppLocalVoiceAAC12replaySpeech6itemID6policyAA0E18PlaybackAcceptanceVAA0e4ItemG0V_AA0E13EnqueuePolicyOtYaKF -->
- `replaySpeech(itemID:policy:)` (swift.method)
<!-- api-symbol: s:13AppLocalVoiceAAC12startSession13configurationAA011RecognitionE10AcceptanceVAA0gE13ConfigurationV_tYaKF -->
- `startSession(configuration:)` (swift.method)
<!-- api-symbol: s:13AppLocalVoiceAAC13cancelSession2idyAA011RecognitionE2IDV_tYaF -->
- `cancelSession(id:)` (swift.method)
<!-- api-symbol: s:13AppLocalVoiceAAC13enqueueSpeech_8priority13configuration6policyAA0E18PlaybackAcceptanceVSS_AA0E8PriorityOAA0E13ConfigurationVAA0E13EnqueuePolicyOtYaKF -->
- `enqueueSpeech(_:priority:configuration:policy:)` (swift.method)
<!-- api-symbol: s:13AppLocalVoiceAAC13finishSession2idAA15FinalTranscriptVAA011RecognitionE2IDV_tYaKF -->
- `finishSession(id:)` (swift.method)
<!-- api-symbol: s:13AppLocalVoiceAAC13recoveryStateAA0c8RecoveryE0Ovp -->
- `recoveryState` (swift.property)
<!-- api-symbol: s:13AppLocalVoiceAAC15availableVoices3forSayAA06SpeechC0VG10Foundation6LocaleV_tYaF -->
- `availableVoices(for:)` (swift.method)
<!-- api-symbol: s:13AppLocalVoiceAAC15runtimeSnapshotAA0c7RuntimeE0VyYaF -->
- `runtimeSnapshot()` (swift.method)
<!-- api-symbol: s:13AppLocalVoiceAAC15skipSpeechQueueAA0E14PlaybackResultVSgyYaF -->
- `skipSpeechQueue()` (swift.method)
<!-- api-symbol: s:13AppLocalVoiceAAC15stopSpeechQueueSayAA0E14PlaybackResultVGyYaF -->
- `stopSpeechQueue()` (swift.method)
<!-- api-symbol: s:13AppLocalVoiceAAC16pauseSpeechQueueAA0E13ControlResultOyYaF -->
- `pauseSpeechQueue()` (swift.method)
<!-- api-symbol: s:13AppLocalVoiceAAC16speakImmediately_13configurationAA24SpeechPlaybackAcceptanceVSS_AA0G13ConfigurationVtYaKF -->
- `speakImmediately(_:configuration:)` (swift.method)
<!-- api-symbol: s:13AppLocalVoiceAAC17resumeSpeechQueueAA0E13ControlResultOyYaF -->
- `resumeSpeechQueue()` (swift.method)
<!-- api-symbol: s:13AppLocalVoiceAAC18capabilitySnapshot3forAA0c10CapabilityE0V10Foundation6LocaleV_tYaF -->
- `capabilitySnapshot(for:)` (swift.method)
<!-- api-symbol: s:13AppLocalVoiceAAC18prepareRecognition3for6policy8progressAA0E17PreparationResultV10Foundation6LocaleV_AA17SpeechModelPolicyOyAA0eI5PhaseOScMYccSgtYaKF -->
- `prepareRecognition(for:policy:progress:)` (swift.method)
<!-- api-symbol: s:13AppLocalVoiceAAC18queueConfiguration15lifecyclePolicy11diagnosticsAbA011SpeechQueueE0V_AA014AudioLifecycleG0VyAA0C10DiagnosticVScMYccSgtcfc -->
- `init(queueConfiguration:lifecyclePolicy:diagnostics:)` (swift.init)
<!-- api-symbol: s:13AppLocalVoiceAAC21waitForSpeechPlayback2idAA0fG6ResultVAA0fG2IDV_tYaKF -->
- `waitForSpeechPlayback(id:)` (swift.method)
<!-- api-symbol: s:13AppLocalVoiceAAC23clearPendingSpeechQueueSayAA0F14PlaybackResultVGyYaF -->
- `clearPendingSpeechQueue()` (swift.method)
<!-- api-symbol: s:13AppLocalVoiceAAC23stopAndClearSpeechQueueSayAA0G14PlaybackResultVGyYaF -->
- `stopAndClearSpeechQueue()` (swift.method)
<!-- api-symbol: s:13AppLocalVoiceAAC5closeAA13CleanupResultOyYaF -->
- `close()` (swift.method)
