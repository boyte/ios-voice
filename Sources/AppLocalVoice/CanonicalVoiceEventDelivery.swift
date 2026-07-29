import Foundation

/// Canonical delivery layer for recognition, speech queue, and recovery
/// events. It intentionally shares the process-wide subscriber registry with
/// recognition delivery so the eight-subscriber limit is one contract.
struct CanonicalVoiceEventDelivery {
    private let registry: CanonicalEventSubscriberRegistry
    private let capacity: Int
    private var subscriptions: [UUID: CanonicalVoiceEventSubscription] = [:]
    private var nextDeliveryOrder: UInt64 = 0

    init(
        registry: CanonicalEventSubscriberRegistry,
        capacity: Int = RecognitionEventDeliveryLimits.maximumDurableEventCountPerSubscriber
    ) {
        self.registry = registry
        self.capacity = capacity
    }

    mutating func subscribe(
        initialEvent: VoiceEventStreamEvent? = nil,
        onTermination: @escaping @Sendable (UUID) -> Void
    ) -> VoiceEventStream {
        let id = UUID()
        let admission = registry.admit(
            id: id,
            maximumSubscriberCount: RecognitionEventDeliveryLimits.maximumSubscriberCount
        )
        guard admission.accepted else {
            let error = VoiceError.eventSubscriberLimitReached(
                maximum: RecognitionEventDeliveryLimits.maximumSubscriberCount,
                active: admission.activeSubscriberCount
            )
            return VoiceEventStream { continuation in continuation.finish(throwing: error) }
        }
        let subscription = CanonicalVoiceEventSubscription(
            id: id,
            capacity: capacity,
            onTermination: { [registry] in
                registry.release(id: id)
                onTermination(id)
            }
        )
        subscriptions[id] = subscription
        if let initialEvent {
            let deliveryOrder = nextDeliveryOrder
            nextDeliveryOrder = nextDeliveryOrder == .max ? 0 : nextDeliveryOrder + 1
            // The recovery snapshot belongs to this newly admitted stream. It
            // must not go through publish(), which would change the history
            // of every existing subscriber.
            _ = subscription.offer(initialEvent, deliveryOrder: deliveryOrder)
        }
        return subscription.stream()
    }

    mutating func publish(_ event: VoiceEventStreamEvent) {
        let deliveryOrder = nextDeliveryOrder
        nextDeliveryOrder = nextDeliveryOrder == .max ? 0 : nextDeliveryOrder + 1
        var remove: [UUID] = []
        for (id, subscription) in subscriptions {
            if !subscription.offer(event, deliveryOrder: deliveryOrder) { remove.append(id) }
        }
        for id in remove {
            subscriptions.removeValue(forKey: id)
            registry.release(id: id)
        }
    }

    mutating func removeSubscription(_ id: UUID) {
        subscriptions.removeValue(forKey: id)
        registry.release(id: id)
    }

}

private final class CanonicalVoiceEventSubscription: @unchecked Sendable {
    private struct Buffered {
        let event: VoiceEventStreamEvent
        let deliveryOrder: UInt64
    }

    private let id: UUID
    private let capacity: Int
    private let onTermination: @Sendable () -> Void
    private let lock = NSLock()
    private var durable: [Buffered] = []
    private var advisory: [String: Buffered] = [:]
    private var waiter: CheckedContinuation<VoiceEventStreamEvent?, Error>?
    private var terminalFailure: VoiceError?
    private var ended = false
    private var terminationReported = false

    init(id: UUID, capacity: Int, onTermination: @escaping @Sendable () -> Void) {
        self.id = id
        self.capacity = capacity
        self.onTermination = onTermination
    }

    deinit { reportTermination() }

    func stream() -> VoiceEventStream {
        let lifetime = CanonicalVoiceEventStreamLifetime { [self] in cancel() }
        return VoiceEventStream(unfolding: { [self, lifetime] in
            lifetime.keepAlive()
            return try await next()
        })
    }

