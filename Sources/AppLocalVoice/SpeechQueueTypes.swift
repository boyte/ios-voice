import Foundation

/// Library-generated identity of one immutable accepted speech item.
///
/// This identity survives replay. A rejected enqueue receives no item ID.
public struct SpeechItemID: Hashable, Sendable, CustomStringConvertible {
    /// UUID backing this library-generated item identity.
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

/// Library-generated identity of one accepted attempt to play a speech item.
///
/// Every accepted enqueue and replay receives a distinct playback ID and one
/// exactly-once terminal outcome. A rejected request receives no playback ID.
public struct SpeechPlaybackID: Hashable, Sendable, CustomStringConvertible {
    /// UUID backing this library-generated playback-attempt identity.
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

/// Pending-order priority. User-initiated attempts sort ahead of normal
/// attempts but never preempt active playback.
public enum SpeechPriority: Int, Sendable, Equatable, Comparable {
    /// Normal pending priority.
    case normal = 0
    /// User-initiated pending priority, ordered ahead of normal attempts.
    case userInitiated = 1

    /// Creates a priority from its raw integer value, or `nil` for an unknown value.
    public init?(rawValue: Int) {
        switch rawValue {
        case 0: self = .normal
        case 1: self = .userInitiated
        default: return nil
        }
    }

    /// Compares pending priorities by their raw ordering value.
    public static func < (lhs: SpeechPriority, rhs: SpeechPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Validated host input that has not yet received library identity.
public struct SpeechItemRequest: Sendable, Equatable {
    /// Maximum number of UTF-16 code units accepted in one speech item.
    public static let maximumUTF16Length = VoiceTextLimits.maximumUTF16Length

    /// Text that will be spoken after queue acceptance.
    public let text: String
    /// Pending-order priority for this request.
    public let priority: SpeechPriority
    /// Synthesis configuration captured by this request.
    public let configuration: SpeechConfiguration

    /// Creates a validated speech-item request.
    public init(
        text: String,
        priority: SpeechPriority = .normal,
        configuration: SpeechConfiguration = .init()
    ) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceError.invalidSpeechItem("A speech item must contain non-whitespace text.")
        }
        guard text.utf16.count <= Self.maximumUTF16Length else {
            throw VoiceError.textTooLong(maximumUTF16Length: Self.maximumUTF16Length)
        }
        self.text = text
        self.priority = priority
        self.configuration = configuration
    }
}

/// Immutable speech item stored only after queue acceptance.
public struct SpeechItem: Sendable, Equatable, Identifiable {
    /// Immutable identity assigned when the item is accepted.
    public let id: SpeechItemID
    /// Text retained for replay and playback.
    public let text: String
    /// Pending-order priority retained for replay.
    public let priority: SpeechPriority
    /// Synthesis configuration retained for replay.
    public let configuration: SpeechConfiguration

    init(id: SpeechItemID, request: SpeechItemRequest) {
        self.id = id
        text = request.text
        priority = request.priority
        configuration = request.configuration
    }
}

/// Atomic placement for an accepted enqueue or replay attempt.
public enum SpeechEnqueuePolicy: Sendable, Equatable {
    /// Add the attempt to the end of the pending order.
    case append
    /// Place the attempt at the front of the pending order.
    case playNext
    /// Replace the active attempt and preserve the remaining pending order.
    case replaceCurrent
    /// Replace the active attempt and discard all other pending attempts.
    case replaceAll
}

/// Deterministic behavior when the pending-attempt bound is reached.
public enum SpeechQueueOverflowPolicy: Sendable, Equatable {
    /// Reject the new request when the pending bound is full.
    case rejectNew
    /// Cancel the oldest pending attempt to make room for the new request.
    case dropOldestPending
}

/// Whether ordered pending playback may advance automatically.
public enum SpeechQueueMode: Sendable, Equatable {
    /// Automatically advance to the next pending attempt.
    case running
    /// Keep pending attempts accepted but do not start the next one automatically.
    case suspended
}

/// Content-free metadata for one active or pending queue attempt.
public struct SpeechQueueAttemptSnapshot: Sendable, Equatable {
    /// Immutable item identity.
    public let itemID: SpeechItemID
    /// One playback-attempt identity.
    public let playbackID: SpeechPlaybackID
    /// Retained queue priority.
    public let priority: SpeechPriority
    /// Retained item size, in UTF-16 code units. The text itself is excluded.
    public let textUTF16Length: Int

