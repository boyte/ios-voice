import Foundation
import XCTest
@testable import AppLocalVoice

@MainActor
final class RuntimeFacadeGateTests: XCTestCase {
    func testStablePublisherHonorsFiveAndTenSecondUnchangedPrefixIntervals() throws {
        let sessionID = RecognitionSessionID()
        var fiveSecondPublisher = StableTranscriptPublisher(
            sessionID: sessionID,
            policy: try StableChunkPolicy(intervalSeconds: 5)
        )
        XCTAssertTrue(try fiveSecondPublisher.observe(text: "five seconds", at: .zero).isEmpty)
        XCTAssertTrue(
            try fiveSecondPublisher.drainMaturedChunks(at: .milliseconds(4_999)).isEmpty
        )
        XCTAssertEqual(
            try fiveSecondPublisher.drainMaturedChunks(at: .seconds(5)).map(\.text),
            ["five seconds"]
        )

        var tenSecondPublisher = StableTranscriptPublisher(
            sessionID: sessionID,
            policy: try StableChunkPolicy(intervalSeconds: 10)
        )
        XCTAssertTrue(try tenSecondPublisher.observe(text: "ten seconds", at: .zero).isEmpty)
        XCTAssertTrue(
            try tenSecondPublisher.drainMaturedChunks(at: .milliseconds(9_999)).isEmpty
        )
        XCTAssertEqual(
            try tenSecondPublisher.drainMaturedChunks(at: .seconds(10)).map(\.text),
            ["ten seconds"]
        )
    }

    func testStableChunksEmitContiguousUTF16AndFlushTailBeforeFinal() async throws {
        let clock = ManualStableTranscriptClock()
        let input = ControlledSpeechInput()
        let voice = AppLocalVoice(
            input: input,
            output: ControlledSpeechOutput(),
            stableTranscriptClock: clock
        )
        let recorder = RecognitionEventRecorder()
        let stream = await voice.recognitionEvents()
        let observation = Task {
            for try await event in stream {
                await recorder.append(event)
                if event.kind.isTerminal { return }
            }
        }

        let acceptance = try await voice.startSession(configuration: .init(
            publicationPolicy: .stableChunks(try StableChunkPolicy(intervalSeconds: 1))
        ))
        await waitForGateFacadeState(.listening, voice: voice)

        await input.send(TranscriptUpdate(text: "Hello ", isFinal: false))
        try await waitForRecordedEvent(recorder) { event in
            if case .transcript(.preview(let preview)) = event.kind {
                return preview.text == "Hello "
            }
            return false
        }
        let containedStableChunkBeforeInterval = await recorder.containsStableChunk
        XCTAssertFalse(containedStableChunkBeforeInterval)

        for _ in 0..<5 { await Task.yield() }
        clock.advance(by: .seconds(1))
        await Task.yield()
        try await waitForRecordedEvent(recorder) { event in
            if case .transcript(.stableChunk(let chunk)) = event.kind {
                return chunk.text == "Hello "
            }
            return false
        }

        let finalText = "Hello world 👋"
        await input.send(TranscriptUpdate(text: finalText, isFinal: false))
        try await waitForRecordedEvent(recorder) { event in
            if case .transcript(.preview(let preview)) = event.kind {
                return preview.text == finalText
            }
            return false
        }
        let final = try await voice.finishSession(id: acceptance.sessionID)
        try await observation.value

        let events = await recorder.snapshot
        let chunks = events.compactMap { event -> StableTranscriptChunk? in
            if case .transcript(.stableChunk(let chunk)) = event.kind { return chunk }
            return nil
        }
        XCTAssertEqual(chunks.map(\.sequence), Array(0..<UInt64(chunks.count)))
        XCTAssertEqual(chunks.first?.utf16Range.location, 0)
        for index in chunks.indices.dropFirst() {
            XCTAssertEqual(
                chunks[index].utf16Range.location,
                chunks[chunks.index(before: index)].utf16Range.endLocation
            )
        }
        XCTAssertTrue(chunks.allSatisfy { $0.utf16Range.length == $0.text.utf16.count })
        XCTAssertEqual(chunks.map(\.text).joined(), final.text)
        XCTAssertEqual(chunks.last?.utf16Range.endLocation, final.text.utf16.count)

        let lastChunkIndex = try XCTUnwrap(events.lastIndex { event in
            if case .transcript(.stableChunk) = event.kind { return true }
            return false
        })
        let finalIndex = try XCTUnwrap(events.firstIndex { event in
            if case .transcript(.finalTranscript) = event.kind { return true }
            return false
        })
        XCTAssertLessThan(lastChunkIndex, finalIndex)
        XCTAssertEqual(events.last?.kind, .outcome(.completed))
        let closed = await voice.close()
        XCTAssertEqual(closed, .released)
    }

