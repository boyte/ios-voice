import XCTest
@testable import AppLocalVoice

/// Deterministic tests for the host-facing contract. These tests deliberately use
/// fakes so lifecycle behavior can be exercised without a microphone, route, or
/// network connection.
final class DeterministicFailureHarnessTests: XCTestCase {
    func testDeniedMicrophonePermissionDoesNotStartInput() async throws {
        let input = HarnessSpeechInput()
        await input.setMicrophonePermission(false)
        let output = HarnessSpeechOutput()
        let coordinator = VoiceCoordinator(input: input, output: output)

        do {
            try await coordinator.startListening()
            XCTFail("Expected microphone permission failure")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .microphonePermissionDenied)
        }

        let state = await coordinator.state
        let startCount = await input.startCount
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(startCount, 0)
    }

    func testDeniedSpeechAuthorizationDoesNotStartInput() async throws {
        let input = HarnessSpeechInput()
        await input.setAuthorization(.denied)
        let coordinator = VoiceCoordinator(input: input, output: HarnessSpeechOutput())

        do {
            try await coordinator.startListening()
            XCTFail("Expected speech permission failure")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .speechPermissionDenied)
        }

        let startCount = await input.startCount
        XCTAssertEqual(startCount, 0)
    }

    func testRestrictedSpeechAuthorizationUsesPermissionDeniedContract() async throws {
        let input = HarnessSpeechInput()
        await input.setAuthorization(.restricted)
        let coordinator = VoiceCoordinator(input: input, output: HarnessSpeechOutput())

        do {
            try await coordinator.startListening()
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
        let coordinator = VoiceCoordinator(input: input, output: HarnessSpeechOutput())
        let events = await coordinator.events()

        do {
            try await coordinator.startListening(configuration: .init(
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
        let terminal = await events.first(where: {
            if case .listeningFinished = $0 { return true }
            return false
        })
        XCTAssertEqual(terminal, .listeningFinished(.failed(.onDeviceRecognitionUnavailable(locale))))
    }

    func testModelInstallationCancellationUnwindsWithoutFailureEvent() async throws {
        let input = HarnessSpeechInput()
        await input.setStartError(.cancelled)
        let coordinator = VoiceCoordinator(input: input, output: HarnessSpeechOutput())
        let events = await coordinator.events()

        do {
            try await coordinator.startListening(configuration: .init(policy: .allowModelInstallation))
            XCTFail("Expected model installation cancellation")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .cancelled)
        }

        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
        let observed = await collectVoiceEventsThroughListeningFinished(events)
        XCTAssertFalse(observed.contains { event in
            if case .failure = event { return true }
            return false
        })
        let terminal = observed.first(where: {
            if case .listeningFinished = $0 { return true }
            return false
        })
        XCTAssertEqual(terminal, .listeningFinished(.cancelled))
    }

    func testCancellationDuringReservedModelStartupHasOneTerminalAndBalancedResources() async throws {
        let ledger = ResourceLedger()
        let input = ControlledSpeechInput(ledger: ledger)
        await input.setStartBlocked(true)
        let coordinator = VoiceCoordinator(input: input, output: ControlledSpeechOutput(ledger: ledger))
        let events = await coordinator.events()
        let start = Task { try await coordinator.startListening(configuration: .init(policy: .allowModelInstallation)) }

        await input.waitForStartEntry()
        start.cancel()
        await input.setStartBlocked(false)

        do {
            try await start.value
            XCTFail("reserved startup unexpectedly completed after cancellation")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .cancelled)
        }
        let observed = try await withBoundedTimeout { await collectVoiceEventsThroughListeningFinished(events) }
        XCTAssertEqual(observed.filter { if case .listeningFinished = $0 { return true }; return false }.count, 1)
        XCTAssertEqual(observed.filter { if case .failure = $0 { return true }; return false }.count, 0)
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

        let starting = Task {
            try await coordinator.startListening(configuration: .init(policy: .allowModelInstallation))
        }
        await input.waitForStartEntry()
        starting.cancel()

        do {
            try await starting.value
            XCTFail("cancelled startup must not wait forever for a non-cooperative provider")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .cancelled)
        } catch is CancellationError {
            // Task cancellation may win before the coordinator normalizes it.
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
        let events = await coordinator.events()

        do {
            try await coordinator.startListening()
            XCTFail("host audio coexistence failure unexpectedly succeeded")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .audioSessionUnavailable("Host audio is active."))
        }
        let observed = try await withBoundedTimeout { await collectVoiceEventsThroughListeningFinished(events) }
        XCTAssertEqual(observed.filter { if case .listeningFinished = $0 { return true }; return false }.count, 1)
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
        let coordinator = VoiceCoordinator(input: input, output: HarnessSpeechOutput())

        do {
            try await coordinator.startListening(configuration: .init(locale: Locale(identifier: "zz-ZZ")))
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
        let input = HarnessSpeechInput()
        let output = HarnessSpeechOutput()
        let coordinator = VoiceCoordinator(input: input, output: output)
        let events = await coordinator.events()

        try await coordinator.startListening()
        await input.send(TranscriptUpdate(text: "hel", isFinal: false))
        await input.send(TranscriptUpdate(text: "hello", isFinal: true))
        let transcript = try await coordinator.endListening()

        XCTAssertEqual(transcript, "hello")
        let state = await coordinator.state
        let matchingEvent = await events.first(where: { event in
            if case .transcript(let update) = event { return update.text == "hello" && update.isFinal }
            return false
        })
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(matchingEvent, .transcript(TranscriptUpdate(text: "hello", isFinal: true)))
    }

    func testCancellationIsIdempotentAndDoesNotLeaveInputActive() async throws {
        let input = HarnessSpeechInput()
        let coordinator = VoiceCoordinator(input: input, output: HarnessSpeechOutput())

        try await coordinator.startListening()
        await coordinator.cancelListening()
        await coordinator.cancelListening()

        let state = await coordinator.state
        let cancelCount = await input.cancelCount
        let isActive = await input.isActive
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(cancelCount, 1)
        XCTAssertEqual(isActive, false)
    }

    func testStaleResultAfterCancellationCannotChangeCoordinatorState() async throws {
        let input = HarnessSpeechInput()
        let coordinator = VoiceCoordinator(input: input, output: HarnessSpeechOutput())

        try await coordinator.startListening()
        await coordinator.cancelListening()
        await input.send(TranscriptUpdate(text: "stale", isFinal: true))

        try await coordinator.startListening()
        await input.send(TranscriptUpdate(text: "current", isFinal: true))
        let transcript = try await coordinator.endListening()

        XCTAssertEqual(transcript, "current")
        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
    }

    func testTTSCompletionIsObservableAndStopCancelsPendingSpeech() async throws {
        let input = HarnessSpeechInput()
        let output = HarnessSpeechOutput()
        let coordinator = VoiceCoordinator(input: input, output: output)
        let events = await coordinator.events()

        let speechTask = Task { try await coordinator.speak("hello") }
        await output.waitUntilStarted()
        await coordinator.stopSpeaking()

        do {
            try await speechTask.value
            XCTFail("Expected stop to cancel speech")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .cancelled)
        }
        let state = await coordinator.state
        let cancelledEvent = await events.first(where: { $0 == .speechCancelled })
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(cancelledEvent, .speechCancelled)
    }

    func testCloseStopsInputAndOutputAndReturnsToIdle() async throws {
        let input = HarnessSpeechInput()
        let output = HarnessSpeechOutput()
        let coordinator = VoiceCoordinator(input: input, output: output)

        try await coordinator.startListening()
        await coordinator.close()
        await coordinator.close()

        let state = await coordinator.state
        let cancelCount = await input.cancelCount
        let stopCount = await output.stopCount
        XCTAssertEqual(state, .idle)
        XCTAssertEqual(cancelCount, 1)
        XCTAssertEqual(stopCount, 0, "closing an idle output must not invoke provider cleanup")
    }
}

