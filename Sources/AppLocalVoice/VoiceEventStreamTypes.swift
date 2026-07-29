import Foundation

/// Process-scoped recovery transition carried by the canonical event stream.
public enum VoiceRecoveryEventKind: Sendable, Equatable {
    /// The process is ready for new audio work.
    case ready
    /// The process is reconciling resources from a prior operation.
    case reconciling
    /// Cleanup remains blocked by the associated failure.
    case blocked(VoiceFailure)
}

extension VoiceRecoveryEventKind {
    var recoveryState: VoiceRecoveryState {
        switch self {
        case .ready: .ready
        case .reconciling: .reconciling
        case .blocked(let failure): .blocked(failure)
        }
    }

    init(recoveryState: VoiceRecoveryState) {
        switch recoveryState {
        case .ready: self = .ready
        case .reconciling: self = .reconciling
        case .blocked(let failure): self = .blocked(failure)
        }
    }
}

/// Ordered, content-free recovery event.
public struct VoiceRecoveryEvent: Sendable, Equatable {
    /// Monotonic process-wide ordinal of this recovery event.
    public let eventOrdinal: UInt64
    /// Recovery transition represented by this event.
    public let kind: VoiceRecoveryEventKind

    /// Creates an ordered recovery event.
    public init(eventOrdinal: UInt64, kind: VoiceRecoveryEventKind) {
        self.eventOrdinal = eventOrdinal
        self.kind = kind
    }
}

/// One value in the canonical throwing stream. Hosts can consume recognition,
/// playback, and recovery through one subscription without adopting a
/// backend, chat-message, or UI abstraction.
public enum VoiceEventStreamEvent: Sendable, Equatable {
    /// A finite current-state snapshot delivered only to a newly subscribed stream.
    case snapshot(VoiceRuntimeSnapshot)
    /// A recognition-session event.
    case recognition(RecognitionEvent)
    /// A speech-queue or playback event.
    case speechQueue(SpeechQueueEvent)
    /// Coalescible original-text playback progress.
    case speechProgress(SpeechPlaybackProgress)
    /// A process recovery event.
    case recovery(VoiceRecoveryEvent)

    /// Monotonic ordinal carried by the underlying event.
    public var eventOrdinal: UInt64 {
        switch self {
        case .snapshot(let value): value.generation
        case .recognition(let event): event.eventOrdinal
        case .speechQueue(let event): event.eventOrdinal
        case .speechProgress: 0
        case .recovery(let event): event.eventOrdinal
        }
    }

    /// Cursor that identifies this event in its ordered stream.
    public var cursor: EventDeliveryCursor {
        switch self {
        case .snapshot(let value): return .processRuntime(eventOrdinal: value.generation)
        case .recognition(let event):
            return .recognition(sessionID: event.sessionID, eventOrdinal: event.eventOrdinal)
        case .speechQueue(let event):
            return .speechQueue(
                itemID: event.itemID,
                playbackID: event.playbackID,
                eventOrdinal: event.eventOrdinal
            )
        case .speechProgress(let progress):
            return .speechQueue(itemID: progress.itemID, playbackID: progress.playbackID, eventOrdinal: 0)
        case .recovery(let event):
            return .processRuntime(eventOrdinal: event.eventOrdinal)
        }
    }
}

/// Canonical stream type. The stream is finite in memory and reports delivery
/// gaps explicitly through `VoiceError`.
public typealias VoiceEventStream = AsyncThrowingStream<VoiceEventStreamEvent, Error>

/// Active recognition metadata in a runtime snapshot.
public struct VoiceRecognitionSnapshot: Sendable, Equatable {
    /// Active session identity.
    public let sessionID: RecognitionSessionID
    /// Current recognition state.
    public let state: RecognitionSessionState
    /// Latest coalescible preview, if publication permits it.
    public let latestPreview: TranscriptPreview?
    /// Creates recognition snapshot metadata.
    public init(sessionID: RecognitionSessionID, state: RecognitionSessionState, latestPreview: TranscriptPreview?) { self.sessionID = sessionID; self.state = state; self.latestPreview = latestPreview }
}

/// Finite current voice state for reconciliation after event loss.
public struct VoiceRuntimeSnapshot: Sendable, Equatable {
    /// Current serialized lifecycle state.
    public let state: VoiceState
    /// Current cleanup/recovery truth.
    public let recoveryState: VoiceRecoveryState
    /// Active recognition metadata, if any.
    public let recognition: VoiceRecognitionSnapshot?
    /// Current queue metadata without speech text.
    public let queue: SpeechQueueSnapshot
    /// Coordinator generation captured with the snapshot.
    public let generation: UInt64
    /// Creates a finite runtime snapshot.
    public init(state: VoiceState, recoveryState: VoiceRecoveryState, recognition: VoiceRecognitionSnapshot?, queue: SpeechQueueSnapshot, generation: UInt64) { self.state = state; self.recoveryState = recoveryState; self.recognition = recognition; self.queue = queue; self.generation = generation }
}
