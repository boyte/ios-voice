import XCTest
@testable import AppLocalVoice

/// Contract tests whose assertions depend on the complete event sequence, not
/// merely on eventual state. The canonical stream is buffered, so the test
/// remains deterministic even when the coordinator emits several events
/// synchronously.
final class StateMachineHardeningTests: XCTestCase {
    func testSuccessfulListeningHasOrderedLifecycleAndExactlyOneTerminalOutcome() async throws {
        let input = ControlledSpeechInput()
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())
        let stream = await coordinator.voiceEvents()
        let kindsTask = Task { try await collectRecognitionKinds(stream) }

        try await coordinator.startTurn()
        await input.send(TranscriptUpdate(text: "hello", isFinal: true))
        _ = try await coordinator.finishTurn()

        let kinds = try await withBoundedTimeout(.seconds(1)) { try await kindsTask.value }
        XCTAssertEqual(kinds.first, .accepted)
        // Session state events are advisory and coalesce to the newest value
        // for a subscriber that has not yet pulled, so assert order among
        // the states that were observed rather than an exact sequence.
        assertSessionStatesAreOrdered(kinds)
        let finalizingIndex = try XCTUnwrap(kinds.firstIndex(of: .stateChanged(.finalizing)))
        let terminalIndex = try XCTUnwrap(kinds.firstIndex(of: .outcome(.completed)))
        XCTAssertLessThan(finalizingIndex, terminalIndex)
        XCTAssertEqual(kinds.last, .outcome(.completed))
        // Exactly one terminal outcome for the session.
        XCTAssertEqual(kinds.filter { $0.isTerminal }.count, 1)
        // The authoritative final transcript survives exactly once.
        let finals = kinds.compactMap { kind -> String? in
            if case .transcript(.finalTranscript(let transcript)) = kind { return transcript.text }
            return nil
        }
        XCTAssertEqual(finals, ["hello"])
        // There is no idle recognition event, so assert the equivalent global
        // state at the point the turn returned.
        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
    }

    func testFailureHasOrderedFailureTerminalAndRecoveryEventsExactlyOnce() async throws {
        let input = ControlledSpeechInput()
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())
        let stream = await coordinator.voiceEvents()
        let kindsTask = Task { try await collectRecognitionKinds(stream) }

        try await coordinator.startTurn()
        // Let the coordinator's transcript task begin iterating before the
        // controlled provider terminates its stream. The canonical stream
        // buffers the termination, but this yield makes the lifecycle
        // hand-off explicit and keeps the test independent of executor
        // scheduling.
        for _ in 0..<16 { await Task.yield() }
        let error = VoiceError.audioSessionUnavailable("phone call")
        await input.failStream(error)

        let kinds = try await withBoundedTimeout(.seconds(1)) { try await kindsTask.value }
        // A failure surfaces as a single `.outcome(.failed)` carrying the
        // same error category; there is no separate failure event.
        XCTAssertEqual(kinds.first, .accepted)
        assertSessionStatesAreOrdered(kinds)
        XCTAssertFalse(kinds.contains(.stateChanged(.finalizing)))
        guard let last = kinds.last, case .outcome(.failed(let failure)) = last else {
            return XCTFail("expected a failed terminal outcome, got \(String(describing: kinds.last))")
        }
        XCTAssertEqual(failure.category, error.category)
        XCTAssertEqual(kinds.filter { $0.isTerminal }.count, 1)
        // The coordinator reconciles back to idle after the terminal outcome.
        await waitForState(.idle, coordinator: coordinator)
        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        let cancelCount = await input.cancels
        let balanced = await input.ledger.isBalanced()
        XCTAssertEqual(cancelCount, 1)
        XCTAssertTrue(balanced)
    }

    func testCleanupFailureStaysFailedUntilCloseCanReconcileResources() async throws {
        let input = ControlledSpeechInput()
        await input.setCleanupBlocked(true)
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())
        let stream = await coordinator.voiceEvents()
        let kindsTask = Task { try await collectRecognitionKinds(stream) }

        try await coordinator.startTurn()
        await coordinator.cancelTurn()

        let failedState = await coordinator.state
        XCTAssertEqual(failedState, .failed)
        let kinds = try await withBoundedTimeout(.seconds(1)) { try await kindsTask.value }
        // Exactly one terminal outcome, and it reports the unresolved-cleanup
        // failure. `VoiceFailure` carries no message, so the failure is
        // asserted by its category.
        XCTAssertEqual(kinds.filter { $0.isTerminal }.count, 1)
        guard case .outcome(.failed(let failure))? = kinds.last else {
            return XCTFail("expected a failed terminal outcome, got \(String(describing: kinds.last))")
        }
        XCTAssertEqual(failure.category, .audioSessionUnavailable)

        await input.setCleanupBlocked(false)
        await coordinator.close()
        let recoveredState = await coordinator.state
        XCTAssertEqual(recoveredState, .idle)
    }

    func testFinishFailureCancelsCaptureAndAllowsASecondOperation() async throws {
        let input = ControlledSpeechInput()
        await input.setFailure(HarnessFailure(stage: .finalization, message: "finalize failed"))
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())

        try await coordinator.startTurn()
        do {
            _ = try await coordinator.finishTurn()
            XCTFail("finish should report the injected failure")
        } catch let error as HarnessFailure {
            XCTAssertEqual(error.stage, .finalization)
        }

        await waitForState(.idle, coordinator: coordinator)
        let stateAfterFailure = await coordinator.state
        let balanced = await input.ledger.isBalanced()
        XCTAssertEqual(stateAfterFailure, .idle)
        XCTAssertTrue(balanced)

        await input.setFailure(nil)
        try await coordinator.startTurn()
        await coordinator.cancelTurn()
        let recoveredState = await coordinator.state
        XCTAssertEqual(recoveredState, .idle)
    }

    func testInterruptionErrorMapsToInterruptedTerminalWithoutASecondFailureEvent() async throws {
        let input = ControlledSpeechInput()
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())
        let stream = await coordinator.voiceEvents()
        let kindsTask = Task { try await collectRecognitionKinds(stream) }

        try await coordinator.startTurn()
        await input.failStream(VoiceError.interrupted("route changed"))

        let kinds = try await withBoundedTimeout(.seconds(1)) { try await kindsTask.value }
        // Exactly one terminal outcome, and it is `.interrupted`, never a
        // failed outcome.
        XCTAssertEqual(kinds.filter { $0.isTerminal }.count, 1)
        guard case .outcome(.interrupted)? = kinds.last else {
            return XCTFail("expected an interrupted terminal outcome, got \(String(describing: kinds.last))")
        }
        XCTAssertFalse(kinds.contains { if case .outcome(.failed) = $0 { true } else { false } })
        await waitForState(.idle, coordinator: coordinator)
        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
    }

    func testConcurrentListeningAndSpeechAreRejectedBeforeProviderReentry() async throws {
        let input = ControlledSpeechInput()
        let output = ControlledSpeechOutput()
        let coordinator = VoiceCoordinator(input: input, output: output)

        try await coordinator.startTurn()
        do {
            try await coordinator.speakNow("blocked")
            XCTFail("speech must not begin while listening")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .invalidState("A voice operation is already active."))
        }
        let speechStarts = await output.starts
        XCTAssertEqual(speechStarts, 0)

        await coordinator.cancelTurn()
        let speech = Task { try await coordinator.speakNow("first") }
        await output.waitUntilStarted()
        do {
            try await coordinator.speakNow("second")
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

        try await coordinator.startTurn(configuration: .init(policy: .allowModelInstallation))
        let forwardedConfiguration = await input.lastConfiguration
        XCTAssertEqual(forwardedConfiguration?.policy, .allowModelInstallation)
        await coordinator.cancelTurn()

        await input.setCapabilities(SpeechCapabilities(locale: .current, isSupported: true, supportsOnDevice: false))
        do {
            try await coordinator.startTurn(configuration: .init(policy: .installedModelsOnly))
            XCTFail("installed-only policy must reject an unavailable model")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .onDeviceRecognitionUnavailable(.current))
        }
        await waitForState(.idle, coordinator: coordinator)
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
                    if await coordinator.state == .idle { _ = try? await coordinator.startTurn() }
                case 1:
                    if await coordinator.state == .listening { _ = try? await coordinator.finishTurn() }
                case 2:
                    await coordinator.cancelTurn()
                case 3:
                    if await coordinator.state == .idle {
                        let task = Task { try? await coordinator.speakNow("seed-\(seed)") }
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
        // Subscribe before the turn, but deliberately do not iterate yet. This
        // models a host whose UI task is busy while recognition continues; the
        // canonical stream coalesces preview/state advisories and keeps a
        // bounded durable buffer.
        let stream = await coordinator.voiceEvents()

        try await coordinator.startTurn()
        for _ in 0..<256 {
            await input.send(TranscriptUpdate(text: "partial", isFinal: false))
        }
        await input.send(TranscriptUpdate(text: "the final answer", isFinal: true))
        let finalText = try await coordinator.finishTurn()
        XCTAssertEqual(finalText, "the final answer")

        let kinds = try await collectRecognitionKinds(stream)
        XCTAssertLessThanOrEqual(kinds.count, RecognitionEventDeliveryLimits.maximumDurableEventCountPerSubscriber)
        XCTAssertTrue(kinds.contains { kind in
            if case .transcript(.finalTranscript(let transcript)) = kind {
                return transcript.text == "the final answer"
            }
            return false
        })
        XCTAssertTrue(kinds.contains(.outcome(.completed)))
    }

    func testRepeatedTurnsStayBoundedAndExposeTheMostRecentFinalSnapshot() async throws {
        let input = ControlledSpeechInput()
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())

        for turn in 0..<40 {
            try await coordinator.startTurn()
            for _ in 0..<64 {
                await input.send(TranscriptUpdate(text: "turn-\(turn)-partial", isFinal: false))
            }
            let expected = "turn-\(turn)-final"
            await input.send(TranscriptUpdate(text: expected, isFinal: true))
            let finalText = try await coordinator.finishTurn()
            XCTAssertEqual(finalText, expected)
        }

        // The single-turn slow-consumer test proves that the bounded stream
        // retains the final snapshot. This repeated-turn test focuses on
        // resource stability and final return values without attempting to
        // drain a canonical stream that intentionally remains open.
        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle)
    }

}

extension ControlledSpeechInput {
    func setCapabilities(_ value: SpeechCapabilities) {
        capabilitiesValue = value
    }
}

/// Session state events are advisory: a slow subscriber observes the newest
/// value, so only the relative order of the states seen can be asserted.
private func assertSessionStatesAreOrdered(
    _ kinds: [RecognitionEventKind],
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let order: [RecognitionSessionState] = [.preparing, .listening, .finalizing]
    let seen = kinds.compactMap { kind -> RecognitionSessionState? in
        if case .stateChanged(let state) = kind { return state }
        return nil
    }
    let ranks = seen.compactMap { order.firstIndex(of: $0) }
    XCTAssertEqual(ranks.count, seen.count, "unknown session state", file: file, line: line)
    XCTAssertEqual(ranks, ranks.sorted(), "session states out of order: \(seen)", file: file, line: line)
    XCTAssertEqual(Set(ranks).count, ranks.count, "duplicate session state: \(seen)", file: file, line: line)
}
