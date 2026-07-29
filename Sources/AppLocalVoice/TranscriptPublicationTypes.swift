/// Optional monotonic timing metadata measured from recognition-session start.
public struct TranscriptTimeRange: Hashable, Sendable {
    /// Offset from recognition-session start to the beginning, in milliseconds.
    public let startMilliseconds: UInt64
    /// Offset from recognition-session start to the end, in milliseconds.
    public let endMilliseconds: UInt64

    /// Duration between the start and end offsets, in milliseconds.
    public var durationMilliseconds: UInt64 { endMilliseconds - startMilliseconds }

    /// Creates a time range whose end is not earlier than its start.
    public init(startMilliseconds: UInt64, endMilliseconds: UInt64) throws {
        guard endMilliseconds >= startMilliseconds else {
            throw VoiceError.transcriptConsistency
        }
        self.startMilliseconds = startMilliseconds
        self.endMilliseconds = endMilliseconds
    }
}

/// Contiguous UTF-16 range in the assembled recognition transcript.
public struct TranscriptUTF16Range: Hashable, Sendable {
    /// Zero-based UTF-16 offset of the range.
    public let location: Int
    /// Number of UTF-16 code units in the range.
    public let length: Int

    /// Exclusive UTF-16 end offset of the range.
    public var endLocation: Int { location + length }

    /// Creates a non-negative, non-overflowing UTF-16 range.
    public init(location: Int, length: Int) throws {
        let (_, overflowed) = location.addingReportingOverflow(length)
        guard location >= 0, length >= 0, !overflowed else {
            throw VoiceError.transcriptConsistency
        }
        self.location = location
        self.length = length
    }
}

/// A volatile complete transcript snapshot for immediate UI replacement.
///
/// Revisions start at zero and strictly increase per session. Slow consumers
/// may observe gaps because preview snapshots are the only coalescible payload.
public struct TranscriptPreview: Sendable, Equatable {
    /// Recognition session that produced this preview.
    public let sessionID: RecognitionSessionID
    /// Monotonically increasing revision within the session.
    public let revision: UInt64
    /// Complete current transcript text.
    public let text: String
    /// Optional timing metadata for the preview text.
    public let timeRange: TranscriptTimeRange?

    init(
        sessionID: RecognitionSessionID,
        revision: UInt64,
        text: String,
        timeRange: TranscriptTimeRange? = nil
    ) {
        self.sessionID = sessionID
        self.revision = revision
        self.text = text
        self.timeRange = timeRange
    }
}

/// Immutable append-only transcript text safe for a host's stable sink.
///
/// Sequences start at zero and are contiguous. The UTF-16 range is immutable
/// and must abut the prior chunk's range. On successful completion, ordered
/// chunk text reconstructs ``FinalTranscript/text`` exactly.
public struct StableTranscriptChunk: Sendable, Equatable {
    /// Recognition session that produced this stable chunk.
    public let sessionID: RecognitionSessionID
    /// Contiguous chunk sequence number within the session.
    public let sequence: UInt64
    /// Immutable transcript text represented by the chunk.
    public let text: String
    /// Contiguous UTF-16 location of the chunk in the assembled transcript.
    public let utf16Range: TranscriptUTF16Range
    /// Optional timing metadata for the chunk.
    public let timeRange: TranscriptTimeRange?

    init(
        sessionID: RecognitionSessionID,
        sequence: UInt64,
        text: String,
        utf16Range: TranscriptUTF16Range,
        timeRange: TranscriptTimeRange? = nil
    ) throws {
        guard !text.isEmpty, utf16Range.length == text.utf16.count else {
            throw VoiceError.transcriptConsistency
        }
        self.sessionID = sessionID
        self.sequence = sequence
        self.text = text
        self.utf16Range = utf16Range
        self.timeRange = timeRange
    }
}

/// Immutable complete recognition result produced by explicit finalization.
///
/// Recognition finality never means that the host submitted this text.
public struct FinalTranscript: Sendable, Equatable {
    /// Recognition session that produced this final transcript.
    public let sessionID: RecognitionSessionID
    /// Complete final transcript text.
    public let text: String
    /// Optional timing metadata for the final text.
    public let timeRange: TranscriptTimeRange?

    init(
        sessionID: RecognitionSessionID,
        text: String,
        timeRange: TranscriptTimeRange? = nil
    ) {
        self.sessionID = sessionID
        self.text = text
        self.timeRange = timeRange
    }
}

