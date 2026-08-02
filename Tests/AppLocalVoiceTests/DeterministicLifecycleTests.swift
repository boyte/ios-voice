import XCTest
@testable import AppLocalVoice

final class DeterministicLifecycleTests: XCTestCase {
    func testEverySuccessfulCaptureBalancesResources() async throws {
        let ledger = ResourceLedger()
        let input = ControlledSpeechInput(ledger: ledger)
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())

        try await coordinator.startListening()
        await input.send(TranscriptUpdate(text: "hello", isFinal: true))
        _ = try await coordinator.endListening()

        let balanced = await ledger.isBalanced()
        let counts = await ledger.count(.microphone)
        XCTAssertTrue(balanced)
        XCTAssertEqual(counts.acquired, 1)
        XCTAssertEqual(counts.released, 1)
    }

    func testModelPolicyReachesTheInputBoundaryWhenPreflightAllowsStart() async throws {
        let input = ControlledSpeechInput()
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())
        try await coordinator.startListening(configuration: .init(policy: .allowModelInstallation))
        let configuration = await input.lastConfiguration
        await coordinator.cancelListening()

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
                try await coordinator.startListening(configuration: .init(policy: .allowModelInstallation))
                XCTFail("expected \(stage) failure")
            } catch {
                XCTAssertEqual(error as? HarnessFailure, expectedFailure)
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
            let events = await coordinator.events()
            try await coordinator.startListening()
            await input.failStream(HarnessFailure(stage: stage, message: stage.description))

            let failure = await events.first(where: {
                if case .failure = $0 { return true }
                return false
            })
            XCTAssertNotNil(failure)
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
        try await coordinator.startListening()

        do {
            _ = try await coordinator.endListening()
            XCTFail("expected finalization failure")
        } catch {
            XCTAssertEqual(error as? HarnessFailure, expectedFailure)
        }

        let state = await coordinator.state
        let balanced = await ledger.isBalanced()
        XCTAssertEqual(state, .idle)
        XCTAssertTrue(balanced)
    }

    func testStaleCallbacksCannotEnterTheNextGeneration() async throws {
        let input = ControlledSpeechInput()
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())
        try await coordinator.startListening()
        await coordinator.cancelListening()
        try await coordinator.startListening()
        await input.sendStale(TranscriptUpdate(text: "old", isFinal: true))
        await input.send(TranscriptUpdate(text: "new", isFinal: true))
        let result = try await coordinator.endListening()

        XCTAssertEqual(result, "new")
    }

    func testTTSStopAndDuplicateDelegateCompletionAreIdempotent() async throws {
        let output = ControlledSpeechOutput()
        let coordinator = VoiceCoordinator(input: ControlledSpeechInput(), output: output)
        let task = Task { try await coordinator.speak("hello") }
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
            try await coordinator.speak("hello")
            XCTFail("expected synthesis failure")
        } catch let error as HarnessFailure {
            XCTAssertEqual(error.stage, .speech)
        }

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
                    if await coordinator.state == .idle { try? await coordinator.startListening() }
                case 1:
                    if await coordinator.state == .listening { _ = try? await coordinator.endListening() }
                case 2:
                    await coordinator.cancelListening()
                case 3:
                    if await coordinator.state == .idle {
                        let speechTask = Task { try? await coordinator.speak("x") }
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
