import XCTest
@testable import AppLocalVoice

/// Recovery tests for the host-facing lifecycle contract.
///
/// These tests intentionally use the deterministic provider fakes rather than
/// Apple's frameworks. Their job is to prove that every provider failure has a
/// bounded recovery path, one terminal outcome, and exactly-once resource
/// cleanup. Apple-framework behavior belongs to the physical-device matrix.
@MainActor
final class RecoveryLifecycleAuditTests: XCTestCase {
    func testEveryInjectedInputFailureRecoversOnTheNextAttempt() async throws {
        let stages: [HarnessStage] = [
            .microphonePermission,
            .speechAuthorization,
            .capability,
            .model,
            .sessionActivation,
            .analyzer,
            .converter,
            .engineStart
        ]

        for stage in stages {
            let ledger = ResourceLedger()
            let input = ControlledSpeechInput(ledger: ledger)
            let output = ControlledSpeechOutput(ledger: ledger)
            await input.setFailure(HarnessFailure(stage: stage, message: stage.description))
            let voice = AppLocalVoice(input: input, output: output)

            do {
                try await voice.startListening(configuration: .init(policy: .allowModelInstallation))
                XCTFail("expected injected \(stage) failure")
            } catch {
                // The exact public error can vary by provider boundary; the
                // invariant here is recovery and resource release.
            }

            await input.setFailure(nil)
            let failedState = await voice.state
            let failedBalanced = await ledger.isBalanced()
            XCTAssertEqual(failedState, .idle, "\(stage) left the facade active")
            XCTAssertTrue(failedBalanced, "\(stage) leaked a resource")

            try await voice.startListening()
            await voice.cancelListening()
            let recoveredState = await voice.state
            let recoveredBalanced = await ledger.isBalanced()
            XCTAssertEqual(recoveredState, .idle, "\(stage) could not recover")
            XCTAssertTrue(recoveredBalanced, "\(stage) leaked after recovery")
            await voice.close()
        }
    }

    func testPermissionAndCapabilityFailuresDoNotEnterProviderCapture() async throws {
        let stages: [HarnessStage] = [.microphonePermission, .speechAuthorization, .capability]

        for stage in stages {
            let input = ControlledSpeechInput()
            let output = ControlledSpeechOutput()
            await input.setFailure(HarnessFailure(stage: stage, message: stage.description))
            let coordinator = VoiceCoordinator(input: input, output: output)
            let expectedFailure: VoiceError
            switch stage {
            case .microphonePermission:
                expectedFailure = .microphonePermissionDenied
            case .speechAuthorization:
                expectedFailure = .speechPermissionDenied
            case .capability:
                expectedFailure = .unsupportedLocale(.current)
            default:
                XCTFail("unexpected permission/capability stage: \(stage)")
                continue
            }

            do {
                try await coordinator.startListening()
                XCTFail("expected injected \(stage) failure")
            } catch {
                XCTAssertEqual(error as? VoiceError, expectedFailure)
            }

            let starts = await input.starts
            XCTAssertEqual(starts, 0, "permission/capability failure entered capture")
            let state = await coordinator.state
            let balanced = await input.ledger.isBalanced()
            XCTAssertEqual(state, .idle)
            XCTAssertTrue(balanced)
        }
    }

    func testFinalizationFailureRecoversAndTheSecondTurnCleansUpExactlyOnce() async throws {
        let ledger = ResourceLedger()
        let input = ControlledSpeechInput(ledger: ledger)
        let voice = AppLocalVoice(input: input, output: ControlledSpeechOutput(ledger: ledger))
        let expectedFailure = HarnessFailure(stage: .finalization, message: "finalization failed")
        await input.setFailure(expectedFailure)

        try await voice.startListening()
        do {
            _ = try await voice.finishListening()
            XCTFail("expected finalization failure")
        } catch {
            XCTAssertEqual(error as? HarnessFailure, expectedFailure)
        }

        let failedState = await voice.state
        let failedBalanced = await ledger.isBalanced()
        XCTAssertEqual(failedState, .idle)
        XCTAssertTrue(failedBalanced)
        let firstCounts = await ledger.count(.microphone)
        XCTAssertEqual(firstCounts.acquired, 1)
        XCTAssertEqual(firstCounts.released, 1)

        await input.setFailure(nil)
        try await voice.startListening()
        await voice.cancelListening()
        await voice.close()

        let finalCounts = await ledger.count(.microphone)
        XCTAssertEqual(finalCounts.acquired, 2)
        XCTAssertEqual(finalCounts.released, 2)
        let recoveredBalanced = await ledger.isBalanced()
        XCTAssertTrue(recoveredBalanced)
    }