    func testRewriteOfPublishedStablePrefixFailsTranscriptConsistency() async throws {
        let clock = ManualStableTranscriptClock()
        let input = ControlledSpeechInput()
        let voice = AppLocalVoice(
            input: input,
            output: ControlledSpeechOutput(),
            stableTranscriptClock: clock
        )
        let recorder = RecognitionEventRecorder()
        let stream = await voice.recognitionEvents()
        let observation = Task {
            for try await event in stream {
                await recorder.append(event)
                if event.kind.isTerminal { return }
            }
        }

        _ = try await voice.startSession(configuration: .init(
            publicationPolicy: .stableChunks(try StableChunkPolicy(intervalSeconds: 1))
        ))
        await waitForGateFacadeState(.listening, voice: voice)
        await input.send(TranscriptUpdate(text: "immutable ", isFinal: false))
        try await waitForRecordedEvent(recorder) { event in
            if case .transcript(.preview) = event.kind { return true }
            return false
        }
        await clock.waitUntilSleeping()
        clock.advance(by: .seconds(1))
        await Task.yield()
        try await waitForRecordedEvent(recorder) { event in
            if case .transcript(.stableChunk) = event.kind { return true }
            return false
        }

        await input.send(TranscriptUpdate(text: "rewritten ", isFinal: false))
        try await observation.value

        let events = await recorder.snapshot
        guard case .outcome(.failed(let failure)) = events.last?.kind else {
            XCTFail("Expected transcript-consistency terminal failure")
            return
        }
        XCTAssertEqual(failure.category, .transcriptConsistency)
        XCTAssertFalse(events.contains { event in
            if case .transcript(.finalTranscript) = event.kind { return true }
            return false
        })
        let closed = await voice.close()
        XCTAssertEqual(closed, .released)
    }

    func testAdvisorySlotsDoNotConsumeDurableCapacityAndOverflowReportsCursor() async throws {
        let registry = CanonicalEventSubscriberRegistry()
        var delivery = RecognitionEventDelivery(subscriberRegistry: registry)
        let stream = delivery.subscribe { _ in }
        let sessionID = RecognitionSessionID()

        for revision in 0..<UInt64(200) {
            delivery.publish(RecognitionEvent(
                sessionID: sessionID,
                eventOrdinal: revision * 2,
                kind: .transcript(.preview(TranscriptPreview(
                    sessionID: sessionID,
                    revision: revision,
                    text: "preview"
                )))
            ))
            delivery.publish(RecognitionEvent(
                sessionID: sessionID,
                eventOrdinal: revision * 2 + 1,
                kind: .stateChanged(revision.isMultiple(of: 2) ? .listening : .finalizing)
            ))
        }

        let durableBase: UInt64 = 10_000
        for offset in 0..<UInt64(RecognitionEventDeliveryLimits.maximumDurableEventCountPerSubscriber) {
            delivery.publish(RecognitionEvent(
                sessionID: sessionID,
                eventOrdinal: durableBase + offset,
                kind: .accepted
            ))
        }
        let firstUndeliveredOrdinal = durableBase +
            UInt64(RecognitionEventDeliveryLimits.maximumDurableEventCountPerSubscriber)
        delivery.publish(RecognitionEvent(
            sessionID: sessionID,
            eventOrdinal: firstUndeliveredOrdinal,
            kind: .outcome(.completed)
        ))

        var received: [RecognitionEvent] = []
        do {
            for try await event in stream { received.append(event) }
            XCTFail("Expected explicit durable delivery overflow")
        } catch let error as VoiceError {
            XCTAssertEqual(
                error,
                .eventDeliveryOverflow(
                    capacity: 32,
                    firstUndelivered: .recognition(
                        sessionID: sessionID,
                        eventOrdinal: firstUndeliveredOrdinal
                    )
                )
            )
        }

        XCTAssertEqual(received.filter(\.kind.isAccepted).count, 32)
        XCTAssertEqual(received.filter { event in
            if case .transcript(.preview) = event.kind { return true }
            return false
        }.count, 1)
        XCTAssertEqual(received.filter { event in
            if case .stateChanged = event.kind { return true }
            return false
        }.count, 1)
    }