    init(itemID: SpeechItemID, playbackID: SpeechPlaybackID, priority: SpeechPriority, textUTF16Length: Int) {
        self.itemID = itemID
        self.playbackID = playbackID
        self.priority = priority
        self.textUTF16Length = textUTF16Length
    }
}

/// Finite metadata-only view of the ordered speech queue.
public struct SpeechQueueSnapshot: Sendable, Equatable {
    /// Queue advancement mode.
    public let mode: SpeechQueueMode
    /// Active attempt, if playback is in progress.
    public let active: SpeechQueueAttemptSnapshot?
    /// Pending attempts in playback order.
    public let pending: [SpeechQueueAttemptSnapshot]
    /// Replayable immutable item IDs in eviction order.
    public let retainedItemIDs: [SpeechItemID]
    /// Queue mutation generation captured with this snapshot.
    public let generation: UInt64

    init(mode: SpeechQueueMode, active: SpeechQueueAttemptSnapshot?, pending: [SpeechQueueAttemptSnapshot], retainedItemIDs: [SpeechItemID], generation: UInt64) {
        self.mode = mode
        self.active = active
        self.pending = pending
        self.retainedItemIDs = retainedItemIDs
        self.generation = generation
    }
}

/// Bounded pending-attempt and completed-item replay-history configuration.
public struct SpeechQueueConfiguration: Sendable, Equatable {
    /// Smallest permitted pending-attempt capacity.
    public static let minimumPendingItemCount = 1
    /// Largest permitted pending-attempt capacity.
    public static let maximumPendingItemCount = 128
    /// Default pending-attempt capacity.
    public static let defaultMaximumPendingItemCount = 32
    /// Smallest permitted replay-history capacity.
    public static let minimumReplayHistoryItemCount = 0
    /// Largest permitted replay-history capacity.
    public static let maximumReplayHistoryItemCount = 256
    /// Default replay-history capacity.
    public static let defaultMaximumReplayHistoryItemCount = 64
    /// Smallest permitted aggregate pending text budget in UTF-16 code units.
    public static let minimumPendingTextUTF16Length = 8_192
    /// Largest permitted aggregate pending text budget in UTF-16 code units.
    public static let maximumPendingTextUTF16Length = 4_194_304
    /// Default aggregate pending text budget in UTF-16 code units.
    public static let defaultMaximumPendingTextUTF16Length = 1_048_576
    /// Smallest permitted aggregate replay-history text budget in UTF-16 code units.
    public static let minimumReplayHistoryTextUTF16Length = 8_192
    /// Largest permitted aggregate replay-history text budget in UTF-16 code units.
    public static let maximumReplayHistoryTextUTF16Length = 8_388_608
    /// Default aggregate replay-history text budget in UTF-16 code units.
    public static let defaultMaximumReplayHistoryTextUTF16Length = 2_097_152

    /// Maximum number of pending attempts retained by the queue.
    public let maximumPendingItemCount: Int
    /// Maximum number of completed items retained for replay.
    public let maximumReplayHistoryItemCount: Int
    /// Maximum aggregate UTF-16 text length retained in pending attempts.
    public let maximumPendingTextUTF16Length: Int
    /// Maximum aggregate UTF-16 text length retained in replay history.
    public let maximumReplayHistoryTextUTF16Length: Int
    /// Behavior when the pending-attempt capacity is full.
    public let overflowPolicy: SpeechQueueOverflowPolicy
    /// Initial automatic-advancement mode of the queue.
    public let initialMode: SpeechQueueMode

    /// Creates a queue configuration with the package defaults.
    public init() {
        maximumPendingItemCount = Self.defaultMaximumPendingItemCount
        maximumReplayHistoryItemCount = Self.defaultMaximumReplayHistoryItemCount
        maximumPendingTextUTF16Length = Self.defaultMaximumPendingTextUTF16Length
        maximumReplayHistoryTextUTF16Length = Self.defaultMaximumReplayHistoryTextUTF16Length
        overflowPolicy = .rejectNew
        initialMode = .running
    }

