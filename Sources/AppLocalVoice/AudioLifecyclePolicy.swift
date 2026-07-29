/// Typed, content-free cause of an interrupted recognition or playback outcome.
public enum VoiceInterruptionReason: Sendable, Equatable {
    /// A phone call, Siri session, alarm, or other system interruption began.
    case systemInterruption
    /// The active audio route became unavailable or changed incompatibly.
    case routeChange
    /// The application entered the background while audio work was active.
    case appBackground
    /// The system audio services were reset while audio work was active.
    case mediaServicesReset
}

/// Policy for audio already playing outside AppLocalVoice.
public enum ExternalAudioPolicy: Sendable, Equatable {
    /// Continue AppLocalVoice audio alongside other audio when the system permits it.
    case mix
    /// Lower the volume of other audio while AppLocalVoice is active.
    case duck
    /// Interrupt other audio when AppLocalVoice starts audio work.
    case interrupt
    /// Reject AppLocalVoice audio when other audio is already active.
    case reject
}

/// Policy applied when an ordinary application enters the background.
/// Listening always ends and playback never silently resumes on foreground.
public enum VoiceBackgroundPolicy: Sendable, Equatable {
    /// Stop active audio work when the application enters the background.
    case stop
}

/// Policy for phone, Siri, alarm, and similar system interruptions.
/// Active work stops and a later user action is required to restart or resume.
public enum VoiceInterruptionPolicy: Sendable, Equatable {
    /// Stop active work and require a later explicit host action to restart it.
    case stop
}

/// Policy for an invalidated route. Active work stops and requires an explicit
/// user restart.
public enum VoiceRouteChangePolicy: Sendable, Equatable {
    /// Stop active work and require an explicit host restart after the route changes.
    case stopAndRequireRestart
}

/// Bounded cleanup retry behavior after logical operation termination.
public enum VoiceCleanupFailurePolicy: Sendable, Equatable {
    /// Keep the service blocked until the host explicitly retries cleanup.
    case requireExplicitRetry
}

/// Process audio behavior selected for a host-ready session and speech queue.
public struct AudioLifecyclePolicy: Sendable, Equatable {
    /// Policy for audio that is already playing outside AppLocalVoice.
    public var externalAudio: ExternalAudioPolicy
    /// Policy applied when the application enters the background.
    public var background: VoiceBackgroundPolicy
    /// Policy applied to phone, Siri, alarm, and similar system interruptions.
    public var interruption: VoiceInterruptionPolicy
    /// Policy applied when the active audio route is invalidated.
    public var routeChange: VoiceRouteChangePolicy
    /// Policy applied when resource cleanup does not complete immediately.
    public var cleanupFailure: VoiceCleanupFailurePolicy

    /// Creates an audio lifecycle policy with conservative restart and cleanup defaults.
    public init(
        externalAudio: ExternalAudioPolicy = .duck,
        background: VoiceBackgroundPolicy = .stop,
        interruption: VoiceInterruptionPolicy = .stop,
        routeChange: VoiceRouteChangePolicy = .stopAndRequireRestart,
        cleanupFailure: VoiceCleanupFailurePolicy = .requireExplicitRetry
    ) {
        self.externalAudio = externalAudio
        self.background = background
        self.interruption = interruption
        self.routeChange = routeChange
        self.cleanupFailure = cleanupFailure
    }
}

/// Whether new process audio work is currently safe.
public enum VoiceRecoveryState: Sendable, Equatable {
    /// New audio work may be admitted immediately.
    case ready
    /// The service is reconciling resources from a prior operation.
    case reconciling
    /// Cleanup failed and the associated failure explains what the host should do.
    case blocked(VoiceFailure)
}

/// Result of one explicit close or resource-reconciliation request.
public enum CleanupResult: Sendable, Equatable {
    /// Resources were released successfully.
    case released
    /// Cleanup remains unresolved and the failure describes the required recovery.
    case blocked(VoiceFailure)
}
