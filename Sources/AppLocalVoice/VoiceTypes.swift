import Foundation

/// Safety limits that keep a single host request from turning into an
/// unbounded in-memory queue. The limit is deliberately internal so the
/// public surface stays small; the typed error reports the value to callers.
enum VoiceTextLimits {
    static let maximumUTF16Length = 1_048_576
}

/// Controls whether AppLocalVoice may ask Apple to install a missing speech model.
public enum SpeechModelPolicy: Sendable, Equatable {
    /// Use only a model already installed on the device.
    case installedModelsOnly
    /// Permit Apple to download the required model before capture begins.
    case allowModelInstallation
}

/// Configuration for one on-device speech-recognition turn.
public struct RecognitionConfiguration: Sendable, Equatable {
    /// Locale used for recognition and model selection.
    public var locale: Locale
    /// Policy controlling missing speech-model installation.
    public var policy: SpeechModelPolicy

    /// Creates recognition configuration with explicit locale and model policy.
    public init(locale: Locale = .current, policy: SpeechModelPolicy = .installedModelsOnly) {
        self.locale = locale
        self.policy = policy
    }
}

/// Configuration for one on-device speech-synthesis request.
public struct SpeechConfiguration: Sendable, Equatable {
    /// The locale used to select a system speech voice.
    ///
    /// The default preserves source compatibility with earlier releases. The
    /// value is captured when the configuration is created; synthesis never
    /// consults `Locale.current` implicitly afterward.
    public var locale: Locale
    /// Optional stable identifier of an installed Apple voice.
    public var voiceIdentifier: String?
    /// Preferred quality when selecting an installed voice automatically.
    public var preferredQuality: SpeechVoiceQuality
    /// AVSpeechSynthesizer speech rate in the inclusive 0...1 range.
    public var rate: Float
    /// AVSpeechSynthesizer volume in the inclusive 0...1 range.
    public var volume: Float
    /// Maximum number of UTF-16 code units in one synthesizer utterance.
    /// Long text is split at sentence and word boundaries. Values must be
    /// between 128 and 32,000; the upper bound keeps one queued utterance
    /// bounded while still allowing long responses. A complete speech request
    /// is also limited to 1,048,576 UTF-16 code units.
    public var maximumCharactersPerUtterance: Int

    /// Creates synthesis configuration with validated-at-use defaults.
    public init(
        locale: Locale = .current,
        voiceIdentifier: String? = nil,
        preferredQuality: SpeechVoiceQuality = .premium,
        rate: Float = 0.52,
        volume: Float = 1.0,
        maximumCharactersPerUtterance: Int = 4_000
    ) {
        self.locale = locale
        self.voiceIdentifier = voiceIdentifier
        self.preferredQuality = preferredQuality
        self.rate = rate
        self.volume = volume
        self.maximumCharactersPerUtterance = maximumCharactersPerUtterance
    }
}

/// Quality class reported by Apple's installed speech-voice catalog.
public enum SpeechVoiceQuality: Sendable, Equatable {
    /// The smaller, broadly available system voice class.
    case compact
    /// The higher-quality downloadable system voice class.
    case enhanced
    /// Apple's highest-quality downloadable voice class, when available.
    case premium
}

/// Metadata for one installed Apple speech voice.
public struct SpeechVoice: Sendable, Equatable, Identifiable {
    /// Stable Apple voice identifier accepted by `SpeechConfiguration`.
    public let id: String
    /// Display name supplied by Apple.
    public let name: String
    /// Informational BCP-47-like language identifier supplied by Apple.
    public let languageIdentifier: String
    /// Installed voice quality class.
    public let quality: SpeechVoiceQuality

    /// Creates voice metadata. Runtime catalogs are supplied by AppLocalVoice.
    public init(id: String, name: String, languageIdentifier: String, quality: SpeechVoiceQuality) {
        self.id = id
        self.name = name
        self.languageIdentifier = languageIdentifier
        self.quality = quality
    }
}

