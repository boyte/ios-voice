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

/// Actor-confined registry whose subscriptions use pull-based delivery. This
/// keeps durable capacity independent from coalesced preview and state slots.
struct RecognitionEventDelivery {
    private let subscriberRegistry: CanonicalEventSubscriberRegistry
    private let maximumSubscriberCount: Int
    private let durableCapacity: Int
    private var subscriptions: [UUID: WeakRecognitionEventSubscription] = [:]
    private var nextDeliveryOrder: UInt64 = 0

    init(
        subscriberRegistry: CanonicalEventSubscriberRegistry,
        maximumSubscriberCount: Int = RecognitionEventDeliveryLimits.maximumSubscriberCount,
        durableCapacity: Int = RecognitionEventDeliveryLimits.maximumDurableEventCountPerSubscriber
    ) {
        precondition(maximumSubscriberCount > 0)
        precondition(durableCapacity > 0)
        self.subscriberRegistry = subscriberRegistry
        self.maximumSubscriberCount = maximumSubscriberCount
        self.durableCapacity = durableCapacity
    }

    mutating func subscribe(
        onTermination: @escaping @Sendable (UUID) -> Void
    ) -> AsyncThrowingStream<RecognitionEvent, Error> {
        compactReleasedSubscriptions()

        let id = UUID()
        let admission = subscriberRegistry.admit(
            id: id,
            maximumSubscriberCount: maximumSubscriberCount
        )
        guard admission.accepted else {
            let error = VoiceError.eventSubscriberLimitReached(
                maximum: maximumSubscriberCount,
                active: admission.activeSubscriberCount
            )
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: error)
            }
        }

        let registry = subscriberRegistry
        let subscription = RecognitionEventSubscription(
            id: id,
            durableCapacity: durableCapacity,
            onTermination: {
                registry.release(id: id)
                onTermination(id)
            }
        )
        subscriptions[id] = WeakRecognitionEventSubscription(subscription)
        return subscription.stream()
    }

    mutating func publish(_ event: RecognitionEvent) {
        compactReleasedSubscriptions()
        let order = nextDeliveryOrder
        nextDeliveryOrder &+= 1

        var terminatedIDs: [UUID] = []
        for (id, weakSubscription) in subscriptions {
            guard let subscription = weakSubscription.value else {
                terminatedIDs.append(id)
                continue
            }
            if !subscription.offer(event, deliveryOrder: order) {
                terminatedIDs.append(id)
            }
        }
        for id in terminatedIDs {
            subscriptions.removeValue(forKey: id)
            subscriberRegistry.release(id: id)
        }
    }

    mutating func removeSubscription(id: UUID) {
        subscriptions.removeValue(forKey: id)
        subscriberRegistry.release(id: id)
    }

    private mutating func compactReleasedSubscriptions() {
        let releasedIDs = subscriptions.compactMap { id, subscription in
            subscription.value == nil ? id : nil
        }
        for id in releasedIDs {
            subscriptions.removeValue(forKey: id)
            subscriberRegistry.release(id: id)
        }
    }
}

private final class WeakRecognitionEventSubscription {
    weak var value: RecognitionEventSubscription?

    init(_ value: RecognitionEventSubscription) {
        self.value = value
    }
}

/// SAFETY: `lock` protects all buffered events, waiter state, terminal state,
/// and exactly-once termination state. Continuations and callbacks are copied
/// out and resumed or invoked only after unlocking.
private final class RecognitionEventSubscription: @unchecked Sendable {
    private struct BufferedEvent {
        let deliveryOrder: UInt64
        let event: RecognitionEvent
    }

    private enum AdvisoryKey: Hashable {
        case preview(RecognitionSessionID)
        case state(RecognitionSessionID)
    }

    private let id: UUID
    private let durableCapacity: Int
    private let onTermination: @Sendable () -> Void
    private let lock = NSLock()

    private var durableEvents: [BufferedEvent] = []
    private var advisoryEvents: [AdvisoryKey: BufferedEvent] = [:]
    private var waiter: CheckedContinuation<RecognitionEvent?, Error>?
    private var terminalFailure: VoiceError?
    private var isEnded = false
    private var terminationReported = false

    init(
        id: UUID,
        durableCapacity: Int,
        onTermination: @escaping @Sendable () -> Void
    ) {
        self.id = id
        self.durableCapacity = durableCapacity
        self.onTermination = onTermination
    }

    deinit {
        reportTerminationIfNeeded()
    }

    func stream() -> AsyncThrowingStream<RecognitionEvent, Error> {
        let lifetime = RecognitionEventStreamLifetime { [self] in cancel() }
        return AsyncThrowingStream(unfolding: { [self, lifetime] in
            lifetime.keepAlive()
            return try await next()
        })
    }

