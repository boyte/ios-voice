import XCTest
@testable import AppLocalVoice

final class VoiceCoordinatorTests: XCTestCase {
    func testCapabilitySnapshotReportsMissingInstallableRecognitionModel() async {
        let input = TestSpeechInput()
        await input.setCapabilities(SpeechCapabilities(
            locale: Locale(identifier: "en-US"),
            isSupported: true,
            supportsOnDevice: false,
            reason: "The speech model is not installed yet."
        ))
        await input.setModelInstallationAvailable(true)
        let coordinator = VoiceCoordinator(input: input, output: TestSpeechOutput())

        let snapshot = await coordinator.capabilitySnapshot(
            for: Locale(identifier: "en-US")
        )

        XCTAssertEqual(
            snapshot.recognition.modelReadiness,
            .notInstalled(installationAvailable: true)
        )
        XCTAssertEqual(snapshot.features[.modelInstallation], .available)
    }

    func testVoiceTurnUsesInjectedInputAndOutput() async throws {
        let input = TestSpeechInput()
        let output = TestSpeechOutput()
        let coordinator = VoiceCoordinator(input: input, output: output)

        try await coordinator.startListening()
        await input.send(TranscriptUpdate(text: "hello", isFinal: false))
        let text = try await coordinator.endListening()

        XCTAssertEqual(text, "hello")
        let finalState = await coordinator.state
        XCTAssertEqual(finalState, .idle)

        try await coordinator.speak("world")
        let spokenTexts = await output.spokenTexts
        XCTAssertEqual(spokenTexts, ["world"])
    }

    func testAllowModelInstallationReachesInputProvider() async throws {
        let input = TestSpeechInput()
        await input.setCapabilities(SpeechCapabilities(
            locale: .current,
            isSupported: true,
            supportsOnDevice: false
        ))
        let coordinator = VoiceCoordinator(input: input, output: TestSpeechOutput())

        try await coordinator.startListening(configuration: .init(policy: .allowModelInstallation))

        let configuration = await input.lastConfiguration
        let startCount = await input.startCount
        XCTAssertEqual(configuration?.policy, .allowModelInstallation)
        XCTAssertEqual(startCount, 1)
        await coordinator.cancelListening()
    }

    func testInstalledOnlyPolicyRejectsUnavailableModelAndUnwindsInput() async throws {
        let input = TestSpeechInput()
        await input.setCapabilities(SpeechCapabilities(
            locale: .current,
            isSupported: true,
            supportsOnDevice: false
        ))
        let coordinator = VoiceCoordinator(input: input, output: TestSpeechOutput())
        let events = await coordinator.events()

        do {
            try await coordinator.startListening()
            XCTFail("Expected installed-only policy failure")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .onDeviceRecognitionUnavailable(.current))
        }

