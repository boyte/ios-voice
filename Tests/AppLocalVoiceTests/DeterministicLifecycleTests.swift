import XCTest
@testable import AppLocalVoice

final class DeterministicLifecycleTests: XCTestCase {
    func testEverySuccessfulCaptureBalancesResources() async throws {
        let ledger = ResourceLedger()
        let input = ControlledSpeechInput(ledger: ledger)
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())

        try await coordinator.startTurn()
        await input.send(TranscriptUpdate(text: "hello", isFinal: true))
        _ = try await coordinator.finishTurn()

        let balanced = await ledger.isBalanced()
        let counts = await ledger.count(.microphone)
        XCTAssertTrue(balanced)
        XCTAssertEqual(counts.acquired, 1)
        XCTAssertEqual(counts.released, 1)
    }

    func testModelPolicyReachesTheInputBoundaryWhenPreflightAllowsStart() async throws {
        let input = ControlledSpeechInput()
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())
        try await coordinator.startTurn(configuration: .init(policy: .allowModelInstallation))
        let configuration = await input.lastConfiguration
        await coordinator.cancelTurn()

        XCTAssertEqual(configuration?.policy, .allowModelInstallation)
    }

    func testStartupFailuresNeverLeakCaptureResources() async throws {
        let stages: [HarnessStage] = [.model, .sessionActivation, .analyzer, .converter, .engineStart]
        for stage in stages {
            let ledger = ResourceLedger()
            let input = ControlledSpeechInput(ledger: ledger)
            let expectedFailure = HarnessFailure(stage: stage, message: stage.description)
            await input.setFailure(expectedFailure)
            let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())

            do {
                try await coordinator.startTurn(configuration: .init(policy: .allowModelInstallation))
                XCTFail("expected \(stage) failure")
            } catch let error as VoiceError {
                // A provider error that is not itself a `VoiceError` surfaces
                // across the session boundary as the typed `.underlying`
                // category. The stage identity lives in the harness fake, not
                // in the content-free canonical outcome.
                XCTAssertEqual(error.category, .underlying, "\(stage)")
            }

            let balanced = await ledger.isBalanced()
            let state = await coordinator.state
            XCTAssertTrue(balanced, "resource leak at \(stage)")
            XCTAssertEqual(state, .idle)
        }
    }

    func testInterruptionAndRouteErrorsAreObservableWithoutStaleTranscript() async throws {
        for stage in [HarnessStage.interruption, .routeChange] {
            let ledger = ResourceLedger()
            let input = ControlledSpeechInput(ledger: ledger)
            let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())
            let stream = await coordinator.voiceEvents()
            let kindsTask = Task { try await collectRecognitionKinds(stream) }
            try await coordinator.startTurn()
            await input.failStream(HarnessFailure(stage: stage, message: stage.description))

            let kinds = try await withBoundedTimeout(.seconds(1)) { try await kindsTask.value }
            // The failure is observable as exactly one failed terminal
            // outcome, and no final transcript is published on the failure
            // path.
            XCTAssertEqual(kinds.filter { $0.isTerminal }.count, 1)
            guard case .outcome(.failed)? = kinds.last else {
                return XCTFail("expected a failed terminal outcome for \(stage), got \(String(describing: kinds.last))")
            }
            XCTAssertFalse(kinds.contains { $0.isFinalTranscript })
            let balanced = await ledger.isBalanced()
            XCTAssertTrue(balanced)
        }
    }

    func testFinalizationFailureRecoversToIdleAndBalancesResources() async throws {
        let ledger = ResourceLedger()
        let input = ControlledSpeechInput(ledger: ledger)
        let expectedFailure = HarnessFailure(stage: .finalization, message: "finalize failed")
        await input.setFailure(expectedFailure)
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())
        try await coordinator.startTurn()

        do {
            _ = try await coordinator.finishTurn()
            XCTFail("expected finalization failure")
        } catch let error as HarnessFailure {
            XCTAssertEqual(error, expectedFailure)
        }

        await waitForState(.idle, coordinator: coordinator)
        let state = await coordinator.state
        let balanced = await ledger.isBalanced()
        XCTAssertEqual(state, .idle)
        XCTAssertTrue(balanced)
    }

    func testStaleCallbacksCannotEnterTheNextGeneration() async throws {
        let input = ControlledSpeechInput()
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())
        try await coordinator.startTurn()
        await coordinator.cancelTurn()
        try await coordinator.startTurn()
        await input.sendStale(TranscriptUpdate(text: "old", isFinal: true))
        await input.send(TranscriptUpdate(text: "new", isFinal: true))
        let result = try await coordinator.finishTurn()

        XCTAssertEqual(result, "new")
    }

    func testTTSStopAndDuplicateDelegateCompletionAreIdempotent() async throws {
        let output = ControlledSpeechOutput()
        let coordinator = VoiceCoordinator(input: ControlledSpeechInput(), output: output)
        let task = Task { try await coordinator.speakNow("hello") }
        await output.waitUntilStarted()
        await output.complete(.success(()))
        await output.complete(.success(()))
        try await task.value
        let starts = await output.starts
        let balanced = await output.ledger.isBalanced()
        XCTAssertEqual(starts, 1)
        XCTAssertTrue(balanced)
    }

    func testTTSFailureReleasesSpeechResourceAndReturnsFailure() async throws {
        let ledger = ResourceLedger()
        let output = ControlledSpeechOutput(ledger: ledger)
        await output.setFailure(HarnessFailure(stage: .speech, message: "synthesis failed"))
        let coordinator = VoiceCoordinator(input: ControlledSpeechInput(), output: output)

        do {
            try await coordinator.speakNow("hello")
            XCTFail("expected synthesis failure")
        } catch let error as HarnessFailure {
            XCTAssertEqual(error.stage, .speech)
        }

        // The playback result resolves before the post-failure cleanup
        // transitions back to idle; wait for that transition explicitly.
        await waitForState(.idle, coordinator: coordinator)
        let balanced = await ledger.isBalanced()
        let state = await coordinator.state
        XCTAssertTrue(balanced)
        XCTAssertEqual(state, .idle)
    }

    func testCancellationStressLeavesCoordinatorIdleAcrossDeterministicSequences() async throws {
        for seed in 1...32 {
            let input = ControlledSpeechInput()
            let output = ControlledSpeechOutput()
            let coordinator = VoiceCoordinator(input: input, output: output)
            var random = DeterministicRandom(seed: UInt64(seed))

            for _ in 0..<24 {
                switch random.nextInt(5) {
                case 0:
                    if await coordinator.state == .idle { _ = try? await coordinator.startTurn() }
                case 1:
                    if await coordinator.state == .listening { _ = try? await coordinator.finishTurn() }
                case 2:
                    await coordinator.cancelTurn()
                case 3:
                    if await coordinator.state == .idle {
                        let speechTask = Task { try? await coordinator.speakNow("x") }
                        await output.waitUntilStarted()
                        await coordinator.stopSpeaking()
                        _ = await speechTask.value
                    }
                default:
                    await coordinator.close()
                }
            }
            await coordinator.close()
            let state = await coordinator.state
            let inputBalanced = await input.ledger.isBalanced()
            let outputBalanced = await output.ledger.isBalanced()
            XCTAssertEqual(state, .idle, "seed \(seed)")
            XCTAssertTrue(inputBalanced, "seed \(seed)")
            XCTAssertTrue(outputBalanced, "seed \(seed)")
        }
    }
}

extension ControlledSpeechOutput {
    func setFailure(_ value: HarnessFailure?) { failure = value }
}

extension HarnessStage: CustomStringConvertible {
    var description: String {
        switch self {
        case .microphonePermission: "microphonePermission"
        case .speechAuthorization: "speechAuthorization"
        case .capability: "capability"
        case .model: "model"
        case .sessionActivation: "sessionActivation"
        case .analyzer: "analyzer"
        case .converter: "converter"
        case .engineStart: "engineStart"
        case .hostAudioCoexistence: "hostAudioCoexistence"
        case .interruption: "interruption"
        case .routeChange: "routeChange"
        case .finalization: "finalization"
        case .speech: "speech"
        }
    }
}