private actor HarnessSpeechInput: SpeechInput {
    private var continuation: AsyncThrowingStream<TranscriptUpdate, Error>.Continuation?
    private var latestText = ""
    private var capabilitiesValue = SpeechCapabilities(
        locale: .current,
        isSupported: true,
        supportsOnDevice: true
    )
    private var microphonePermission = true
    private var authorization: SpeechAuthorization = .authorized
    private var startError: VoiceError?
    private(set) var startCount = 0
    private(set) var cancelCount = 0
    private(set) var isActive = false

    func setMicrophonePermission(_ value: Bool) { microphonePermission = value }
    func setAuthorization(_ value: SpeechAuthorization) { authorization = value }
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

    func requestMicrophonePermission() async -> Bool { microphonePermission }
    func requestAuthorization() async -> SpeechAuthorization { authorization }

    func start(configuration: RecognitionConfiguration) async throws -> AsyncThrowingStream<TranscriptUpdate, Error> {
        startCount += 1
        if let startError { throw startError }
        isActive = true
        return AsyncThrowingStream { continuation in
            self.continuation = continuation
        }
    }

    func send(_ update: TranscriptUpdate) {
        latestText = update.text
        continuation?.yield(update)
    }

    func stop() async throws -> String {
        isActive = false
        continuation?.finish()
        continuation = nil
        return latestText
    }

    func cancel() async {
        guard isActive else { return }
        cancelCount += 1
        isActive = false
        continuation?.finish()
        continuation = nil
    }
}

private actor HarnessSpeechOutput: SpeechOutput {
    private(set) var spokenTexts: [String] = []
    private(set) var stopCount = 0
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var completion: CheckedContinuation<Void, Error>?

    func availableVoices(for locale: Locale) async -> [SpeechVoice] { [] }

    func speak(_ text: String, configuration: SpeechConfiguration) async throws {
        spokenTexts.append(text)
        started = true
        for waiter in startWaiters { waiter.resume() }
        startWaiters.removeAll()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion = continuation
            }
        } onCancel: {
            Task { await self.cancelPendingSpeech() }
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func pause() async {}
    func resume() async {}

    func stop() async {
        stopCount += 1
        cancelPendingSpeech()
    }

    private func cancelPendingSpeech() {
        completion?.resume(throwing: VoiceError.cancelled)
        completion = nil
    }
}
