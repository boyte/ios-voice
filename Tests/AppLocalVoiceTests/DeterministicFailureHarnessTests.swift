import XCTest
@testable import AppLocalVoice

/// Deterministic tests for the host-facing contract. These tests deliberately use
/// fakes so lifecycle behavior can be exercised without a microphone, route, or
/// network connection.
final class DeterministicFailureHarnessTests: XCTestCase {
    func testDeniedMicrophonePermissionDoesNotStartInput() async throws {
        let input = ControlledSpeechInput()
        await input.setFailure(HarnessFailure(stage: .microphonePermission, message: "microphone permission denied"))
        let output = ControlledSpeechOutput()
        let coordinator = VoiceCoordinator(input: input, output: output)

        do {
            try await coordinator.startTurn()
            XCTFail("Expected microphone permission failure")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .microphonePermissionDenied)
        }

        let state = await coordinator.state
        let startCount = await input.starts
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(startCount, 0)
    }

    func testDeniedVoicePermissionStatusDoesNotStartInput() async throws {
        let input = ControlledSpeechInput()
        await input.setFailure(HarnessFailure(stage: .speechAuthorization, message: "speech authorization denied"))
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())

        do {
            try await coordinator.startTurn()
            XCTFail("Expected speech permission failure")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .speechPermissionDenied)
        }

        let startCount = await input.starts
        XCTAssertEqual(startCount, 0)
    }

    func testRestrictedVoicePermissionStatusUsesPermissionDeniedContract() async throws {
        let input = HarnessSpeechInput()
        await input.setAuthorization(.restricted)
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())

        do {
            try await coordinator.startTurn()
            XCTFail("Expected restricted speech authorization failure")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .speechPermissionDenied)
        }

        let startCount = await input.startCount
        let state = await coordinator.state
        XCTAssertEqual(startCount, 0)
        XCTAssertEqual(state, .idle)
    }

    func testModelInstallationFailureUnwindsListeningStartup() async throws {
        let input = HarnessSpeechInput()
        let locale = Locale(identifier: "en-US")
        await input.setStartError(.onDeviceRecognitionUnavailable(locale))
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())
        let stream = await coordinator.voiceEvents()
        let kindsTask = Task { try await collectRecognitionKinds(stream) }

        do {
            try await coordinator.startTurn(configuration: .init(
                locale: locale,
                policy: .allowModelInstallation
            ))
            XCTFail("Expected model installation failure")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .onDeviceRecognitionUnavailable(locale))
        }

        let state = await coordinator.state
        let startCount = await input.startCount
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(startCount, 1)
        let kinds = try await withBoundedTimeout { try await kindsTask.value }
        XCTAssertEqual(kinds.filter(\.isTerminal).count, 1)
        XCTAssertEqual(
            kinds.last,
            .outcome(.failed(VoiceError.onDeviceRecognitionUnavailable(locale).failure))
        )
    }

    func testModelInstallationCancellationUnwindsWithoutFailureEvent() async throws {
        let input = HarnessSpeechInput()
        await input.setStartError(.cancelled)
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())
        let stream = await coordinator.voiceEvents()
        let kindsTask = Task { try await collectRecognitionKinds(stream) }

        do {
            try await coordinator.startTurn(configuration: .init(policy: .allowModelInstallation))
            XCTFail("Expected model installation cancellation")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .cancelled)
        }

        // The cancelled startup is retained until its provider task returns,
        // so the idle transition is asynchronous relative to the thrown error.
        await waitForState(.idle, coordinator: coordinator)
        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        let kinds = try await withBoundedTimeout { try await kindsTask.value }
        XCTAssertFalse(kinds.contains { kind in
            if case .outcome(.failed) = kind { return true }
            return false
        })
        XCTAssertEqual(kinds.filter(\.isTerminal).count, 1)
        XCTAssertEqual(kinds.last, .outcome(.cancelled))
    }

    func testCancellationDuringReservedModelStartupHasOneTerminalAndBalancedResources() async throws {
        let ledger = ResourceLedger()
        let input = ControlledSpeechInput(ledger: ledger)
        await input.setStartBlocked(true)
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput(ledger: ledger))
        let stream = await coordinator.voiceEvents()
        let kindsTask = Task { try await collectRecognitionKinds(stream) }
        let acceptance = try await coordinator.startSession(
            configuration: RecognitionSessionConfiguration(recognition: .init(policy: .allowModelInstallation))
        )

        await input.waitForStartEntry()
        // Cancel the reserved session while the provider is still inside
        // startup, then release the provider so the retained startup returns.
        let cancellation = Task { await coordinator.cancelSession(id: acceptance.sessionID) }
        await input.setStartBlocked(false)
        await cancellation.value

        do {
            _ = try await coordinator.endSession(id: acceptance.sessionID)
            XCTFail("reserved startup unexpectedly completed after cancellation")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .cancelled)
        }
        let kinds = try await withBoundedTimeout { try await kindsTask.value }
        XCTAssertEqual(kinds.filter(\.isTerminal).count, 1)
        XCTAssertEqual(kinds.filter { if case .outcome(.failed) = $0 { return true }; return false }.count, 0)
        XCTAssertEqual(kinds.last, .outcome(.cancelled))
        await waitForState(.idle, coordinator: coordinator)
        let state = await coordinator.state
        let balanced = await ledger.isBalanced()
        XCTAssertEqual(state, .idle)
        XCTAssertTrue(balanced)
    }

    func testNonCooperativeProviderStartupStaysFailedUntilItsTaskActuallyReturns() async throws {
        let input = ControlledSpeechInput()
        await input.setStartBlocked(true)
        let coordinator = VoiceCoordinator(
            input: input,
            output: ControlledSpeechOutput(),
            cleanupTimeout: .milliseconds(20)
        )

        let acceptance = try await coordinator.startSession(
            configuration: RecognitionSessionConfiguration(recognition: .init(policy: .allowModelInstallation))
        )
        await input.waitForStartEntry()
        // The provider never returns, so the bounded cancel must give up on
        // startup completion rather than wait forever.
        await coordinator.cancelSession(id: acceptance.sessionID)

        do {
            _ = try await coordinator.endSession(id: acceptance.sessionID)
            XCTFail("cancelled startup must not wait forever for a non-cooperative provider")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .cancelled)
        }

        let failedState = await coordinator.state
        let closeBeforeProviderReturn = await coordinator.closeAndReport()
        XCTAssertEqual(failedState, .failed)
        XCTAssertFalse(closeBeforeProviderReturn)

        // Releasing the provider proves that the retained startup task, not a
        // timeout flag alone, is the ownership boundary for reuse.
        await input.setStartBlocked(false)
        try await withBoundedTimeout(.milliseconds(250)) {
            while await coordinator.state != .idle {
                await Task.yield()
            }
        }
        let closeAfterProviderReturn = await coordinator.closeAndReport()
        let recoveredState = await coordinator.state
        XCTAssertTrue(closeAfterProviderReturn)
        XCTAssertEqual(recoveredState, .idle)
    }

    func testHostAudioCoexistenceFailureIsTypedAndDoesNotAcquireResources() async throws {
        let ledger = ResourceLedger()
        let input = ControlledSpeechInput(ledger: ledger)
        await input.setFailure(HarnessFailure(stage: .hostAudioCoexistence, message: "host audio is active"))
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput(ledger: ledger))
        let stream = await coordinator.voiceEvents()
        let kindsTask = Task { try await collectRecognitionKinds(stream) }

        do {
            try await coordinator.startTurn()
            XCTFail("host audio coexistence failure unexpectedly succeeded")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .audioSessionUnavailable("Host audio is active."))
        }
        let kinds = try await withBoundedTimeout { try await kindsTask.value }
        XCTAssertEqual(kinds.filter(\.isTerminal).count, 1)
        XCTAssertEqual(
            kinds.last,
            .outcome(.failed(VoiceError.audioSessionUnavailable("Host audio is active.").failure))
        )
        let state = await coordinator.state
        let balanced = await ledger.isBalanced()
        XCTAssertEqual(state, .idle)
        XCTAssertTrue(balanced)
    }

    func testInstalledOnlyUnavailableModelIsReportedAtTheInputBoundary() async throws {
        let input = HarnessSpeechInput()
        await input.setCapabilities(SpeechCapabilities(
            locale: Locale(identifier: "zz-ZZ"),
            isSupported: true,
            supportsOnDevice: false
        ))
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())

        do {
            try await coordinator.startTurn(configuration: .init(locale: Locale(identifier: "zz-ZZ")))
            XCTFail("Expected the fake input to reject the start")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .onDeviceRecognitionUnavailable(Locale(identifier: "zz-ZZ")))
        }

        let startCount = await input.startCount
        let state = await coordinator.state
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(state, .idle)
    }

    func testPartialTranscriptIsDeliveredAndFinalTextIsReturned() async throws {
        let input = ControlledSpeechInput()
        let output = ControlledSpeechOutput()
        let coordinator = VoiceCoordinator(input: input, output: output)
        let stream = await coordinator.voiceEvents()
        let kindsTask = Task { try await collectRecognitionKinds(stream) }

        let sessionID = try await coordinator.startTurn()
        await input.send(TranscriptUpdate(text: "hel", isFinal: false))
        await input.send(TranscriptUpdate(text: "hello", isFinal: true))
        let transcript = try await coordinator.finishTurn()

        XCTAssertEqual(transcript, "hello")
        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        let kinds = try await withBoundedTimeout { try await kindsTask.value }
        XCTAssertTrue(kinds.contains(.transcript(.finalTranscript(FinalTranscript(sessionID: sessionID, text: "hello")))))
        let previewTexts = kinds.compactMap { kind -> String? in
            guard case .transcript(.preview(let preview)) = kind else { return nil }
            return preview.text
        }
        XCTAssertEqual(previewTexts.last, "hello", "the latest preview carries the final provider text")
        XCTAssertEqual(kinds.last, .outcome(.completed))
    }

    func testCancellationIsIdempotentAndDoesNotLeaveInputActive() async throws {
        let input = ControlledSpeechInput()
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())

        try await coordinator.startTurn()
        await coordinator.cancelTurn()
        await coordinator.cancelTurn()

        let state = await coordinator.state
        let cancelCount = await input.cancels
        let isActive = await input.isActive
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(cancelCount, 1)
        XCTAssertEqual(isActive, false)
    }

    func testStaleResultAfterCancellationCannotChangeCoordinatorState() async throws {
        let input = ControlledSpeechInput()
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput())

        try await coordinator.startTurn()
        await coordinator.cancelTurn()
        await input.send(TranscriptUpdate(text: "stale", isFinal: true))

        try await coordinator.startTurn()
        await input.send(TranscriptUpdate(text: "current", isFinal: true))
        let transcript = try await coordinator.finishTurn()

        XCTAssertEqual(transcript, "current")
        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
    }

    func testTTSCompletionIsObservableAndStopCancelsPendingSpeech() async throws {
        let input = ControlledSpeechInput()
        let output = ControlledSpeechOutput()
        let coordinator = VoiceCoordinator(input: input, output: output)

        let acceptance = try await coordinator.speakImmediately("hello")
        let speechTask = Task { try await coordinator.awaitPlayback(acceptance.playbackID) }
        await output.waitUntilStarted()
        await coordinator.stopSpeaking()

        do {
            try await speechTask.value
            XCTFail("Expected stop to cancel speech")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .cancelled)
        }
        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        // The playback result is the exactly-once terminal truth for the
        // accepted playback ID.
        let result = try await withBoundedTimeout {
            try await coordinator.waitForSpeechPlayback(acceptance.playbackID)
        }
        XCTAssertEqual(result.playbackID, acceptance.playbackID)
        XCTAssertEqual(result.outcome, .cancelled(.stopped))
        let spoken = await output.spoken
        XCTAssertEqual(spoken, ["hello"])
    }

    func testCloseStopsInputAndOutputAndReturnsToIdle() async throws {
        let input = ControlledSpeechInput()
        let output = ControlledSpeechOutput()
        let coordinator = VoiceCoordinator(input: input, output: output)

        try await coordinator.startTurn()
        await coordinator.close()
        await coordinator.close()

        let state = await coordinator.state
        let cancelCount = await input.cancels
        let stopCount = await output.stops
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(cancelCount, 1)
        XCTAssertEqual(stopCount, 0, "closing an idle output must not invoke provider cleanup")
    }
}