        let startCount = await input.startCount
        let cancelCount = await input.cancelCount
        let isActive = await input.isActive
        let state = await coordinator.state
        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(cancelCount, 1)
        XCTAssertFalse(isActive)
        XCTAssertEqual(state, .idle)
        let terminal = await events.first(where: { event in
            if case .listeningFinished = event { return true }
            return false
        })
        XCTAssertEqual(terminal, .listeningFinished(.failed(.onDeviceRecognitionUnavailable(.current))))
    }

    func testStreamFailureCancelsInputAndReturnsToIdle() async throws {
        let input = TestSpeechInput()
        let coordinator = VoiceCoordinator(input: input, output: TestSpeechOutput())
        let events = await coordinator.events()

        try await coordinator.startListening()
        await input.fail(VoiceError.audioSessionUnavailable("route lost"))
        await waitUntil { await coordinator.state == .idle }

        let cancelCount = await input.cancelCount
        let isActive = await input.isActive
        XCTAssertEqual(cancelCount, 1)
        XCTAssertFalse(isActive)
        let terminal = await events.first(where: { event in
            if case .listeningFinished = event { return true }
            return false
        })
        XCTAssertEqual(terminal, .listeningFinished(.failed(.audioSessionUnavailable("route lost"))))
    }

    func testOversizedProviderTranscriptFailsClosedBeforeFinalization() async throws {
        let input = TestSpeechInput()
        let coordinator = VoiceCoordinator(input: input, output: TestSpeechOutput())
        let events = await coordinator.events()

        try await coordinator.startListening()
        await input.send(TranscriptUpdate(
            text: String(repeating: "x", count: VoiceTextLimits.maximumUTF16Length + 1),
            isFinal: false
        ))
        await waitUntil { await coordinator.state == .idle }

        let terminal = await events.first(where: { event in
            if case .listeningFinished = event { return true }
            return false
        })
        XCTAssertEqual(
            terminal,
            .listeningFinished(.failed(.textTooLong(
                maximumUTF16Length: VoiceTextLimits.maximumUTF16Length
            )))
        )
    }

    func testEventSubscriptionsEvictTheOldestWhenTheBoundIsReached() async {
        let coordinator = VoiceCoordinator(input: TestSpeechInput(), output: TestSpeechOutput())
        var streams: [AsyncStream<VoiceEvent>] = []
        for _ in 0...VoiceCoordinator.maximumEventSubscribers {
            streams.append(await coordinator.events())
        }

        let firstEnded = await Task {
            for await _ in streams[0] {}
            return true
        }.value
        XCTAssertTrue(firstEnded)
    }

    func testUnexpectedNormalInputStreamCompletionProducesAFailureTerminal() async throws {
        let input = TestSpeechInput()
        let coordinator = VoiceCoordinator(input: input, output: TestSpeechOutput())
        let events = await coordinator.events()

        try await coordinator.startListening()
        await input.finishStreamNormally()
        await waitUntil { await coordinator.state == .idle }

        let terminal = await events.first(where: { event in
            if case .listeningFinished = event { return true }
            return false
        })
        XCTAssertEqual(
            terminal,
            .listeningFinished(.failed(.underlying("Speech input ended before finalization.")))
        )
    }

    func testInterruptionHasItsOwnTerminalReasonWithoutFailureEvent() async throws {
        let input = TestSpeechInput()
        let coordinator = VoiceCoordinator(input: input, output: TestSpeechOutput())
        let events = await coordinator.events()

        try await coordinator.startListening()
        await input.fail(VoiceError.interrupted("phone call"))
        await waitUntil { await coordinator.state == .idle }

        let terminal = await events.first(where: { event in
            if case .listeningFinished = event { return true }
            return false
        })
        XCTAssertEqual(terminal, .listeningFinished(.interrupted(.systemInterruption)))
    }

    func testFinishFailureCancelsInputAndRecoversFromFinalizing() async throws {
        let input = TestSpeechInput()
        await input.setStopError(.audioSessionUnavailable("finalization failed"))
        let coordinator = VoiceCoordinator(input: input, output: TestSpeechOutput())

        try await coordinator.startListening()
        do {
            _ = try await coordinator.endListening()
            XCTFail("Expected finalization failure")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .audioSessionUnavailable("finalization failed"))
        }

        let cancelCount = await input.cancelCount
        let isActive = await input.isActive
        let state = await coordinator.state
        XCTAssertEqual(cancelCount, 1)
        XCTAssertFalse(isActive)
        XCTAssertEqual(state, .idle)

        // Recovery is real, not just a state reset: a new turn can start.
        await input.setStopError(nil)
        try await coordinator.startListening()
        await coordinator.cancelListening()
    }

    func testConcurrentStartsHaveOneWinnerBeforeAsyncStartupCompletes() async throws {
        let input = TestSpeechInput()
        await input.setBlocksStart(true)
        let coordinator = VoiceCoordinator(input: input, output: TestSpeechOutput())

        let first = Task { try await coordinator.startListening() }
        await waitUntil { await input.startCount == 1 }

        do {
            try await coordinator.startListening()
            XCTFail("Expected the reserved operation to reject a concurrent start")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .invalidState("A voice operation is already active."))
        }

        await input.releaseStart()
        try await first.value
        await coordinator.cancelListening()
        let startCount = await input.startCount
        XCTAssertEqual(startCount, 1)
    }

    func testExternalCancellationSuppressesAStaleProviderStartupError() async throws {
        let input = TestSpeechInput()
        await input.setBlocksStart(true)
        await input.setStartError(.audioSessionUnavailable("stale provider error"))
        let coordinator = VoiceCoordinator(input: input, output: TestSpeechOutput())

        let starting = Task { try await coordinator.startListening() }
        await waitUntil { await input.startCount == 1 }
        let cancelling = Task { await coordinator.cancelListening() }
        await Task.yield()
        await input.releaseStart()
        await cancelling.value

        do {
            try await starting.value
            XCTFail("cancelled startup unexpectedly succeeded")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .cancelled)
        }
        let state = await coordinator.state
        XCTAssertEqual(state, .idle)
    }

    func testConcurrentSpeechIsRejectedAndStopCancelsOnlyTheWinner() async throws {
        let input = TestSpeechInput()
        let output = TestSpeechOutput()
        await output.setBlocksSpeech(true)
        let coordinator = VoiceCoordinator(input: input, output: output)

        let first = Task { try await coordinator.speak("first") }
        await output.waitUntilStarted()

        do {
            try await coordinator.speak("second")
            XCTFail("Expected the reserved speech operation to reject a concurrent speak")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .invalidState("A voice operation is already active."))
        }

        await coordinator.stopSpeaking()
        do {
            try await first.value
            XCTFail("Expected the first speech operation to be cancelled")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .cancelled)
        } catch is CancellationError {
            // Task cancellation may win before the coordinator normalizes it.
        }
        let spokenTexts = await output.spokenTexts
        let state = await coordinator.state
        XCTAssertEqual(spokenTexts, ["first"])
        XCTAssertEqual(state, .idle)
    }

    func testPreCancelledSpeechNeverReentersTheOutputProvider() async throws {
        let input = TestSpeechInput()
        let output = TestSpeechOutput()
        let coordinator = VoiceCoordinator(input: input, output: output)

        let task = Task { try await coordinator.speak("should not start") }
        task.cancel()

        do {
            try await task.value
            XCTFail("pre-cancelled speech unexpectedly succeeded")
        } catch let error as VoiceError {
            XCTAssertEqual(error, .cancelled)
        } catch is CancellationError {
            // Task cancellation may win before the coordinator normalizes it.
        }
        let startCount = await output.spokenTexts.count
        let state = await coordinator.state
        XCTAssertEqual(startCount, 0)
        XCTAssertEqual(state, .idle)
    }

    func testUnreleasedSpeechResourcesKeepTheCoordinatorFailedUntilCloseRetry() async throws {
        let input = TestSpeechInput()
        let output = LateUnreleasedSpeechOutput()
        let coordinator = VoiceCoordinator(input: input, output: output)

        do {
            try await coordinator.speak("resource failure")
            XCTFail("a provider that retains audio resources must fail the speech turn")
        } catch let error as VoiceError {
            XCTAssertEqual(
                error,
                .speechSynthesisUnavailable(
                    "Speech audio resources were not released; retry close() before starting another turn."
                )
            )
        }

        let failedState = await coordinator.state
        let closeBeforeRelease = await coordinator.closeAndReport()
        let stillFailedState = await coordinator.state
        XCTAssertEqual(failedState, .failed)
        XCTAssertFalse(closeBeforeRelease)
        XCTAssertEqual(stillFailedState, .failed)

        await output.setReleased(true)
        let closeAfterRelease = await coordinator.closeAndReport()
        let recoveredState = await coordinator.state
        let startCount = await input.startCount
        XCTAssertTrue(closeAfterRelease)
        XCTAssertEqual(recoveredState, .idle)
        XCTAssertEqual(startCount, 0)
    }

    func testSuccessfulListeningEmitsOneTerminalReason() async throws {
        let input = TestSpeechInput()
        let coordinator = VoiceCoordinator(input: input, output: TestSpeechOutput())
        let events = await coordinator.events()

        try await coordinator.startListening()
        _ = try await coordinator.endListening()

        let terminal = await events.first(where: { event in
            if case .listeningFinished = event { return true }
            return false
        })
        XCTAssertEqual(terminal, .listeningFinished(.completed))
    }

    func testCancelListeningEmitsCancelledTerminalReasonAndIsIdempotent() async throws {
        let input = TestSpeechInput()
        let coordinator = VoiceCoordinator(input: input, output: TestSpeechOutput())
        let events = await coordinator.events()

        try await coordinator.startListening()
        await coordinator.cancelListening()
        await coordinator.cancelListening()

        let terminal = await events.first(where: { event in
            if case .listeningFinished = event { return true }
            return false
        })
        let cancelCount = await input.cancelCount
        XCTAssertEqual(terminal, .listeningFinished(.cancelled))
        XCTAssertEqual(cancelCount, 1)
    }
}

