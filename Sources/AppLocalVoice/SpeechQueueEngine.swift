import Foundation

/// Provider-neutral serialized speech queue.
///
/// The engine owns acceptance, ordering, replay identity, and queue lifecycle.
/// It deliberately knows nothing about AVAudioSession or an Apple speech
/// provider; a coordinator drives the accepted attempts through its output
/// adapter and reports terminal outcomes back here.
actor SpeechQueueEngine {
    struct Attempt: Sendable, Equatable {
        let item: SpeechItem
        let playbackID: SpeechPlaybackID
    }

    private struct Pending: Sendable, Equatable {
        let item: SpeechItem
        let playbackID: SpeechPlaybackID
    }

    private let configuration: SpeechQueueConfiguration
    private var mode: SpeechQueueMode
    private var pending: [Pending] = []
    private var pendingTextUTF16Length = 0
    private var current: Pending?
    private var items: [SpeechItemID: SpeechItem] = [:]
    private var replayOrder: [SpeechItemID] = []
    private var nextEventOrdinal: UInt64 = 0
    private var mutationGeneration: UInt64 = 0
    private var undeliveredEvents: [SpeechQueueEvent] = []
    private var undeliveredResults: [SpeechPlaybackResult] = []
    private var continuations: [UUID: AsyncStream<SpeechQueueEvent>.Continuation] = [:]

    init(configuration: SpeechQueueConfiguration = .init()) {
        self.configuration = configuration
        mode = configuration.initialMode
    }

    func events() -> AsyncStream<SpeechQueueEvent> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id) }
            }
        }
    }

    func enqueue(
        _ request: SpeechItemRequest,
        policy: SpeechEnqueuePolicy = .append
    ) throws -> SpeechPlaybackAcceptance {
        let item = SpeechItem(id: SpeechItemID(), request: request)
        let acceptance = try accept(item: item, policy: policy)
        items[item.id] = item
        replayOrder.append(item.id)
        trimReplayHistory()
        return acceptance
    }

    func replay(
        _ itemID: SpeechItemID,
        policy: SpeechEnqueuePolicy = .append
    ) throws -> SpeechPlaybackAcceptance {
        guard let item = items[itemID] else {
            throw VoiceError.itemUnavailable(itemID)
        }
        return try accept(item: item, policy: policy)
    }

    func pause() -> SpeechControlResult {
        guard mode == .running else { return .alreadyApplied }
        mode = .suspended
        if let current { _ = emit(item: current, kind: .paused) }
        else { advanceMutationGeneration() }
        return .applied
    }

    func resume() -> SpeechControlResult {
        guard mode == .suspended else { return .alreadyApplied }
        mode = .running
        if let current { _ = emit(item: current, kind: .resumed) }
        else { advanceMutationGeneration() }
        return .applied
    }

    /// Suspends ordered playback without changing the accepted attempts.
    func suspend() -> SpeechControlResult {
        guard mode == .running else { return .alreadyApplied }
        mode = .suspended
        advanceMutationGeneration()
        return .applied
    }

    func isRunning() -> Bool { mode == .running }

    func nextAttempt() -> Attempt? {
        guard mode == .running, current == nil, !pending.isEmpty else { return nil }
        let next = pending.removeFirst()
        removePendingText(for: next)
        current = next
        _ = emit(item: next, kind: .started)
        return Attempt(item: next.item, playbackID: next.playbackID)
    }

    func finish(
        playbackID: SpeechPlaybackID,
        outcome: SpeechPlaybackOutcome
    ) -> SpeechPlaybackResult? {
        guard let active = current, active.playbackID == playbackID else { return nil }
        current = nil
        return recordOutcome(active, outcome: outcome)
    }

    func skip() -> SpeechPlaybackResult? {
        guard let active = current else { return nil }
        current = nil
        return recordOutcome(active, outcome: .skipped)
    }

    /// Stops only the active attempt and suspends ordered playback. Pending
    /// attempts remain accepted and retain their original playback identity.
    func stopActive(
        reason: SpeechPlaybackCancellationReason = .stopped
    ) -> [SpeechPlaybackResult] {
        let modeChanged = mode != .suspended
        mode = .suspended
        guard let active = current else {
            if modeChanged { advanceMutationGeneration() }
            return []
        }
        current = nil
        return [recordOutcome(active, outcome: .cancelled(reason))]
    }

    @discardableResult
    func stopAndClear(
        reason: SpeechPlaybackCancellationReason = .stopped,
        suspend: Bool = true
    ) -> [SpeechPlaybackResult] {
        let modeChanged = suspend && mode != .suspended
        if suspend { mode = .suspended }
        var results: [SpeechPlaybackResult] = []
        if let active = current {
            current = nil
            let outcome = SpeechPlaybackOutcome.cancelled(reason)
            results.append(recordOutcome(active, outcome: outcome))
        }
        for attempt in pending {
            let outcome = SpeechPlaybackOutcome.cancelled(reason)
            results.append(recordOutcome(attempt, outcome: outcome))
        }
        pending.removeAll(keepingCapacity: false)
        pendingTextUTF16Length = 0
        if results.isEmpty, modeChanged { advanceMutationGeneration() }
        return results
    }

    func clearPending() -> [SpeechPlaybackResult] {
        let attempts = pending
        guard !attempts.isEmpty else { return [] }
        pending.removeAll(keepingCapacity: false)
        pendingTextUTF16Length = 0
        let results = attempts.map { attempt in
            recordOutcome(attempt, outcome: .cancelled(.cleared))
        }
        return results
    }

    func pendingCount() -> Int { pending.count }
    func snapshot() -> SpeechQueueSnapshot {
        func value(_ attempt: Pending) -> SpeechQueueAttemptSnapshot {
            SpeechQueueAttemptSnapshot(itemID: attempt.item.id, playbackID: attempt.playbackID, priority: attempt.item.priority, textUTF16Length: attempt.item.text.utf16.count)
        }
        return SpeechQueueSnapshot(mode: mode, active: current.map(value), pending: pending.map(value), retainedItemIDs: replayOrder, generation: mutationGeneration)
    }
    func hasOutstandingWork() -> Bool { current != nil || !pending.isEmpty }
    func clearReplayHistory() {
        guard !items.isEmpty || !replayOrder.isEmpty else { return }
        items.removeAll(keepingCapacity: false)
        replayOrder.removeAll(keepingCapacity: false)
        advanceMutationGeneration()
    }
    func drainEvents() -> [SpeechQueueEvent] {
        defer { undeliveredEvents.removeAll(keepingCapacity: true) }
        return undeliveredEvents
    }
    func drainResults() -> [SpeechPlaybackResult] {
        defer { undeliveredResults.removeAll(keepingCapacity: true) }
        return undeliveredResults
    }
    func activeAttempt() -> Attempt? {
        guard let current else { return nil }
        return Attempt(item: current.item, playbackID: current.playbackID)
    }

    func isCurrent(_ playbackID: SpeechPlaybackID) -> Bool {
        current?.playbackID == playbackID
    }

    private func accept(item: SpeechItem, policy: SpeechEnqueuePolicy) throws -> SpeechPlaybackAcceptance {
        let playbackID = SpeechPlaybackID()
        let attempt = Pending(item: item, playbackID: playbackID)
        switch policy {
        case .append:
            try append(attempt)
        case .playNext:
            try insertNext(attempt)
        case .replaceCurrent:
            // Validate capacity before touching the active attempt. A rejected
            // replacement must leave the currently playing item untouched.
            try ensurePendingTextCapacity(for: attempt)
            try ensureCapacity()
            if let active = current {
                current = nil
                _ = recordOutcome(active, outcome: .cancelled(.replaced))
            }
            insertNextUnchecked(attempt)
        case .replaceAll:
            try ensureReplacementTextCapacity(for: attempt)
            _ = clearPending()
            if let active = current {
                current = nil
                _ = recordOutcome(active, outcome: .cancelled(.replaced))
            }
            insertNextUnchecked(attempt)
        }
        let accepted = emit(item: attempt, kind: .accepted)
        return SpeechPlaybackAcceptance(
            itemID: item.id,
            playbackID: playbackID,
            acceptedEventOrdinal: accepted.eventOrdinal
        )
    }

    private func append(_ attempt: Pending) throws {
        try ensurePendingTextCapacity(for: attempt)
        try ensureCapacity()
        let insertionIndex = pending.firstIndex {
            $0.item.priority < attempt.item.priority
        } ?? pending.endIndex
        insertUnchecked(attempt, at: insertionIndex)
    }

    private func insertNext(_ attempt: Pending) throws {
        try ensurePendingTextCapacity(for: attempt)
        try ensureCapacity()
        insertNextUnchecked(attempt)
    }

    private func ensureCapacity() throws {
        guard pending.count >= configuration.maximumPendingItemCount else { return }
        switch configuration.overflowPolicy {
        case .rejectNew:
            throw VoiceError.queueFull(maximumPendingItemCount: configuration.maximumPendingItemCount)
        case .dropOldestPending:
            guard !pending.isEmpty else { return }
            let dropped = pending.removeFirst()
            removePendingText(for: dropped)
            let outcome = SpeechPlaybackOutcome.cancelled(.overflow)
            _ = recordOutcome(dropped, outcome: outcome)
        }
    }

    private func pendingTextBudgetError() -> VoiceError {
        .queueTextBudgetExceeded(
            maximumUTF16Length: configuration.maximumPendingTextUTF16Length
        )
    }

    private func ensurePendingTextCapacity(for attempt: Pending) throws {
        let length = attempt.item.text.utf16.count
        let result = pendingTextUTF16Length.addingReportingOverflow(length)
        guard !result.overflow,
              result.partialValue <= configuration.maximumPendingTextUTF16Length else {
            throw pendingTextBudgetError()
        }
    }

    private func ensureReplacementTextCapacity(for attempt: Pending) throws {
        guard attempt.item.text.utf16.count <= configuration.maximumPendingTextUTF16Length else {
            throw pendingTextBudgetError()
        }
    }

    private func insertUnchecked(_ attempt: Pending, at index: Int) {
        pending.insert(attempt, at: index)
        addPendingText(for: attempt)
    }

    private func insertNextUnchecked(_ attempt: Pending) {
        insertUnchecked(attempt, at: 0)
    }

    private func addPendingText(for attempt: Pending) {
        let result = pendingTextUTF16Length.addingReportingOverflow(attempt.item.text.utf16.count)
        pendingTextUTF16Length = result.overflow ? Int.max : result.partialValue
    }

    private func removePendingText(for attempt: Pending) {
        let result = pendingTextUTF16Length.subtractingReportingOverflow(attempt.item.text.utf16.count)
        pendingTextUTF16Length = result.overflow ? 0 : result.partialValue
    }

    private func emit(item: Pending, kind: SpeechQueueEventKind) -> SpeechQueueEvent {
        advanceMutationGeneration()
        let event = SpeechQueueEvent(
            itemID: item.item.id,
            playbackID: item.playbackID,
            eventOrdinal: nextEventOrdinal,
            kind: kind
        )
        nextEventOrdinal = nextEventOrdinal == .max ? 0 : nextEventOrdinal + 1
        undeliveredEvents.append(event)
        for continuation in continuations.values { continuation.yield(event) }
        return event
    }

    private func advanceMutationGeneration() {
        mutationGeneration &+= 1
    }

    private func recordOutcome(
        _ attempt: Pending,
        outcome: SpeechPlaybackOutcome
    ) -> SpeechPlaybackResult {
        let event = emit(item: attempt, kind: .outcome(outcome))
        let result = SpeechPlaybackResult(
            itemID: attempt.item.id,
            playbackID: attempt.playbackID,
            terminalEventOrdinal: event.eventOrdinal,
            outcome: outcome
        )
        undeliveredResults.append(result)
        return result
    }

    private func removeSubscriber(_ id: UUID) { continuations.removeValue(forKey: id) }

    private func trimReplayHistory() {
        while replayOrder.count > configuration.maximumReplayHistoryItemCount
            || (replayHistoryTextUTF16Length() ?? Int.max) > configuration.maximumReplayHistoryTextUTF16Length {
            guard let oldest = replayOrder.first else { return }
            replayOrder.removeFirst()
            items.removeValue(forKey: oldest)
        }
    }

    private func replayHistoryTextUTF16Length() -> Int? {
        var total = 0
        for id in replayOrder {
            guard let item = items[id] else { continue }
            let result = total.addingReportingOverflow(item.text.utf16.count)
            guard !result.overflow else { return nil }
            total = result.partialValue
        }
        return total
    }
}