    func testCanonicalSubscriberLimitIsProcessWideAndDoesNotEvictExistingStreams() async throws {
        let registry = CanonicalEventSubscriberRegistry()
        var firstDelivery = RecognitionEventDelivery(subscriberRegistry: registry)
        var secondDelivery = RecognitionEventDelivery(subscriberRegistry: registry)
        var streams: [AsyncThrowingStream<RecognitionEvent, Error>] = []
        for _ in 0..<4 { streams.append(firstDelivery.subscribe { _ in }) }
        for _ in 0..<4 { streams.append(secondDelivery.subscribe { _ in }) }
        XCTAssertEqual(registry.activeSubscriberCount, 8)

        let rejected = secondDelivery.subscribe { _ in }
        do {
            for try await _ in rejected {}
            XCTFail("Expected ninth subscriber rejection")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .eventSubscriberLimitReached(maximum: 8, active: 8))
        }
        XCTAssertEqual(registry.activeSubscriberCount, 8)

        let sessionID = RecognitionSessionID()
        let event = RecognitionEvent(sessionID: sessionID, eventOrdinal: 0, kind: .accepted)
        firstDelivery.publish(event)
        secondDelivery.publish(event)
        for stream in streams {
            var iterator = stream.makeAsyncIterator()
            let received = try await iterator.next()
            XCTAssertEqual(received, event)
        }
    }

    func testCanonicalRecoverySnapshotsArePerSubscriptionDuringReconciliationAndBlocked() async throws {
        let output = RecoveryBlockingSpeechOutput(releaseAfterFirstFailure: true)
        let coordinator = VoiceCoordinator(
            input: ControlledSpeechInput(),
            output: output,
            eventSubscriberRegistry: CanonicalEventSubscriberRegistry()
        )
        let first = await coordinator.voiceEvents()
        var firstIterator = first.makeAsyncIterator()
        guard case .snapshot(let readySnapshot)? = try await firstIterator.next() else {
            XCTFail("The first subscription must receive its own ready snapshot")
            return
        }
        XCTAssertEqual(readySnapshot.recoveryState, .ready)

        _ = try await coordinator.enqueueSpeech(
            SpeechItemRequest(text: "unreleased")
        )
        try await withBoundedTimeout(.seconds(1)) {
            while await coordinator.state != .failed { await Task.yield() }
        }
        // The failed queue worker may still be releasing its output lease.
        // Let that worker finish before arming the close-specific check below.
        await output.setReleased(true)
        try await withBoundedTimeout(.seconds(1)) {
            while await coordinator.state != .idle { await Task.yield() }
        }
        await output.setReleased(false)
        await output.blockNextResourceCheck()

        let closing = Task.detached { await coordinator.closeAndReport() }
        try await withBoundedTimeout(.seconds(1)) {
            await output.waitUntilResourceCheckEntered()
        }
        let recoveryState = await coordinator.recoveryState
        XCTAssertEqual(recoveryState, .reconciling)

        let second = await coordinator.voiceEvents()
        var secondIterator = second.makeAsyncIterator()
        guard case .snapshot(let reconcilingSnapshot)? = try await secondIterator.next() else {
            XCTFail("A subscription during reconciliation must receive reconciling")
            return
        }
        XCTAssertEqual(reconcilingSnapshot.recoveryState, .reconciling)

        await output.releaseResourceCheck(asReleased: false)
        let closed = await closing.value
        XCTAssertFalse(closed)
        let blockedState = await coordinator.recoveryState
        XCTAssertEqual(blockedState, .blocked(.init(
            category: .audioSessionUnavailable,
            recommendedAction: .retry
        )))

        let third = await coordinator.voiceEvents()
        var thirdIterator = third.makeAsyncIterator()
        guard case .snapshot(let blockedSnapshot)? = try await thirdIterator.next() else {
            XCTFail("A subscription while blocked must receive blocked")
            return
        }
        XCTAssertEqual(blockedSnapshot.recoveryState, .blocked(.init(
            category: .audioSessionUnavailable,
            recommendedAction: .retry
        )))

        var firstRecoveryKinds: [VoiceRecoveryEventKind] = []
        while firstRecoveryKinds.count < 2 {
            guard let event = try await firstIterator.next() else { break }
            if case .recovery(let recovery) = event {
                firstRecoveryKinds.append(recovery.kind)
            }
        }
        XCTAssertEqual(firstRecoveryKinds, [.reconciling, .blocked(.init(
            category: .audioSessionUnavailable,
            recommendedAction: .retry
        ))])

        var secondRecoveryKinds: [VoiceRecoveryEventKind] = [.reconciling]
        while secondRecoveryKinds.count < 2 {
            guard let event = try await secondIterator.next() else { break }
            if case .recovery(let recovery) = event {
                secondRecoveryKinds.append(recovery.kind)
            }
        }
        XCTAssertEqual(secondRecoveryKinds, [.reconciling, .blocked(.init(
            category: .audioSessionUnavailable,
            recommendedAction: .retry
        ))])
    }

    func testPublicRecoveryStateSnapshotTracksReconciliationBlockedAndReady() async throws {
        let output = RecoveryBlockingSpeechOutput()
        let voice = AppLocalVoice(
            input: ControlledSpeechInput(),
            output: output,
            eventSubscriberRegistry: CanonicalEventSubscriberRegistry()
        )

        let initialRecoveryState = await voice.recoveryState
        XCTAssertEqual(initialRecoveryState, .ready)
        _ = try await voice.enqueueSpeech("unreleased")
        try await withBoundedTimeout(.seconds(1)) {
            while await voice.state != .failed { await Task.yield() }
        }
        // This facade-level check verifies the externally queryable stable
        // states. The canonical-stream test above owns the separately
        // synchronized transient `.reconciling` assertion.
        let closeResult = await voice.close()
        XCTAssertEqual(closeResult, .blocked(.init(
            category: .audioSessionUnavailable,
            recommendedAction: .retry
        )))
        let blockedRecoveryState = await voice.recoveryState
        XCTAssertEqual(blockedRecoveryState, .blocked(.init(
            category: .audioSessionUnavailable,
            recommendedAction: .retry
        )))

        await output.setReleased(true)
        let recovered = await voice.close()
        XCTAssertEqual(recovered, .released)
        let recoveredRecoveryState = await voice.recoveryState
        XCTAssertEqual(recoveredRecoveryState, .ready)
    }

    func testProcessLeaseSurvivesIdleAndNonOwnerCloseThenReleasesOnOwnerClose() async throws {
        let runtimeLease = ProcessVoiceRuntimeLease()
        let firstInput = ControlledSpeechInput()
        let secondInput = ControlledSpeechInput()
        let first = AppLocalVoice(
            input: firstInput,
            output: ControlledSpeechOutput(),
            runtimeLease: runtimeLease
        )
        let second = AppLocalVoice(
            input: secondInput,
            output: ControlledSpeechOutput(),
            runtimeLease: runtimeLease
        )
        let secondStream = await second.recognitionEvents()

        let firstAcceptance = try await first.startSession()
        await waitForGateFacadeState(.listening, voice: first)
        await first.cancelSession(id: firstAcceptance.sessionID)
        await waitForGateFacadeState(.idle, voice: first)

        do {
            _ = try await second.startSession()
            XCTFail("Competing facade must fail before admission")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .serviceInUse)
        }
        let rejectedProviderStarts = await secondInput.starts
        XCTAssertEqual(rejectedProviderStarts, 0)
        let nonOwnerClosed = await second.close()
        XCTAssertEqual(nonOwnerClosed, .released)
        let firstStateAfterNonOwnerClose = await first.state
        XCTAssertEqual(firstStateAfterNonOwnerClose, .idle)

        let firstClosed = await first.close()
        XCTAssertEqual(firstClosed, .released)
        let secondAcceptance = try await second.startSession()
        var iterator = secondStream.makeAsyncIterator()
        let firstSecondFacadeEvent = try await iterator.next()
        XCTAssertEqual(firstSecondFacadeEvent?.kind, .accepted)
        XCTAssertEqual(firstSecondFacadeEvent?.sessionID, secondAcceptance.sessionID)
        await waitForGateFacadeState(.listening, voice: second)
        await second.cancelSession(id: secondAcceptance.sessionID)
        let secondClosed = await second.close()
        XCTAssertEqual(secondClosed, .released)
    }

    func testBlockedOwnerCloseRetainsProcessLeaseUntilCleanupSucceeds() async throws {
        let runtimeLease = ProcessVoiceRuntimeLease()
        let blockedInput = ControlledSpeechInput()
        let competitorInput = ControlledSpeechInput()
        let owner = AppLocalVoice(
            input: blockedInput,
            output: ControlledSpeechOutput(),
            runtimeLease: runtimeLease
        )
        let competitor = AppLocalVoice(
            input: competitorInput,
            output: ControlledSpeechOutput(),
            runtimeLease: runtimeLease
        )

        let acceptance = try await owner.startSession()
        await waitForGateFacadeState(.listening, voice: owner)
        await blockedInput.setCleanupBlocked(true)
        await owner.cancelSession(id: acceptance.sessionID)
        let blockedState = await owner.state
        XCTAssertEqual(blockedState, .failed)
        let blockedClose = await owner.close()
        XCTAssertEqual(blockedClose, .blocked(.init(
            category: .audioSessionUnavailable,
            recommendedAction: .retry
        )))

        do {
            _ = try await competitor.startSession()
            XCTFail("Blocked cleanup must retain the process lease")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .serviceInUse)
        }
        let competitorStartsBeforeRelease = await competitorInput.starts
        XCTAssertEqual(competitorStartsBeforeRelease, 0)

        await blockedInput.setCleanupBlocked(false)
        let ownerClosed = await owner.close()
        XCTAssertEqual(ownerClosed, .released)
        let competitorAcceptance = try await competitor.startSession()
        await waitForGateFacadeState(.listening, voice: competitor)
        await competitor.cancelSession(id: competitorAcceptance.sessionID)
        let competitorClosed = await competitor.close()
        XCTAssertEqual(competitorClosed, .released)
    }

    func testDiscardedActiveFacadePerformsBoundedCleanupBeforeReleasingRuntimeLease() async throws {
        let runtimeLease = ProcessVoiceRuntimeLease()
        let ownerInput = ControlledSpeechInput()
        let competitorInput = ControlledSpeechInput()
        var owner: AppLocalVoice? = AppLocalVoice(
            input: ownerInput,
            output: ControlledSpeechOutput(),
            runtimeLease: runtimeLease
        )
        let competitor = AppLocalVoice(
            input: competitorInput,
            output: ControlledSpeechOutput(),
            runtimeLease: runtimeLease
        )

        if let owner {
            _ = try await owner.startSession()
            await waitForGateFacadeState(.listening, voice: owner)
        } else {
            XCTFail("expected the active owner facade")
            return
        }
        owner = nil

        let deadline = ContinuousClock().now.advanced(by: .seconds(3))
        while ContinuousClock().now < deadline {
            if let acceptance = try? await competitor.startSession() {
                await waitForGateFacadeState(.listening, voice: competitor)
                await competitor.cancelSession(id: acceptance.sessionID)
                let closed = await competitor.close()
                XCTAssertEqual(closed, .released)
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The discarded owner did not release the runtime lease after bounded cleanup")
    }

    func testCancellationAfterAwaitedResourceCheckCreatesNoIdentityEventOrProviderStart() async throws {
        let output = AdmissionBlockingSpeechOutput()
        let input = ControlledSpeechInput()
        let voice = AppLocalVoice(input: input, output: output)
        let stream = await voice.recognitionEvents()

        let cancelledStart = Task { @MainActor in
            try await voice.startSession()
        }
        await output.waitUntilResourceCheckEntered()
        cancelledStart.cancel()
        await output.releaseResourceCheck()

        do {
            _ = try await cancelledStart.value
            XCTFail("Cancelled pre-admission check must not accept a session")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .cancelled)
        }
        let startsAfterCancelledAdmission = await input.starts
        XCTAssertEqual(startsAfterCancelledAdmission, 0)

        let acceptance = try await voice.startSession()
        var iterator = stream.makeAsyncIterator()
        let firstEvent = try await iterator.next()
        XCTAssertEqual(firstEvent?.kind, .accepted)
        XCTAssertEqual(firstEvent?.sessionID, acceptance.sessionID)
        await waitForGateFacadeState(.listening, voice: voice)
        await voice.cancelSession(id: acceptance.sessionID)
        let closed = await voice.close()
        XCTAssertEqual(closed, .released)
    }
}