/// Device capability information for on-device speech recognition.
public struct SpeechCapabilities: Sendable, Equatable {
    /// Locale that was queried.
    public let locale: Locale
    /// Whether the locale is supported by the recognition stack. This can be
    /// true even when the current device cannot run the transcriber or the
    /// locale's asset is not installed.
    public let isSupported: Bool
    /// Whether the current device can use an installed on-device model for
    /// this locale. This reflects live hardware and asset readiness, not just
    /// locale support.
    public let supportsOnDevice: Bool
    /// Human-readable explanation when capability is unavailable.
    public let reason: String?

    /// Creates capability information.
    public init(locale: Locale, isSupported: Bool, supportsOnDevice: Bool, reason: String? = nil) {
        self.locale = locale
        self.isSupported = isSupported
        self.supportsOnDevice = supportsOnDevice
        self.reason = reason
    }
}

enum SpeechAuthorization: Sendable, Equatable {
    case notDetermined
    case denied
    case restricted
    case authorized
}

/// A complete transcript snapshot emitted during recognition.
public struct TranscriptUpdate: Sendable, Equatable {
    /// Full current transcript text, never a delta.
    public let text: String
    /// Whether this snapshot is final for the active turn.
    public let isFinal: Bool

    /// Creates a transcript snapshot.
    public init(text: String, isFinal: Bool) {
        self.text = text
        self.isFinal = isFinal
    }
}

/// Actionable serialized state of the voice service.
public enum VoiceState: Sendable, Equatable {
    /// No recognition or synthesis operation is active.
    case idle
    /// A recognition turn owns the lifecycle and is waiting on permission,
    /// model readiness, audio-session activation, or engine startup.
    case preparing
    /// Microphone capture and live recognition are active.
    case listening
    /// Capture has ended and the analyzer is producing its final result.
    case finalizing
    /// Speech synthesis is active.
    case speaking
    /// A failure state. Ordinary failures transition through `.failed` and
    /// then return to `.idle`; unresolved provider cleanup remains `.failed`
    /// and blocks new operations until a later `close()` reconciles resources.
    case failed
}

/// The reason a listening operation reached its terminal state.
///
/// A terminal event is emitted exactly once for every listening operation
/// that successfully reserved the coordinator. `failed` contains the
/// normalized public error so hosts do not need to infer a reason from state
/// transitions or implementation-specific errors.
public enum VoiceTerminationReason: Sendable, Equatable {
    /// Recognition produced its final snapshot successfully.
    case completed
    /// Recognition reached its configured capture-duration limit and finalized normally.
    case durationLimitReached
    /// The host or task cancelled recognition.
    case cancelled
    /// The system interrupted or invalidated the active audio route.
    case interrupted(VoiceInterruptionReason)
    /// Recognition failed with a typed public error.
    case failed(VoiceError)
}

/// Internal provider-boundary signal that preserves a system lifecycle cause
/// without exposing notification text through the public error surface.
struct VoiceLifecycleInterruption: Error, Sendable, Equatable {
    let reason: VoiceInterruptionReason
}

/// Event stream emitted by the serialized voice service.
public enum VoiceEvent: Sendable, Equatable {
    /// The public lifecycle state changed.
    case stateChanged(VoiceState)
    /// A complete partial or final transcript snapshot.
    case transcript(TranscriptUpdate)
    /// Recognition reached its exactly-once terminal reason.
    case listeningFinished(VoiceTerminationReason)
    /// Synthesis began playback.
    case speechStarted
    /// Synthesis completed playback.
    case speechFinished
    /// Synthesis was cancelled before completion.
    case speechCancelled
    /// A recoverable operation failure occurred.
    case failure(VoiceError)
}

