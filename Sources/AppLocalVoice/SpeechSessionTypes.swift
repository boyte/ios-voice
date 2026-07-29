import Foundation

/// Library-generated identity for one admitted recognition generation.
///
/// Hosts may compare and retain this value, but do not choose it. The library
/// allocates it after reserving a recognition request and before provider work.
public struct RecognitionSessionID: Hashable, Sendable, CustomStringConvertible {
    /// UUID backing this library-generated session identity.
    public let rawValue: UUID

    init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    init() {
        self.init(rawValue: UUID())
    }

    /// String representation of the underlying UUID.
    public var description: String { rawValue.uuidString }
}

/// Validated publication cadence for immutable stable transcript chunks.
///
/// The interval is an earliest desired boundary. The publisher may wait for a
/// sentence, word, or grapheme boundary before emitting stable text.
public struct StableChunkPolicy: Hashable, Sendable {
    /// Smallest permitted stable-chunk interval, in seconds.
    public static let minimumIntervalSeconds = 1
    /// Largest permitted stable-chunk interval, in seconds.
    public static let maximumIntervalSeconds = 30
    /// Default stable-chunk interval, in seconds.
    public static let defaultIntervalSeconds = 5

    /// Recommended stable-chunk policy for general interactive use.
    public static let recommended = StableChunkPolicy(
        validatedIntervalSeconds: defaultIntervalSeconds
    )

    /// Stable-chunk interval requested by the host, in seconds.
    public let intervalSeconds: Int

    /// Creates a policy whose interval is in the inclusive 1...30-second range.
    public init(intervalSeconds: Int) throws {
        guard Self.minimumIntervalSeconds...Self.maximumIntervalSeconds ~= intervalSeconds else {
            throw VoiceError.invalidRecognitionConfiguration(
                "Stable chunk intervals must be between 1 and 30 seconds."
            )
        }
        self.init(validatedIntervalSeconds: intervalSeconds)
    }

    private init(validatedIntervalSeconds: Int) {
        intervalSeconds = validatedIntervalSeconds
    }
}

/// Selects the transcript payload kinds published for one recognition session.
///
/// Editable draft is host behavior built from `.previewAndFinal`; it is not a
/// fourth library publication policy or a submit/discard state.
public enum TranscriptPublicationPolicy: Hashable, Sendable {
    /// Emit volatile preview snapshots followed by one recognition-final value.
    case previewAndFinal
    /// Suppress previews and chunks, then emit one recognition-final value.
    case finalOnly
    /// Emit previews, immutable stable chunks, and one recognition-final value.
    case stableChunks(StableChunkPolicy)
}

/// Host-ready configuration for one recognition session.
///
/// This additive value composes the existing provider configuration with the
/// accepted publication and lifecycle policies. It does not start provider work.
public struct RecognitionSessionConfiguration: Sendable, Equatable {
    /// Default library-managed recognition duration.
    public static let defaultMaximumRecognitionDuration: Duration = .seconds(120)
    /// Smallest finite recognition duration accepted by the library.
    public static let minimumMaximumRecognitionDuration: Duration = .seconds(1)
    /// Largest finite recognition duration accepted by the library.
    public static let maximumMaximumRecognitionDuration: Duration = .seconds(600)
    /// Provider recognition settings for this session.
    public var recognition: RecognitionConfiguration
    /// Transcript payload cadence for this session.
    public var publicationPolicy: TranscriptPublicationPolicy
    /// Audio interruption, route, background, and cleanup behavior for this session.
    public var lifecyclePolicy: AudioLifecyclePolicy
    /// Maximum capture time after the provider reaches listening, or `nil` for no library limit.
    public var maximumRecognitionDuration: Duration?

    /// Creates host-ready session configuration without starting provider work.
    public init(
        recognition: RecognitionConfiguration = .init(),
        publicationPolicy: TranscriptPublicationPolicy = .previewAndFinal,
        lifecyclePolicy: AudioLifecyclePolicy = .init(),
        maximumRecognitionDuration: Duration? = Self.defaultMaximumRecognitionDuration
    ) {
        self.recognition = recognition
        self.publicationPolicy = publicationPolicy
        self.lifecyclePolicy = lifecyclePolicy
        self.maximumRecognitionDuration = maximumRecognitionDuration
    }
}

/// Fixed process admission and per-subscriber durable memory bounds for the
/// canonical recognition event API. Coalesced preview and state slots do not
/// consume durable capacity.
public enum RecognitionEventDeliveryLimits {
    /// Maximum number of simultaneous process-wide event subscribers.
    public static let maximumSubscriberCount = 8
    /// Maximum number of durable events retained for each subscriber.
    public static let maximumDurableEventCountPerSubscriber = 32

    /// Compatibility spelling retained for the provisional E1 model surface.
    public static let maximumNonPreviewEventsPerSubscriber =
        maximumDurableEventCountPerSubscriber
}

/// Host-visible authorization state for a protected speech resource.
public enum VoicePermissionStatus: Sendable, Equatable {
    /// Permission has not yet been requested.
    case notDetermined
    /// Permission was granted.
    case authorized
    /// Permission was denied.
    case denied
    /// Permission is unavailable because of device or system restrictions.
    case restricted
}

