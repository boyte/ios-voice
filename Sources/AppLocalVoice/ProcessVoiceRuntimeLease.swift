import Foundation

/// Process-wide ownership boundary above the package's audio-session broker.
///
/// The lease is intentionally independent of `AVAudioSession` role leases: one
/// facade keeps this lease across idle periods so another facade cannot create
/// a competing recognition, synthesis, or future queue owner.
final class ProcessVoiceRuntimeLease: @unchecked Sendable {
    enum Acquisition: Sendable, Equatable {
        case acquired
        case alreadyOwned
    }

    static let shared = ProcessVoiceRuntimeLease()

    private let lock = NSLock()
    private var ownerID: UUID?

    func acquire(for requestedOwnerID: UUID) throws -> Acquisition {
        lock.lock()
        defer { lock.unlock() }

        if let ownerID {
            guard ownerID == requestedOwnerID else {
                throw VoiceError.serviceInUse
            }
            return .alreadyOwned
        }

        ownerID = requestedOwnerID
        return .acquired
    }

    @discardableResult
    func release(for requestedOwnerID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard ownerID == requestedOwnerID else { return false }
        ownerID = nil
        return true
    }

    func isOwned(by requestedOwnerID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ownerID == requestedOwnerID
    }

    func canAcquire(for requestedOwnerID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ownerID == nil || ownerID == requestedOwnerID
    }
}