/// Typed errors produced by recognition, synthesis, permissions, and lifecycle policy.
public enum VoiceError: Error, Sendable, Equatable, LocalizedError {
    /// The host or task cancelled the operation.
    case cancelled
    /// Microphone permission is denied.
    case microphonePermissionDenied
    /// Microphone use is restricted by the device or system policy.
    case microphonePermissionRestricted
    /// Speech-recognition permission is denied.
    case speechPermissionDenied
    /// Speech recognition is restricted by the device or system policy.
    case speechPermissionRestricted
    /// Apple does not support recognition for the requested locale.
    case unsupportedLocale(Locale)
    /// A required on-device recognition capability is unavailable.
    case onDeviceRecognitionUnavailable(Locale)
    /// Apple's system-managed recognition-model installation failed.
    case recognitionModelInstallationFailed(
        Locale,
        providerError: VoiceProviderErrorCode? = nil
    )
    /// The shared audio session could not be configured or activated.
    case audioSessionUnavailable(String)
    /// A system interruption or route invalidation ended the operation.
    case interrupted(String)
    /// The active audio route was lost or became unusable.
    case audioRouteUnavailable
    /// Apple synthesis failed or did not report completion before recovery timeout.
    case speechSynthesisUnavailable(String)
    /// The requested installed voice is unavailable.
    case speechVoiceUnavailable(String)
    /// A recognition transcript or synthesis request exceeded the bounded
    /// text-memory safety limit.
    case textTooLong(maximumUTF16Length: Int)
    /// A bounded operation watchdog expired.
    case operationTimedOut
    /// Another facade owns the process-wide runtime lease.
    case serviceInUse
    /// A canonical event subscription exceeded the process-wide observer
    /// limit. Existing observers are unchanged.
    case eventSubscriberLimitReached(maximum: Int, active: Int)
    /// A subscriber exhausted its finite durable-event delivery buffer. The
    /// cursor identifies the first durable event that was not delivered.
    case eventDeliveryOverflow(capacity: Int, firstUndelivered: EventDeliveryCursor)
    /// Provider output contradicted an already published stable transcript prefix.
    case transcriptConsistency
    /// Overflow policy rejected a new attempt because the pending queue is full.
    case queueFull(maximumPendingItemCount: Int)
    /// Aggregate queued text would exceed the configured UTF-16 retention budget.
    case queueTextBudgetExceeded(maximumUTF16Length: Int)
    /// Replay history no longer retains the requested immutable item.
    case itemUnavailable(SpeechItemID)
    /// Resource release is unresolved; only close or reconciliation is safe.
    case cleanupPending
    /// Recognition or transcript-publication configuration failed validation.
    case invalidRecognitionConfiguration(String)
    /// Synthesis configuration failed validation.
    case invalidSpeechConfiguration(String)
    /// Queue bounds or overflow configuration failed validation.
    case invalidSpeechQueueConfiguration(String)
    /// A speech item failed validation before queue admission.
    case invalidSpeechItem(String)
    /// The requested operation is incompatible with the current lifecycle state.
    case invalidState(String)
    /// An underlying provider failure without a more specific category.
    case underlying(String)

    /// A stable, content-free category suitable for diagnostics and metrics.
    ///
    /// Associated values on ``VoiceError`` are intentionally not included.
    /// Hosts must match this category rather than localized descriptions.
    public var category: VoiceErrorCategory {
        switch self {
        case .cancelled: .cancelled
        case .microphonePermissionDenied: .microphonePermissionDenied
        case .microphonePermissionRestricted: .microphonePermissionRestricted
        case .speechPermissionDenied: .speechPermissionDenied
        case .speechPermissionRestricted: .speechPermissionRestricted
        case .unsupportedLocale: .unsupportedLocale
        case .onDeviceRecognitionUnavailable: .onDeviceRecognitionUnavailable
        case .recognitionModelInstallationFailed: .recognitionModelInstallationFailed
        case .audioSessionUnavailable: .audioSessionUnavailable
        case .interrupted: .interrupted
        case .audioRouteUnavailable: .audioRouteUnavailable
        case .speechSynthesisUnavailable: .speechSynthesisUnavailable
        case .speechVoiceUnavailable: .speechVoiceUnavailable
        case .textTooLong: .textTooLong
        case .operationTimedOut: .operationTimedOut
        case .serviceInUse: .serviceInUse
        case .eventSubscriberLimitReached: .eventSubscriberLimitReached
        case .eventDeliveryOverflow: .eventDeliveryOverflow
        case .transcriptConsistency: .transcriptConsistency
        case .queueFull: .queueFull
        case .queueTextBudgetExceeded: .queueTextBudgetExceeded
        case .itemUnavailable: .itemUnavailable
        case .cleanupPending: .cleanupPending
        case .invalidRecognitionConfiguration: .invalidRecognitionConfiguration
        case .invalidSpeechConfiguration: .invalidSpeechConfiguration
        case .invalidSpeechQueueConfiguration: .invalidSpeechQueueConfiguration
        case .invalidSpeechItem: .invalidSpeechItem
        case .invalidState: .invalidState
        case .underlying: .underlying
        }
    }