/// Readiness of the on-device recognition model for a resolved locale.
public enum RecognitionModelReadiness: Sendable, Equatable {
    /// A usable recognition model is installed.
    case installed
    /// The model is absent; the associated value reports whether installation can be requested.
    case notInstalled(installationAvailable: Bool)
    /// The locale or device cannot provide a recognition model.
    case unavailable
    /// Model readiness could not be determined.
    case unknown
}

/// Machine-readable availability of one host-facing feature.
public enum VoiceCapabilityAvailability: Sendable, Equatable {
    /// The feature is available for the queried capability snapshot.
    case available
    /// The feature is unavailable for the associated typed reason.
    case unavailable(VoiceFailure)
}

/// Features reported independently from starting an operation.
public enum VoiceFeature: Hashable, Sendable {
    /// On-device speech recognition.
    case speechRecognition
    /// Installation of a missing recognition model.
    case modelInstallation
    /// Volatile live transcript previews.
    case liveTranscriptPreview
    /// Immutable stable transcript chunks.
    case stableTranscriptChunks
    /// Speech synthesis.
    case speechSynthesis
    /// Ordered speech queue admission and playback.
    case speechQueue
    /// Pause and resume controls for queued speech.
    case speechPauseResume
}

/// Locale and model capability for on-device recognition.
public struct RecognitionCapability: Sendable, Equatable {
    /// Locale requested by the host.
    public let requestedLocale: Locale
    /// Apple's resolved locale, including a same-language regional equivalent.
    public let resolvedLocale: Locale?
    /// Readiness of the recognition model for the resolved locale.
    public let modelReadiness: RecognitionModelReadiness
    /// Overall availability of recognition for this capability query.
    public let availability: VoiceCapabilityAvailability

    /// Creates locale and model capability metadata.
    public init(
        requestedLocale: Locale,
        resolvedLocale: Locale?,
        modelReadiness: RecognitionModelReadiness,
        availability: VoiceCapabilityAvailability
    ) {
        self.requestedLocale = requestedLocale
        self.resolvedLocale = resolvedLocale
        self.modelReadiness = modelReadiness
        self.availability = availability
    }
}

/// A point-in-time, provider-neutral capability snapshot.
///
/// Capability lookup does not acquire the process runtime lease and does not
/// guarantee that a later mutating operation will still observe the same state.
public struct VoiceCapabilitySnapshot: Sendable, Equatable {
    /// Current microphone authorization state.
    public let microphonePermission: VoicePermissionStatus
    /// Current speech-recognition authorization state.
    public let speechRecognitionPermission: VoicePermissionStatus
    /// Locale and model capability metadata.
    public let recognition: RecognitionCapability
    /// Voices currently installed for the queried locale.
    public let installedVoices: [SpeechVoice]
    /// An absent key means that feature was not queried in this snapshot.
    public let features: [VoiceFeature: VoiceCapabilityAvailability]

    /// Creates a point-in-time capability snapshot.
    public init(
        microphonePermission: VoicePermissionStatus,
        speechRecognitionPermission: VoicePermissionStatus,
        recognition: RecognitionCapability,
        installedVoices: [SpeechVoice],
        features: [VoiceFeature: VoiceCapabilityAvailability]
    ) {
        self.microphonePermission = microphonePermission
        self.speechRecognitionPermission = speechRecognitionPermission
        self.recognition = recognition
        self.installedVoices = installedVoices
        self.features = features
    }

    /// Returns the queried availability for a feature, if the snapshot contains it.
    public func availability(for feature: VoiceFeature) -> VoiceCapabilityAvailability? {
        features[feature]
    }
}

/// Result of an explicit, side-effecting recognition preparation request.
///
/// Preparation may request the permissions required by the active Apple speech
/// path and, when opted in, install a missing local model. It never creates a
/// recognition session, opens the microphone, configures audio, or acquires a
/// process runtime lease.
public struct RecognitionPreparationResult: Sendable, Equatable {
    /// Capability truth re-read after preparation completed.
    public let capabilitySnapshot: VoiceCapabilitySnapshot
    /// Whether this call owned a system installation request that completed
    /// successfully and reconciled to installed. Joining an existing download,
    /// observing a preinstalled model, or receiving a nil request returns false.
    public let installedModel: Bool

    /// Creates explicit preparation metadata.
    public init(capabilitySnapshot: VoiceCapabilitySnapshot, installedModel: Bool) {
        self.capabilitySnapshot = capabilitySnapshot
        self.installedModel = installedModel
    }
}

/// Content-free progress for Apple's system-managed recognition-model download.
public enum RecognitionModelDownloadProgress: Sendable, Equatable {
    /// Apple has not exposed a meaningful total for this download.
    case indeterminate
    /// A finite, clamped fraction in the inclusive `0...1` range.
    case fractionCompleted(Double)
}

/// A content-free phase emitted by explicit recognition preparation.
public enum RecognitionPreparationPhase: Sendable, Equatable {
    /// Permissions, locale support, and current model state are being checked.
    case checkingReadiness
    /// Apple is downloading or reconciling the requested recognition model.
    case downloadingModel(RecognitionModelDownloadProgress)
    /// The required recognition model was re-read as installed.
    case modelInstalled
}

/// Main-actor delivery for authoritative recognition-preparation progress.
///
/// Values contain no provider descriptions, locale identifiers, transcript
/// text, audio, or host content. Delivery ends before `prepareRecognition`
/// returns or throws.
public typealias RecognitionPreparationProgressHandler =
    @MainActor @Sendable (RecognitionPreparationPhase) -> Void