private actor RecognitionEventRecorder {
    private var events: [RecognitionEvent] = []

    func append(_ event: RecognitionEvent) { events.append(event) }
    var snapshot: [RecognitionEvent] { events }
    var containsStableChunk: Bool {
        events.contains { event in
            if case .transcript(.stableChunk) = event.kind { return true }
            return false
        }
    }

    func contains(_ predicate: @Sendable (RecognitionEvent) -> Bool) -> Bool {
        events.contains(where: predicate)
    }
}

private func waitForRecordedEvent(
    _ recorder: RecognitionEventRecorder,
    matching predicate: @escaping @Sendable (RecognitionEvent) -> Bool
) async throws {
    try await withBoundedTimeout(.seconds(2)) {
        while !(await recorder.contains(predicate)) {
            await Task.yield()
        }
    }
}

private func waitForGateFacadeState(
    _ expected: VoiceState,
    voice: AppLocalVoice,
    timeout: Duration = .seconds(2)
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while await voice.state != expected, clock.now < deadline {
        await Task.yield()
    }
}

/// SAFETY: `lock` protects the clock value, sleeper table, and registration
/// waiters. Continuations are removed while locked and resumed after unlocking.
private final class ManualStableTranscriptClock: StableTranscriptClock, @unchecked Sendable {
    private struct Sleeper {
        let deadline: Duration
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var current: Duration = .zero
    private var sleepers: [UUID: Sleeper] = [:]
    private var sleepWaiters: [CheckedContinuation<Void, Never>] = []