    /// Stable host action recommended for this error category.
    public var recommendedRecoveryAction: VoiceRecoveryAction {
        switch self {
        case .cancelled: .none
        case .microphonePermissionDenied, .speechPermissionDenied: .openSettings
        case .microphonePermissionRestricted, .speechPermissionRestricted: .showPermissionHelp
        case .unsupportedLocale: .chooseSupportedLocale
        case .onDeviceRecognitionUnavailable: .reviewRecognitionModel
        case .recognitionModelInstallationFailed: .retry
        case .audioSessionUnavailable, .speechSynthesisUnavailable, .operationTimedOut, .underlying: .retry
        case .interrupted, .audioRouteUnavailable: .retryAfterInterruption
        case .speechVoiceUnavailable: .chooseInstalledVoice
        case .textTooLong: .shortenText
        case .serviceInUse: .useOwningService
        case .eventSubscriberLimitReached, .eventDeliveryOverflow: .reconcileEventState
        case .transcriptConsistency: .discardPartialTranscript
        case .queueFull: .makeQueueSpace
        case .queueTextBudgetExceeded: .shortenText
        case .itemUnavailable: .reenqueueItem
        case .cleanupPending: .retryCleanup
        case .invalidRecognitionConfiguration,
             .invalidSpeechConfiguration,
             .invalidSpeechQueueConfiguration,
             .invalidSpeechItem: .changeConfiguration
        case .invalidState: .waitForIdle
        }
    }

    /// Content-free failure metadata suitable for public lifecycle events.
    public var failure: VoiceFailure {
        VoiceFailure(category: category, recommendedAction: recommendedRecoveryAction)
    }

    /// A human-readable message for display and debugging; not a stable code.
    public var errorDescription: String? {
        switch self {
        case .cancelled: "Speech was cancelled."
        case .microphonePermissionDenied: "Microphone permission is required."
        case .microphonePermissionRestricted: "Microphone use is restricted on this device."
        case .speechPermissionDenied: "Speech recognition permission is required."
        case .speechPermissionRestricted: "Speech recognition is restricted on this device."
        case .unsupportedLocale(let locale): "Speech recognition is unavailable for \(locale.identifier)."
        case .onDeviceRecognitionUnavailable(let locale): "On-device speech recognition is unavailable for \(locale.identifier)."
        case .recognitionModelInstallationFailed(let locale, _):
            "The on-device recognition model could not be installed for \(locale.identifier)."
        case .audioSessionUnavailable(let message): message
        case .interrupted(let message): message
        case .audioRouteUnavailable: "The active audio route is unavailable."
        case .speechSynthesisUnavailable(let message): message
        case .speechVoiceUnavailable(let identifier): "The requested speech voice is unavailable: \(identifier)."
        case .textTooLong(let maximumUTF16Length):
            "Speech text exceeds the maximum supported size of \(maximumUTF16Length) UTF-16 code units."
        case .operationTimedOut: "The voice operation timed out."
        case .serviceInUse: "Another voice service currently owns the process audio runtime."
        case .eventSubscriberLimitReached(let maximum, let active):
            "The canonical event observer limit is \(maximum); \(active) observers are active."
        case .eventDeliveryOverflow(let capacity, _):
            "The event observer exceeded its durable-event capacity of \(capacity)."
        case .transcriptConsistency:
            "Recognition output contradicted an already published stable transcript."
        case .queueFull(let maximumPendingItemCount):
            "The speech queue already contains its maximum of \(maximumPendingItemCount) pending items."
        case .queueTextBudgetExceeded(let maximumUTF16Length):
            "Queued speech text exceeds the configured retention limit of \(maximumUTF16Length) UTF-16 code units."
        case .itemUnavailable(let itemID):
            "The speech item is no longer retained for replay: \(itemID)."
        case .cleanupPending: "Audio resources are not fully reconciled."
        case .invalidRecognitionConfiguration(let message): message
        case .invalidSpeechConfiguration(let message): message
        case .invalidSpeechQueueConfiguration(let message): message
        case .invalidSpeechItem(let message): message
        case .invalidState(let message): message
        case .underlying(let message): message
        }
    }
}