/// Stable discriminator for the three library transcript payload kinds.
public enum TranscriptPublicationKind: Sendable, Equatable {
    /// A volatile complete preview snapshot.
    case preview
    /// An immutable append-only transcript chunk.
    case stableChunk
    /// The complete recognition-final transcript.
    case finalTranscript
}

/// Type-distinct transcript payloads emitted by a recognition session.
public enum TranscriptPublication: Sendable, Equatable {
    /// A volatile preview payload.
    case preview(TranscriptPreview)
    /// An immutable stable-chunk payload.
    case stableChunk(StableTranscriptChunk)
    /// A complete final-transcript payload.
    case finalTranscript(FinalTranscript)

    /// Stable discriminator for the payload kind.
    public var kind: TranscriptPublicationKind {
        switch self {
        case .preview: .preview
        case .stableChunk: .stableChunk
        case .finalTranscript: .finalTranscript
        }
    }

    /// Recognition session that produced the payload.
    public var sessionID: RecognitionSessionID {
        switch self {
        case .preview(let value): value.sessionID
        case .stableChunk(let value): value.sessionID
        case .finalTranscript(let value): value.sessionID
        }
    }
}

/// Advisory recognition lifecycle state carried by ``RecognitionEvent``.
public enum RecognitionSessionState: Sendable, Equatable {
    /// The provider or model is preparing for capture.
    case preparing
    /// Recognition is actively receiving microphone input.
    case listening
    /// Capture ended and the provider is producing final output.
    case finalizing
}

/// Exactly-once logical terminal result for an admitted recognition session.
public enum RecognitionOutcome: Sendable, Equatable {
    /// Recognition produced a final transcript successfully.
    case completed
    /// Recognition reached its configured capture-duration limit and finalized normally.
    case durationLimitReached
    /// The host or task cancelled recognition.
    case cancelled
    /// A system interruption ended recognition.
    case interrupted(VoiceInterruptionReason)
    /// Recognition failed with the associated content-free failure metadata.
    case failed(VoiceFailure)
}

/// Payload of one strictly ordered recognition event.
public enum RecognitionEventKind: Sendable, Equatable {
    /// The durable first event for every admitted session.
    case accepted
    /// An advisory recognition-state transition.
    case stateChanged(RecognitionSessionState)
    /// A transcript publication.
    case transcript(TranscriptPublication)
    /// The exactly-once terminal recognition outcome.
    case outcome(RecognitionOutcome)

    /// Whether this is the durable first event for a session.
    public var isAccepted: Bool {
        if case .accepted = self { true } else { false }
    }

    /// Whether this event carries the terminal recognition outcome.
    public var isTerminal: Bool {
        if case .outcome = self { true } else { false }
    }
}

/// Additive start-result seam exposing identity before provider payloads.
public struct RecognitionSessionAcceptance: Sendable, Equatable {
    /// Identity assigned to the admitted recognition session.
    public let sessionID: RecognitionSessionID
    /// Always ``RecognitionEvent/acceptedEventOrdinal``.
    public let acceptedEventOrdinal: UInt64

    init(sessionID: RecognitionSessionID) {
        self.sessionID = sessionID
        acceptedEventOrdinal = RecognitionEvent.acceptedEventOrdinal
    }
}

/// Strictly ordered event for one recognition session.
///
/// Ordinal zero is exactly one `.accepted` event. Later ordinals increase by
/// one through advisory states and payloads. A successful sequence ends with a
/// final transcript followed by one completed outcome; cancellation,
/// interruption, and failure emit no later preview or final payload.
public struct RecognitionEvent: Sendable, Equatable {
    /// Ordinal assigned to the durable first event of every session.
    public static let acceptedEventOrdinal: UInt64 = 0

    /// Recognition session that produced this event.
    public let sessionID: RecognitionSessionID
    /// Strictly increasing ordinal within the session.
    public let eventOrdinal: UInt64
    /// Ordered lifecycle or transcript payload.
    public let kind: RecognitionEventKind

    init(sessionID: RecognitionSessionID, eventOrdinal: UInt64, kind: RecognitionEventKind) {
        self.sessionID = sessionID
        self.eventOrdinal = eventOrdinal
        self.kind = kind
    }

    /// Whether this event is the next accepted ordinal for the same session.
    public func immediatelyFollows(_ previous: RecognitionEvent) -> Bool {
        guard sessionID == previous.sessionID, previous.eventOrdinal < .max else { return false }
        return eventOrdinal == previous.eventOrdinal + 1
    }

    /// Whether two observations represent the same ordered event.
    public func duplicates(_ other: RecognitionEvent) -> Bool {
        sessionID == other.sessionID && eventOrdinal == other.eventOrdinal
    }
}