/// Minimal input fake retained only for the knobs `ControlledSpeechInput`
/// lacks: a `.restricted` authorization status, an arbitrary capability
/// snapshot (supported locale without an on-device model), and a specific
/// typed `VoiceError` thrown from `start`.
private actor HarnessSpeechInput: SpeechInput {
    private var continuation: AsyncThrowingStream<TranscriptUpdate, Error>.Continuation?
    private var capabilitiesValue = SpeechCapabilities(
        locale: .current,
        isSupported: true,
        supportsOnDevice: true
    )
    private var authorization: VoicePermissionStatus = .authorized
    private var startError: VoiceError?
    private(set) var startCount = 0
    private(set) var isActive = false

    func setAuthorization(_ value: VoicePermissionStatus) { authorization = value }
    func setCapabilities(_ value: SpeechCapabilities) { capabilitiesValue = value }
    func setStartError(_ value: VoiceError?) { startError = value }

    func capabilities(for locale: Locale) async -> SpeechCapabilities {
        SpeechCapabilities(
            locale: capabilitiesValue.locale,
            isSupported: capabilitiesValue.isSupported,
            supportsOnDevice: capabilitiesValue.supportsOnDevice,
            reason: capabilitiesValue.reason
        )
    }

    func requestMicrophonePermission() async -> Bool { true }
    func requestAuthorization() async -> VoicePermissionStatus { authorization }

    func start(configuration: RecognitionConfiguration, input: RecognitionInput, lifecyclePolicy: AudioLifecyclePolicy) async throws -> AsyncThrowingStream<TranscriptUpdate, Error> {
        startCount += 1
        if let startError { throw startError }
        isActive = true
        return AsyncThrowingStream { continuation in
            self.continuation = continuation
        }
    }

    func stop() async throws -> String {
        isActive = false
        continuation?.finish()
        continuation = nil
        return ""
    }

    func cancel() async {
        guard isActive else { return }
        isActive = false
        continuation?.finish()
        continuation = nil
    }
}