    /// Returns `false` when this event terminates delivery for the subscriber.
    func offer(_ event: RecognitionEvent, deliveryOrder: UInt64) -> Bool {
        var waiting: CheckedContinuation<RecognitionEvent?, Error>?
        var termination: (@Sendable () -> Void)?

        lock.lock()
        guard !isEnded, terminalFailure == nil else {
            lock.unlock()
            return false
        }

        if let waiter {
            self.waiter = nil
            waiting = waiter
            lock.unlock()
            waiting?.resume(returning: event)
            return true
        }

        let buffered = BufferedEvent(deliveryOrder: deliveryOrder, event: event)
        if let key = Self.advisoryKey(for: event) {
            advisoryEvents[key] = buffered
            lock.unlock()
            return true
        }

        guard durableEvents.count < durableCapacity else {
            terminalFailure = .eventDeliveryOverflow(
                capacity: durableCapacity,
                firstUndelivered: event.deliveryCursor
            )
            termination = takeTerminationCallbackLocked()
            lock.unlock()
            termination?()
            return false
        }

        durableEvents.append(buffered)
        lock.unlock()
        return true
    }

    private func next() async throws -> RecognitionEvent? {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                installNextContinuation(continuation)
            }
        }, onCancel: { [self] in
            cancel()
        })
    }

    private func installNextContinuation(
        _ continuation: CheckedContinuation<RecognitionEvent?, Error>
    ) {
        var event: RecognitionEvent?
        var failure: VoiceError?
        var shouldEnd = false

        lock.lock()
        if let buffered = removeOldestBufferedEventLocked() {
            event = buffered.event
        } else if let terminalFailure {
            failure = terminalFailure
            self.terminalFailure = nil
            isEnded = true
        } else if isEnded {
            shouldEnd = true
        } else {
            precondition(waiter == nil, "Concurrent iteration of one event stream is unsupported.")
            waiter = continuation
            lock.unlock()
            return
        }
        lock.unlock()

        if let event {
            continuation.resume(returning: event)
        } else if let failure {
            continuation.resume(throwing: failure)
        } else if shouldEnd {
            continuation.resume(returning: nil)
        }
    }

    private func removeOldestBufferedEventLocked() -> BufferedEvent? {
        var selected = durableEvents.first
        var selectedAdvisoryKey: AdvisoryKey?

        for (key, candidate) in advisoryEvents {
            if selected.map({ candidate.deliveryOrder < $0.deliveryOrder }) ?? true {
                selected = candidate
                selectedAdvisoryKey = key
            }
        }

        guard let selected else { return nil }
        if let selectedAdvisoryKey {
            advisoryEvents.removeValue(forKey: selectedAdvisoryKey)
        } else {
            durableEvents.removeFirst()
        }
        return selected
    }

    private func cancel() {
        var waiting: CheckedContinuation<RecognitionEvent?, Error>?
        var termination: (@Sendable () -> Void)?

        lock.lock()
        if !isEnded {
            isEnded = true
            durableEvents.removeAll(keepingCapacity: false)
            advisoryEvents.removeAll(keepingCapacity: false)
            terminalFailure = nil
            waiting = waiter
            waiter = nil
        }
        termination = takeTerminationCallbackLocked()
        lock.unlock()

        waiting?.resume(returning: nil)
        termination?()
    }

    private func reportTerminationIfNeeded() {
        lock.lock()
        let termination = takeTerminationCallbackLocked()
        lock.unlock()
        termination?()
    }

    private func takeTerminationCallbackLocked() -> (@Sendable () -> Void)? {
        guard !terminationReported else { return nil }
        terminationReported = true
        return onTermination
    }

    private static func advisoryKey(for event: RecognitionEvent) -> AdvisoryKey? {
        switch event.kind {
        case .stateChanged:
            .state(event.sessionID)
        case .transcript(.preview):
            .preview(event.sessionID)
        case .accepted, .transcript(.stableChunk), .transcript(.finalTranscript), .outcome:
            nil
        }
    }
}

/// The throwing unfolding initializer in the supported SDK has no `onCancel`
/// parameter. This sentinel uses the supported continuation termination hook
/// to end a subscription when the returned stream releases its producer.
private final class RecognitionEventStreamLifetime: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init(onTermination: @escaping @Sendable () -> Void) {
        let pair = AsyncStream<Void>.makeStream()
        stream = pair.stream
        continuation = pair.continuation
        continuation.onTermination = { _ in onTermination() }
    }

    deinit {
        continuation.finish()
    }

    func keepAlive() {}
}

private extension RecognitionEvent {
    var deliveryCursor: EventDeliveryCursor {
        .recognition(sessionID: sessionID, eventOrdinal: eventOrdinal)
    }
}
