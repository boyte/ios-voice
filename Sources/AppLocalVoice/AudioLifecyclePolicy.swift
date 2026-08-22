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

/// Process audio behavior selected for a host-ready session and speech queue.
///
/// Backgrounding, system interruptions, and route invalidation always stop
/// active work and require an explicit host restart; blocked cleanup always
/// requires an explicit `close()` retry. Only the external-audio policy is
/// configurable.
public struct AudioLifecyclePolicy: Sendable, Equatable {
    /// Policy for audio that is already playing outside AppLocalVoice.
    public var externalAudio: ExternalAudioPolicy

    /// Creates an audio lifecycle policy.
    public init(externalAudio: ExternalAudioPolicy = .duck) {
        self.externalAudio = externalAudio
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