    /// Creates a queue configuration after validating both capacity bounds.
    public init(
        maximumPendingItemCount: Int,
        maximumReplayHistoryItemCount: Int = SpeechQueueConfiguration.defaultMaximumReplayHistoryItemCount,
        maximumPendingTextUTF16Length: Int = SpeechQueueConfiguration.defaultMaximumPendingTextUTF16Length,
        maximumReplayHistoryTextUTF16Length: Int = SpeechQueueConfiguration.defaultMaximumReplayHistoryTextUTF16Length,
        overflowPolicy: SpeechQueueOverflowPolicy = .rejectNew,
        initialMode: SpeechQueueMode = .running
    ) throws {
        let pendingRange = Self.minimumPendingItemCount...Self.maximumPendingItemCount
        let historyRange = Self.minimumReplayHistoryItemCount...Self.maximumReplayHistoryItemCount
        let pendingTextRange = Self.minimumPendingTextUTF16Length...Self.maximumPendingTextUTF16Length
        let historyTextRange = Self.minimumReplayHistoryTextUTF16Length...Self.maximumReplayHistoryTextUTF16Length
        guard pendingRange.contains(maximumPendingItemCount),
              historyRange.contains(maximumReplayHistoryItemCount),
              pendingTextRange.contains(maximumPendingTextUTF16Length),
              historyTextRange.contains(maximumReplayHistoryTextUTF16Length) else {
            throw VoiceError.invalidSpeechQueueConfiguration(
                "Pending capacity must be 1...128, replay history must be 0...256, "
                    + "pending text must be 8,192...4,194,304 UTF-16 code units, and "
                    + "replay-history text must be 8,192...8,388,608 UTF-16 code units."
            )
        }
        self.maximumPendingItemCount = maximumPendingItemCount
        self.maximumReplayHistoryItemCount = maximumReplayHistoryItemCount
        self.maximumPendingTextUTF16Length = maximumPendingTextUTF16Length
        self.maximumReplayHistoryTextUTF16Length = maximumReplayHistoryTextUTF16Length
        self.overflowPolicy = overflowPolicy
        self.initialMode = initialMode
    }
}

/// Provider-neutral queue command seam for the later queue implementation.
public enum SpeechQueueCommand: Sendable, Equatable {
    /// Enqueue a validated request using the specified placement policy.
    case enqueue(SpeechItemRequest, policy: SpeechEnqueuePolicy)
    /// Pause active queued playback.
    case pause
    /// Resume queued playback.
    case resume
    /// Stop the active queued playback.
    case stop
    /// Skip the active queued item.
    case skip
    /// Cancel pending queued items without changing active playback.
    case clearPending
    /// Stop active playback and cancel all pending items.
    case stopAndClear
    /// Replay a retained item using the specified placement policy.
    case replay(SpeechItemID, policy: SpeechEnqueuePolicy)
}

/// Result of an idempotent pause or resume request.
public enum SpeechControlResult: Sendable, Equatable {
    /// The requested control operation changed queue or provider state.
    case applied
    /// The requested state was already in effect.
    case alreadyApplied
    /// No queued playback was active for the requested operation.
    case noActivePlayback
    /// The speech provider rejected the requested control operation.
    case providerRejected
}

/// Why an accepted playback attempt was cancelled.
public enum SpeechPlaybackCancellationReason: Sendable, Equatable {
    /// The host stopped playback.
    case stopped
    /// A replacement policy superseded the attempt.
    case replaced
    /// The host cleared pending work.
    case cleared
    /// The queue dropped the attempt to satisfy its overflow policy.
    case overflow
    /// Recognition superseded queued speech.
    case supersededByRecognition
    /// The service was closed while the attempt was active or pending.
    case closeRequested
}

/// Mutually exclusive terminal outcome for one accepted playback ID.
public enum SpeechPlaybackOutcome: Sendable, Equatable {
    /// The provider completed playback normally.
    case finished
    /// Playback ended for the associated cancellation reason.
    case cancelled(SpeechPlaybackCancellationReason)
    /// The host skipped the attempt before normal completion.
    case skipped
    /// A system interruption ended playback.
    case interrupted(VoiceInterruptionReason)
    /// Playback failed with the associated content-free failure metadata.
    case failed(VoiceFailure)
}

/// Result returned when the queue atomically accepts an enqueue or replay.
public struct SpeechPlaybackAcceptance: Sendable, Equatable {
    /// Immutable item identity accepted by the queue.
    public let itemID: SpeechItemID
    /// Attempt identity assigned to this acceptance.
    public let playbackID: SpeechPlaybackID
    /// Ordinal of the acceptance event in the queue stream.
    public let acceptedEventOrdinal: UInt64