    var now: Duration {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        let deadline = now + duration
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                register(id: id, deadline: deadline, continuation: continuation)
            }
        }, onCancel: { [self] in
            cancel(id: id)
        })
    }

    func waitUntilSleeping() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if sleepers.isEmpty {
                sleepWaiters.append(continuation)
                lock.unlock()
            } else {
                lock.unlock()
                continuation.resume()
            }
        }
    }

    func advance(by duration: Duration) {
        var ready: [CheckedContinuation<Void, Error>] = []
        lock.lock()
        current += duration
        let readyIDs = sleepers.compactMap { id, sleeper in
            sleeper.deadline <= current ? id : nil
        }
        for id in readyIDs {
            if let sleeper = sleepers.removeValue(forKey: id) {
                ready.append(sleeper.continuation)
            }
        }
        lock.unlock()
        ready.forEach { $0.resume() }
    }

    private func register(
        id: UUID,
        deadline: Duration,
        continuation: CheckedContinuation<Void, Error>
    ) {
        var waiters: [CheckedContinuation<Void, Never>] = []
        lock.lock()
        if deadline <= current {
            lock.unlock()
            continuation.resume()
        } else if Task.isCancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
        } else {
            sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
            waiters = sleepWaiters
            sleepWaiters.removeAll(keepingCapacity: false)
            lock.unlock()
            waiters.forEach { $0.resume() }
        }
    }

    private func cancel(id: UUID) {
        lock.lock()
        let sleeper = sleepers.removeValue(forKey: id)
        lock.unlock()
        sleeper?.continuation.resume(throwing: CancellationError())
    }
}