/// Content-free identity for an underlying system/provider error.
///
/// Provider descriptions and `userInfo` are intentionally discarded because
/// they are neither stable contracts nor safe diagnostic fields.
public struct VoiceProviderErrorCode: Sendable, Equatable {
    /// The provider-owned error domain.
    public let domain: String
    /// The provider-owned numeric error code.
    public let code: Int

    /// Creates stable provider error identity without retaining descriptions.
    public init(domain: String, code: Int) {
        self.domain = domain
        self.code = code
    }
}

/// Stable error categories that contain no human-entered or provider-supplied
/// text. This is the only error representation emitted by diagnostics.
public enum VoiceErrorCategory: Sendable, Equatable {
    /// Cancellation category.
    case cancelled
    /// Microphone permission category.
    case microphonePermissionDenied
    /// Restricted microphone category.
    case microphonePermissionRestricted
    /// Speech permission category.
    case speechPermissionDenied
    /// Restricted speech-recognition category.
    case speechPermissionRestricted
    /// Unsupported locale category.
    case unsupportedLocale
    /// On-device recognition availability category.
    case onDeviceRecognitionUnavailable
    /// Recognition-model installation category.
    case recognitionModelInstallationFailed
    /// Audio-session category.
    case audioSessionUnavailable
    /// Interruption category.
    case interrupted
    /// Audio-route loss category.
    case audioRouteUnavailable
    /// Speech synthesis category.
    case speechSynthesisUnavailable
    /// Voice-catalog availability category.
    case speechVoiceUnavailable
    /// Bounded text-memory category.
    case textTooLong
    /// Operation watchdog category.
    case operationTimedOut
    /// Competing process-runtime owner category.
    case serviceInUse
    /// Canonical event-subscriber admission category.
    case eventSubscriberLimitReached
    /// Durable event-delivery overflow category.
    case eventDeliveryOverflow
    /// Stable transcript contradiction category.
    case transcriptConsistency
    /// Bounded pending-queue rejection category.
    case queueFull
    /// Aggregate queued-text retention category.
    case queueTextBudgetExceeded
    /// Missing bounded replay-history item category.
    case itemUnavailable
    /// Unresolved resource-cleanup category.
    case cleanupPending
    /// Invalid recognition configuration category.
    case invalidRecognitionConfiguration
    /// Invalid synthesis configuration category.
    case invalidSpeechConfiguration
    /// Invalid queue configuration category.
    case invalidSpeechQueueConfiguration
    /// Invalid speech-item category.
    case invalidSpeechItem
    /// Invalid lifecycle-state category.
    case invalidState
    /// Generic underlying-failure category.
    case underlying
}

/// Stable host action associated with a public error category.
public enum VoiceRecoveryAction: Sendable, Equatable {
    /// No additional host action is required.
    case none
    /// Direct the user to the relevant system settings.
    case openSettings
    /// Explain that device or system policy prevents the requested permission.
    case showPermissionHelp
    /// Ask the host to select a supported recognition locale.
    case chooseSupportedLocale
    /// Ask the host to inspect or install the required recognition model.
    case reviewRecognitionModel
    /// Ask the host to select a voice that is installed on the device.
    case chooseInstalledVoice
    /// Retry the failed operation.
    case retry
    /// Retry after the system interruption has ended.
    case retryAfterInterruption
    /// Shorten the text before submitting it again.
    case shortenText
    /// Correct the supplied operation configuration.
    case changeConfiguration
    /// Wait until the current serialized operation is idle.
    case waitForIdle
    /// Route the request through the service that owns the process runtime lease.
    case useOwningService
    /// Reconcile the event cursor or subscription state before continuing.
    case reconcileEventState
    /// Discard the partial transcript and begin a fresh recognition turn.
    case discardPartialTranscript
    /// Remove or cancel queued work before enqueuing another item.
    case makeQueueSpace
    /// Recreate a speech item and enqueue it again.
    case reenqueueItem
    /// Explicitly retry unresolved resource cleanup.
    case retryCleanup
}