private extension XCTestCase {
    func waitUntil(
        timeout: UInt64 = 1_000_000_000,
        condition: @escaping @Sendable () async -> Bool
    ) async {
        let deadline = ContinuousClock.now + .nanoseconds(Int64(timeout))
        while !(await condition()) && ContinuousClock.now < deadline {
            await Task.yield()
        }
        let satisfied = await condition()
        XCTAssertTrue(satisfied, "Timed out waiting for condition")
    }
}

private actor TestSpeechInput: SpeechInput {
    private var continuation: AsyncThrowingStream<TranscriptUpdate, Error>.Continuation?
    private var latest = ""
    private var capabilitiesValue = SpeechCapabilities(locale: .current, isSupported: true, supportsOnDevice: true)
    private var microphonePermission = true
    private var authorization: SpeechAuthorization = .authorized
    private var modelInstallationIsAvailable = false
    private var stopError: VoiceError?
    private var blocksStart = false
    private var startError: VoiceError?
    private var startWaiter: CheckedContinuation<Void, Never>?
    private(set) var startCount = 0
    private(set) var cancelCount = 0
    private(set) var isActive = false
    private(set) var lastConfiguration: RecognitionConfiguration?

    func setCapabilities(_ value: SpeechCapabilities) { capabilitiesValue = value }
    func setModelInstallationAvailable(_ value: Bool) {
        modelInstallationIsAvailable = value
    }
    func setStopError(_ value: VoiceError?) { stopError = value }
    func setBlocksStart(_ value: Bool) { blocksStart = value }
    func setStartError(_ value: VoiceError?) { startError = value }
    func releaseStart() { startWaiter?.resume(); startWaiter = nil }

    func capabilities(for locale: Locale) async -> SpeechCapabilities {
        SpeechCapabilities(
            locale: locale,
            isSupported: capabilitiesValue.isSupported,
            supportsOnDevice: capabilitiesValue.supportsOnDevice,
            reason: capabilitiesValue.reason
        )
    }

    func modelInstallationAvailable(for locale: Locale) async -> Bool {
        modelInstallationIsAvailable
    }

    func requestMicrophonePermission() async -> Bool { microphonePermission }
    func requestAuthorization() async -> SpeechAuthorization { authorization }

    func start(configuration: RecognitionConfiguration) async throws -> AsyncThrowingStream<TranscriptUpdate, Error> {
        startCount += 1
        lastConfiguration = configuration
        if blocksStart {
            await withCheckedContinuation { startWaiter = $0 }
        }
        if let startError { throw startError }
        isActive = true
        return AsyncThrowingStream { continuation in self.continuation = continuation }
    }

    func send(_ update: TranscriptUpdate) {
        latest = update.text
        continuation?.yield(update)
    }

    func fail(_ error: Error) {
        continuation?.finish(throwing: error)
        continuation = nil
    }

    func finishStreamNormally() {
        continuation?.finish()
        continuation = nil
    }

    func stop() async throws -> String {
        if let stopError { throw stopError }
        isActive = false
        continuation?.finish()
        continuation = nil
        return latest
    }

    func cancel() async {
        guard isActive else { return }
        cancelCount += 1
        isActive = false
        continuation?.finish()
        continuation = nil
    }
}

private actor TestSpeechOutput: SpeechOutput {
    private(set) var spokenTexts: [String] = []
    private var blocksSpeech = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var completion: CheckedContinuation<Void, Error>?
    private var started = false

    func setBlocksSpeech(_ value: Bool) { blocksSpeech = value }
    func availableVoices(for locale: Locale) async -> [SpeechVoice] { [] }

    func speak(_ text: String, configuration: SpeechConfiguration) async throws {
        spokenTexts.append(text)
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        guard blocksSpeech else { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { completion = $0 }
        } onCancel: {
            Task { await self.cancelPendingSpeech() }
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func pause() async {}
    func resume() async {}

    func stop() async { cancelPendingSpeech() }

    private func cancelPendingSpeech() {
        completion?.resume(throwing: VoiceError.cancelled)
        completion = nil
    }
}

private actor LateUnreleasedSpeechOutput: SpeechOutput {
    private var released = true

    func availableVoices(for locale: Locale) async -> [SpeechVoice] { [] }

    func speak(_ text: String, configuration: SpeechConfiguration) async throws {
        released = false
    }

    func pause() async {}
    func resume() async {}
    func stop() async {}

    func resourcesAreReleased() async -> Bool { released }

    func setReleased(_ value: Bool) { released = value }
}