private actor AdmissionBlockingSpeechOutput: SpeechOutput {
    private var shouldBlock = true
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func availableVoices(for locale: Locale) async -> [SpeechVoice] { [] }
    func speak(_ text: String, configuration: SpeechConfiguration) async throws {}
    func pause() async {}
    func resume() async {}
    func stop() async {}

    func resourcesAreReleased() async -> Bool {
        guard shouldBlock else { return true }
        shouldBlock = false
        let waiters = enteredWaiters
        enteredWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return true
    }

    func waitUntilResourceCheckEntered() async {
        guard shouldBlock else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func releaseResourceCheck() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor RecoveryBlockingSpeechOutput: SpeechOutput {
    private var released = true
    private var blockNextCheck = false
    private let releaseAfterFirstFailure: Bool
    private var waitingForReleaseAfterFailure = false
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(releaseAfterFirstFailure: Bool = false) {
        self.releaseAfterFirstFailure = releaseAfterFirstFailure
    }

    func availableVoices(for locale: Locale) async -> [SpeechVoice] { [] }

    func speak(_ text: String, configuration: SpeechConfiguration) async throws {
        released = false
    }

    func pause() async {}
    func resume() async {}
    func stop() async {}

    func resourcesAreReleased() async -> Bool {
        if blockNextCheck {
            blockNextCheck = false
            enteredContinuation?.resume()
            enteredContinuation = nil
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
            return released
        }
        if releaseAfterFirstFailure, waitingForReleaseAfterFailure, !released {
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
        if !released {
            waitingForReleaseAfterFailure = releaseAfterFirstFailure
        } else {
            waitingForReleaseAfterFailure = false
        }
        return released
    }

    func blockNextResourceCheck() {
        blockNextCheck = true
    }

    func waitUntilResourceCheckEntered() async {
        if releaseContinuation != nil { return }
        await withCheckedContinuation { continuation in
            enteredContinuation = continuation
        }
    }

    func releaseResourceCheck(asReleased value: Bool) {
        released = value
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func setReleased(_ value: Bool) {
        released = value
        if value {
            waitingForReleaseAfterFailure = false
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }
}