    func testInterruptionAndRouteFailuresProduceOneTerminalOutcomeAndRecover() async throws {
        for stage in [HarnessStage.interruption, .routeChange] {
            let ledger = ResourceLedger()
            let input = ControlledSpeechInput(ledger: ledger)
            let output = ControlledSpeechOutput(ledger: ledger)
            let coordinator = VoiceCoordinator(input: input, output: output)
            let stream = await coordinator.events()
            let eventsTask = Task { await collectUntilListeningFinished(stream) }

            try await coordinator.startListening()
            await input.failStream(VoiceError.interrupted(stage.description))

            let events = await eventsTask.value
            let terminalEvents = events.filter {
                if case .listeningFinished = $0 { return true }
                return false
            }
            let cancelCount = await input.cancels
            let failedBalanced = await ledger.isBalanced()
            let failedState = await coordinator.state
            XCTAssertEqual(terminalEvents.count, 1, "duplicate terminal event for \(stage)")
            XCTAssertEqual(cancelCount, 1, "cleanup was not exactly once for \(stage)")
            XCTAssertTrue(failedBalanced, "route/interruption leaked for \(stage)")
            XCTAssertEqual(failedState, .idle)

            // A terminal interruption must invalidate only that generation;
            // the next turn must still be usable.
            try await coordinator.startListening()
            await coordinator.cancelListening()
            let recoveryBalanced = await ledger.isBalanced()
            XCTAssertTrue(recoveryBalanced, "recovery leaked for \(stage)")
        }
    }

    func testSpeechFailureAndCancellationReleaseExactlyOnceAndPermitRecovery() async throws {
        let ledger = ResourceLedger()
        let input = ControlledSpeechInput(ledger: ledger)
        let output = ControlledSpeechOutput(ledger: ledger)
        let coordinator = VoiceCoordinator(input: input, output: output)
        let expectedFailure = HarnessFailure(stage: .speech, message: "synthesis failed")
        await output.setFailure(expectedFailure)

        do {
            try await coordinator.speak("first")
            XCTFail("expected synthesis failure")
        } catch {
            XCTAssertEqual(error as? HarnessFailure, expectedFailure)
        }

        let failedCounts = await ledger.count(.speech)
        XCTAssertEqual(failedCounts.acquired, 0)
        XCTAssertEqual(failedCounts.released, 0)
        let failedBalanced = await ledger.isBalanced()
        XCTAssertTrue(failedBalanced)

        await output.setFailure(nil)
        let speech = Task { try await coordinator.speak("second") }
        await output.waitUntilStarted()
        await coordinator.stopSpeaking()
        _ = try? await speech.value
        let speechCounts = await ledger.count(.speech)
        let speechBalanced = await ledger.isBalanced()
        XCTAssertEqual(speechCounts.acquired, 1)
        XCTAssertEqual(speechCounts.released, 1)
        XCTAssertTrue(speechBalanced)
    }

    func testCloseIsIdempotentForListeningAndSpeechAndFacadeCanDeallocate() async throws {
        let ledger = ResourceLedger()
        let input = ControlledSpeechInput(ledger: ledger)
        let output = ControlledSpeechOutput(ledger: ledger)
        weak var weakVoice: AppLocalVoice?

        do {
            var voice: AppLocalVoice? = AppLocalVoice(input: input, output: output)
            weakVoice = voice
            try await voice?.startListening()
            await voice?.close()
            await voice?.close()
            voice = nil
        }

        // Yield once so actor-owned tasks and the facade's final release are
        // observable without depending on wall-clock sleeps.
        await Task.yield()
        XCTAssertNil(weakVoice)
        let cancelCount = await input.cancels
        let balanced = await ledger.isBalanced()
        XCTAssertEqual(cancelCount, 1)
        XCTAssertTrue(balanced)

        let speechVoice = AppLocalVoice(input: input, output: output)
        let speech = Task { try? await speechVoice.speak("pending") }
        await output.waitUntilStarted()
        let stopsBeforeSpeechClose = await output.stops
        await speechVoice.close()
        await speechVoice.close()
        _ = await speech.value
        let stopCount = await output.stops
        let speechBalanced = await ledger.isBalanced()
        XCTAssertEqual(stopCount, stopsBeforeSpeechClose + 1, "close must stop an active output operation once")
        XCTAssertTrue(speechBalanced)
    }
}

private func collectUntilListeningFinished(_ stream: AsyncStream<VoiceEvent>) async -> [VoiceEvent] {
    var events: [VoiceEvent] = []
    for await event in stream {
        events.append(event)
        if case .listeningFinished = event { break }
    }
    return events
}