    func offer(_ event: VoiceEventStreamEvent, deliveryOrder: UInt64) -> Bool {
        var continuation: CheckedContinuation<VoiceEventStreamEvent?, Error>?
        lock.lock()
        guard !ended, terminalFailure == nil else { lock.unlock(); return false }
        if let waiter {
            self.waiter = nil
            continuation = waiter
            lock.unlock()
            continuation?.resume(returning: event)
            return true
        }
        if let key = advisoryKey(event) {
            advisory[key] = Buffered(event: event, deliveryOrder: deliveryOrder)
            lock.unlock()
            return true
        }
        guard durable.count < capacity else {
            terminalFailure = .eventDeliveryOverflow(
                capacity: capacity,
                firstUndelivered: event.cursor
            )
            let termination = takeTerminationLocked()
            lock.unlock()
            termination?()
            return false
        }
        durable.append(Buffered(event: event, deliveryOrder: deliveryOrder))
        lock.unlock()
        return true
    }

    private func next() async throws -> VoiceEventStreamEvent? {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                install(continuation)
            }
        }, onCancel: { [self] in cancel() })
    }

    private func install(_ continuation: CheckedContinuation<VoiceEventStreamEvent?, Error>) {
        lock.lock()
        let result: Result<VoiceEventStreamEvent?, Error>?
        if let buffered = removeOldestLocked() {
            result = .success(buffered.event)
        } else if let failure = terminalFailure {
            terminalFailure = nil
            ended = true
            result = .failure(failure)
        } else if ended {
            result = .success(nil)
        } else {
            precondition(waiter == nil, "Concurrent iteration of one voice event stream is unsupported.")
            waiter = continuation
            lock.unlock()
            return
        }
        lock.unlock()
        switch result! {
        case .success(let value): continuation.resume(returning: value)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }

    private func removeOldestLocked() -> Buffered? {
        var selected = durable.first
        var key: String?
        for (candidateKey, candidate) in advisory {
            if selected == nil || candidate.deliveryOrder < selected!.deliveryOrder {
                selected = candidate
                key = candidateKey
            }
        }
        guard let selected else { return nil }
        if let key { advisory.removeValue(forKey: key) } else { durable.removeFirst() }
        return selected
    }

    private func cancel() {
        lock.lock()
        guard !ended else { lock.unlock(); reportTermination(); return }
        ended = true
        durable.removeAll()
        advisory.removeAll()
        let waiter = self.waiter
        self.waiter = nil
        let termination = takeTerminationLocked()
        lock.unlock()
        waiter?.resume(returning: nil)
        termination?()
    }

    private func reportTermination() {
        lock.lock()
        let termination = takeTerminationLocked()
        lock.unlock()
        termination?()
    }

    private func takeTerminationLocked() -> (@Sendable () -> Void)? {
        guard !terminationReported else { return nil }
        terminationReported = true
        return onTermination
    }

    private func advisoryKey(_ event: VoiceEventStreamEvent) -> String? {
        switch event {
        case .snapshot:
            return nil
        case .recognition(let event):
            switch event.kind {
            case .stateChanged: return "recognition-state-\(event.sessionID)"
            case .transcript(.preview): return "recognition-preview-\(event.sessionID)"
            default: return nil
            }
        case .speechQueue(let event):
            switch event.kind {
            case .paused, .resumed: return "speech-control-\(event.playbackID)"
            default: return nil
            }
        case .speechProgress(let progress):
            return "speech-progress-\(progress.playbackID)"
        // Recovery transitions change whether hosts may safely begin new
        // audio work. They are durable state-machine boundaries, not a
        // newest-value UI advisory; subscribers must observe reconciliation
        // before a subsequent blocked or ready result.
        case .recovery: return nil
        }
    }
}

private final class CanonicalVoiceEventStreamLifetime: @unchecked Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init(onTermination: @escaping @Sendable () -> Void) {
        let pair = AsyncStream<Void>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
        continuation.onTermination = { _ in onTermination() }
    }

    func keepAlive() {}
    deinit { continuation.finish() }
}
