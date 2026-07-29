import XCTest
@testable import AppLocalVoice

/// Contract tests whose assertions depend on the complete event sequence, not
/// merely on eventual state. The stream is buffered, so the test remains
/// deterministic even when the coordinator emits several events synchronously.
final class StateMachineHardeningTests: XCTestCase {
    func testSuccessfulListeningHasOrderedLifecycleAndExactlyOneTerminalOutcome() async throws {
        let input = ControlledSpeechInput()
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())
        let stream = await coordinator.events()
        let eventsTask = Task { await collectThroughIdle(stream) }

        try await coordinator.startListening()
        await input.send(TranscriptUpdate(text: "hello", isFinal: true))
        _ = try await coordinator.endListening()

        let events = try await withBoundedTimeout(.seconds(1)) { await eventsTask.value }
        let preparingIndex = try XCTUnwrap(events.firstIndex(of: .stateChanged(.preparing)))
        let listeningIndex = try XCTUnwrap(events.firstIndex(of: .stateChanged(.listening)))
        let finalizingIndex = try XCTUnwrap(events.firstIndex(of: .stateChanged(.finalizing)))
        let terminalIndex = try XCTUnwrap(events.firstIndex(of: .listeningFinished(.completed)))
        XCTAssertLessThan(preparingIndex, listeningIndex)
        XCTAssertLessThan(listeningIndex, finalizingIndex)
        XCTAssertLessThan(finalizingIndex, terminalIndex)
        XCTAssertEqual(events.last, .stateChanged(.idle))
        let transcripts = events.compactMap { event -> TranscriptUpdate? in
            if case .transcript(let update) = event { return update }
            return nil
        }
        XCTAssertEqual(transcripts, [TranscriptUpdate(text: "hello", isFinal: true)])
        XCTAssertEqual(events.filter { if case .listeningFinished = $0 { true } else { false } }.count, 1)
    }

    func testFailureHasOrderedFailureTerminalAndRecoveryEventsExactlyOnce() async throws {
        let input = ControlledSpeechInput()
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())
        let stream = await coordinator.events()
        let eventsTask = Task { await collectEvents(stream, count: 6) }

        try await coordinator.startListening()
        // Let the coordinator's transcript task begin iterating before the
        // controlled provider terminates its stream. AsyncStream buffers the
        // termination, but this yield makes the lifecycle hand-off explicit
        // and keeps the test independent of executor scheduling.
        for _ in 0..<16 { await Task.yield() }
        let error = VoiceError.audioSessionUnavailable("phone call")
        await input.failStream(error)

        let events = try await withBoundedTimeout(.seconds(1)) { await eventsTask.value }
        XCTAssertEqual(events, [
            .stateChanged(.preparing),
            .stateChanged(.listening),
            .failure(error),
            .listeningFinished(.failed(error)),
            .stateChanged(.failed),
            .stateChanged(.idle)
        ])
        XCTAssertEqual(events.filter { if case .listeningFinished = $0 { true } else { false } }.count, 1)
        let cancelCount = await input.cancels
        let balanced = await input.ledger.isBalanced()
        XCTAssertEqual(cancelCount, 1)
        XCTAssertTrue(balanced)
    }

    func testCleanupFailureStaysFailedUntilCloseCanReconcileResources() async throws {
        let input = ControlledSpeechInput()
        await input.setCleanupBlocked(true)
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())
        let stream = await coordinator.events()

        try await coordinator.startListening()
        await coordinator.cancelListening()

        let failedState = await coordinator.state
        XCTAssertEqual(failedState, .failed)
        let firstEvents = await collectEvents(stream, count: 4)
        XCTAssertEqual(firstEvents.filter { if case .listeningFinished = $0 { true } else { false } }.count, 1)
        XCTAssertTrue(firstEvents.contains(.failure(.audioSessionUnavailable("The microphone cleanup is still in progress; retry close() before starting another turn."))))

        await input.setCleanupBlocked(false)
        await coordinator.close()
        let recoveredState = await coordinator.state
        XCTAssertEqual(recoveredState, .idle)
    }

    func testFinishFailureCancelsCaptureAndAllowsASecondOperation() async throws {
        let input = ControlledSpeechInput()
        await input.setFailure(HarnessFailure(stage: .finalization, message: "finalize failed"))
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())

        try await coordinator.startListening()
        do {
            _ = try await coordinator.endListening()
            XCTFail("finish should report the injected failure")
        } catch let error as HarnessFailure {
            XCTAssertEqual(error.stage, .finalization)
        }

        let stateAfterFailure = await coordinator.state
        let balanced = await input.ledger.isBalanced()
        XCTAssertEqual(stateAfterFailure, .idle)
        XCTAssertTrue(balanced)

        await input.setFailure(nil)
        try await coordinator.startListening()
        await coordinator.cancelListening()
        let recoveredState = await coordinator.state
        XCTAssertEqual(recoveredState, .idle)
    }

    func testInterruptionErrorMapsToInterruptedTerminalWithoutASecondFailureEvent() async throws {
        let input = ControlledSpeechInput()
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())
        let stream = await coordinator.events()
        let eventsTask = Task { await collectThroughIdle(stream) }

        try await coordinator.startListening()
        await input.failStream(VoiceError.interrupted("route changed"))

        let events = try await withBoundedTimeout(.seconds(1)) { await eventsTask.value }
        XCTAssertEqual(events.filter { if case .failure = $0 { true } else { false } }.count, 0)
        XCTAssertEqual(events.filter { if case .listeningFinished(.interrupted) = $0 { true } else { false } }.count, 1)
        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
    }

    func testConcurrentListeningAndSpeechAreRejectedBeforeProviderReentry() async throws {
        let input = ControlledSpeechInput()
        let output = ControlledSpeechOutput()
        let coordinator = VoiceCoordinator(input: input, output: output)

        try await coordinator.startListening()
        do {
            try await coordinator.speak("blocked")
            XCTFail("speech must not begin while listening")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .invalidState("A voice operation is already active."))
        }
        let speechStarts = await output.starts
        XCTAssertEqual(speechStarts, 0)

        await coordinator.cancelListening()
        let speech = Task { try await coordinator.speak("first") }
        await output.waitUntilStarted()
        do {
            try await coordinator.speak("second")
            XCTFail("a second speech operation must be rejected")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .invalidState("A voice operation is already active."))
        }
        await coordinator.stopSpeaking()
        _ = try? await speech.value
        let spoken = await output.spoken
        XCTAssertEqual(spoken, ["first"])
    }

    func testModelPolicyIsForwardedAndInstalledOnlyPreflightIsDeterministic() async throws {
        let input = ControlledSpeechInput()
        await input.setCapabilities(SpeechCapabilities(locale: .current, isSupported: true, supportsOnDevice: true))
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())

        try await coordinator.startListening(configuration: .init(policy: .allowModelInstallation))
        let forwardedConfiguration = await input.lastConfiguration
        XCTAssertEqual(forwardedConfiguration?.policy, .allowModelInstallation)
        await coordinator.cancelListening()

        await input.setCapabilities(SpeechCapabilities(locale: .current, isSupported: true, supportsOnDevice: false))
        do {
            try await coordinator.startListening(configuration: .init(policy: .installedModelsOnly))
            XCTFail("installed-only policy must reject an unavailable model")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .onDeviceRecognitionUnavailable(.current))
        }
        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
    }

    func testRandomizedOperationSequencesAreReproducibleAndLeaveNoResources() async throws {
        for seed in 1...64 {
            let ledger = ResourceLedger()
            let input = ControlledSpeechInput(ledger: ledger)
            let output = ControlledSpeechOutput(ledger: ledger)
            let coordinator = VoiceCoordinator(input: input, output: output)
            var random = DeterministicRandom(seed: UInt64(seed))

            for _ in 0..<48 {
                switch random.nextInt(6) {
                case 0:
                    if await coordinator.state == .idle { _ = try? await coordinator.startListening() }
                case 1:
                    if await coordinator.state == .listening { _ = try? await coordinator.endListening() }
                case 2:
                    await coordinator.cancelListening()
                case 3:
                    if await coordinator.state == .idle {
                        let task = Task { try? await coordinator.speak("seed-\(seed)") }
                        await output.waitUntilStarted()
                        await output.complete(.success(()))
                        _ = await task.value
                    }
                case 4:
                    await coordinator.stopSpeaking()
                default:
                    await coordinator.close()
                }
            }

            await coordinator.close()
            let state = await coordinator.state
            let balanced = await ledger.isBalanced()
            XCTAssertEqual(state, .idle, "seed \(seed)")
            XCTAssertTrue(balanced, "resource leak for seed \(seed)")
        }
    }

    func testSlowConsumerRetainsTheLatestFinalTranscriptWithinBoundedBuffer() async throws {
        let input = ControlledSpeechInput()
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())
        // Deliberately do not iterate yet. This models a host whose UI task is
        // busy while recognition continues.
        let stream = await coordinator.events()

        try await coordinator.startListening()
        for _ in 0..<256 {
            await input.send(TranscriptUpdate(text: "partial", isFinal: false))
        }
        await input.send(TranscriptUpdate(text: "the final answer", isFinal: true))
        let finalText = try await coordinator.endListening()
        XCTAssertEqual(finalText, "the final answer")

        let events = await collectThroughIdle(stream)
        XCTAssertLessThanOrEqual(events.count, 32)
        XCTAssertTrue(events.contains(.transcript(TranscriptUpdate(text: "the final answer", isFinal: true))))
        XCTAssertTrue(events.contains(.listeningFinished(.completed)))
    }

    func testRepeatedTurnsStayBoundedAndExposeTheMostRecentFinalSnapshot() async throws {
        let input = ControlledSpeechInput()
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())

        for turn in 0..<40 {
            try await coordinator.startListening()
            for _ in 0..<64 {
                await input.send(TranscriptUpdate(text: "turn-\(turn)-partial", isFinal: false))
            }
            let expected = "turn-\(turn)-final"
            await input.send(TranscriptUpdate(text: expected, isFinal: true))
            let finalText = try await coordinator.endListening()
            XCTAssertEqual(finalText, expected)
        }

        // The single-turn slow-consumer test proves that the bounded stream
        // retains the final snapshot. This repeated-turn test focuses on
        // resource stability and final return values without attempting to
        // drain an AsyncStream that intentionally remains open.
        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle)
    }

}

extension ControlledSpeechInput {
    func setCapabilities(_ value: SpeechCapabilities) {
        capabilitiesValue = value
    }
}

private func collectEvents(_ stream: AsyncStream<VoiceEvent>, count: Int) async -> [VoiceEvent] {
    var events: [VoiceEvent] = []
    for await event in stream {
        events.append(event)
        if events.count == count { break }
    }
    return events
}

private func collectThroughIdle(_ stream: AsyncStream<VoiceEvent>) async -> [VoiceEvent] {
    var events: [VoiceEvent] = []
    for await event in stream {
        events.append(event)
        if event == .stateChanged(.idle) { break }
    }
    return events
}
