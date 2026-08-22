import Foundation

/// Typed position of the first durable event a canonical observer did not
/// receive. The cursor contains identity and ordering only, never voice text.
public enum EventDeliveryCursor: Hashable, Sendable {
    /// Cursor for a recognition-session event stream.
    case recognition(sessionID: RecognitionSessionID, eventOrdinal: UInt64)
    /// Cursor for a speech-queue event stream.
    case speechQueue(
        itemID: SpeechItemID,
        playbackID: SpeechPlaybackID,
        eventOrdinal: UInt64
    )
    /// Cursor for a process-wide recovery event stream.
    case processRuntime(eventOrdinal: UInt64)
}

/// Process-wide admission registry for canonical event observers.
/// SAFETY: `lock` protects the complete subscriber-ID set transaction for every
/// admission, release, and count operation. No callback runs under the lock.
final class CanonicalEventSubscriberRegistry: @unchecked Sendable {
    struct Admission: Sendable, Equatable {
        let accepted: Bool
        let activeSubscriberCount: Int
    }

    static let shared = CanonicalEventSubscriberRegistry()

    private let lock = NSLock()
    private var activeSubscriberIDs: Set<UUID> = []

    func admit(id: UUID, maximumSubscriberCount: Int) -> Admission {
        lock.lock()
        defer { lock.unlock() }

        let active = activeSubscriberIDs.count
        guard active < maximumSubscriberCount else {
            return Admission(accepted: false, activeSubscriberCount: active)
        }
        activeSubscriberIDs.insert(id)
        return Admission(accepted: true, activeSubscriberCount: active + 1)
    }

    func release(id: UUID) {
        lock.lock()
        activeSubscriberIDs.remove(id)
        lock.unlock()
    }

    var activeSubscriberCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return activeSubscriberIDs.count
    }
}