    init(itemID: SpeechItemID, playbackID: SpeechPlaybackID, acceptedEventOrdinal: UInt64) {
        self.itemID = itemID
        self.playbackID = playbackID
        self.acceptedEventOrdinal = acceptedEventOrdinal
    }
}

/// Exactly-once terminal result for an accepted playback attempt.
public struct SpeechPlaybackResult: Sendable, Equatable {
    /// Immutable item identity associated with the terminal result.
    public let itemID: SpeechItemID
    /// Playback-attempt identity associated with the terminal result.
    public let playbackID: SpeechPlaybackID
    /// Ordinal of the terminal event in the queue stream.
    public let terminalEventOrdinal: UInt64
    /// Exactly-once terminal outcome for the attempt.
    public let outcome: SpeechPlaybackOutcome

    init(
        itemID: SpeechItemID,
        playbackID: SpeechPlaybackID,
        terminalEventOrdinal: UInt64,
        outcome: SpeechPlaybackOutcome
    ) {
        self.itemID = itemID
        self.playbackID = playbackID
        self.terminalEventOrdinal = terminalEventOrdinal
        self.outcome = outcome
    }
}

/// Advisory original-text progress for one accepted playback attempt.
public struct SpeechPlaybackProgress: Sendable, Equatable {
    /// Immutable item identity associated with the attempt.
    public let itemID: SpeechItemID
    /// Playback-attempt identity associated with the progress range.
    public let playbackID: SpeechPlaybackID
    /// UTF-16 range in the complete original speech request.
    public let utf16Range: Range<Int>

    /// Creates content-free playback progress metadata.
    public init(itemID: SpeechItemID, playbackID: SpeechPlaybackID, utf16Range: Range<Int>) {
        self.itemID = itemID
        self.playbackID = playbackID
        self.utf16Range = utf16Range
    }
}

/// Ordered lifecycle payload for one accepted playback attempt.
public enum SpeechQueueEventKind: Sendable, Equatable {
    /// The queue accepted the playback attempt.
    case accepted
    /// Provider playback began.
    case started
    /// Provider playback was paused.
    case paused
    /// Provider playback resumed.
    case resumed
    /// The attempt reached its terminal outcome.
    case outcome(SpeechPlaybackOutcome)

    /// Whether this event terminates its playback attempt.
    public var isTerminal: Bool {
        if case .outcome = self { true } else { false }
    }
}

/// Queue-ordered event correlated to both immutable item and playback attempt.
public struct SpeechQueueEvent: Sendable, Equatable {
    /// Immutable item identity associated with the event.
    public let itemID: SpeechItemID
    /// Playback-attempt identity associated with the event.
    public let playbackID: SpeechPlaybackID
    /// Monotonic ordinal of the event in the queue stream.
    public let eventOrdinal: UInt64
    /// Lifecycle payload carried by the event.
    public let kind: SpeechQueueEventKind

    init(
        itemID: SpeechItemID,
        playbackID: SpeechPlaybackID,
        eventOrdinal: UInt64,
        kind: SpeechQueueEventKind
    ) {
        self.itemID = itemID
        self.playbackID = playbackID
        self.eventOrdinal = eventOrdinal
        self.kind = kind
    }

    /// Returns whether this event is the immediate successor of another event.
    public func immediatelyFollows(_ previous: SpeechQueueEvent) -> Bool {
        guard previous.eventOrdinal < .max else { return false }
        return eventOrdinal == previous.eventOrdinal + 1
    }
}

/// Explicit compatibility alias for item-attempt lifecycle terminology.
/// Every `SpeechItemEvent` carries both item and playback identity.
public typealias SpeechItemEvent = SpeechQueueEvent