/// Content-free, actionable failure metadata for session, queue, capability,
/// and resource-reconciliation events.
public struct VoiceFailure: Sendable, Equatable {
    /// Stable category for the failure.
    public let category: VoiceErrorCategory
    /// Host action recommended for recovering from the failure.
    public let recommendedAction: VoiceRecoveryAction

    /// Creates content-free failure metadata.
    public init(category: VoiceErrorCategory, recommendedAction: VoiceRecoveryAction) {
        self.category = category
        self.recommendedAction = recommendedAction
    }
}

/// The logical operation represented by an opt-in diagnostic record.
public enum VoiceDiagnosticOperation: Sendable, Equatable {
    /// A microphone recognition operation.
    case listening
    /// A speech-synthesis operation.
    case speaking
    /// A host-requested cleanup operation.
    case close
}

/// The lifecycle point represented by an opt-in diagnostic record.
public enum VoiceDiagnosticPhase: Sendable, Equatable {
    /// The operation reserved its lifecycle.
    case started
    /// The operation completed normally.
    case completed
    /// The operation ended by explicit cancellation or a controlled stop.
    case cancelled
    /// The operation ended with a stable failure category.
    case failed
}

/// A coarse audio-output route classification. It deliberately excludes the
/// route's device name, UID, and any other identifying metadata.
public enum VoiceRouteClass: Sendable, Equatable {
    /// The route could not be safely classified.
    case unknown
    /// A built-in device speaker route.
    case builtInSpeaker
    /// A built-in receiver route.
    case builtInReceiver
    /// A wired headset or line-output route.
    case wired
    /// A Bluetooth route without device identity metadata.
    case bluetooth
    /// A USB audio route.
    case usb
    /// An in-car audio route.
    case car
    /// An AirPlay route.
    case airPlay
    /// A route outside the known coarse classes.
    case other
}

/// One privacy-safe, opt-in lifecycle observation.
///
/// Diagnostics contain state, a host-correlatable operation identity, a
/// stable error category, a coarse route class, and monotonic elapsed time.
/// They never contain audio, transcript text, synthesized text, voice names,
/// device names, route identifiers, or arbitrary error descriptions.
public struct VoiceDiagnostic: Sendable, Equatable {
    /// Library-generated correlation identity for this logical operation.
    public let operationID: UUID
    /// The operation lane represented by this record.
    public let operation: VoiceDiagnosticOperation
    /// The lifecycle phase represented by this record.
    public let phase: VoiceDiagnosticPhase
    /// Serialized voice state when this record was emitted.
    public let state: VoiceState
    /// Stable failure category, if this phase represents a failure.
    public let errorCategory: VoiceErrorCategory?
    /// Coarse route class without route identity metadata.
    public let routeClass: VoiceRouteClass
    /// Monotonic elapsed time from operation admission, in nanoseconds.
    public let durationNanoseconds: UInt64

    /// Creates a content-free diagnostic record.
    public init(
        operationID: UUID,
        operation: VoiceDiagnosticOperation,
        phase: VoiceDiagnosticPhase,
        state: VoiceState,
        errorCategory: VoiceErrorCategory? = nil,
        routeClass: VoiceRouteClass = .unknown,
        durationNanoseconds: UInt64 = 0
    ) {
        self.operationID = operationID
        self.operation = operation
        self.phase = phase
        self.state = state
        self.errorCategory = errorCategory
        self.routeClass = routeClass
        self.durationNanoseconds = durationNanoseconds
    }
}

/// An opt-in callback for privacy-safe lifecycle diagnostics.
///
/// The callback executes on the ``AppLocalVoice`` main actor. The host owns
/// retention, aggregation, and export of these records. AppLocalVoice never
/// logs or persists them.
public typealias VoiceDiagnosticsSink = @MainActor @Sendable (VoiceDiagnostic) -> Void

/// Bounded stream of privacy-safe diagnostic records.
///
/// The stream carries no transcript, synthesized text, provider description,
/// route identifier, or credential-like value. A slow consumer may lose older
/// records; it must use the lifecycle/event APIs for authoritative recovery.
public typealias VoiceDiagnosticsStream = AsyncStream<VoiceDiagnostic>
